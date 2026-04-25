// VLCPiPCoordinator.swift
//
// v1.5.35+ Architektur (Schritt 2):
//
// libvlc rendert NICHT mehr in eine eigene Metal-View. Stattdessen
// liefert es Frames über `libvlc_video_set_callbacks` direkt in einen
// CVPixelBuffer den unser `VLCFramePump` verwaltet. Der Pump enqueued
// jeden Frame als CMSampleBuffer in EINE `AVSampleBufferDisplayLayer`
// — und genau diese Layer ist gleichzeitig:
//
//   1. Foreground-Renderer: in der Container-View des Platform-Views
//      sichtbar während die App vorne ist.
//   2. PiP-Source: an den `AVPictureInPictureController` als
//      `ContentSource(sampleBufferDisplayLayer:)` gebunden.
//
// Damit existiert NUR EINE Render-Senke, kein paralleler vout-Pfad mehr,
// kein Snapshot-Hack mehr. Konsequenzen:
//
//   - Auto-Next im Background-PiP funktioniert: keine vout-Layer
//     die teardown gehen kann; libvlc ruft einfach weiter unsere
//     Lock/Unlock-Callbacks auf.
//   - PiP läuft mit echter Decoder-FPS.
//   - Die ganzen alten Workarounds (drawable-Kick, mediaSwapDeadline,
//     hasVideoOut-Gate, Snapshot-FPS-Boost) sind weggekürzt.
//
// Was bleibt:
//   - PiPController-Setup + Possible-State-Observer.
//   - Layer-Größen-Sync auf hostView.bounds.
//   - AVAudioSession-Setup für Background-Audio.
//   - Delegate-Callbacks an VLCPlayerPlugin (Possible/Active-Events).

import AVKit
import AVFoundation
import MobileVLCKit
import UIKit

/// Wrapt `AVSampleBufferDisplayLayer` in eine UIView, damit sie mit
/// dem normalen UIView-Layout-System mitresized wird (autoresizing-
/// Mask, Constraints, layoutSubviews). Eine "nackte" CALayer hat das
/// alles nicht — sie behält ihren initial gesetzten Frame bis man sie
/// manuell anfasst, was zu der fehlerhaften Skalierung in v1.6.0 geführt
/// hat (Layer war 1280×720 fixed, hostView war zb 390×220 → Bild
/// gigantisch und am rechten Rand abgeschnitten).
@available(iOS 15.0, *)
final class VLCDisplayLayerView: UIView {
    override class var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }
    var displayLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }
}

@available(iOS 15.0, *)
class VLCPiPCoordinator: NSObject {
    /// View die die Sample-Buffer-Display-Layer hostet. Wird beim
    /// attach() in `hostView` als Subview eingehängt mit Auto-
    /// Resize, also passt sie sich automatisch an Rotation /
    /// Player-Container-Resize an.
    private let displayView: VLCDisplayLayerView

    /// Convenience-Accessor: die eigentliche Layer hängt direkt an
    /// displayView (über das `layerClass`-Override). Wird sowohl als
    /// Render-Senke vom FramePump benutzt als auch als
    /// `ContentSource(sampleBufferDisplayLayer:)` an den
    /// AVPictureInPictureController.
    var displayLayer: AVSampleBufferDisplayLayer {
        return displayView.displayLayer
    }

    /// Host-View in der unsere displayView gemountet ist. Muss in der
    /// View-Hierarchie bleiben, sonst stoppt iOS PiP.
    private(set) weak var hostView: UIView?

    private weak var mediaPlayer: VLCMediaPlayer?
    private var pipController: AVPictureInPictureController?

    /// Der Frame-Pump — die eigentliche Decoder-→-Layer-Pipeline.
    /// Ist nil bis attach() läuft.
    private var pump: VLCFramePump?

    /// KVO-Token für AVPictureInPictureController.isPictureInPicturePossible.
    private var possibilityObservation: NSKeyValueObservation?

    /// Timer der periodisch player.time → displayLayer.controlTimebase
    /// synct. Ohne Timebase zeigt iOS-PiP "Live" statt einer
    /// Progressbar und verweigert Auto-PiP-on-Background. Mit
    /// Timebase weiß das System wo der Player gerade steht.
    private var timebaseSyncTimer: Timer?

    /// Event-Callbacks Richtung Dart.
    var onPiPStateChanged: ((_ active: Bool) -> Void)?
    var onPiPAvailabilityChanged: ((_ possible: Bool) -> Void)?

