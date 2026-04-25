// VLCPiPCoordinator.swift
//
// Session 2: Picture-in-Picture-Unterstützung für den VLC-Backend.
//
// Warum überhaupt ein eigener Koordinator und kein direkter
// AVPictureInPictureController-Call aus VLCPlayerPlugin?
// Weil PiP für VLCKit ein komplett eigenes Rendering-Rig braucht.
// AVPlayer hat das integriert — `AVPictureInPictureController(playerLayer:)`
// wickelt die AVPlayerLayer in den System-PiP-Prozess ein und fertig.
// VLCKit rendert über seinen eigenen OpenGL/Metal-Stack in ein UIView
// (`VLCMediaPlayer.drawable`), das iOS NICHT direkt in PiP einfügen kann.
//
// Lösung: Wir fahren eine ZWEITE Video-Senke parallel — eine
// AVSampleBufferDisplayLayer — und füttern die mit CMSampleBuffers. Der
// PiP-Controller bekommt diese Layer als Source
// (`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:...)`,
// iOS 15+) und zeigt sie im System-PiP-Window.
//
// Frame-Quelle (erste Iteration):
//   VLCMediaPlayer.saveVideoSnapshotAt(path:) → lastSnapshot → UIImage →
//   CVPixelBuffer → CMSampleBuffer → enqueue in displayLayer.
//   Das schreibt zwar kurz auf Disk (NSTemporaryDirectory, meistens
//   RAM-backed auf iOS) und ist daher NICHT 60fps-fähig — für einen
//   kleinen PiP-Viewport bei 10–15fps ist das völlig okay, der User
//   glancet da rein während er was anderes macht.
//
// Wenn wir später Performance brauchen (z.B. PiP auf iPad in groß,
// User schaut wirklich da rein): Sub-Plan Session 3 = libvlc's
// video_set_callbacks via Bridging-Header anziehen, dann kriegen wir
// die rohen Decoder-Frames direkt ohne Disk-Umweg. Wird aber ein
// eigener Battle weil MobileVLCKit den C-Handle nicht public exposed.

import AVKit
import AVFoundation
import CoreVideo
import MobileVLCKit
import UIKit

@available(iOS 15.0, *)
class VLCPiPCoordinator: NSObject {
    /// Die Layer, die iOS in den PiP-Floating-Window rendert. Wird vom
    /// AVPictureInPictureController exclusively gemanaged — wir füttern
    /// sie nur mit CMSampleBuffers.
    let displayLayer: AVSampleBufferDisplayLayer

    /// Host-View, in die die displayLayer eingehängt wird. Muss Teil
    /// der View-Hierarchie bleiben, sonst stoppt iOS PiP.
    private(set) weak var hostView: UIView?

    private weak var mediaPlayer: VLCMediaPlayer?
    private var pipController: AVPictureInPictureController?

    /// 10 Hz Snapshot-Takt. Bewusst niedrig — jeder Snapshot triggert
    /// einen Disk-Write in VLCKit (saveVideoSnapshotAt schreibt PNG).
    /// 10 fps ist für PiP ausreichend, und die CPU-Last bleibt
    /// beherrschbar. Wenn User sich beschwert dass's ruckelt → Session 3
    /// = libvlc callbacks.
    private var captureLink: CADisplayLink?
    // 20 Hz — hochgeschraubt nach User-Feedback "PiP ist stockig"
    // (v1.5.22). saveVideoSnapshotAt schreibt in NSTemporaryDirectory,
    // das ist auf iOS RAM-backed, daher nicht die erwartete Disk-Kosten.
    // Wenn 20 fps auf älteren Geräten jankt, geht's wieder runter oder
    // wir ziehen libvlc_video_set_callbacks direkt (Session 3b).
    private let captureFPS: Int = 20
    /// Boost-Rate während des Auto-Next-Swap-Fensters. Wenn libvlc nach
    /// dem Media-Wechsel im Background-PiP-Modus den Video-Output spät
    /// hochfährt, wollen wir den allerersten verfügbaren Frame sofort
    /// einfangen — sonst sieht der User die schwarze Layer eine halbe
    /// Sekunde länger als nötig. 40 Hz ist ein 2× Boost, kostet nur
    /// während der wenigen Sekunden des Swap-Fensters extra CPU.
    private let captureFPSBoost: Int = 40
    /// True solange wir im Boost-Modus sind. Verhindert dass parallele
    /// mediaWillChange()-Aufrufe (die theoretisch nicht passieren sollten)
    /// den Link zigmal neu aufsetzen.
    private var captureBoostActive: Bool = false

