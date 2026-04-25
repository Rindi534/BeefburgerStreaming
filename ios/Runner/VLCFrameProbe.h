// VLCFrameProbe.h
//
// Schritt 1 in Richtung "echtes" PiP für den VLC-Backend: prüfen, ob
// wir aus einem `VLCMediaPlayer` an den darunterliegenden libvlc-
// C-Handle (`libvlc_media_player_t *`) rankommen UND ob wir gegen die
// libvlc-C-Funktionen linken können. Das ist die Voraussetzung für
// `libvlc_video_set_callbacks` — das ist der API-Pfad mit dem wir
// rohe Decoder-Frames direkt in unsere `AVSampleBufferDisplayLayer`
// füttern können statt über den langsamen Snapshot→PNG→UIImage-Hack.
//
// Diese Probe stört das normale Playback NICHT. Sie greift nur den
// C-Handle ab und ruft eine sichere Read-Only-Funktion
// (`libvlc_media_player_get_position`) auf um zu beweisen dass der
// Linker die libvlc-Symbole findet. Das Ergebnis kommt als String
// raus und wird vom Plugin via EventChannel an die Dart-Seite
// gepostet, damit man's am iPhone in einem Snackbar sehen kann
// (kein Xcode-Console-Zugriff nötig).

#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Probiert den libvlc-C-Handle aus dem MobileVLCKit-Wrapper zu holen
/// und einen Read-Only-libvlc-Call dagegen abzufeuern. Idempotent;
/// kein Side-Effect auf Playback.
///
/// @param player Der VLCMediaPlayer zu dem wir den C-Handle wollen.
/// @param outDiagnostic Wird mit einem menschenlesbaren Status-String
///        gefüllt (zb "OK: handle=0x... position=-1.000000" oder
///        "FAIL: VLCMediaPlayer hat keinen bekannten C-Handle-Accessor").
/// @return YES wenn alles geklappt hat.
BOOL VLCProbeLibvlcHandle(VLCMediaPlayer *player,
                          NSString * _Nullable * _Nullable outDiagnostic);

NS_ASSUME_NONNULL_END
