// Bridges the system-wide "Now Playing" session (MediaRemote) to Vinyl.
//
// Since macOS 15.4 MediaRemote only answers Apple-signed clients, so this library is
// loaded into /usr/bin/perl (an Apple platform binary) and streams JSON lines to stdout.
// Entry points are installed as perl XSUBs; their arguments are ignored.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);

static void *mediaRemote;
static MRGetNowPlayingInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetPID getPID;
static NSUInteger lastArtworkHash;
static NSUInteger lastArtworkLength;
static BOOL emitScheduled;

static BOOL loadMediaRemote(void) {
    if (mediaRemote) return YES;
    mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mediaRemote) return NO;
    getInfo = (MRGetNowPlayingInfo)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetIsPlaying)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPID)dlsym(mediaRemote, "MRMediaRemoteGetNowPlayingApplicationPID");
    return getInfo && getIsPlaying && getPID;
}

static void writeLine(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id number(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *string(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static void emit(void) {
    emitScheduled = NO;
    dispatch_queue_t queue = dispatch_get_main_queue();
    getInfo(queue, ^(NSDictionary *info) {
        getPID(queue, ^(int pid) {
            getIsPlaying(queue, ^(Boolean playing) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                NSString *title = string(info, @"kMRMediaRemoteNowPlayingInfoTitle");
                out[@"active"] = @(info != nil && title.length > 0);
                out[@"playing"] = @(playing);
                out[@"pid"] = @(pid);
                NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
                if (app.bundleIdentifier) out[@"bundleID"] = app.bundleIdentifier;
                if (app.localizedName) out[@"appName"] = app.localizedName;
                if (info) {
                    out[@"title"] = title;
                    out[@"artist"] = string(info, @"kMRMediaRemoteNowPlayingInfoArtist");
                    out[@"album"] = string(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
                    id duration = number(info, @"kMRMediaRemoteNowPlayingInfoDuration");
                    if (duration) out[@"duration"] = duration;
                    double rate = [number(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate") doubleValue];
                    out[@"rate"] = @(rate);
                    id elapsed = number(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
                    if (elapsed) {
                        double position = [elapsed doubleValue];
                        id stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                        if (playing && [stamp isKindOfClass:[NSDate class]]) {
                            position += -[(NSDate *)stamp timeIntervalSinceNow] * (rate > 0 ? rate : 1);
                        }
                        out[@"elapsed"] = @(position);
                    }
                    id identifier = info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"]
                        ?: info[@"kMRMediaRemoteNowPlayingInfoUniqueIdentifier"];
                    if (identifier) out[@"id"] = [identifier description];

                    // Artwork is large: only send it when it changes.
                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if ([art isKindOfClass:[NSData class]] && art.length > 0) {
                        NSUInteger hash = art.hash;
                        if (hash != lastArtworkHash || art.length != lastArtworkLength) {
                            lastArtworkHash = hash;
                            lastArtworkLength = art.length;
                            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        }
                        out[@"hasArtwork"] = @YES;
                    } else {
                        out[@"hasArtwork"] = @NO;
                    }
                }
                writeLine(out);
            });
        });
    });
}

static void scheduleEmit(void) {
    if (emitScheduled) return;
    emitScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ emit(); });
}

/// Streams one JSON object per change (plus a heartbeat) until the process is killed.
void vinyl_stream(void) {
    @autoreleasepool {
        if (!loadMediaRemote()) {
            writeLine(@{ @"error": @"MediaRemote unavailable" });
            exit(2);
        }
        MRRegister registerFn = (MRRegister)dlsym(mediaRemote, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerFn) registerFn(dispatch_get_main_queue());

        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
                scheduleEmit();
            }];
        }
        // Exit when Vinyl goes away (stdin closes).
        dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(input, ^{
            char buffer[256];
            if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
        });
        dispatch_resume(input);

        [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) { emit(); }];
        emit();
        CFRunLoopRun();
    }
}

/// Sends the MediaRemote command number in $VINYL_COMMAND (2 = toggle, 4 = next, 5 = previous).
void vinyl_send(void) {
    if (!loadMediaRemote()) exit(2);
    MRSendCommand send = (MRSendCommand)dlsym(mediaRemote, "MRMediaRemoteSendCommand");
    const char *command = getenv("VINYL_COMMAND");
    if (!send || !command) exit(2);
    send(atoi(command), nil);
    exit(0);
}