    /// Temp-Pfad für saveVideoSnapshotAt. Reusen wir pro Tick, dann
    /// bleibt der Inode stabil und der Filesystem-Cache warm.
    private let snapshotPath: String

    /// Verhindert überlappende Snapshot-Requests falls ein Tick länger
    /// dauert als das nächste CADisplayLink-Intervall.
    private var snapshotInFlight: Bool = false

    /// KVO-Token für AVPictureInPictureController.isPictureInPicturePossible.
    /// Solange der Wert false ist, würde startPictureInPicture() silent
    /// fehlschlagen. Wir warten darauf und pushen den aktuellen Stand
    /// via Callback an Dart.
    private var possibilityObservation: NSKeyValueObservation?

    /// Event-Callback Richtung Dart. VLCPlayerPlugin setzt hier einen
    /// Closure rein, der das auf den EventSink weiterreicht.
    var onPiPStateChanged: ((_ active: Bool) -> Void)?
    var onPiPAvailabilityChanged: ((_ possible: Bool) -> Void)?

    /// Wird true sobald der erste Frame erfolgreich in die displayLayer
    /// enqueued wurde. Erst dann erzeugen wir den PiPController, weil
    /// iOS sonst eine leere Layer sieht und isPictureInPicturePossible
    /// dauerhaft auf false locked.
    private var firstFrameEnqueued: Bool = false

    /// Zeitpunkt bis zu dem wir nach einem replaceMedia() aggressiv
    /// weitersnapshotten — auch wenn `hasVideoOut` noch false ist.
    /// Grund: wenn Auto-Next-Episode während aktivem PiP feuert, stoppt
    /// VLC die alte Media, der Video-Output-Handle flippt kurz auf
    /// false, hasVideoOut kommt im Background-PiP-Modus u.U. nicht
    /// sofort zurück, und die displayLayer behält den LETZTEN Frame
    /// der alten Folge stehen — User sieht "PiP freezt mit letzter
    /// Szene der alten Folge" (v1.5.29 Bugreport). In diesem Zeit-
    /// fenster bumpen wir den hasVideoOut-Gate ab und vertrauen auf
    /// den Obj-C-Wrapper VLCSafeSaveSnapshot, der etwaige NSExceptions
    /// abfängt. Zusätzlich wird zu Beginn die Layer geflusht, damit
    /// PiP NICHT die alte Szene zeigt während das neue Video hochfährt.
    private var mediaSwapDeadline: TimeInterval = 0

    override init() {
        self.displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer.videoGravity = .resizeAspect
        // Schwarz als Platzhalter bevor der erste Frame reinkommt —
        // iOS würde sonst eine weiße Fläche zeigen.
        self.displayLayer.backgroundColor = UIColor.black.cgColor

        // Timebase-Erzeugung ist in attach() verschoben. Grund:
        // zwischen init() und dem ersten tatsächlichen Frame-Enqueue
        // vergehen oft mehrere hundert Millisekunden (init → Platform-
        // View-Mount → attach → warten auf hasVideoOut → erster
        // Snapshot). Wenn die Timebase schon in init() mit Rate 1.0
        // losläuft, ist sie beim ersten Frame längst weitergewandert,
        // während unsere PTS bei 0 starten — der Frame landet dann
        // in der "Vergangenheit", iOS markiert die Layer als idle,
        // isPictureInPicturePossible bleibt false (Symptom in v1.5.19).

        let tmp = NSTemporaryDirectory()
        self.snapshotPath = (tmp as NSString)
            .appendingPathComponent("beefburger_vlc_pip_\(UUID().uuidString).png")

        super.init()
    }

