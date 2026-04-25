// VLCFramePump.m
//
// Implementierung Header siehe oben.
//
// Threading-Modell:
//
//   - libvlc ruft format_setup_cb / lock_cb / unlock_cb / display_cb
//     aus seinem internen DECODER-Thread auf. NICHT main thread.
//   - CVPixelBufferPool, CVPixelBuffer-Lock/Unlock, CMSampleBuffer-
//     Erzeugung und AVSampleBufferDisplayLayer.enqueue sind alle
//     thread-safe (Apple-Doku bestätigt).
//   - format_cleanup_cb feuert bei stop() / dealloc-Pfad — wir
//     räumen den Pool auf.
//   - detach() setzt die Callbacks auf NULL via libvlc API; libvlc
//     synchronisiert intern dass nach dem Aufruf KEIN Callback mehr
//     feuert. Erst danach ist der Pump sicher freizugeben.
//
// Pixel-Format-Wahl: BGRA (32-bit). Begründung:
//
//   - libvlcs "RV32"-Chroma → libvlc konvertiert YUV→BGRA intern via
//     swscale. Kostet CPU, aber wir bekommen einen Buffer den
//     AVSampleBufferDisplayLayer ohne weitere Konvertierung
//     darstellen kann.
//   - Alternative NV12 wäre schneller (kein Konvert, Decoder-Format
//     direkt durchgereicht), erfordert aber Color-Space-Attachments
//     auf dem CMSampleBuffer (BT.601 vs 709 vs 2020) und genauere
//     CMVideoFormatDescription-Konfiguration. Wenn BGRA-Path stabil
//     läuft, switchen wir später um. Erstmal Korrektheit > Performance.
//
// Alignment / Pitch:
//
//   - libvlc verlangt pitch (= bytes pro Zeile) als Multiple von
//     einem chroma-spezifischen Wert. Für BGRA reicht 4-Byte-Alignment
//     (jedes Pixel ist 4 Bytes), aber CVPixelBufferPool gibt uns oft
//     extra Padding (round-up auf 64).
//   - Wir lesen den tatsächlichen pitch via CVPixelBufferGetBytesPerRow
//     ab nachdem wir den Buffer haben und schreiben ihn in pitches[0]
//     beim format_setup zurück. So weiß libvlc wie weit jede Zeile
//     auseinanderliegt und schreibt korrekt.

#import "VLCFramePump.h"
#import <MobileVLCKit/MobileVLCKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

// ─── libvlc C-API forward decls ────────────────────────────────────
// MobileVLCKit liefert keine vlc/*.h aus; wir extern-en uns die
// Symbole rein. Linker findet sie in MobileVLCKits embedded libvlc
// (durch Schritt-1-Probe verifiziert: libvlc_media_player_get_position
// hat erfolgreich gelinkt).

typedef struct libvlc_media_player_t libvlc_media_player_t;

// Format-Callbacks (libvlc 3.x signature)
typedef unsigned (*libvlc_video_format_cb)(void **opaque,
                                            char *chroma,
                                            unsigned *width,
                                            unsigned *height,
                                            unsigned *pitches,
                                            unsigned *lines);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);

// Per-frame Callbacks
typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque,
                                        void *picture,
                                        void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);

extern void libvlc_video_set_callbacks(libvlc_media_player_t *p_mi,
                                        libvlc_video_lock_cb lock,
                                        libvlc_video_unlock_cb unlock,
                                        libvlc_video_display_cb display,
                                        void *opaque);

extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *p_mi,
                                               libvlc_video_format_cb setup,
                                               libvlc_video_cleanup_cb cleanup);

// Subtitle/SPU control (direkter libvlc-API-Pfad, statt
// MobileVLCKits currentVideoSubTitleIndex-Setter — der scheint in
// 3.5.x nicht zuverlässig durchzuschlagen wenn vmem-Vout aktiv ist).
extern int libvlc_video_set_spu(libvlc_media_player_t *p_mi, int i_spu);
extern int libvlc_video_get_spu(libvlc_media_player_t *p_mi);

