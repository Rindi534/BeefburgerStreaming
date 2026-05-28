// VLCLibvlcLogger.m
//
// libvlc-Log-Integration. Wir greifen den C-Handle der VLCLibrary
// via Reflection ab (genau wie in VLCFramePump für den Player-
// Handle) und registrieren uns als libvlc-Log-Callback. Alle
// Messages werden in Application Support / vlc-debug.log
// geschrieben.

#import "VLCLibvlcLogger.h"
#import <MobileVLCKit/MobileVLCKit.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <time.h>

// libvlc-Forward-Decls.
typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_log_t libvlc_log_t;

typedef void (*libvlc_log_cb)(void *data,
                               int level,
                               const libvlc_log_t *ctx,
                               const char *fmt,
                               va_list args);

extern void libvlc_log_set(libvlc_instance_t *p_instance,
                            libvlc_log_cb cb,
                            void *data);

extern void libvlc_log_unset(libvlc_instance_t *p_instance);

// Static state — der Logger ist app-global, eine Instanz reicht.
static BOOL g_attached = NO;
static NSString *g_logPath = nil;
static FILE *g_logFile = NULL;
static pthread_mutex_t g_logMutex = PTHREAD_MUTEX_INITIALIZER;

static const char *kLevelNames[] = {
    "DEBUG",   // 0
    "?",       // 1 (unused)
    "NOTICE",  // 2
    "WARN",    // 3
    "ERROR"    // 4
};

static void VLCLog_callback(void *data,
                             int level,
                             const libvlc_log_t *ctx,
                             const char *fmt,
                             va_list args)
{
    pthread_mutex_lock(&g_logMutex);
    if (g_logFile) {
        // Timestamp
        char ts[32];
        time_t t = time(NULL);
        struct tm tmInfo;
        localtime_r(&t, &tmInfo);
        strftime(ts, sizeof(ts), "%H:%M:%S", &tmInfo);

        const char *lvlName = (level >= 0 && level <= 4) ? kLevelNames[level] : "?";
        fprintf(g_logFile, "[%s][%s] ", ts, lvlName);
        vfprintf(g_logFile, fmt, args);
        fputc('\n', g_logFile);
        fflush(g_logFile);
    }
    pthread_mutex_unlock(&g_logMutex);
}

static libvlc_instance_t *VLCExtractLibvlcInstance(void)
{
    Class libCls = NSClassFromString(@"VLCLibrary");
    if (!libCls) return NULL;
    SEL sharedSel = NSSelectorFromString(@"sharedLibrary");
    if (![libCls respondsToSelector:sharedSel]) return NULL;
    IMP sharedImp = [libCls methodForSelector:sharedSel];
    id (*sharedFunc)(Class, SEL) = (id (*)(Class, SEL))sharedImp;
    id lib = sharedFunc(libCls, sharedSel);
    if (!lib) return NULL;

    // Probiere bekannte Accessor-Namen für den libvlc-instance-handle.
    NSArray<NSString *> *candidates = @[@"instance", @"_instance", @"libVLCInstance"];
    for (NSString *name in candidates) {
        SEL sel = NSSelectorFromString(name);
        if (![lib respondsToSelector:sel]) continue;
        IMP imp = [lib methodForSelector:sel];
        void *(*func)(id, SEL) = (void *(*)(id, SEL))imp;
        void *result = func(lib, sel);
        if (result) {
            NSLog(@"[VLCLibvlcLogger] got libvlc_instance_t* via -%@", name);
            return (libvlc_instance_t *)result;
        }
    }

    NSLog(@"[VLCLibvlcLogger] FAIL: VLCLibrary hat keinen bekannten "
          @"instance-Accessor");
    return NULL;
}

@implementation VLCLibvlcLogger

+ (NSString *)logPath
{
    if (g_logPath) return g_logPath;
    NSError *err = nil;
    NSURL *supportDir = [[NSFileManager defaultManager]
        URLForDirectory:NSApplicationSupportDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:&err];
    if (!supportDir) {
        NSLog(@"[VLCLibvlcLogger] cant get Application Support: %@", err);
        return @"/tmp/vlc-debug.log";
    }
    NSURL *fileUrl = [supportDir URLByAppendingPathComponent:@"vlc-debug.log"];
    g_logPath = [fileUrl.path copy];
    return g_logPath;
}

+ (BOOL)attach
{
    if (g_attached) return YES;

    libvlc_instance_t *inst = VLCExtractLibvlcInstance();
    if (!inst) return NO;

    NSString *path = [self logPath];
    pthread_mutex_lock(&g_logMutex);
    // Beim Start die Datei truncate'n damit sie nicht unbegrenzt
    // wächst.
    g_logFile = fopen([path UTF8String], "w");
    if (g_logFile) {
        fprintf(g_logFile, "=== libvlc log session start ===\n");
        fflush(g_logFile);
    }
    pthread_mutex_unlock(&g_logMutex);

    if (!g_logFile) {
        NSLog(@"[VLCLibvlcLogger] FAIL: cant open log file at %@", path);
        return NO;
    }

    libvlc_log_set(inst, VLCLog_callback, NULL);
    g_attached = YES;
    NSLog(@"[VLCLibvlcLogger] attached, writing to %@", path);
    return YES;
}

+ (NSString *)readLogTail
{
    NSString *path = [self logPath];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return @"(no log file)";
    @try {
        // Letzte 50 KB lesen
        const unsigned long long kMaxBytes = 50 * 1024;
        unsigned long long size = [fh seekToEndOfFile];
        unsigned long long start = (size > kMaxBytes) ? (size - kMaxBytes) : 0;
        [fh seekToFileOffset:start];
        NSData *data = [fh readDataToEndOfFile];
        [fh closeFile];
        NSString *str = [[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding];
        return str ?: @"(decode failure)";
    } @catch (NSException *ex) {
        return [NSString stringWithFormat:@"(read failure: %@)", ex.reason];
    }
}

@end
