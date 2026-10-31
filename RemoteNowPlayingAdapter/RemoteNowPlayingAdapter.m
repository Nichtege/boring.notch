//
//  RemoteNowPlayingAdapter.m
//  RemoteNowPlayingAdapter
//
//  Tells what other devices play, like the iPhone or a HomePod, as macOS itself hears of it. Passes commands on to them.
//  macOS answers MediaRemote only for its own programs, so this gets loaded into /usr/bin/perl. It writes one JSON
//  line per change and reads one command per line. The end of its input means the app is gone. Nothing is kept.
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>

@interface NSObject (MediaRemote)
@property (readonly) NSString *displayName;
@property (readonly) NSString *bundleIdentifier;
@end

typedef void (*RegisterFunction)(dispatch_queue_t);
typedef void (*OriginsFunction)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*InfoFunction)(id, dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*ClientFunction)(id, dispatch_queue_t, void (^)(id));
typedef Boolean (*IsLocalFunction)(id);
typedef void *(*PathFunction)(id, id, id);
typedef void (*SendFunction)(unsigned, CFDictionaryRef, void *, unsigned, dispatch_queue_t, void (^)(unsigned, CFArrayRef));

static OriginsFunction getOrigins;
static InfoFunction getInfo;
static ClientFunction getClient;
static IsLocalFunction isLocal;
static PathFunction makePath;
static SendFunction sendCommand;
static CFStringRef *skipIntervalKey;

// All of this belongs to the queue
static dispatch_queue_t queue;
static NSDictionary *originsByName;
static NSString *lastLine;
static NSMutableDictionary *lastArtworkKeys;
static BOOL isRefreshDue;