// ─── Internal context ──────────────────────────────────────────────

@interface VLCFramePump () {
    // ivars sind @public weil die statischen C-Callbacks
    // (VLCPump_FormatSetupCB, VLCPump_LockCB, ...) direkt darauf
    // zugreifen müssen. ObjC-Property-Accessoren wären für die
    // Frame-Hot-Path zu teuer (Methoden-Dispatch pro Frame).
    @public
    // C-Handle bleibt während der Pump attached ist gültig.
    // weak-Ref auf den ObjC-Wrapper hält uns davor dass libvlc
    // freigegeben wird ohne dass wir vorher die Callbacks unset'en.
    libvlc_media_player_t *_handle;
    __weak VLCMediaPlayer *_player;

    // Aktueller Pool. Wird im format_setup angelegt mit den
    // ausgehandelten Dimensionen, im format_cleanup entsorgt.
    CVPixelBufferPoolRef _pool;
    int32_t _width;
    int32_t _height;
    size_t _pitch;

    // Format-Description (gecached). Erzeugt einmal pro Pool-Init,
    // wiederverwendet für jedes CMSampleBuffer das wir bauen.
    CMVideoFormatDescriptionRef _formatDesc;

    // Lock-Counter um doppelte attach() abzufangen.
    BOOL _attached;

    // 1-Frame-Lag-Hold: Buffer aus dem vorherigen Frame, gehalten
    // bis der nächste rein kommt. Verhindert Memcpy-into-released-
    // memory innerhalb eines normalen Frame-Cycles.
    CVPixelBufferRef _heldBuffer;

    // CFBridgingRetain auf self, übergeben als opaque an libvlc.
    // Hält uns am Leben so lange libvlc den Pointer in seinen
    // Callback-Slots stehen hat. Wird erst in dealloc(!) released —
    // niemals während aktivem Player oder mid-stop, weil das den
    // Crash auslöst (siehe Doku zu detach unten).
    void *_opaque;
}
@property (nonatomic, weak, readwrite) AVSampleBufferDisplayLayer *displayLayer;
@property (atomic, readwrite) uint64_t framesEnqueued;
@end

// ─── Forward-decls of static C callbacks ───────────────────────────
static unsigned VLCPump_FormatSetupCB(void **opaque,
                                       char *chroma,
                                       unsigned *width,
                                       unsigned *height,
                                       unsigned *pitches,
                                       unsigned *lines);
static void VLCPump_FormatCleanupCB(void *opaque);
static void *VLCPump_LockCB(void *opaque, void **planes);
static void VLCPump_UnlockCB(void *opaque, void *picture, void *const *planes);
static void VLCPump_DisplayCB(void *opaque, void *picture);

// ─── Implementation ────────────────────────────────────────────────

@implementation VLCFramePump

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)layer
{
    self = [super init];
    if (self) {
        _displayLayer = layer;
        _handle = NULL;
        _pool = NULL;
        _formatDesc = NULL;
        _attached = NO;
        _framesEnqueued = 0;
    }
    return self;
}

