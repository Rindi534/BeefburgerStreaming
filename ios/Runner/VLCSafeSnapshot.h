// VLCSafeSnapshot.h
//
// Swift kann keine NSExceptions fangen — aber VLCMediaPlayers
// -saveVideoSnapshotAt:withWidth:andHeight: wirft genau solche, wenn
// der Video-Output noch nicht bereit ist (siehe Crash-Log zu
// v1.5.16, Runner crash 865BAEB7). Wir brauchen deshalb einen
// dünnen Objective-C-Wrapper, der @try/@catch macht und das Ergebnis
// als simples BOOL zurückgibt.

#import <Foundation/Foundation.h>

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Ruft saveVideoSnapshotAt:withWidth:andHeight: in einem try/catch
/// auf. Gibt YES zurück wenn der Snapshot ohne Exception durchlief,
/// NO wenn etwas geworfen hat. Der Caller sollte bei NO davon
/// ausgehen, dass kein Frame-File geschrieben wurde und lastSnapshot
/// nicht aktualisiert ist.
BOOL VLCSafeSaveSnapshot(VLCMediaPlayer *player,
                         NSString *path,
                         int width,
                         int height);

NS_ASSUME_NONNULL_END