static NSDictionary *payload(NSDictionary *info, id origin, id client) {
    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"title"] = title;
    result[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
    result[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    result[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    result[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    result[@"rate"] = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    result[@"item"] = info[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"];
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if (stamp) result[@"stamp"] = @(stamp.timeIntervalSince1970);
    if ([origin respondsToSelector:@selector(displayName)]) result[@"device"] = [origin displayName];
    if ([client respondsToSelector:@selector(bundleIdentifier)]) result[@"app"] = [client bundleIdentifier];
    return result;
}

static void emit(NSArray *entries) {
    NSMutableArray *devices = [NSMutableArray array];
    for (NSArray *entry in entries) {
        [devices addObject:payload(entry[1], entry[0], entry[2] == NSNull.null ? nil : entry[2])];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"devices": devices} options:NSJSONWritingSortedKeys error:nil];
    if (!json) return;
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];

    // A cover comes once for each item. It can also follow a moment after the rest
    BOOL hasNewArtwork = NO;
    for (NSUInteger index = 0; index < entries.count; index++) {
        NSDictionary *info = entries[index][1];
        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSString *device = devices[index][@"device"] ?: @"";
        NSString *artworkKey = [NSString stringWithFormat:@"%@|%@", devices[index][@"item"], info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]];
        if (artwork.length > 0 && ![artworkKey isEqualToString:lastArtworkKeys[device]]) {
            lastArtworkKeys[device] = artworkKey;
            devices[index][@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            hasNewArtwork = YES;
        }
    }
    if (!hasNewArtwork && [line isEqualToString:lastLine]) return;
    lastLine = line;

    if (hasNewArtwork) json = [NSJSONSerialization dataWithJSONObject:@{@"devices": devices} options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    getOrigins(queue, ^(CFArrayRef list) {
        NSMutableArray *origins = [NSMutableArray array];
        for (id origin in (__bridge NSArray *)list) {
            if (!isLocal(origin)) [origins addObject:origin];
        }

        NSMutableArray *found = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (id origin in origins) {
            dispatch_group_enter(group);
            getInfo(origin, queue, ^(CFDictionaryRef info) {
                NSDictionary *dictionary = [(__bridge NSDictionary *)info copy] ?: @{};
                getClient(origin, queue, ^(id client) {
                    [found addObject:@[origin, dictionary, client ?: NSNull.null]];
                    dispatch_group_leave(group);
                });
            });
        }
        dispatch_group_notify(group, queue, ^{
            // Only what has something to show, and always in the same order
            NSMutableArray *entries = [NSMutableArray array];
            NSMutableDictionary *names = [NSMutableDictionary dictionary];
            for (NSArray *entry in found) {
                if ([entry[0] respondsToSelector:@selector(displayName)]) names[[entry[0] displayName]] = entry[0];
                if (entry[1][@"kMRMediaRemoteNowPlayingInfoTitle"] != nil) [entries addObject:entry];
            }
            originsByName = names;
            [entries sortUsingComparator:^NSComparisonResult(NSArray *one, NSArray *other) {
                return [[one[0] description] compare:[other[0] description]];
            }];
            emit(entries);
        });
    });
}

static void scheduleRefresh(void) {
    dispatch_async(queue, ^{
        if (isRefreshDue) return;
        isRefreshDue = YES;
        // One change comes as a whole burst of notifications
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), queue, ^{
            isRefreshDue = NO;
            refresh();
        });
    });
}

/// One line: the command, its device, and how far for a skip. Separated by tabs, as device names have spaces.
static void handleCommand(NSString *line) {
    NSArray *fields = [line componentsSeparatedByString:@"\t"];
    if ([fields.firstObject isEqualToString:@"refresh"]) {
        scheduleRefresh();
        return;
    }
    NSDictionary *commands = @{@"play": @0, @"pause": @1, @"toggle": @2, @"next": @4, @"previous": @5, @"forward": @17, @"backward": @18};
    NSNumber *command = commands[fields.firstObject];
    id origin = fields.count > 1 ? originsByName[fields[1]] : nil;
    if (!command || !origin) return;

    NSDictionary *options = nil;
    if (fields.count > 2 && skipIntervalKey) options = @{(__bridge NSString *)*skipIntervalKey: @([fields[2] doubleValue])};
    id path = (__bridge_transfer id)makePath(origin, nil, nil);
    sendCommand(command.unsignedIntValue, (__bridge CFDictionaryRef)options, (__bridge void *)path, 0, queue, ^(unsigned error, CFArrayRef statuses) {});
}

__attribute__((visibility("default"))) void run(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    RegisterFunction registerForNotifications = dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getOrigins = dlsym(framework, "MRMediaRemoteGetAvailableOrigins");
    getInfo = dlsym(framework, "MRMediaRemoteGetNowPlayingInfoForOrigin");
    getClient = dlsym(framework, "MRMediaRemoteGetNowPlayingClientForOrigin");
    isLocal = dlsym(framework, "MROriginIsLocalOrigin");
    makePath = dlsym(framework, "MRNowPlayingPlayerPathCreate");
    sendCommand = dlsym(framework, "MRMediaRemoteSendCommandToPlayer");
    skipIntervalKey = dlsym(framework, "kMRMediaRemoteOptionSkipInterval");
    // Another macOS may not have these any more. The app then simply shows nothing from other devices
    if (!registerForNotifications || !getOrigins || !getInfo || !getClient || !isLocal || !makePath || !sendCommand) return;

    queue = dispatch_queue_create("com.nichtege.boringnotch.remotenowplaying", DISPATCH_QUEUE_SERIAL);
    lastArtworkKeys = [NSMutableDictionary dictionary];

    registerForNotifications(dispatch_get_main_queue());
    NSArray *names = @[
        @"kMRMediaRemoteOriginNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteOriginNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteOriginNowPlayingApplicationPlaybackStateDidChangeNotification",
        @"kMROriginNowPlayingPlaybackQueueChangedNotification",
        @"kMROriginPlaybackQueueContentItemArtworkChangedNotification",
    ];
    for (NSString *name in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            scheduleRefresh();
        }];
    }

    // The notifications say what changes on a device, not when one comes or goes
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ refresh(); });
    dispatch_resume(timer);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[256];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(queue, ^{ handleCommand(line); });
        }
        exit(0);
    });

    CFRunLoopRun();
}