    override init() {
        self.displayView = VLCDisplayLayerView(frame: .zero)
        self.displayView.backgroundColor = .black
        super.init()
        self.displayLayer.videoGravity = .resizeAspect

        // Timebase einrichten. Ohne sie schaltet iOS-PiP auf "Live"-
        // Modus (kein Scrubber, kein Skip) und verweigert
        // canStartPictureInPictureAutomaticallyFromInline. Wir setzen
        // sie auf den HostTimeClock und syncen periodisch die Time
        // gegen player.time damit das System weiß wo wir stehen.
        var tb: CMTimebase?
        let s = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &tb)
        if s == noErr, let timebase = tb {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0.0) // erstmal pausiert
            self.displayLayer.controlTimebase = timebase
        }
    }

    /// Verbindet den Koordinator mit einem laufenden VLCMediaPlayer
    /// und hängt die displayView in die übergeordnete View ein.
    /// Erst NACH attach() ist startPiP() sinnvoll.
    func attach(to mediaPlayer: VLCMediaPlayer, hostView: UIView) {
        self.mediaPlayer = mediaPlayer
        self.hostView = hostView

        // displayView als Subview einhängen mit voller Größe und
        // Auto-Resize. Anders als bei einer raw CALayer wird die
        // SampleBufferDisplayLayer dadurch automatisch mitresized
        // wenn hostView seine Bounds ändert (Rotation, Player-Container-
        // Resize, etc.). Insert-Index 0 = ganz hinten in der z-Order,
        // damit Flutter-Overlays (Controls etc.) drüberliegen.
        displayView.frame = hostView.bounds
        displayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostView.insertSubview(displayView, at: 0)
        NSLog("[VLCPiP] attach: hostView.bounds=\(hostView.bounds), displayView attached")

        // AVAudioSession für Background-Audio.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[VLCPiP] AVAudioSession setup failed: \(error)")
        }

        // Frame-Pump anhängen — DAS ist die neue Pipeline.
        let p = VLCFramePump(displayLayer: displayLayer)
        let ok = p.attach(toPlayer: mediaPlayer)
        if !ok {
            NSLog("[VLCPiP] FrameLatch attach FAILED — DisplayLayer wird leer bleiben")
        }
        pump = p

        // PiPController kann sofort erzeugt werden — die Layer ist
        // schon registriert. iOS evaluiert isPictureInPicturePossible
        // basierend auf den Frames die in den nächsten ~100ms
        // einfließen werden.
        createPiPController()

        // Timebase-Sync starten — 5 Hz reicht (System interpoliert).
        timebaseSyncTimer?.invalidate()
        timebaseSyncTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: true
        ) { [weak self] _ in
            self?.syncTimebase()
        }
    }

    /// Letzte bekannte Media-Length um zu erkennen wann sie bekannt
    /// wird (Erstaufruf vs. nachher) — dann müssen wir iOS-PiP
    /// zwingen sein TimeRange-Cache zu invalidieren, sonst zeigt's
    /// dauerhaft "Live".
    private var lastKnownLengthMs: Int32 = 0

    /// Aktualisiert displayLayer.controlTimebase auf den aktuellen
    /// Stand des VLCMediaPlayers. Rate=1 wenn playing, 0 wenn paused.
    /// Time = aktuelle Wiedergabe-Position. iOS-PiP nutzt das für
    /// seine Progressbar und Play/Pause-State im Floating-Window.
    private func syncTimebase() {
        guard let tb = displayLayer.controlTimebase,
              let player = mediaPlayer else { return }
        let isPlaying = player.isPlaying
        let posMs = player.time.intValue
        let posSec = max(0, Double(posMs) / 1000.0)
        let target = CMTime(seconds: posSec, preferredTimescale: 1000)
        CMTimebaseSetTime(tb, time: target)
        CMTimebaseSetRate(tb, rate: isPlaying ? 1.0 : 0.0)

        // Wenn die Media-Length JETZT bekannt ist (war's vorher nicht),
        // PiP-Controller anstoßen seine Range-Abfrage zu wiederholen.
        // Sonst klebt er auf "Live" weil bei der ersten Abfrage
        // length=0 war → unsere TimeRange-Antwort war (0, ∞).
        let currentLength = player.media?.length.intValue ?? 0
        if currentLength > 0 && currentLength != lastKnownLengthMs {
            lastKnownLengthMs = currentLength
            pipController?.invalidatePlaybackState()
            NSLog("[VLCPiP] media length now \(currentLength)ms — invalidatePlaybackState")
        }
    }

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
            NSLog("[VLCPiP] isPictureInPicturePossible → \(possible)")
            self?.onPiPAvailabilityChanged?(possible)
        }
        NSLog("[VLCPiP] PiPController created")
    }

    func detach() {
        timebaseSyncTimer?.invalidate()
        timebaseSyncTimer = nil
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        // Pump VOR View-Removal — sonst feuert libvlc Callbacks
        // gegen eine displayLayer die schon aus der Hierarchie ist.
        // libvlc_video_set_callbacks(NULL) wartet intern bis alle
        // in-flight Callbacks fertig sind, danach ist es safe weiter
        // aufzuräumen.
        pump?.detach()
        pump = nil
        displayView.removeFromSuperview()
        pipController = nil
        mediaPlayer = nil
        hostView = nil
        NSLog("[VLCPiP] detached")
    }

    deinit {
        // Sicherheitsnetz für den Fall dass detach() nicht explizit
        // aufgerufen wurde (zb wenn Flutter die PlatformView teardown
        // ohne dispose-MethodCall durchläuft). Wenn wir ohne pump-
        // detach deallociert würden, würden libvlc-Callbacks gegen
        // einen toten ObjC-Pointer feuern → use-after-free Crash.
        if pump != nil {
            NSLog("[VLCPiP] deinit ohne vorheriges detach — räume nach")
            pump?.detach()
        }
    }

    // MARK: - PiP control (vom Plugin via MethodChannel aufgerufen)

    var isPiPActive: Bool {
        return pipController?.isPictureInPictureActive ?? false
    }

    var isPiPPossible: Bool {
        return pipController?.isPictureInPicturePossible ?? false
    }

    func startPiP() {
        guard let ctrl = pipController else {
            NSLog("[VLCPiP] startPiP: pipController nil — Abbruch")
            return
        }
        guard ctrl.isPictureInPicturePossible else {
            NSLog("[VLCPiP] startPiP: isPictureInPicturePossible=false "
                + "(framesEnqueued=\(pump?.framesEnqueued ?? 0)) — Abbruch")
            return
        }
        ctrl.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    /// Direkter libvlc-Subtitle-Setter. Umgeht
    /// MobileVLCKits currentVideoSubTitleIndex weil der Setter
    /// in 3.5.x mit unserem vmem-Vout-Pfad nicht zu wirken scheint.
    /// Returnt YES wenn libvlc den Wechsel akzeptiert hat.
    @discardableResult
    func setSubtitleTrackViaLibvlc(_ id: Int) -> Bool {
        return pump?.setSPUTrack(Int32(id)) ?? false
    }

    var currentSubtitleTrackViaLibvlc: Int {
        return Int(pump?.currentSPUTrack() ?? -1)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(iOS 15.0, *)
extension VLCPiPCoordinator: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[VLCPiP] PiP startup failed: \(error.localizedDescription)")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        NSLog("[VLCPiP] didStart")
        onPiPStateChanged?(true)
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        NSLog("[VLCPiP] didStop")
        onPiPStateChanged?(false)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension VLCPiPCoordinator: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // System-PiP-UI hat den Play/Pause-Button gedrückt.
        if playing {
            mediaPlayer?.play()
        } else {
            mediaPlayer?.pause()
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        // Liefere den (start, end) der aktuellen Folge — System-PiP
        // braucht das für seine eigene Progressbar.
        guard let player = mediaPlayer,
              let media = player.media,
              media.length.intValue > 0 else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        let durSec = Double(media.length.intValue) / 1000.0
        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: durSec, preferredTimescale: 1000)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return !(mediaPlayer?.isPlaying ?? false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // PiP-Window wurde resized — irrelevant für uns, der Pump
        // produziert weiter in voller Decoder-Auflösung und das
        // System scaliert.
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // PiP-UI Skip-Buttons (10s vor/zurück).
        guard let player = mediaPlayer else {
            completionHandler()
            return
        }
        let wasPlaying = player.isPlaying
        let currentMs = player.time.intValue
        let deltaMs = Int32(CMTimeGetSeconds(skipInterval) * 1000)
        let target = currentMs + deltaMs
        let safe = max(0, target)
        player.time = VLCTime(int: safe)
        // VLC pausiert beim Setter von `time` intern kurz und resumed
        // dann selbständig — manchmal aber NICHT, vorallem wenn der
        // Seek über Keyframe-Grenzen läuft. Dann bleibt der Player
        // pausiert nach dem Skip und der User muss manuell Play
        // drücken im PiP-UI. Wir erzwingen das hier, damit das Skip
        // sich wie bei Netflix anfühlt: tap → ohne Pause weiter.
        if wasPlaying {
            player.play()
        }
        completionHandler()
    }
}
