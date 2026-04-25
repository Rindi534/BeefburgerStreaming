// VLCFrameProbe.m
//
// Implementation siehe Header. Strategie:
//
// 1. C-Handle aus VLCMediaPlayer holen: MobileVLCKit hat über die
//    Versionen unterschiedliche Accessor-Namen verwendet. Wir
//    probieren die mir bekannten der Reihe nach via NSSelector
//    durch — der erste der existiert UND einen non-null Wert
//    liefert gewinnt.
//
// 2. Linkage gegen libvlc beweisen: `libvlc_media_player_get_position`
//    extern deklarieren und aufrufen. Wenn der Linker das Symbol nicht
//    findet, schlägt der iOS-Build mit "undefined symbol" fehl —
//    dann wissen wir früh genug dass MobileVLCKit die Symbole nicht
//    re-exportet und wir einen anderen Weg brauchen.
//
// Wenn beide Schritte erfolgreich sind, sind wir grün für Schritt 2:
// `libvlc_video_set_callbacks` + AVSampleBufferDisplayLayer-direct-feed.

#import "VLCFrameProbe.h"
#import <MobileVLCKit/MobileVLCKit.h>
#import <objc/runtime.h>

// libvlc-C-API: minimaler Subset den wir für die Probe brauchen.
// Kein Header-Import (MobileVLCKit liefert die libvlc/*.h NICHT als
// Public-Headers aus), wir extern-en uns die Signaturen selbst rein.
// Das funktioniert solange das Build die libvlc-Symbole zur Laufzeit
// auflösen kann — was MobileVLCKit als statisch-eingelinktes libvlc
// tut. Schritt 2 wird die Liste erweitern.
typedef struct libvlc_media_player_t libvlc_media_player_t;

extern float libvlc_media_player_get_position(libvlc_media_player_t *p_mi);

/// Versucht via Reflection den C-Handle aus dem Obj-C-Wrapper zu
/// extrahieren. Probiert die in MobileVLCKit-Geschichte verwendeten
/// Accessor-Namen durch. Returnt NULL wenn keiner zieht.
static libvlc_media_player_t *VLCExtractHandle(VLCMediaPlayer *player,
                                                NSString **usedAccessor)
{
    // Reihenfolge: aktuelle Public-API zuerst, dann historische.
    NSArray<NSString *> *candidates = @[
        @"libVLCMediaPlayer",   // moderne Public-API in MobileVLCKit 3.5+
        @"playerInstance",      // ältere VLCKit-Versionen
        @"instance",            // weitere Variante
        @"player",              // sehr alte interne Form
    ];

    for (NSString *name in candidates) {
        SEL sel = NSSelectorFromString(name);
        if (![player respondsToSelector:sel]) continue;

        // Method-IMP aufrufen. Rückgabe ist void* / pointer.
        IMP imp = [player methodForSelector:sel];
        // Cast: wir wissen die Methode nimmt nur self+_cmd und gibt
        // einen pointer zurück. void * ist signifikant agnostisch.
        void *(*func)(id, SEL) = (void *(*)(id, SEL))imp;
        void *result = func(player, sel);
        if (result != NULL) {
            if (usedAccessor) *usedAccessor = name;
            return (libvlc_media_player_t *)result;
        }
    }

    // Ivar-Fallback: in sehr alten Versionen war's nur als Instance-
    // Variable da, ohne Accessor. Versuche `_p_mi` direkt.
    Ivar ivar = class_getInstanceVariable([player class], "_p_mi");
    if (ivar) {
        ptrdiff_t offset = ivar_getOffset(ivar);
        void **slot = (void **)((uint8_t *)(__bridge void *)player + offset);
        if (slot && *slot) {
            if (usedAccessor) *usedAccessor = @"_p_mi (ivar)";
            return (libvlc_media_player_t *)(*slot);
        }
    }

    return NULL;
}

/// Diagnostic dump aller exposed Properties — nur für den Failure-Pfad.
/// Hilft mir zu sehen wie diese MobileVLCKit-Version den Handle nennt
/// falls keiner der Kandidaten zog.
static NSString *VLCDumpPropertiesAndMethods(VLCMediaPlayer *player)
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    Class cls = [player class];
    // Properties
    unsigned int pcount = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pcount);
    for (unsigned int i = 0; i < pcount; i++) {
        const char *name = property_getName(props[i]);
        [lines addObject:[NSString stringWithFormat:@"prop:%s", name]];
    }
    if (props) free(props);

    // Methoden mit Pointer-Rückgabe (heuristisch — Accessor-Pattern)
    unsigned int mcount = 0;
    Method *methods = class_copyMethodList(cls, &mcount);
    for (unsigned int i = 0; i < mcount; i++) {
        SEL sel = method_getName(methods[i]);
        const char *encoding = method_getTypeEncoding(methods[i]);
        const char *selName = sel_getName(sel);
        // Nur Methoden ohne Argumente listen (Accessor-artig)
        if (encoding && encoding[0] == '^') {
            [lines addObject:[NSString stringWithFormat:@"meth:%s -> %s",
                              selName, encoding]];
        }
    }
    if (methods) free(methods);

    return [lines componentsJoinedByString:@", "];
}

BOOL VLCProbeLibvlcHandle(VLCMediaPlayer *player,
                          NSString * _Nullable * _Nullable outDiagnostic)
{
    if (!player) {
        if (outDiagnostic) *outDiagnostic = @"FAIL: player ist nil";
        return NO;
    }

    NSString *accessor = nil;
    libvlc_media_player_t *handle = VLCExtractHandle(player, &accessor);
    if (handle == NULL) {
        if (outDiagnostic) {
            NSString *dump = VLCDumpPropertiesAndMethods(player);
            *outDiagnostic = [NSString stringWithFormat:
                @"FAIL: kein C-Handle-Accessor gefunden. "
                @"VLCMediaPlayer-class=%@. Verfügbar: %@",
                NSStringFromClass([player class]), dump];
        }
        NSLog(@"[VLCProbe] %@", outDiagnostic ? *outDiagnostic : @"");
        return NO;
    }

    // Linkage-Beweis: ein leichtgewichtiger libvlc-Call der KEINEN
    // Side-Effect auf Playback hat. -1.0 ist der Wert wenn noch keine
    // Position bekannt ist (frisch initialisiert oder ohne Media).
    float position = libvlc_media_player_get_position(handle);

    NSString *msg = [NSString stringWithFormat:
        @"OK: handle=%p (via -%@), libvlc_media_player_get_position=%f",
        handle, accessor, position];
    if (outDiagnostic) *outDiagnostic = msg;
    NSLog(@"[VLCProbe] %@", msg);
    return YES;
}