- (void)dealloc
{
    // Wir kommen erst hier hin NACHDEM:
    //   - VLCPlayerView.deinit lief → coord.detach (= unser detach,
    //     hat NICHTS gegen libvlc gemacht, nur _attached=NO)
    //   - mediaPlayer.stop() lief → libvlc Input/Decoder/Vout
    //     komplett heruntergefahren. Keine in-flight picture_
    //     CopyPixels mehr.
    //   - pipCoordinator wurde nil → coord released → wir released.
    //
    // Erst JETZT ist es safe `set_callbacks(NULL)` zu rufen, weil
    // libvlc gar nicht mehr aktiv ist und keine SPU-Flush-Operation
    // mehr triggern kann.
    if (_handle) {
        libvlc_video_set_callbacks(_handle, NULL, NULL, NULL, NULL);
        libvlc_video_set_format_callbacks(_handle, NULL, NULL);
        _handle = NULL;
    }

    // CFBridgingRelease: balanciert den CFBridgingRetain aus attach.
    // Nach diesem Punkt hat libvlc keinen gültigen opaque-Pointer
    // mehr (haben wir gerade mit set_callbacks(NULL) geclear-t),
    // also ist es safe den retain wegzunehmen. Falls dealloc ohne
    // vorheriges detach lief, retten wir zumindest hier den Leak.
    if (_opaque) {
        CFBridgingRelease(_opaque);
        _opaque = NULL;
    }

    // Pool und Held jetzt direkt freigeben — libvlc ist garantiert
    // nicht mehr drauf.
    if (_heldBuffer) {
        CVPixelBufferRelease(_heldBuffer);
        _heldBuffer = NULL;
    }
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }
}

- (BOOL)attachToPlayer:(VLCMediaPlayer *)player
{
    if (_attached) {
        NSLog(@"[VLCFramePump] attachToPlayer: bereits attached, ignoriert");
        return YES;
    }
    if (!player) return NO;

    // C-Handle holen — dieselbe Reflection wie in VLCFrameProbe.
    SEL sel = NSSelectorFromString(@"libVLCMediaPlayer");
    if (![player respondsToSelector:sel]) {
        NSLog(@"[VLCFramePump] FAIL: VLCMediaPlayer hat keinen "
              @"-libVLCMediaPlayer accessor (alte MobileVLCKit-Version?)");
        return NO;
    }
    IMP imp = [player methodForSelector:sel];
    void *(*func)(id, SEL) = (void *(*)(id, SEL))imp;
    libvlc_media_player_t *handle = (libvlc_media_player_t *)func(player, sel);
    if (handle == NULL) {
        NSLog(@"[VLCFramePump] FAIL: -libVLCMediaPlayer hat NULL geliefert");
        return NO;
    }

    _handle = handle;
    _player = player;

    // CFBridgingRetain: libvlc bekommt einen +1-retain auf self via
    // opaque. Solange libvlc den Pointer in seinen Callback-Slots
    // stehen hat (auch nach detach! siehe Doku unten), bleibt self
    // alive — die statischen C-Callbacks dürfen also nie auf
    // dangling memory hauen. Balance: CFBridgingRelease in dealloc.
    _opaque = (void *)CFBridgingRetain(self);

    // WICHTIG: Format-Callbacks ZUERST setzen, dann erst die per-frame.
    libvlc_video_set_format_callbacks(handle,
                                       VLCPump_FormatSetupCB,
                                       VLCPump_FormatCleanupCB);
    libvlc_video_set_callbacks(handle,
                               VLCPump_LockCB,
                               VLCPump_UnlockCB,
                               VLCPump_DisplayCB,
                               _opaque);

    _attached = YES;
    NSLog(@"[VLCFramePump] attached zu %p", handle);
    return YES;
}

- (BOOL)setSPUTrack:(int)trackId
{
    if (!_handle) return NO;
    int rc = libvlc_video_set_spu(_handle, trackId);
    NSLog(@"[VLCFramePump] libvlc_video_set_spu(%d) → rc=%d, current=%d",
          trackId, rc, libvlc_video_get_spu(_handle));
    return rc == 0;
}

- (int)currentSPUTrack
{
    if (!_handle) return -1;
    return libvlc_video_get_spu(_handle);
}

