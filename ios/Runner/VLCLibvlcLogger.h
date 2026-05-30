// VLCLibvlcLogger — hängt sich an libvlc's internes Log-System
// (libvlc_log_set) und schreibt alle Messages in eine Datei in
// Application Support. Damit sehen wir was libvlc beim Decoder-
// Setup, SPU-Compositing, Vout-Modul-Selection etc. tatsächlich
// macht — Diagnose statt Raten.
//
// Log-Datei: Application Support / vlc-debug.log
// (rotation: vorhandener wird beim Player-Start überschrieben damit
//  die Datei nicht unbegrenzt wächst)

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VLCLibvlcLogger : NSObject

/// Hängt das libvlc-Log-System ein. Idempotent — mehrfaches Aufrufen
/// macht nichts kaputt. Returns NO wenn der libvlc-Handle nicht
/// extrahiert werden konnte.
+ (BOOL)attach;

/// Gibt den absoluten Pfad der Log-Datei zurück. Kann zum Anzeigen
/// in der App oder zum Versenden genutzt werden.
+ (NSString *)logPath;

/// Liest die Log-Datei und gibt den Inhalt als String zurück. Limit
/// auf die letzten 50 KB damit die UI nicht überfordert wird.
+ (NSString *)readLogTail;

@end

NS_ASSUME_NONNULL_END
