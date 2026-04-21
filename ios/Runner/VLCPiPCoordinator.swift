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
    private let captureFPS: Int = 10

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

    override init() {
        self.displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer.videoGravity = .resizeAspect
        // Schwarz als Platzhalter bevor der erste Frame reinkommt —
        // iOS würde sonst eine weiße Fläche zeigen.
        self.displayLayer.backgroundColor = UIColor.black.cgColor

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

        // Die Sample-Buffer-Layer muss Teil einer sichtbaren Layer-Hierarchie
        // sein damit AVPictureInPictureController sie akzeptiert. Wir
        // legen sie als 1×1-Pixel unsichtbare Layer unter die VLC-
        // Drawable-View — unsichtbar wird sie durch 0 Opacity + Größe 1,
        // aber iOS "sieht" sie trotzdem in der Hierarchie und das reicht.
        displayLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        displayLayer.opacity = 0
        hostView.layer.addSublayer(displayLayer)

        // AVAudioSession muss .playback sein damit PiP und
        // Background-Audio überhaupt erlaubt werden. NativePlayerPlugin
        // setzt das auch — zweimal setzen schadet nicht.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .moviePlayback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Nicht fatal; ohne .playback wird PiP zwar scheitern, aber
            // der Playback selbst läuft weiter.
            NSLog("[VLCPiP] AVAudioSession setup failed: \(error)")
        }

        // PiP-Controller mit ContentSource (iOS 15+ API, weil wir eine
        // custom sample-buffer-layer haben statt einer AVPlayerLayer).
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let ctrl = AVPictureInPictureController(contentSource: source)
        ctrl.delegate = self
        self.pipController = ctrl

        // iOS meldet über isPictureInPicturePossible wann alles bereit
        // ist (Audio-Session aktiv, Layer gemountet, etc.). Wir spiegeln
        // das an den Dart-Layer damit der Button nur clickable wird wenn
        // PiP wirklich greift.
        possibilityObservation = ctrl.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            self?.onPiPAvailabilityChanged?(controller.isPictureInPicturePossible)
        }
    }

    func detach() {
        stopCapture()
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        displayLayer.removeFromSuperlayer()
        pipController = nil
        mediaPlayer = nil
        hostView = nil
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
        guard let ctrl = pipController else { return }
        guard ctrl.isPictureInPicturePossible else {
            NSLog("[VLCPiP] startPiP aber isPictureInPicturePossible=false — Abbruch")
            return
        }
        // Vor dem Start brauchen wir mindestens einen Frame in der
        // Layer, sonst zeigt iOS kurz einen Flash. Einmal synchron ziehen.
        captureOneFrame()
        startCapture()
        ctrl.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
        // stopCapture() nicht hier — passiert erst im Delegate-Callback
        // didStopPictureInPicture, sonst friert der letzte Frame vor
        // Beendigung ein.
    }

    // MARK: - Frame pipeline

    private func startCapture() {
        stopCapture()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(captureFPS),
                maximum: Float(captureFPS),
                preferred: Float(captureFPS))
        } else {
            link.preferredFramesPerSecond = captureFPS
        }
        link.add(to: .main, forMode: .common)
        captureLink = link
    }

    private func stopCapture() {
        captureLink?.invalidate()
        captureLink = nil
    }

    @objc private func tick() {
        captureOneFrame()
    }

    private func captureOneFrame() {
        guard let player = mediaPlayer else { return }
        guard player.isPlaying || pipController?.isPictureInPictureActive == true else {
            return
        }
        if snapshotInFlight { return }
        snapshotInFlight = true

        // Snapshot-Size: PiP-Window ist klein (meist 320×180-ish), wir
        // rendern mit 480p um die Konvertier-Kosten niedrig zu halten.
        let width: Int32 = 480
        let height: Int32 = 270

        // saveVideoSnapshotAt ist blocking und schreibt synchron zum
        // aktuellen Thread — der CADisplayLink läuft auf Main, also
        // tritt hier theoretisch ein Jank-Risiko auf. In der Praxis bei
        // 10 Hz und 480p auf Main ist das unter 5ms pro Snapshot. Wenn
        // wir später Probleme sehen, verlegen wir den Write auf ein
        // dispatch_queue — aber dann muss lastSnapshot cross-thread
        // gelesen werden, das ist nicht garantiert safe.
        player.saveVideoSnapshot(
            at: snapshotPath,
            withWidth: width,
            andHeight: height)

        guard let image = player.lastSnapshot else {
            snapshotInFlight = false
            return
        }
        if let buffer = sampleBuffer(from: image) {
            if displayLayer.status == .failed {
                displayLayer.flush()
            }
            displayLayer.enqueue(buffer)
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

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(captureFPS)),
            presentationTimeStamp: now,
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

    /// PiP-Overlay braucht die Media-Länge um den Scrubber korrekt zu
    /// zeichnen. Live-Stream = .invalid. Wir haben immer Finite-Länge
    /// weil's lokale Dateien sind.
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let player = mediaPlayer,
              let lenMs = player.media?.length.intValue else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        let duration = CMTime(seconds: Double(lenMs) / 1000.0, preferredTimescale: 1000)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let start = CMTimeSubtract(
            now,
            CMTime(seconds: Double(player.time.intValue) / 1000.0, preferredTimescale: 1000))
        return CMTimeRange(start: start, duration: duration)
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
        stopCapture()
        onPiPStateChanged?(false)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        NSLog("[VLCPiP] failedToStartPictureInPicture: \(error)")
        stopCapture()
        onPiPStateChanged?(false)
    }
}