    /// Verbindet den Koordinator mit dem laufenden VLCMediaPlayer und
    /// hängt die Sample-Buffer-Layer in die übergeordnete PlatformView
    /// ein. Erst nach attach() ist startPiP() möglich.
    func attach(to mediaPlayer: VLCMediaPlayer, hostView: UIView) {
        self.mediaPlayer = mediaPlayer
        self.hostView = hostView

        // 1. Layer-Größe: echte hostView-Bounds nehmen, mit Fallback.
        //    iOS verwirft 0×0-Layer als PiP-Quelle — wenn die PlatformView
        //    beim attach() noch nicht gelayoutet ist (was auf iOS häufig
        //    der Fall ist, weil Flutter async embeddet), bleibt der
        //    Possible-State permanent false. Daher Fallback auf 1280×720,
        //    wird beim ersten layoutPass dann via DispatchQueue.main.async
        //    auf die echte Größe korrigiert.
        let initialSize: CGSize
        if hostView.bounds.width > 1 && hostView.bounds.height > 1 {
            initialSize = hostView.bounds.size
        } else {
            initialSize = CGSize(width: 1280, height: 720)
        }
        displayLayer.frame = CGRect(origin: .zero, size: initialSize)
        hostView.layer.insertSublayer(displayLayer, at: 0)
        NSLog("[VLCPiP] attach: layer size=\(initialSize) "
            + "(hostView.bounds=\(hostView.bounds))")

        // 2. Timebase JETZT erzeugen (nicht mehr in init) damit ihr
        //    Nullpunkt beim Start des Frame-Flows liegt — PTS und
        //    Timebase-Zeit bleiben dadurch synchron ab Frame #1.
        var tb: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb)
        if status == noErr, let timebase = tb {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            displayLayer.controlTimebase = timebase
            NSLog("[VLCPiP] Timebase initialized")
        } else {
            NSLog("[VLCPiP] Timebase creation FAILED status=\(status) — PiP wird nicht funktionieren")
        }