- (void)detach
{
    if (!_attached) return;
    // KEIN libvlc_video_set_callbacks(NULL) hier!
    //
    // Begründung — Crash-Analysis v1.6.5 (.ips Stack zeigt
    // gleichzeitig laufende `input_DecoderDelete`, `vout_control_
    // WaitEmpty`, `_pthread_join` UND `picture_CopyPixels` mit
    // dest=NULL): wenn man set_callbacks(NULL) aufruft während
    // mediaPlayer.stop() schon läuft (oder unmittelbar bevor),
    // tauscht libvlc das Vout-Modul mid-flight aus und flusht
    // dabei eine pending SPU-Render-Operation in einen frisch-
    // allokierten Picture-Slot dessen plane[0]=NULL ist
    // (Allokation noch nicht fertig). → memcpy(NULL, src, 5792)
    // → SIGSEGV.
    //
    // Sicherer Pfad: Callbacks BLEIBEN registriert. Pool und
    // gehaltener Buffer bleiben in den ivars. mediaPlayer.stop()
    // (vom Caller direkt nach detach) räumt libvlc ordnungsgemäß
    // ab — zu dem Zeitpunkt ruft libvlc unsere lock/unlock auch
    // gar nicht mehr. Erst in dealloc (das passiert erst NACH
    // dem Stop) machen wir den finalen set_callbacks(NULL) und
    // Pool-Release.
    //
    // _attached=NO blockiert nur weitere enqueues in unseren
    // unlock_cb (siehe dortigen Check) damit wir keine Frames
    // mehr in eine möglicherweise schon entfernte DisplayLayer
    // schieben.
    _attached = NO;
    _player = nil;
    NSLog(@"[VLCFramePump] detached (callbacks bleiben aktiv bis dealloc — Anti-SPU-Flush-Crash)");
}

// ─── Internal — vom format_setup Callback aufgerufen ────────────────

- (BOOL)_initPoolWithWidth:(int32_t)width height:(int32_t)height
{
    if (_pool) {
        CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
    }
    if (_formatDesc) {
        CFRelease(_formatDesc);
        _formatDesc = NULL;
    }

    NSDictionary *pixelBufferAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        // Cache-Hinweis für Metal-Compositor von AVSampleBufferDisplayLayer.
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    NSDictionary *poolAttrs = @{
        // Bis zu 8 buffers im Pool — deckt Decode-Vorlauf + ein paar
        // im Display-Queue. Mehr wäre Memory-Verschwendung; weniger
        // führt zu blockierendem CVPixelBufferPoolCreatePixelBuffer.
        (id)kCVPixelBufferPoolMinimumBufferCountKey: @8,
    };

    CVReturn res = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        (__bridge CFDictionaryRef)pixelBufferAttrs,
        &_pool);
    if (res != kCVReturnSuccess || _pool == NULL) {
        NSLog(@"[VLCFramePump] CVPixelBufferPoolCreate FAILED: %d", res);
        return NO;
    }

    // Einen Probe-Buffer dequeuen um den tatsächlichen pitch
    // (bytesPerRow) zu ermitteln, den schreiben wir libvlc als
    // pitches[0] zurück.
    CVPixelBufferRef probe = NULL;
    res = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                              _pool, &probe);
    if (res != kCVReturnSuccess || probe == NULL) {
        NSLog(@"[VLCFramePump] Probe-buffer create FAILED: %d", res);
        return NO;
    }
    _pitch = CVPixelBufferGetBytesPerRow(probe);
    CVPixelBufferRelease(probe);

    // CMVideoFormatDescription einmalig erzeugen.
    OSStatus s = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        kCVPixelFormatType_32BGRA,
        width, height,
        NULL,
        &_formatDesc);
    if (s != noErr) {
        NSLog(@"[VLCFramePump] CMVideoFormatDescriptionCreate FAILED: %d", (int)s);
        return NO;
    }

    _width = width;
    _height = height;
    NSLog(@"[VLCFramePump] pool ready %dx%d pitch=%zu", width, height, _pitch);
    return YES;
}

