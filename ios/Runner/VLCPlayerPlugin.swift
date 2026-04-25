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
import AVFoundation

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

        // AVAudioSession auf "playback" fixieren und aktiv halten.
        // Ohne diesen Call deaktiviert iOS die Session nach ein paar
        // Sekunden Pause → beim Resume muss der AudioUnit erst wieder
        // hochfahren, was den hörbaren Audio-Lag ~400-600ms produziert
        // hat. Mit aktiver Session bleibt der AudioUnit primed.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: [])
            try session.setActive(true, options: [])
        } catch {
            // Nicht fatal — VLCKit fällt ohne unseren Setup auf den
            // default Session-Mode zurück. Der Audio-Lag ist dann
            // wieder da, aber Playback funktioniert.
        }

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

        // v1.5.18+48: PiP-Coordinator wieder an, nachdem der
        // NSException-Crash aus v1.5.15/16 über den Obj-C-Wrapper
        // VLCSafeSaveSnapshot + den hasVideoOut-Gate in
        // VLCPiPCoordinator.captureOneFrame entschärft wurde.
        // Siehe Crash-Report Runner 865BAEB7 (v1.5.16).
        let enablePiP = true
        if enablePiP, #available(iOS 15.0, *) {
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
        } else {
            // Kein PiP verfügbar → Dart-Seite proaktiv informieren,
            // sonst wartet der UI-Layer ewig auf ein pipAvailability-
            // Event und der Button bleibt grau (was akzeptabel ist,
            // aber so ist's explizit).
            self.eventSink.send([
                "event": "pipAvailability",
                "value": false,
            ])
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
                           startSeconds: Double,
                           keepVoutAlive: Bool = false) {
        guard let url = resolveUrl(urlString) else {
            eventSink.send(["event": "error",
                            "message": "Ungültiger Pfad: \(urlString)"])
            return
        }

        // VLCMediaPlayer's setter `media =` ruft intern bereits
        // libvlc_media_player_stop() auf bevor es die neue Media setzt.
        // Der explizite stop() hier davor war redundant UND kontra-
        // produktiv im PiP-Background-Pfad: er hat einen ZWEITEN
        // Teardown-Zyklus angestoßen, der mit dem play()-Restart
        // ganz unten gerace't ist. In Foreground egal, in Background
        // (PiP aktiv, App suspended bis auf Audio) hat das libvlc's
        // vout-Modul beim Hochfahren der neuen Folge tot gemacht
        // → Audio läuft, Video bleibt schwarz. (User-Bugreport v1.5.32.)
        //
        // `keepVoutAlive` markiert den Auto-Next-Pfad explizit; in
        // dem Fall verzichten wir auf den expliziten stop und vertrauen
        // dem Setter. Beim regulären Erst-Load (keepVoutAlive=false,
        // mediaPlayer hat noch keine Media) ist stop() ein No-op
        // sowieso — wir lassen ihn aber drin damit das Verhalten
        // identisch bleibt zu vorher und wir keinen Regression-
        // Vektor in den foreground-Erstaufruf einbauen.
        if !keepVoutAlive {
            mediaPlayer.stop()
        }

        let media = VLCMedia(url: url)

        // Datei-Caching-Buffer (ms). Niedrig halten (300ms) damit
        // Pause→Play-Resume nicht wartet bis der Buffer aufgefüllt ist
        // — das war die Haupt-Ursache für den hörbaren Audio-Lag nach
        // Pause in 1.5.25. Für lokale Dateien ist der Buffer ohnehin
        // trivial zu füllen (Disk-I/O ist schneller als Real-Time-
        // Playback), ein großer Vorrat bringt nichts außer Latenz.
        media.addOption(":file-caching=300")
        // ─── Subtitle stability ───────────────────────────────────────
        // User-Report v1.5.30: Untertitel "flackern — sind da und
        // verschwinden wieder". Ursachen-Analyse:
        //
        // 1. Dropped/skipped Frames: Wenn VLCKit unter Last Frames
        //    verwirft, wird das Subtitle-Overlay MIT verworfen — es
        //    erscheint erst beim nächsten "ganzen" Frame neu. Auf
        //    iPhones mit Metal-HW-Decode ist das unter 4K HEVC +
        //    externem .srt gut reproduzierbar. Fix: drop/skip deaktivieren.
        //
        // 2. `:sub-text-scale=100` forcierte v1.5.24+ einen Glyph-Cache-
        //    Reset bei jedem Subtitle-Track-Wechsel. 100 ist VLCs
        //    Default — die Option explizit zu setzen triggerte den Re-
        //    Render. Raus damit; VLC verwendet eh schon 100.
        //
        // 3. `:freetype-rel-fontsize` steuert die Subtitle-Schriftgröße
        //    relativ zur Videohöhe (kleiner = größer). 16 ist der
        //    Default-Wert, explizit gesetzt stabilisiert es aber den
        //    Font-Layout-Cache (VLC nutzt den Wert als Cache-Key und
        //    vermeidet Invalidierungen bei Auflösungswechseln der
        //    Rendering-Surface — relevant wenn PiP-Layer-Size anders
        //    ist als die Haupt-Drawable).
        media.addOption(":no-drop-late-frames")
        media.addOption(":no-skip-frames")
        media.addOption(":freetype-rel-fontsize=16")

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
            // v1.5.25 hatte einen Re-Seek-Workaround für Audio-Lag nach
            // Pause/Play — der hat aber einen sichtbaren Video-Hang
            // produziert. Wieder raus; der Re-Seek-Sprung war schlimmer
            // als der ursprüngliche Audio-Lag. Der verbleibende Lag
            // kommt von der AVAudioSession-Reaktivierung und braucht
            // einen anderen Fix (Audio-Session "keep-alive").
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
            // PiP-Koordinator VORHER informieren: flushed den stale
            // Frame der alten Folge aus der sampleBufferDisplayLayer
            // und öffnet ein 3s-Recovery-Fenster in dem der
            // hasVideoOut-Gate relaxiert ist. Ohne diesen Aufruf bleibt
            // PiP bei Auto-Next-Episode auf der letzten Szene der alten
            // Folge eingefroren während das neue Audio im Hintergrund
            // schon läuft (User-Bugreport v1.5.29).
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator {
                coord.mediaWillChange()
            }
            loadMedia(urlString: media,
                      subtitleUrl: sub,
                      startSeconds: start,
                      keepVoutAlive: true)
            // Drawable-Kick: nach dem stop/play-Zyklus von loadMedia
            // den drawable-Handle einmal lösen und wieder dranhängen.
            // Während PiP aktiv ist (App im Background) verpasst
            // MobileVLCKit sonst die Video-Output-Reinitialisierung —
            // Audio läuft, aber saveVideoSnapshotAt bekommt keine neuen
            // Frames ("Blackscreen bleibt", v1.5.30-Bugreport). Drei
            // gestaffelte Kicks über die ersten 2s decken unter-
            // schiedliche Decoder-Startup-Timings ab (manche Files
            // brauchen länger bis der erste Keyframe dekodiert ist).
            let kickTimes: [Double] = [0.3, 0.9, 1.8]
            for t in kickTimes {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self = self else { return }
                    // Nur kicken wenn noch kein Video-Output steht —
                    // sonst reißen wir einen gerade laufenden Decoder
                    // unnötig auf.
                    if !self.mediaPlayer.hasVideoOut {
                        let d = self.videoView
                        self.mediaPlayer.drawable = nil
                        self.mediaPlayer.drawable = d
                        NSLog("[VLCPlayer] drawable kicked at +\(t)s "
                            + "(hasVideoOut was false)")
                    }
                }
            }
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
        case "getAudioTracks":
            result(collectTracks(
                ids: mediaPlayer.audioTrackIndexes,
                names: mediaPlayer.audioTrackNames,
                current: mediaPlayer.currentAudioTrackIndex))
        case "getSubtitleTracks":
            result(collectTracks(
                ids: mediaPlayer.videoSubTitlesIndexes,
                names: mediaPlayer.videoSubTitlesNames,
                current: mediaPlayer.currentVideoSubTitleIndex))
        case "setAudioTrack":
            if let args = call.arguments as? [String: Any],
               let id = args["id"] as? Int {
                mediaPlayer.currentAudioTrackIndex = Int32(id)
            }
            result(nil)
        case "setSubtitleTrack":
            // id = -1 schaltet Untertitel aus (VLC-Konvention).
            if let args = call.arguments as? [String: Any],
               let id = args["id"] as? Int {
                mediaPlayer.currentVideoSubTitleIndex = Int32(id)
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

    /// Helper: baut eine Liste aus [{id, name, isCurrent}] Dicts aus den
    /// parallelen Arrays die MobileVLCKit zurückgibt (IDs und Namen
    /// kommen separat; die Reihenfolge zwischen den beiden Arrays
    /// korrespondiert). VLC-Konvention: id = -1 bedeutet
    /// "deaktiviert"/"keine Spur".
    private func collectTracks(ids: [Any]?,
                               names: [Any]?,
                               current: Int32) -> [[String: Any]] {
        guard let ids = ids, let names = names else { return [] }
        let count = min(ids.count, names.count)
        var out: [[String: Any]] = []
        for i in 0..<count {
            let idValue: Int
            if let n = ids[i] as? NSNumber {
                idValue = n.intValue
            } else {
                continue
            }
            let nameValue = (names[i] as? String) ?? "Track \(idValue)"
            out.append([
                "id": idValue,
                "name": nameValue,
                "isCurrent": idValue == Int(current),
            ])
        }
        return out
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
        // 30 Hz (33ms) — 10 Hz sah am Slider noch stufig aus, trotz
        // Tween-Interpolation auf Dart-Seite. 30 Hz ist dicht genug
        // an der Display-Refresh-Rate dass der Flutter-Tween die
        // verbleibenden Frames unsichtbar überbrückt. EventChannel
        // kommt mit der Rate locker klar (~300 Bytes/event).
        // 60 Hz (16ms). v1.5.29 lag bei 33ms/30Hz; User hat "noch
        // flüssiger" gefordert. Über 60Hz geht nicht sinnvoll — die
        // Flutter-UI rendert ebenfalls bei 60Hz (bzw. 120Hz auf ProMotion),
        // schneller emittieren würde nur EventChannel-Traffic verbrennen
        // ohne sichtbaren Gewinn.
        if now - lastPositionEmit < 0.016 { return }
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
