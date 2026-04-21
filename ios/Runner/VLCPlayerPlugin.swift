// VLCPlayerPlugin.swift
//
// Zweiter Video-Backend neben NativePlayerPlugin.swift. Zuständig für
// Container/Codec-Kombis, die AVPlayer nicht nativ lesen kann — .mkv,
// .avi, .iso, .wmv, .flv. MobileVLCKit bringt seinen eigenen Decoder
// (libavcodec) mit, UND hat seit Version 3.5 PiP-Support über die
// AVPictureInPictureController.ContentSource-API eingebaut — das ist
// der Hauptgrund warum wir VLCKit nehmen statt reinem libmpv: die
// ganze CMSampleBuffer-Pipeline mussten wir nicht selbst bauen.
//
// Wichtig: Dart-Seite bleibt identisch zum NativePlayerPlugin-Interface.
// Gleiche MethodChannel-Namen ("play", "pause", "seek", "replaceMedia",
// "dispose"), gleiche Event-Payloads ("position", "duration",
// "playing", "completed", "error"). So kann der IOSPlayerScreen beide
// Backends mit derselben Controller-Abstraktion ansprechen — nur der
// viewType-String bei UiKitView entscheidet, welches Plugin Flutter
// erzeugt. Session 2 baut PiP ein; diese Session liefert reines
// Playback.

import Flutter
import MobileVLCKit
import UIKit
import AVKit

// MARK: - Plugin registration

public class VLCPlayerPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let factory = VLCPlayerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: "beefburger/vlc_player")
    }
}

// MARK: - Platform-view factory

class VLCPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        return VLCPlayerView(
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

class VLCPlayerView: NSObject, FlutterPlatformView {
    private let container: UIView
    private let videoView: UIView
    private let mediaPlayer: VLCMediaPlayer
    private let viewId: Int64

    private let methodChannel: FlutterMethodChannel
    private let eventChannel: FlutterEventChannel
    private let eventSink = VLCEventSinkProxy()

    // VLC emittiert "nowPlaying"-Events hochfrequent; wir drosseln
    // position-Updates auf 5 Hz, analog zum 200 ms Intervall im
    // NativePlayerPlugin. Ohne Drosselung fluten wir den Dart-
    // EventChannel mit ~30 Pro-Sekunde-Updates.
    private var lastPositionEmit: TimeInterval = 0

    // Wir merken uns die angefragte Resume-Position bis zum Zeitpunkt
    // an dem VLC bereit ist zu springen. VLCMediaPlayer akzeptiert
    // seek erst nach dem "Playing"-State (vorher ist die Media-Länge
    // noch unbekannt).
    private var pendingStartSeconds: Double = 0
    private var didApplyStartSeek: Bool = false

    // PiP-Koordinator — opt-in konstruiert, nur auf iOS 15+, weil die
    // ContentSource(sampleBufferDisplayLayer:...)-API erst dort
    // existiert. Unter iOS 15 gibt's auf dem VLC-Pfad kein PiP; der
    // AVPlayer-Pfad für .mp4 bleibt davon unberührt.
    private var pipCoordinator: AnyObject?

    init(frame: CGRect,
         viewId: Int64,
         args: [String: Any],
         messenger: FlutterBinaryMessenger) {
        self.viewId = viewId
        self.container = UIView(frame: frame)
        self.container.backgroundColor = .black

        self.videoView = UIView(frame: frame)
        self.videoView.backgroundColor = .black
        self.videoView.contentMode = .scaleAspectFit

        self.mediaPlayer = VLCMediaPlayer()

        let channelSuffix = "\(viewId)"
        self.methodChannel = FlutterMethodChannel(
            name: "beefburger/vlc_player/methods/\(channelSuffix)",
            binaryMessenger: messenger
        )
        self.eventChannel = FlutterEventChannel(
            name: "beefburger/vlc_player/events/\(channelSuffix)",
            binaryMessenger: messenger
        )

        super.init()

        self.mediaPlayer.drawable = self.videoView
        self.mediaPlayer.delegate = self

        self.eventChannel.setStreamHandler(self.eventSink)
        self.methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }

        self.container.addSubview(self.videoView)
        self.videoView.frame = self.container.bounds
        self.videoView.autoresizingMask =
            [.flexibleWidth, .flexibleHeight]

        // PiP-Koordinator attachen (iOS 15+). Die Sample-Buffer-Layer
        // wird in den Container gehängt, nicht in die VLC-Drawable-View
        // — VLCKit könnte sonst die Sublayers beim OpenGL-Resize kaputt
        // machen. Die Layer ist sichtbar aber 1×1 Pixel + Opacity 0,
        // damit iOS sie in der Hierarchie findet (PiP verlangt das).
        if #available(iOS 15.0, *) {
            let coord = VLCPiPCoordinator()
            coord.attach(to: self.mediaPlayer, hostView: self.container)
            coord.onPiPStateChanged = { [weak self] active in
                self?.eventSink.send([
                    "event": "pipState",
                    "value": active,
                ])
            }
            coord.onPiPAvailabilityChanged = { [weak self] possible in
                self?.eventSink.send([
                    "event": "pipAvailability",
                    "value": possible,
                ])
            }
            self.pipCoordinator = coord
        }

        // Optional: Initial-Media in creationParams. Anders als beim
        // AVPlayer-Plugin starten wir hier NICHT direkt autoplay im
        // Konstruktor — MobileVLCKit braucht einen Moment um die
        // drawable-View zu mounten, und ein zu früher play()-Call
        // produziert gelegentlich einen leeren schwarzen Frame. Der
        // Auto-Play-Aufruf passiert stattdessen in loadMedia() selbst,
        // direkt nach dem Attach.
        if let urlString = args["mediaUrl"] as? String {
            let subtitle = args["subtitleUrl"] as? String
            let start = args["startSeconds"] as? Double ?? 0
            self.loadMedia(urlString: urlString,
                           subtitleUrl: subtitle,
                           startSeconds: start)
        }
    }

    func view() -> UIView { return container }

    // MARK: - Media loading

    private func loadMedia(urlString: String,
                           subtitleUrl: String?,
                           startSeconds: Double) {
        guard let url = resolveUrl(urlString) else {
            eventSink.send(["event": "error",
                            "message": "Ungültiger Pfad: \(urlString)"])
            return
        }

        // Stop + neue Media. VLCMediaPlayer behandelt das korrekt auch
        // wenn wir mitten in einer laufenden Wiedergabe sind — wird
        // für den "nächste Episode inline tauschen"-Pfad gebraucht.
        mediaPlayer.stop()

        let media = VLCMedia(url: url)

        // Hardware-Decode via VideoToolbox explizit einschalten.
        // MobileVLCKit lässt das per default OFF weil Simulator es
        // nicht kann — auf echten Geräten ist's ein massiver Gewinn
        // bei 1080p+ und HEVC.
        media.addOption(":codec=videotoolbox")
        // Netzwerk-Caching-Buffer (ms). Für lokale Dateien fast
        // irrelevant, Default passt.
        media.addOption(":file-caching=1500")

        didApplyStartSeek = false
        pendingStartSeconds = startSeconds

        mediaPlayer.media = media

        // Externe Subtitle — VLC kann .srt/.ass/.vtt out-of-the-box.
        // Das ist ein harter Gewinn gegenüber dem AVPlayer-Pfad, wo
        // .srt nicht direkt geht.
        if let sub = subtitleUrl, !sub.isEmpty {
            let subUrl = URL(fileURLWithPath: sub)
            // addPlaybackSlave existiert seit VLCKit 3.x. false bei
            // "autoPlay" damit VLC nicht ungefragt die Slave-Spur
            // erzwingt — wir lassen den User in der UI wählen.
            mediaPlayer.addPlaybackSlave(
                subUrl, type: .subtitle, enforce: false)
        }

        mediaPlayer.play()
    }

    private func resolveUrl(_ s: String) -> URL? {
        if s.hasPrefix("file://") || s.hasPrefix("http") {
            return URL(string: s)
        }
        return URL(fileURLWithPath: s)
    }

    // MARK: - Method dispatch

    private func handleMethodCall(_ call: FlutterMethodCall,
                                  result: @escaping FlutterResult) {
        switch call.method {
        case "play":
            mediaPlayer.play()
            result(nil)
        case "pause":
            mediaPlayer.pause()
            result(nil)
        case "seek":
            guard let args = call.arguments as? [String: Any],
                  let seconds = args["seconds"] as? Double else {
                result(FlutterError(code: "bad_args",
                                    message: "seek needs seconds",
                                    details: nil))
                return
            }
            seek(toSeconds: seconds)
            result(nil)
        case "setVolume":
            if let args = call.arguments as? [String: Any],
               let v = args["volume"] as? Double {
                // VLC-Range ist 0–200 (100 = unity, darüber Boost).
                // Wir clampen auf 0–1 und mappen auf 0–100.
                let clamped = max(0, min(1, v))
                mediaPlayer.audio?.volume = Int32(clamped * 100)
            }
            result(nil)
        case "setRate":
            if let args = call.arguments as? [String: Any],
               let r = args["rate"] as? Double {
                mediaPlayer.rate = Float(r)
            }
            result(nil)
        case "replaceMedia":
            // Für den PiP-in-place-Swap analog zum NativePlayer-Pfad.
            // Session 2 wird hier ggf. nochmal nachjustieren, wenn der
            // PiP-Controller hängt weil das Drawable kurz leer war.
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
        case "startPiP":
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator {
                coord.startPiP()
                result(nil)
            } else {
                result(FlutterError(code: "unavailable",
                                    message: "PiP braucht iOS 15+",
                                    details: nil))
            }
        case "stopPiP":
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator {
                coord.stopPiP()
            }
            result(nil)
        case "isPiPPossible":
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator {
                result(coord.isPiPPossible)
            } else {
                result(false)
            }
        case "dispose":
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator {
                coord.detach()
            }
            pipCoordinator = nil
            mediaPlayer.stop()
            mediaPlayer.delegate = nil
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func seek(toSeconds seconds: Double) {
        // VLCMediaPlayer.time ist in Millisekunden, als VLCTime.
        let target = VLCTime(int: Int32(seconds * 1000))
        mediaPlayer.time = target
    }

    // MARK: - Lifecycle

    deinit {
        mediaPlayer.stop()
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCPlayerView: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // VLC-States: opening, buffering, playing, paused, stopped,
        // ended, error, esAdded.
        switch mediaPlayer.state {
        case .playing:
            eventSink.send(["event": "playing", "value": true])

            // Erstmal nach "playing" ist media.length verlässlich.
            // Hier emittieren wir die Dauer + applyen eine pending
            // Resume-Position genau einmal.
            let durMs = mediaPlayer.media?.length.intValue ?? 0
            if durMs > 0 {
                eventSink.send([
                    "event": "duration",
                    "seconds": Double(durMs) / 1000.0,
                ])
            }
            if !didApplyStartSeek && pendingStartSeconds > 0 {
                didApplyStartSeek = true
                seek(toSeconds: pendingStartSeconds)
            }
        case .paused:
            eventSink.send(["event": "playing", "value": false])
        case .stopped:
            eventSink.send(["event": "playing", "value": false])
        case .ended:
            // VLC markiert das Ende über "ended" — wir mappen das auf
            // unser Standard-"completed"-Event, damit Dart den
            // identischen Auto-Next-Pfad laufen lassen kann wie beim
            // AVPlayer-Backend.
            eventSink.send(["event": "completed"])
        case .error:
            eventSink.send([
                "event": "error",
                "message": "VLC konnte die Datei nicht öffnen.",
            ])
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let now = Date().timeIntervalSince1970
        if now - lastPositionEmit < 0.2 { return }
        lastPositionEmit = now
        let ms = mediaPlayer.time.intValue
        if ms >= 0 {
            eventSink.send([
                "event": "position",
                "seconds": Double(ms) / 1000.0,
            ])
        }
    }
}

// MARK: - Event sink proxy

/// Buffert Events die anfallen bevor Dart den EventChannel attached
/// hat. Identisch zur NativePlayerPlugin-Variante (EventSinkProxy),
/// separat deklariert um keine Namenskollision zu riskieren und damit
/// jedes Plugin unabhängig geupdated werden kann.
class VLCEventSinkProxy: NSObject, FlutterStreamHandler {
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
