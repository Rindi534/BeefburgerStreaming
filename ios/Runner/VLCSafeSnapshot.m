// VLCSafeSnapshot.m — siehe Header für den Grund.
//
// Wichtig: Wir linken hier gegen MobileVLCKit, aber importieren es
// nur in der .m damit die Swift-Seite über den Bridging-Header
// keine VLCKit-Header durchschleifen muss (die werden ohnehin schon
// über VLCKit/VLCKit.h in den bestehenden Swift-Files gezogen, aber
// der Bridging-Header soll so schmal wie möglich bleiben).

#import "VLCSafeSnapshot.h"
#import <MobileVLCKit/MobileVLCKit.h>

BOOL VLCSafeSaveSnapshot(VLCMediaPlayer *player,
                         NSString *path,
                         int width,
                         int height) {
    if (player == nil || path == nil) {
        return NO;
    }
    @try {
        [player saveVideoSnapshotAt:path withWidth:width andHeight:height];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[VLCSafeSnapshot] saveVideoSnapshotAt threw: %@ — %@",
              exception.name, exception.reason);
        return NO;
    } @catch (...) {
        NSLog(@"[VLCSafeSnapshot] saveVideoSnapshotAt threw unknown exception");
        return NO;
    }
}