- (void)_enqueueBufferFromPicture:(CVPixelBufferRef)pixelBuffer
{
    if (!pixelBuffer || !_formatDesc) return;
    // Nach detach() KEIN enqueue mehr — die Layer wird gerade aus
    // der View-Hierarchie genommen. Frames die jetzt noch
    // einlaufen lassen wir einfach fallen.
    if (!_attached) return;
    AVSampleBufferDisplayLayer *layer = self.displayLayer;
    if (!layer) return;

    // Layer-Status checken. Wenn .failed, flush und neu starten.
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        NSLog(@"[VLCFramePump] DisplayLayer status=failed, flush");
        [layer flush];
    }

    // PTS = aktuelle Host-Time aus CoreMedia. AVSampleBufferDisplayLayer
    // braucht einen *gültigen* PTS pro Frame — sonst geht layer.status
    // auf .failed. Da wir `kCMSampleAttachmentKey_DisplayImmediately`
    // unten setzen, wird der PTS-Wert für die Anzeige-Pacing aber
    // ignoriert; nur sein "valid"-Flag muss stehen.
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = pts,
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBuffer,
        _formatDesc,
        &timing,
        &sampleBuffer);
    if (s != noErr || !sampleBuffer) {
        NSLog(@"[VLCFramePump] CMSampleBufferCreate FAILED: %d", (int)s);
        return;
    }

    // "Display immediately"-Attachment: Layer rendert ohne controlTimebase
    // den Frame sofort statt auf eine Timeline zu warten.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately,
                             kCFBooleanTrue);
    }

    [layer enqueueSampleBuffer:sampleBuffer];
    self.framesEnqueued = self.framesEnqueued + 1;
    CFRelease(sampleBuffer);
}

@end

// ─── Static C Callbacks ─────────────────────────────────────────────

/// libvlc fragt nach dem Pixel-Format. Wir sagen "BGRA, deine
/// Auflösung, Pitch ist X". libvlc passt seine internal-conversion
/// entsprechend an.
///
/// Die Funktion DARF die width/height verändern (zb auf gerade
/// Pixelzahl roundup). Dann re-allokiert libvlc seine internen
/// Buffer auf den neuen Wert. Wir nehmen die Werte wie sie
/// reinkommen und legen den Pool damit an.
static unsigned VLCPump_FormatSetupCB(void **opaque,
                                       char *chroma,
                                       unsigned *width,
                                       unsigned *height,
                                       unsigned *pitches,
                                       unsigned *lines)
{
    VLCFramePump *pump = (__bridge VLCFramePump *)*opaque;
    if (!pump) return 0;

    // Wir wollen BGRA. Schreibe das in das chroma-Array (libvlc
    // erwartet eine 4-char fourCC, NULL-terminator nicht nötig
    // weil das Array selbst nur 4 chars hat).
    chroma[0] = 'R'; chroma[1] = 'V'; chroma[2] = '3'; chroma[3] = '2';

    // Pool bauen mit den verlangten Dimensionen.
    if (![pump _initPoolWithWidth:(int32_t)*width
                            height:(int32_t)*height]) {
        NSLog(@"[VLCFramePump] format_setup: pool init failed");
        return 0;
    }

    // pitch (bytes pro Zeile) und lines (Zeilen-Anzahl) zurückschreiben.
    pitches[0] = (unsigned)pump->_pitch;
    lines[0] = *height;

    NSLog(@"[VLCFramePump] format_setup chroma=RV32 %ux%u pitch=%u",
          *width, *height, pitches[0]);
    return 1; // Anzahl der Buffer die libvlc anfragen darf — 1 plane.
}

static void VLCPump_FormatCleanupCB(void *opaque)
{
    VLCFramePump *pump = (__bridge VLCFramePump *)opaque;
    if (!pump) return;
    NSLog(@"[VLCFramePump] format_cleanup");
    // Wir lassen den Pool bewusst LEBEN bis detach() — VLC ruft
    // format_cleanup auch bei stop() während eines Auto-Next-Swap,
    // und wenn wir den Pool da entsorgen, müsste das nächste
    // format_setup wieder neu allokieren. Behalten ist effizienter.
    // Wenn die nächste Folge andere Dimensionen hat, ersetzt
    // _initPoolWithWidth den Pool dann anyway.
}

