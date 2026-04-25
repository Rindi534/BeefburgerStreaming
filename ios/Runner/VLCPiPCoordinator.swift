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

@available(iOS 15.0, *)
class VLCPiPCoordinator: NSObject {
    /// Die Layer in die der Pump die Frames enqueued, und die
    /// AVPictureInPictureController als Content-Source bekommt.
    let displayLayer: AVSampleBufferDisplayLayer

    /// Host-View in der die Layer gemountet ist. Muss in der View-
    /// Hierarchie bleiben, sonst stoppt iOS PiP.
    private(set) weak var hostView: UIView?

    private weak var mediaPlayer: VLCMediaPlayer?
    private var pipController: AVPictureInPictureController?

    /// Der Frame-Pump — die eigentliche Decoder-→-Layer-Pipeline.
    /// Ist nil bis attach() läuft.
    private var pump: VLCFramePump?

    /// KVO-Token für AVPictureInPictureController.isPictureInPicturePossible.
    private var possibilityObservation: NSKeyValueObservation?

    /// Event-Callbacks Richtung Dart.
    var onPiPStateChanged: ((_ active: Bool) -> Void)?
    var onPiPAvailabilityChanged: ((_ possible: Bool) -> Void)?

    override init() {
        self.displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer.videoGravity = .resizeAspect
        // Schwarz als Hintergrund bevor der erste Frame reinkommt.
        self.displayLayer.backgroundColor = UIColor.black.cgColor
        super.init()
    }

    /// Verbindet den Koordinator mit einem laufenden VLCMediaPlayer
    /// und hängt die Layer in die übergeordnete View ein.
    /// Erst NACH attach() ist startPiP() sinnvoll.
    func attach(to mediaPlayer: VLCMediaPlayer, hostView: UIView) {
        self.mediaPlayer = mediaPlayer
        self.hostView = hostView

        // Layer-Frame initial setzen.
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

        // Layout-Sync (rotation, resize) — async damit erste Layout-Pass
        // durch ist.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.hostView else { return }
            if host.bounds.width > 1 && host.bounds.height > 1 {
                self.displayLayer.frame = host.bounds
                NSLog("[VLCPiP] attach (async): layer resized to \(host.bounds.size)")
            }
        }

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
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        // Pump VOR Layer-Removal — sonst feuert libvlc Callbacks
        // gegen einen toten displayLayer.
        pump?.detach()
        pump = nil
        displayLayer.removeFromSuperlayer()
        pipController = nil
        mediaPlayer = nil
        hostView = nil
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
        let currentMs = player.time.intValue
        let deltaMs = Int32(CMTimeGetSeconds(skipInterval) * 1000)
        let target = currentMs + deltaMs
        let safe = max(0, target)
        player.time = VLCTime(int: safe)
        completionHandler()
    }
}
