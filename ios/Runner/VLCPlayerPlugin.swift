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
    /// Drawable für den AKTUELL spielenden VLCMediaPlayer. War früher
    /// `let`, ist jetzt `var` weil der Auto-Next-Crossfade-Pfad
    /// (siehe `crossfadeToNextMedia`) zur Laufzeit auf eine
    /// frisch-initialisierte Drawable-View umschaltet.
    private var videoView: UIView
    /// Aktueller VLCMediaPlayer. Wird im Crossfade-Pfad gegen einen
    /// neuen, parallel hochgefahrenen Player getauscht. Muss daher
    /// `var` sein.
    private var mediaPlayer: VLCMediaPlayer
    private let viewId: Int64

    // ─── Crossfade-State (Fix C, Auto-Next-Blackscreen-Workaround) ─────
    //
    // Wenn Auto-Next-Episode während aktivem PiP feuert, kann libvlc's
    // vout-Modul beim stop+restart-Zyklus im Background nicht
    // zuverlässig neu initialisiert werden — Audio läuft, Video bleibt
    // schwarz. Fix B (vout-Reuse via setMedia) hat das nicht gelöst,
    // weil der Setter intern weiterhin libvlc_media_player_stop()
    // aufruft.
    //
    // Fix C: Wir spinnen für die nächste Folge einen ZWEITEN
    // VLCMediaPlayer mit eigenem Drawable parallel hoch (audio muted),
    // warten bis er einen Video-Output hat, und übernehmen ihn dann
    // atomisch — der vout der neuen Folge wird hochgefahren WÄHREND
    // der alte noch lebt und PiP die App im "audio+rendering"-Background
    // hält. Damit umgehen wir den vout-Teardown-Race komplett.
    private var nextMediaPlayer: VLCMediaPlayer?
    private var nextVideoView: UIView?
    /// Polling-Timer der wartet bis nextMediaPlayer.hasVideoOut=true
    /// (oder Timeout abläuft) und dann den Swap auslöst.
    private var swapWatchdog: Timer?
    /// Maximale Zeit die wir auf hasVideoOut der neuen Folge warten,
    /// bevor wir trotzdem swappen. 8s deckt langsame iPhones bei
    /// schweren 4K-HEVC-Files ab.
    private let crossfadeTimeoutSeconds: TimeInterval = 8.0
    /// Lautstärke vor dem Swap (0–100). VLCs `audio.volume` ist
    /// 0–200 (über 100 ist Boost). Wir muten den neuen Player bevor
    /// er play() macht und entmuten erst beim Handover.
    private var savedVolumeForSwap: Int32 = 100

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
            guard let args = call.arguments as? [String: Any],
                  let media = args["mediaUrl"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "replaceMedia needs mediaUrl",
                                    details: nil))
                return
            }
            let sub = args["subtitleUrl"] as? String
            let start = (args["startSeconds"] as? Double) ?? 0

            // PiP-aktiv im Hintergrund? → Crossfade-Pfad. Sonst
            // (Foreground / kein PiP) den simplen Setter-Pfad weiter
            // benutzen — der hat in Foreground keinen vout-Race und
            // ist deutlich weniger Code-Bewegung.
            var useCrossfade = false
            if #available(iOS 15.0, *),
               let coord = pipCoordinator as? VLCPiPCoordinator,
               coord.isPiPActive {
                useCrossfade = true
            }

            if useCrossfade {
                NSLog("[VLCPlayer] replaceMedia: crossfade path (PiP active)")
                crossfadeToNextMedia(urlString: media,
                                     subtitleUrl: sub,
                                     startSeconds: start)
                result(nil)
            } else {
                NSLog("[VLCPlayer] replaceMedia: setter path (PiP idle)")
                if #available(iOS 15.0, *),
                   let coord = pipCoordinator as? VLCPiPCoordinator {
                    coord.mediaWillChange()
                }
                loadMedia(urlString: media,
                          subtitleUrl: sub,
                          startSeconds: start,
                          keepVoutAlive: true)
                // Drawable-Kicks (defensiv, falls PiP knapp danach starten
                // sollte) — wie vorher.
                let kickTimes: [Double] = [0.3, 0.9, 1.8]
                for t in kickTimes {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                        guard let self = self else { return }
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
            }
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
            // Falls noch ein Crossfade-Kandidat läuft, vorher killen.
            cancelPendingCrossfade()
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

    // MARK: - Crossfade (Auto-Next during active PiP)
    //
    // Hintergrund: Wenn der Nutzer PiP gestartet hat und die App im
    // Hintergrund ist, kann libvlc's vout-Modul nach einem
    // stop()-Zyklus nicht zuverlässig neu initialisieren — Audio
    // läuft, Video bleibt schwarz.
    //
    // Strategie hier: Wir bauen einen ZWEITEN VLCMediaPlayer mit
    // eigenem Drawable parallel auf, lassen ihn anlaufen WÄHREND der
    // alte noch lebt (PiP hält die App im "audio + Layer-Render"-
    // Background-Modus, das reicht damit auch der zweite Player
    // seinen vout hochfahren darf), warten bis der Erste-Frame-
    // Indikator (`hasVideoOut`) auf dem Neuen steht, und übergeben
    // dann atomisch:
    //
    //   - Lautstärke-Übergabe: alter Player muten, neuer auf alte Vol.
    //   - PiP-Koordinator wird auf den neuen Player umgehängt
    //     (`replaceMediaPlayer`), damit der Snapshot-Pump die Frames
    //     aus der neuen Quelle abgreift.
    //   - delegate-/state-Übergabe: alter Player wird gestoppt, der
    //     neue ersetzt `self.mediaPlayer`.
    //   - Alter Player + alte Drawable-View werden disposed.
    //
    // Edge cases:
    //   - Doppelaufruf: ein laufender Crossfade wird abgebrochen
    //     (alter "Next" verworfen) bevor der neue startet.
    //   - Watchdog-Timeout (8s): wir swappen trotzdem, damit der
    //     User nicht ewig bei "letzte Frame friert"+"neue Audio
    //     läuft" hängenbleibt. Wenn der neue Player kein hasVideoOut
    //     hat, sieht der User halt schwarz — aber zumindest läuft die
    //     Tonspur synchron mit dem unsichtbaren Video weiter.
    private func crossfadeToNextMedia(urlString: String,
                                      subtitleUrl: String?,
                                      startSeconds: Double) {
        guard let url = resolveUrl(urlString) else {
            eventSink.send(["event": "error",
                            "message": "Ungültiger Pfad: \(urlString)"])
            return
        }

        // Falls schon ein Crossfade läuft (User skippt sehr schnell durch
        // mehrere Folgen, oder Auto-Next feuert nochmal): den alten
        // Kandidaten entsorgen, der Watchdog wird beim nächsten Tick
        // den NEUEN sehen.
        cancelPendingCrossfade()

        // Volume sichern damit wir beim Handover gleich wieder einstellen.
        savedVolumeForSwap = mediaPlayer.audio?.volume ?? 100

        // Neue Drawable-View als Geschwister von videoView in Container.
        // WICHTIG: muss in der View-Hierarchie hängen (= im aktiven
        // UIWindow), sonst bekommt VLC's vout-Modul kein backend-
        // surface und initialisiert nie. Wir stecken sie UNTER die
        // aktuelle videoView (insertSubview at: 0), damit der User
        // weiterhin die alte Folge im Hauptfenster sieht solange er
        // nicht im PiP-Modus ist (im PiP-Modus ist's egal, da rendert
        // PiP die SampleBufferDisplayLayer).
        let nextView = UIView(frame: container.bounds)
        nextView.backgroundColor = .black
        nextView.contentMode = .scaleAspectFit
        nextView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(nextView, belowSubview: videoView)
        nextVideoView = nextView

        // Neuer Player + Setup. addPlaybackSlave erst nach `play()`,
        // sonst landet der Slave im falschen Input-Slot (libvlc hat
        // erst beim ersten Demuxer-Pass eine "Episode 0").
        let nextPlayer = VLCMediaPlayer()
        nextPlayer.drawable = nextView
        nextPlayer.delegate = self
        nextMediaPlayer = nextPlayer

        let media = VLCMedia(url: url)
        media.addOption(":file-caching=300")
        media.addOption(":no-drop-late-frames")
        media.addOption(":no-skip-frames")
        media.addOption(":freetype-rel-fontsize=16")
        nextPlayer.media = media

        // Audio des neuen Players muten — wir wollen NICHT zwei
        // Tonspuren übereinander hören während der Crossfade läuft.
        nextPlayer.audio?.volume = 0

        nextPlayer.play()

        if let sub = subtitleUrl, !sub.isEmpty {
            let subUrl = URL(fileURLWithPath: sub)
            nextPlayer.addPlaybackSlave(subUrl, type: .subtitle, enforce: false)
        }

        // PiP-Koordinator informieren — er flusht die Layer NICHT
        // (keine `coord.mediaWillChange()` hier!), damit das letzte
        // Frame der alten Folge stehen bleibt bis der neue Player
        // tatsächlich Frames liefert. Sieht für den User ruhiger aus
        // als ein 2s-Blackscreen-Glitch.
        //
        // Stattdessen booten wir nur den Capture-Boost.
        if #available(iOS 15.0, *),
           let coord = pipCoordinator as? VLCPiPCoordinator {
            coord.mediaSwapBoost(seconds: 15.0)
        }

        // Watchdog: alle 200 ms checken ob der neue Player schon
        // Video-Output hat. Bei Timeout (8s) trotzdem swappen.
        let startTs = Date().timeIntervalSince1970
        let pendingSeek = startSeconds
        swapWatchdog?.invalidate()
        swapWatchdog = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: true
        ) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            // Zielplayer noch derselbe wie zum Zeitpunkt des Schedules?
            // Wenn nicht, abbrechen — ein neuer Crossfade ist gestartet.
            guard let candidate = self.nextMediaPlayer,
                  candidate === nextPlayer else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince1970 - startTs
            let ready = candidate.hasVideoOut
            if ready || elapsed >= self.crossfadeTimeoutSeconds {
                timer.invalidate()
                NSLog("[VLCPlayer] crossfade swap (ready=\(ready), elapsed=\(elapsed)s)")
                self.commitCrossfade(toPlayer: candidate,
                                     newView: nextView,
                                     pendingSeek: pendingSeek)
            }
        }
    }

    /// Bricht einen laufenden Crossfade ab. Disposed den
    /// Halbfertig-Player + dessen View. Idempotent.
    private func cancelPendingCrossfade() {
        swapWatchdog?.invalidate()
        swapWatchdog = nil
        if let p = nextMediaPlayer {
            p.delegate = nil
            p.stop()
        }
        nextMediaPlayer = nil
        nextVideoView?.removeFromSuperview()
        nextVideoView = nil
    }

    /// Atomischer Handover: alter Player wird gestoppt, neuer wird
    /// `self.mediaPlayer`, PiP-Coordinator zeigt auf den neuen.
    private func commitCrossfade(toPlayer newPlayer: VLCMediaPlayer,
                                 newView: UIView,
                                 pendingSeek: Double) {
        let oldPlayer = mediaPlayer
        let oldView = videoView

        // 1. PiP-Coordinator umhängen — ab hier liest der Snapshot-
        //    Pump aus dem neuen Player.
        if #available(iOS 15.0, *),
           let coord = pipCoordinator as? VLCPiPCoordinator {
            coord.replaceMediaPlayer(newPlayer)
        }

        // 2. Audio-Übergabe: alten muten, neuen auf gespeicherte
        //    Volume. Reihenfolge ist wichtig damit kein Doppel-Audio
        //    zu hören ist.
        oldPlayer.audio?.volume = 0
        newPlayer.audio?.volume = savedVolumeForSwap

        // 3. self-Refs umschalten. Ab jetzt sind alle play/pause/seek/
        //    track-Aufrufe gegen den neuen Player.
        mediaPlayer = newPlayer
        videoView = newView

        // 4. Optional: Resume-Position. Beim Auto-Next ist das in der
        //    Regel 0.0, der Pfad ist aber für Konsistenz da.
        if pendingSeek > 0 {
            pendingStartSeconds = pendingSeek
            didApplyStartSeek = false
        } else {
            pendingStartSeconds = 0
            didApplyStartSeek = true
        }

        // 5. Aufräumen: alter Player + alte View weg. Delegate vorher
        //    abklemmen, sonst feuert `mediaPlayerStateChanged` mit
        //    .stopped/.ended für die ALTE Folge nach dem Swap und
        //    triggert nochmal Auto-Next-Logik auf Dart-Seite.
        oldPlayer.delegate = nil
        oldPlayer.stop()
        oldView.removeFromSuperview()

        // 6. Crossfade-State zurücksetzen.
        nextMediaPlayer = nil
        nextVideoView = nil
        swapWatchdog = nil

        NSLog("[VLCPlayer] crossfade committed; videoView+mediaPlayer swapped")
    }

    private func seek(toSeconds seconds: Double) {
        // VLCMediaPlayer.time ist in Millisekunden, als VLCTime.
        let target = VLCTime(int: Int32(seconds * 1000))
        mediaPlayer.time = target
    }

    // MARK: - Lifecycle

    deinit {
        swapWatchdog?.invalidate()
        nextMediaPlayer?.stop()
        mediaPlayer.stop()
    }
}

// MARK: - VLCMediaPlayerDelegate

extension VLCPlayerView: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Crossfade-Guard: während ein Auto-Next-Crossfade hochfährt,
        // hat AUCH der noch-stille `nextMediaPlayer` `delegate=self`
        // gesetzt. Dessen State-Notifications würden sonst gegen
        // `self.mediaPlayer` (= alter Player) ausgewertet — falsche
        // Duration wird emittiert, doppelte playing-Events, etc.
        // Sender via Notification-Object identifizieren und alle
        // Events vom Nicht-Aktiven verwerfen.
        if let sender = aNotification.object as? VLCMediaPlayer,
           sender !== mediaPlayer {
            return
        }
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
        // Siehe Guard in mediaPlayerStateChanged — gleicher Grund.
        if let sender = aNotification.object as? VLCMediaPlayer,
           sender !== mediaPlayer {
            return
        }
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