        // Layout-Sync: wenn der Container resized wird (Rotation etc.)
        // muss die displayLayer mitwachsen.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.hostView else { return }
            if host.bounds.width > 1 && host.bounds.height > 1 {
                self.displayLayer.frame = host.bounds
                NSLog("[VLCPiP] attach (async): layer resized to \(host.bounds.size)")
            }
        }

        // 3. AVAudioSession — zwingend .playback für PiP.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[VLCPiP] AVAudioSession setup failed: \(error)")
        }

        // 4. Capture-Loop zuerst — so können Frames in die Layer
        //    einlaufen bevor wir den PiPController daran binden.
        startCapture()

        // 5. PiPController ERST NACHDEM mindestens ein Frame angekommen
        //    ist. Grund: iOS evaluiert isPictureInPicturePossible direkt
        //    bei .init(contentSource:) und wenn die Layer zu dem Zeitpunkt
        //    noch keine Frames hat / leer ist, latcht er teilweise auf
        //    false. maybeCreatePiPController() pollt in jedem Tick.
        //    Zusätzlicher Fallback-Timer nach 2s damit wir zumindest einen
        //    Controller aufsetzen auch wenn hasVideoOut nie kommt — in dem
        //    Fall bleibt Possible eben false und der Button bleibt grau,
        //    aber es crasht nichts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if self.pipController == nil {
                NSLog("[VLCPiP] 2s-Fallback: PiPController wird auch ohne erste Frames aufgesetzt")
                self.createPiPController()
            }
        }
    }

    /// Erzeugt den AVPictureInPictureController, verkabelt Observer und
    /// Delegate. Wird entweder durch maybeCreatePiPController nach dem
    /// ersten enqueueten Frame oder durch den 2s-Fallback-Timer
    /// aufgerufen. Guard gegen doppelten Aufruf via pipController-Check.
    private func createPiPController() {
        guard pipController == nil else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let ctrl = AVPictureInPictureController(contentSource: source)
        ctrl.delegate = self
        ctrl.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = ctrl

        possibilityObservation = ctrl.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            NSLog("[VLCPiP] isPictureInPicturePossible → \(possible) "
                + "(supported=\(AVPictureInPictureController.isPictureInPictureSupported()), "
                + "layerStatus=\(self?.displayLayer.status.rawValue ?? -1))")
            self?.onPiPAvailabilityChanged?(possible)
        }
        NSLog("[VLCPiP] PiPController created, waiting for Possible-state")
    }

    private func maybeCreatePiPController() {
        guard pipController == nil, firstFrameEnqueued else { return }
        NSLog("[VLCPiP] Erster Frame enqueued → createPiPController")
        createPiPController()
    }

    /// Wird von VLCPlayerPlugin.replaceMedia() direkt VOR dem eigentlichen
    /// Medienwechsel aufgerufen. Startet ein ~3s-Recovery-Fenster in dem
    /// (a) der letzte Frame der alten Folge aus der displayLayer ent-
    /// fernt wird (sonst "freezt" PiP auf der Schlussszene) und (b) der
    /// hasVideoOut-Gate in captureOneFrame umgangen wird, damit wir die
    /// ersten Frames der neuen Folge einfangen sobald der Decoder läuft.
    func mediaWillChange() {
        // 15s-Fenster. v1.5.30 lag bei 3s, reichte aber nicht: in
        // Background-PiP braucht libvlc spürbar länger bis der neue
        // Video-Decoder Frames produziert die saveVideoSnapshotAt
        // tatsächlich abgreifen kann (teilweise bleibt hasVideoOut
        // dauerhaft false solange die App nicht wieder aktiv ist).
        // 15s deckt den realistischen Auto-Next-Flow (Countdown + ein
        // paar Sekunden Pufferzeit) komfortabel ab.
        mediaSwapDeadline = Date().timeIntervalSince1970 + 15.0
        // Stale Frame entfernen. flushAndRemoveImage() reißt NICHT die
        // PiP-Session ab — iOS zeigt nur kurz einen schwarzen Viewport,
        // bis der erste neue Frame reinkommt. Deutlich angenehmer als
        // "Endbild der letzten Folge bleibt eingefroren".
        if displayLayer.status != .failed {
            displayLayer.flushAndRemoveImage()
        }
        // Capture-Loop für die Dauer des Swap-Fensters auf 40 Hz
        // hochziehen. Sobald der erste Frame der neuen Folge dekodiert
        // ist, wollen wir ihn innerhalb von ~25 ms in der PiP-Layer
        // haben statt potenziell 50 ms zu warten — bei sonst schwarzer
        // Layer ist das ein direkt sichtbarer Unterschied.
        boostCaptureForSwap(seconds: 15.0)
        NSLog("[VLCPiP] mediaWillChange: swap-window=15s, layer flushed, capture boosted to \(captureFPSBoost)Hz")
    }

    func detach() {
        stopCapture()
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        displayLayer.removeFromSuperlayer()
        displayLayer.controlTimebase = nil
        pipController = nil
        mediaPlayer = nil
        hostView = nil
        firstFrameEnqueued = false
        lastSyncedRate = -1
        // Snapshot-Tempfile aufräumen.
        try? FileManager.default.removeItem(atPath: snapshotPath)
    }

    // MARK: - PiP control

    var isPiPActive: Bool {
        return pipController?.isPictureInPictureActive ?? false
    }

    var isPiPPossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }

    func startPiP() {
        guard let ctrl = pipController else {
            NSLog("[VLCPiP] startPiP: pipController noch nil (Frame-Flow noch nicht bereit) — Abbruch")
            return
        }
        guard ctrl.isPictureInPicturePossible else {
            NSLog("[VLCPiP] startPiP aber isPictureInPicturePossible=false "
                + "(hasVideoOut=\(mediaPlayer?.hasVideoOut ?? false), "
                + "firstFrameEnqueued=\(firstFrameEnqueued), "
                + "layerStatus=\(displayLayer.status.rawValue)) — Abbruch")
            return
        }
        captureOneFrame()
        NSLog("[VLCPiP] startPictureInPicture() wird aufgerufen")
        ctrl.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
        // stopCapture() nicht hier — passiert erst im Delegate-Callback
        // didStopPictureInPicture, sonst friert der letzte Frame vor
        // Beendigung ein.
    }

    // MARK: - Frame pipeline

    private func startCapture(fps: Int? = nil) {
        stopCapture()
        let rate = fps ?? captureFPS
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(rate),
                maximum: Float(rate),
                preferred: Float(rate))
        } else {
            link.preferredFramesPerSecond = rate
        }
        link.add(to: .main, forMode: .common)
        captureLink = link
    }

    /// Startet den Capture-Link auf der Boost-Rate (siehe `captureFPSBoost`)
    /// und timer-resetted ihn nach `seconds` zurück auf die normale
    /// Rate. Wird von mediaWillChange() aufgerufen, damit wir nach
    /// einem Auto-Next-Swap den ersten neuen Frame mit minimaler Latenz
    /// erwischen — der reguläre 20 Hz-Takt kann ihn um bis zu 50 ms
    /// verfehlen, was bei einer schon schwarzen Layer schmerzhaft
    /// sichtbar ist.
    private func boostCaptureForSwap(seconds: TimeInterval) {
        if captureBoostActive { return }
        captureBoostActive = true
        startCapture(fps: captureFPSBoost)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self else { return }
            self.captureBoostActive = false
            // Nur zurückschalten wenn der Capture-Loop noch läuft.
            // Wenn wir zwischenzeitlich detached wurden, lassen wir's.
            if self.captureLink != nil {
                self.startCapture()
            }
        }
    }

    private func stopCapture() {
        captureLink?.invalidate()
        captureLink = nil
    }

    @objc private func tick() {
        syncTimebaseToPlayer()
        captureOneFrame()
    }

    /// Hält die displayLayer.controlTimebase synchron mit VLCs
    /// aktueller Wiedergabeposition und Play-State. Ohne das driftet
    /// der PiP-Scrubber gegen die tatsächliche VLC-Zeit, und pause/play
    /// wird vom System-PiP-UI nicht als Zustandsänderung erkannt.
    ///
    /// Wir updaten nur bei echten State-Wechseln (nicht jeden Tick),
    /// weil CMTimebaseSetTime/SetRate nicht garantiert thread-safe
    /// gegen CoreMedias internen Frame-Scheduler sind und bei 10Hz-
    /// Dauerfeuer gab's Crash-Reports.
    private var lastSyncedRate: Float64 = -1
    private func syncTimebaseToPlayer() {
        guard let tb = displayLayer.controlTimebase,
              let player = mediaPlayer else { return }
        let rate: Float64 = player.isPlaying ? 1.0 : 0.0

        // NUR Rate syncen, NICHT die Zeit. Seit v1.5.19 leiten wir PTS
        // aus CMTimebaseGetTime ab → Timebase ist "source of truth"
        // für die Frame-Timeline und darf nicht gegen player.time
        // zurückgebogen werden (das hatte v1.5.14–v1.5.18 gemacht und
        // damit den PTS-Flow gegen sich selbst laufen lassen).
        if rate != lastSyncedRate {
            CMTimebaseSetRate(tb, rate: rate)
            lastSyncedRate = rate
        }
    }

    /// Nur für Throttled-Logging: Sekunden-Auflösung des letzten Reports
    /// "kein Frame weil X".
    private var lastBlockReasonLogSec: Int = -1
    private func logBlockReasonOnce(_ reason: String) {
        let now = Int(Date().timeIntervalSince1970)
        if now != lastBlockReasonLogSec {
            lastBlockReasonLogSec = now
            NSLog("[VLCPiP] captureOneFrame blocked: \(reason)")
        }
    }

    private func captureOneFrame() {
        guard let player = mediaPlayer else {
            logBlockReasonOnce("no mediaPlayer")
            return
        }
        // Defensive gates: VLCMediaPlayer.saveVideoSnapshot crasht in
        // MobileVLCKit 3.5 wenn es VOR dem ersten .opening-State
        // aufgerufen wird (kein internal decoder handle). Wir warten
        // mindestens bis opening/buffering/playing/paused. Error/
        // stopped/esAdded-States überspringen wir auch, da ist kein
        // Frame verfügbar.
        guard player.media != nil else {
            logBlockReasonOnce("player.media=nil")
            return
        }
        switch player.state {
        case .opening, .buffering, .playing, .paused:
            break
        default:
            logBlockReasonOnce("state=\(player.state.rawValue)")
            return
        }
        // KRITISCHER Gate: VLCMediaPlayer.saveVideoSnapshotAt wirft eine
        // NSException wenn der Video-Output noch nicht initialisiert ist —
        // selbst im .playing-State ist das die ersten paar Frames oft
        // noch der Fall (Audio läuft schon, Video-Pipeline nicht).
        // Swift kann NSException nicht fangen → SIGABRT, App stirbt.
        // hasVideoOut wird von VLCKit auf true gesetzt sobald der
        // libvlc video_output aktiv ist. Das ist der einzige zuverlässige
        // Ready-Indikator. Siehe Crash-Report v1.5.16 (Runner 865BAEB7).
        // Normalfall: hasVideoOut=true ist der harte Gate. Ausnahme:
        // während des Media-Swap-Recovery-Fensters (siehe mediaWillChange)
        // probieren wir auch bei hasVideoOut=false weiter, weil der
        // Video-Output-Handle beim stop/play-Zyklus von VLC kurz flippt.
        // VLCSafeSaveSnapshot fängt NSExceptions sicher ab, daher kein
        // Crash-Risiko durch das Relaxen.
        let inSwapWindow =
            Date().timeIntervalSince1970 < mediaSwapDeadline
        if !player.hasVideoOut && !inSwapWindow {
            logBlockReasonOnce("hasVideoOut=false (state=\(player.state.rawValue))")
            return
        }
        if snapshotInFlight { return }
        snapshotInFlight = true

        // Snapshot-Size: PiP-Window ist klein, wir rendern mit längster
        // Kante 480 um die Konvertier-Kosten niedrig zu halten.
        // WICHTIG: Seitenverhältnis aus player.videoSize ableiten —
        // saveVideoSnapshotAt:withWidth:andHeight: skaliert stur auf
        // die angefragten Dimensionen, d.h. fixe 480×270 verzerren
        // alles was nicht 16:9 ist (4:3-Serien, 2.35:1-Filme, ...).
        // resizeAspect auf der displayLayer hilft dann nicht mehr,
        // weil die Verzerrung schon im Pixel-Buffer drin ist.
        let videoSize = player.videoSize
        let (width, height): (Int32, Int32)
        if videoSize.width > 0 && videoSize.height > 0 {
            let maxEdge: CGFloat = 480
            let aspect = videoSize.width / videoSize.height
            if aspect >= 1 {
                width = Int32(maxEdge)
                height = Int32((maxEdge / aspect).rounded())
            } else {
                height = Int32(maxEdge)
                width = Int32((maxEdge * aspect).rounded())
            }
        } else {
            // videoSize noch nicht verfügbar (erste Frames) → 16:9 Fallback.
            width = 480
            height = 270
        }

        // Aufruf geht über den Obj-C-Wrapper VLCSafeSaveSnapshot, der
        // intern @try/@catch macht. Das ist der Safety-Net falls
        // hasVideoOut lügt (race condition: Output wird zwischen Gate
        // und Call wieder abgerissen). Rückgabe NO = keine Exception,
        // aber auch kein Frame → snapshotInFlight zurücksetzen und raus.
        let ok = VLCSafeSaveSnapshot(player, snapshotPath, width, height)
        guard ok, let image = player.lastSnapshot else {
            snapshotInFlight = false
            return
        }
        if let buffer = sampleBuffer(from: image) {
            displayLayer.enqueue(buffer)
            if !firstFrameEnqueued {
                firstFrameEnqueued = true
                NSLog("[VLCPiP] erster Frame enqueued; layerStatus=\(displayLayer.status.rawValue)")
                maybeCreatePiPController()
            }
        }
        snapshotInFlight = false
    }

    /// UIImage → CVPixelBuffer → CMSampleBuffer. Muss jedes Mal neu
    /// allokieren weil iOS uns sonst den Buffer noch festhält während
    /// wir ihn überschreiben würden (enqueue ist async).
    private func sampleBuffer(from image: UIImage) -> CMSampleBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CMSampleBuffer mit Timing bauen. PTS = hostTime, damit die
        // Sample-Buffer-Layer die Frames sofort rausgibt statt zu cachen.
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescriptionOut: &formatDescription)
        guard let formatDesc = formatDescription else { return nil }

        // PTS = aktuelle Timebase-Zeit (ohne Lead). Zusammen mit dem
        // kCMSampleAttachmentKey_DisplayImmediately-Attachment unten
        // reicht das, damit iOS den Frame sofort präsentiert UND die
        // Layer als "playing" wahrnimmt. Der Lead aus v1.5.19 hatte
        // das Gegenteil bewirkt — Frames lagen in der Zukunft der
        // Timebase, die Layer hielt sie zurück, Possible-State blieb
        // false.
        let pts: CMTime
        if let tb = displayLayer.controlTimebase {
            pts = CMTimebaseGetTime(tb)
        } else {
            pts = CMClockGetTime(CMClockGetHostTimeClock())
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(captureFPS)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)

        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pb,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sample)

        // Display-immediately-Attachment — sonst wartet die Layer auf
        // Timing-Matching und verzögert/verwirft Frames.
        if let s = sample,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(
                s, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension VLCPiPCoordinator: AVPictureInPictureSampleBufferPlaybackDelegate {
    /// Wird vom System-PiP-UI aus dem Play/Pause-Button aufgerufen.
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        guard let player = mediaPlayer else { return }
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    /// VOD-Semantik: der verfügbare Content geht von 0 bis Dauer.
    /// NICHT (negativeInfinity, positiveInfinity) zurückgeben — das
    /// wäre Live-Stream-Semantik und iOS malt dann keinen Scrubber
    /// und markiert PiP auf manchen Geräten als unavailable.
    /// NICHT (now-elapsed, duration) — das ist quasi-Live-Semantik
    /// und wurde in Version 1.5.14 getestet, iOS lehnte es ab.
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let player = mediaPlayer,
              let lenMs = player.media?.length.intValue,
              lenMs > 0 else {
            // Bevor die Media-Länge bekannt ist (erster Playing-State
            // von VLC), geben wir einen Placeholder zurück damit iOS
            // den Controller nicht sofort verwirft. Sobald die Länge
            // reinkommt, wird der Wert beim nächsten Aufruf korrekt.
            return CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: 3600, preferredTimescale: 1000))
        }
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: Double(lenMs) / 1000.0,
                             preferredTimescale: 1000))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return !(mediaPlayer?.isPlaying ?? false)
    }

    /// Wenn der User in PiP auf Fast-Forward/Rewind drückt (±15s).
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard let player = mediaPlayer else {
            completionHandler()
            return
        }
        let deltaMs = Int32(CMTimeGetSeconds(skipInterval) * 1000)
        let currentMs = player.time.intValue
        let targetMs = max(0, currentMs + deltaMs)
        player.time = VLCTime(int: targetMs)
        completionHandler()
    }

    /// Render-Size-Hint — iOS sagt uns wie groß das PiP-Window ist.
    /// Aktuell ignorieren wir's; könnten Snapshot-Resolution dynamisch
    /// anpassen, aber dann Frame-Rate-Spikes → später.
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // no-op
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(iOS 15.0, *)
extension VLCPiPCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onPiPStateChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        // NICHT stopCapture() — wir lassen den Frame-Flow weiterlaufen
        // damit ein zweiter Auto-PiP-Trigger (z.B. User kommt zurück
        // und wechselt gleich wieder weg) direkt wieder greift.
        onPiPStateChanged?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[VLCPiP] failedToStartPictureInPicture: \(error)")
        onPiPStateChanged?(false)
    }
}