/// VLC will einen Buffer. Wir dequeuen einen frischen aus dem Pool,
/// locken ihn, schreiben den base-pointer in planes[0], geben den
/// CVPixelBuffer als "picture" pointer zurück (libvlc reicht den
/// 1:1 an unlock/display weiter — wir kriegen unsere Referenz
/// unverändert wieder).
static void *VLCPump_LockCB(void *opaque, void **planes)
{
    VLCFramePump *pump = (__bridge VLCFramePump *)opaque;
    if (!pump || !pump->_pool) {
        // Pool noch nicht ready — passiert in der Race zwischen
        // format_setup und der ersten Frame-Anforderung. Geben wir
        // libvlc NULL → Frame wird gedroppt.
        if (planes) planes[0] = NULL;
        return NULL;
    }

    CVPixelBufferRef buffer = NULL;
    CVReturn r = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, pump->_pool, &buffer);
    if (r != kCVReturnSuccess || !buffer) {
        // Pool empty → kCVReturnWouldExceedAllocationThreshold.
        // Frame droppen ist akzeptabel; Decoder produziert nächsten.
        if (planes) planes[0] = NULL;
        return NULL;
    }

    CVPixelBufferLockBaseAddress(buffer, 0);
    if (planes) planes[0] = CVPixelBufferGetBaseAddress(buffer);

    // CFRetain nicht nötig — CVPixelBufferPoolCreatePixelBuffer
    // gibt einen Buffer mit retainCount=1 zurück, den wir in
    // unlock_cb wieder releasen.
    return (void *)buffer;
}

/// VLC ist nominell fertig mit dem Buffer. Wir unlocken, enqueuen
/// als CMSampleBuffer — und behalten den CVPixelBufferRef für eine
/// Frame-Periode festgehalten, statt ihn sofort zu releasen.
///
/// Warum 1-Frame-Lag: libvlc's `picture_CopyPixels` (= memmove des
/// Decoder-Outputs in unseren Buffer) kann ÜBER unlock_cb hinaus
/// laufen — vorallem wenn gerade ein Player-Stop / detach läuft.
/// Wenn wir hier sofort CFReleasen und der Buffer wird recycled
/// (oder die Memory freigegeben), schreibt libvlc in eine ungültige
/// Region → SIGSEGV in `_platform_memmove` (siehe Crash-Report
/// v1.6.2). Mit dem 1-Frame-Hold-Off ist die in-flight memmove
/// längst durch wenn der Buffer eventually released wird.
static void VLCPump_UnlockCB(void *opaque, void *picture, void *const *planes)
{
    (void)planes;
    VLCFramePump *pump = (__bridge VLCFramePump *)opaque;
    CVPixelBufferRef buffer = (CVPixelBufferRef)picture;
    if (!buffer) return;

    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (pump) {
        [pump _enqueueBufferFromPicture:buffer];
        // 1-Frame-Lag: aktueller Buffer wird gehalten, der vorherige
        // (falls vorhanden) jetzt freigegeben — dessen libvlc-Memcpy
        // ist garantiert durch.
        CVPixelBufferRef previous = pump->_heldBuffer;
        pump->_heldBuffer = buffer; // takes our retain
        if (previous) {
            CVPixelBufferRelease(previous);
        }
    } else {
        // Pump ist weg → trotzdem release, sonst Buffer-Leak.
        CVPixelBufferRelease(buffer);
    }
}

static void VLCPump_DisplayCB(void *opaque, void *picture)
{
    // No-op. libvlc würde uns hier sagen "zeig diesen frame jetzt
    // an" wenn wir Drag-/Drop-Pacing wollten. Wir enqueuen aber schon
    // im unlock_cb in die DisplayLayer, die selber pacing macht.
    (void)opaque;
    (void)picture;
}
