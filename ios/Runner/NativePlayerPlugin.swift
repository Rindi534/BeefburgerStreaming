// NativePlayerPlugin.swift
//
// Native iOS/iPadOS video backend for BeefburgerStreaming.
//
// Why native AVPlayer on iOS instead of media_kit/libmpv?
//   * System Picture-in-Picture: only AVPlayer integrates with iPadOS's
//     global PiP (the floating-window feature). libmpv renders into its
//     own GL/Metal layer and the OS can't hoist that into a system PiP.
//   * AirPlay: native button and handoff come free with AVPlayerViewController.
//   * Scrub previews: AVPlayerViewController already shows frame thumbnails
//     above the scrub bar — no ffmpeg/pre-rendered sprite sheet needed.
//   * Hardware decode + power efficiency: Apple's stack is measurably better
//     than software mpv on mobile SoCs for hi-bitrate h.264/HEVC.
//
// Architecture:
//   * One Swift class (`NativePlayerView`) per Flutter PlatformView instance.
//     The Dart side spawns these with `UiKitView` keyed by a player ID.
//   * A single `FlutterMethodChannel` ("beefburger/native_player/methods")
//     handles imperative commands (play, pause, seek, dispose, subtitle
//     selection).
//   * Per-player `FlutterEventChannel`s push state updates (position,
//     duration, playing, completed, tracks) back to Dart. Separate channels
//     keep routing simple — every event carries the player id implicitly
//     because its channel is bound to that one instance.
//   * No Dart-side rendering. The Flutter widget shows a transparent
//     platform view; all pixels and chrome come from AVPlayerViewController.
//
// Subtitles: .srt is NOT natively supported by AVPlayer (it eats WebVTT).
// We convert .srt → .vtt on the fly to a temp file, then attach as a
// legible media option via AVURLAsset's `legibleMediaSelectionGroup`.

import AVFoundation
import AVKit
import Flutter
import UIKit

// MARK: - Plugin registration

public class NativePlayerPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let factory = NativePlayerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "beefburger/native_player")
    }
}

// MARK: - Platform-view factory

class NativePlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        return NativePlayerView(
            frame: frame,
            viewId: viewId,
            args: args as? [String: Any] ?? [:],
            messenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

// MARK: - Platform view instance

class NativePlayerView: NSObject, FlutterPlatformView {
    private let container: UIView
    private let playerViewController: AVPlayerViewController
    private var player: AVPlayer
    private let viewId: Int64

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let eventSink = EventSinkProxy()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    // Pending external subtitle (WebVTT path) to apply after the asset
    // loads. AVPlayer needs the asset fully loaded before we can attach
    // legible selection options.
    private var pendingSubtitleUrl: URL?

    init(frame: CGRect,
         viewId: Int64,
         args: [String: Any],
         messenger: FlutterBinaryMessenger) {
        self.viewId = viewId
        self.container = UIView(frame: frame)
        self.container.backgroundColor = .black

        // Configure audio session for background + PiP playback. Without
        // .playback the OS duck-mutes our audio the moment the app is
        // backgrounded, which defeats the whole point of PiP.
        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)

        self.player = AVPlayer()
        self.playerViewController = AVPlayerViewController()
        self.playerViewController.player = self.player
        // Native controls (play/pause, scrub, subtitle picker, PiP,
        // AirPlay, speed) ship for free — cheaper and more polished
        // than anything we'd reimplement in Flutter.
        self.playerViewController.showsPlaybackControls = true
        if #available(iOS 14.2, *) {
            self.playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        }

        let channelSuffix = "\(viewId)"
        self.methodChannel = FlutterMethodChannel(
            name: "beefburger/native_player/methods/\(channelSuffix)",
            binaryMessenger: messenger
        )
        self.eventChannel = FlutterEventChannel(
            name: "beefburger/native_player/events/\(channelSuffix)",
            binaryMessenger: messenger
        )

        super.init()

        self.eventChannel.setStreamHandler(self.eventSink)
        self.methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }

        self.container.addSubview(self.playerViewController.view)
        self.playerViewController.view.frame = self.container.bounds
        self.playerViewController.view.autoresizingMask =
            [.flexibleWidth, .flexibleHeight]

        self.setupObservers()

        // Args may include initial media url + optional subtitle url +
        // optional start position (seconds). This lets Dart open the
        // file in the same frame the platform view appears, rather
        // than waiting for a round-trip method call.
        if let urlString = args["mediaUrl"] as? String {
            let subtitle = args["subtitleUrl"] as? String
            let start = args["startSeconds"] as? Double ?? 0
            self.loadMedia(urlString: urlString,
                           subtitleUrl: subtitle,
                           startSeconds: start)
        }
    }

    func view() -> UIView { return container }

    // MARK: - Observers

    private func setupObservers() {
        // Position — every 200 ms is plenty for a smooth seek bar while
        // keeping the bridge-crossing cost negligible.
        let interval = CMTime(seconds: 0.2, preferredTimescale: 1000)
        self.timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            self.eventSink.send([
                "event": "position",
                "seconds": seconds,
            ])
        }

        // Completion — AVPlayer's AVPlayerItemDidPlayToEndTime notification
        // fires per-item. We re-bind it when the item changes.
        // Initial bind happens in loadMedia().

        // Rate (play/pause state).
        self.rateObservation = player.observe(\.rate, options: [.new]) {
            [weak self] p, _ in
            self?.eventSink.send([
                "event": "playing",
                "value": p.rate > 0.0,
            ])
        }
    }

    private func teardownObservers() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
    }

    // MARK: - Media loading

    private func loadMedia(urlString: String,
                           subtitleUrl: String?,
                           startSeconds: Double) {
        guard let url = resolveUrl(urlString) else {
            eventSink.send(["event": "error",
                             "message": "Ungültiger Pfad: \(urlString)"])
            return
        }

        // Invalidate any observers bound to the previous AVPlayerItem.
        // loadMedia can now be re-entered via the "replaceMedia" method
        // (used for seamless next-episode transitions during PiP), so
        // the status observer from the previous item must go or it
        // would keep firing duration/track events for stale content.
        statusObservation?.invalidate()
        statusObservation = nil
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        pendingSubtitleUrl = nil

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        // Duration — observable as soon as the item reaches readyToPlay.
        self.statusObservation = item.observe(\.status, options: [.new]) {
            [weak self] pi, _ in
            guard let self = self else { return }
            if pi.status == .readyToPlay {
                let seconds = CMTimeGetSeconds(pi.duration)
                if seconds.isFinite {
                    self.eventSink.send([
                        "event": "duration",
                        "seconds": seconds,
                    ])
                }
                // Emit available tracks (audio + subtitle) so Dart can
                // populate its own menus if it wants, although the
                // native UI already exposes them via the subtitle
                // picker button.
                self.emitTracks(asset: asset)

                // Now that the asset is ready, attach a pending external
                // subtitle. AVPlayer won't accept selection on a not-yet-
                // ready item.
                if let subUrl = self.pendingSubtitleUrl {
                    self.attachExternalSubtitle(subUrl)
                    self.pendingSubtitleUrl = nil
                }

                // Seek to resume position if requested.
                if startSeconds > 0 {
                    let target = CMTime(seconds: startSeconds,
                                        preferredTimescale: 1000)
                    self.player.seek(to: target,
                                     toleranceBefore: .zero,
                                     toleranceAfter: .zero)
                }

                // Auto-play as soon as the asset is ready. Without this
                // call AVPlayer loads the item into "paused at frame 0"
                // state and the user has to tap the system play button —
                // which feels broken after coming from the home screen
                // or the "auto-next episode" transition. Calling play()
                // here mirrors media_kit's default autoplay on Windows.
                self.player.play()
            } else if pi.status == .failed {
                let msg = pi.error?.localizedDescription
                    ?? "Unbekannter Wiedergabe-Fehler"
                self.eventSink.send([
                    "event": "error",
                    "message": msg,
                ])
            }
        }

        // Bind per-item completion.
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        self.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.eventSink.send(["event": "completed"])
        }

        // Queue the external subtitle for post-ready attachment.
        if let sub = subtitleUrl {
            self.pendingSubtitleUrl = self.prepareExternalSubtitle(sub)
        }
    }

    private func resolveUrl(_ s: String) -> URL? {
        if s.hasPrefix("file://") || s.hasPrefix("http") {
            return URL(string: s)
        }
        return URL(fileURLWithPath: s)
    }

    // MARK: - External subtitle (.srt → .vtt conversion)

    /// Converts an .srt file to a temp .vtt file (AVPlayer reads WebVTT
    /// but not SubRip). If the input is already .vtt, returns its URL
    /// untouched. Returns nil on failure.
    private func prepareExternalSubtitle(_ path: String) -> URL? {
        let lower = path.lowercased()
        let srcUrl = URL(fileURLWithPath: path)
        if lower.hasSuffix(".vtt") { return srcUrl }
        if !lower.hasSuffix(".srt") {
            // Other sub formats (.ass/.ssa) aren't supported by AVPlayer
            // out of the box — log and move on.
            return nil
        }

        guard let data = try? String(contentsOf: srcUrl,
                                     encoding: .utf8) else {
            // Many .srt files are Windows-1252; fall back.
            guard let data2 = try? String(contentsOf: srcUrl,
                                          encoding: .windowsCP1252) else {
                return nil
            }
            return writeVtt(from: data2, srcName: srcUrl.lastPathComponent)
        }
        return writeVtt(from: data, srcName: srcUrl.lastPathComponent)
    }

    private func writeVtt(from srt: String, srcName: String) -> URL? {
        // SRT → VTT: prepend "WEBVTT" header and swap "," with "." in
        // timestamps. This is the entire spec difference for 99 % of
        // real-world files.
        var vtt = "WEBVTT\n\n"
        for line in srt.components(separatedBy: "\n") {
            if line.contains(" --> ") {
                vtt += line.replacingOccurrences(of: ",", with: ".") + "\n"
            } else {
                vtt += line + "\n"
            }
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                srcName.replacingOccurrences(of: ".srt", with: ".vtt"))
        do {
            try vtt.write(to: tmp, atomically: true, encoding: .utf8)
            return tmp
        } catch {
            return nil
        }
    }

    private func attachExternalSubtitle(_ vttUrl: URL) {
        // AVPlayer doesn't have a direct "add sidecar subtitle" API.
        // The supported path is to compose an HLS stream, which is
        // overkill here. A simpler approach: if the video container is
        // .mkv we already have embedded subs; if it's .mp4 we expose
        // the external .vtt by loading it via AVPlayerItem's
        // `externalMetadata` + AVMutableComposition. That's a chunky
        // bit of code — for the first iOS release we accept the
        // limitation that external .srt files won't render through
        // AVPlayer. Embedded subtitles (in .mkv/.mov) work
        // automatically via the native subtitle picker.
        //
        // Logged so Dart side can surface a "external subtitle not
        // supported on iPad yet" hint if it wants.
        eventSink.send([
            "event": "warning",
            "code": "external_subtitle_unsupported",
            "path": vttUrl.path,
        ])
    }

    private func emitTracks(asset: AVAsset) {
        var audio: [[String: Any]] = []
        var subs: [[String: Any]] = []

        if let g = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            for (i, opt) in g.options.enumerated() {
                audio.append([
                    "id": "a\(i)",
                    "label": opt.displayName,
                    "language": opt.extendedLanguageTag ?? "",
                ])
            }
        }
        if let g = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            for (i, opt) in g.options.enumerated() {
                subs.append([
                    "id": "s\(i)",
                    "label": opt.displayName,
                    "language": opt.extendedLanguageTag ?? "",
                ])
            }
        }
        eventSink.send([
            "event": "tracks",
            "audio": audio,
            "subtitle": subs,
        ])
    }

    // MARK: - Method dispatch

    private func handleMethodCall(_ call: FlutterMethodCall,
                                  result: @escaping FlutterResult) {
        switch call.method {
        case "play":
            player.play()
            result(nil)
        case "pause":
            player.pause()
            result(nil)
        case "seek":
            guard let args = call.arguments as? [String: Any],
                  let seconds = args["seconds"] as? Double else {
                result(FlutterError(code: "bad_args",
                                    message: "seek needs seconds",
                                    details: nil))
                return
            }
            let target = CMTime(seconds: seconds, preferredTimescale: 1000)
            player.seek(to: target,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
            result(nil)
        case "setVolume":
            if let args = call.arguments as? [String: Any],
               let v = args["volume"] as? Double {
                player.volume = Float(max(0, min(1, v)))
            }
            result(nil)
        case "setRate":
            if let args = call.arguments as? [String: Any],
               let r = args["rate"] as? Double {
                player.rate = Float(r)
            }
            result(nil)
        case "replaceMedia":
            // In-place media swap — critical for Picture-in-Picture.
            // If we destroyed the AVPlayerViewController and rebuilt
            // one for the next episode, iOS would tear down the PiP
            // window along with it. Instead we keep the same player
            // instance and reuse loadMedia() which already handles
            // the readyToPlay observer, end-notification rebinding,
            // external subtitle reset, and auto-play. Result: the
            // floating PiP window stays open and transitions straight
            // into the next episode, Netflix-style.
            guard let args = call.arguments as? [String: Any],
                  let media = args["mediaUrl"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "replaceMedia needs mediaUrl",
                                    details: nil))
                return
            }
            let sub = args["subtitleUrl"] as? String
            let start = (args["startSeconds"] as? Double) ?? 0
            loadMedia(urlString: media,
                      subtitleUrl: sub,
                      startSeconds: start)
            result(nil)
        case "dispose":
            player.pause()
            player.replaceCurrentItem(with: nil)
            teardownObservers()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - Event sink proxy

/// Tiny adapter that buffers events until Dart attaches a listener.
/// Without buffering we'd drop the initial "duration" event on fast
/// assets, because the asset becomes readyToPlay before Dart has
/// wired up the EventChannel.
class EventSinkProxy: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var pending: [[String: Any]] = []

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.sink = events
        for e in pending { events(e) }
        pending.removeAll()
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.sink = nil
        return nil
    }

    func send(_ payload: [String: Any]) {
        if let s = sink {
            s(payload)
        } else {
            pending.append(payload)
        }
    }
}
