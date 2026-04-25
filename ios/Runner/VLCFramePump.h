// VLCFramePump.h
//
// Schritt 2 von "echtes PiP für VLC". Ersetzt den
// saveVideoSnapshotAt-Hack aus Schritt 1.
//
// Wir greifen mit libvlc_video_set_callbacks() direkt in die Decoder-
// Pipeline rein: VLC schreibt jedes dekodierte Frame in einen
// CVPixelBuffer den WIR ihm vorhalten, und wir wrappen den Buffer
// danach als CMSampleBuffer in eine AVSampleBufferDisplayLayer.
//
// Die DisplayLayer ist sowohl Foreground-Renderer (User schaut Video
// in der App) ALS AUCH PiP-Source (System-PiP-Window). Damit existiert
// nur noch eine Render-Senke statt parallel libvlc-vout (UIView) +
// Snapshot-Pump (DisplayLayer). Vorteile:
//
//   - Keine vout-Metal-Layer mehr → kein vout-Teardown-Problem im
//     Background → Auto-Next-im-PiP funktioniert.
//   - Echte Decoder-FPS statt 20 Hz Snapshot-Takt.
//   - Echte PTS pro Frame → System-PiP-UI hat korrekte Zeitlinie.
//   - Subtitles werden von libvlc in den Frame-Buffer geblittet
//     bevor wir ihn enqueuen → kein Flicker zwischen unsynchronisierten
//     Layern.
//
// Lebenszyklus: erst initWithDisplayLayer, dann attachToPlayer.
// Beim dispose oder Episode-Ende detach aufrufen, sonst feuern die
// libvlc-Callbacks gegen einen freigegebenen Pump.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

@interface VLCFramePump : NSObject

/// Die Layer in die wir die Frames enqueuen. Caller behält Ownership;
/// der Pump hält nur eine schwache Referenz, damit dispose der
/// Coordinator-Klasse den Pump auch wirklich freigeben kann.
@property (nonatomic, weak, readonly) AVSampleBufferDisplayLayer *displayLayer;

/// True nachdem `attachToPlayer:` erfolgreich war und libvlc-Callbacks
/// gesetzt sind.
@property (nonatomic, readonly) BOOL isAttached;

/// Diagnostik: wie oft Frames angekommen sind. Hilft beim Debuggen
/// (zb wenn die DisplayLayer schwarz bleibt: Counter zählt hoch?
/// Decoder läuft, Layer-Setup ist kaputt. Counter zählt nicht hoch?
/// Decoder oder Callbacks sind kaputt).
@property (atomic, readonly) uint64_t framesEnqueued;

/// Designierter Initializer.
- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Hängt sich an den libvlc-Player. Setzt video_set_format_callbacks
/// + video_set_callbacks. Returns NO wenn der C-Handle nicht extrahiert
/// werden konnte (sollte nach Probe nicht mehr passieren).
- (BOOL)attachToPlayer:(VLCMediaPlayer *)player
    NS_SWIFT_NAME(attach(toPlayer:));

/// Trennt die Callbacks (setzt sie auf NULL via libvlc) und gibt
/// CVPixelBufferPool frei. Idempotent. MUSS aufgerufen werden bevor
/// der Pump deallociert wird, sonst feuern Callbacks ins Leere
/// → Crash.
- (void)detach;

@end

NS_ASSUME_NONNULL_END
