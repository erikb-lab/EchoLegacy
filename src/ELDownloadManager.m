#import "ELDownloadManager.h"
#import "ELHTTPClient.h"
#import "ELImageCache.h"
#import "ELYouTubeClient.h"
#import "el_fmp4_adts.h"
#include <stdio.h>

NSString *const ELDownloadsChangedNotification = @"ELDownloadsChangedNotification";
NSString *const ELDownloadProgressNotification = @"ELDownloadProgressNotification";

/* Max 2 simultaneous TLS downloads to protect 128 MB RAM & ARM11 CPU */
#define EL_MAX_CONCURRENT_DOWNLOADS 2

typedef struct {
    FILE *outFile;
    el_fmp4_ctx_t *fmp4;
    ELDownloadManager *mgr;
    NSString *videoId;
    long long expectedBytes;
    long long receivedBytes;
    int lastReportedPct;
    BOOL writeError;
} el_dl_ctx_t;

static void el_dl_on_adts_frame(const uint8_t *adts, size_t len, void *userData) {
    el_dl_ctx_t *d = (el_dl_ctx_t *)userData;
    if (!d || !d->outFile || d->writeError) return;
    if (fwrite(adts, 1, len, d->outFile) != len) {
        d->writeError = YES;
    }
}

static BOOL el_dl_on_http_chunk(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_dl_ctx_t *d = (el_dl_ctx_t *)userData;
    if (!d || d->writeError) return NO;
    if (![d->mgr isDownloading:d->videoId]) return NO; /* Cancelled */

    if (el_fmp4_feed(d->fmp4, bytes, length) < 0) {
        d->writeError = YES;
        return NO;
    }

    d->receivedBytes += length;
    long long total = (contentLength > 0) ? contentLength : d->expectedBytes;
    if (total > 0) {
        int pct = (int)((d->receivedBytes * 100) / total);
        if (pct > 99) pct = 99;
        if (pct >= d->lastReportedPct + 3) {
            d->lastReportedPct = pct;
            [d->mgr performSelector:@selector(updateProgressNumber:)
                         withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                     d->videoId, @"videoId",
                                     [NSNumber numberWithFloat:(float)pct / 100.0f], @"progress",
                                     nil]];
        }
    }
    return YES;
}

@implementation ELDownloadManager

+ (ELDownloadManager *)sharedManager {
    static ELDownloadManager *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELDownloadManager alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _tracks = [[NSMutableArray alloc] init];
        _pendingQueue = [[NSMutableArray alloc] init];
        _progressById = [[NSMutableDictionary alloc] init];
        _activeIds = [[NSMutableSet alloc] init];
        _cancelledIds = [[NSMutableSet alloc] init];
        _dlBgTask = UIBackgroundTaskInvalid;

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        _downloadsDir = [[docs stringByAppendingPathComponent:@"EchoLegacy/downloads"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:_downloadsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [self loadIndex];
    }
    return self;
}

- (void)dealloc {
    [_tracks release];
    [_pendingQueue release];
    [_progressById release];
    [_activeIds release];
    [_cancelledIds release];
    [_downloadsDir release];
    [super dealloc];
}

- (NSString *)indexPath {
    return [_downloadsDir stringByAppendingPathComponent:@"index.plist"];
}

- (NSString *)localAudioPathForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return nil;
    return [_downloadsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.aac", videoId]];
}

- (NSString *)localArtPathForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return nil;
    return [_downloadsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", videoId]];
}

- (UIImage *)localArtImageForVideoId:(NSString *)videoId {
    NSString *p = [self localArtPathForVideoId:videoId];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        return [UIImage imageWithContentsOfFile:p];
    }
    return nil;
}

- (unsigned long long)totalDownloadedBytes {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:_downloadsDir error:nil];
    unsigned long long total = 0;
    for (NSString *f in files) {
        if ([f hasSuffix:@".aac"] || [f hasSuffix:@".jpg"]) {
            NSDictionary *a = [fm attributesOfItemAtPath:[_downloadsDir stringByAppendingPathComponent:f] error:nil];
            total += [[a objectForKey:NSFileSize] unsignedLongLongValue];
        }
    }
    return total;
}

- (void)loadIndex {
    NSArray *arr = [NSArray arrayWithContentsOfFile:[self indexPath]];
    if (![arr isKindOfClass:[NSArray class]]) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    @synchronized(self) {
        [_tracks removeAllObjects];
        for (id item in arr) {
            ELTrack *t = [ELTrack trackFromDictionary:item];
            if (t && [fm fileExistsAtPath:[self localAudioPathForVideoId:t.videoId]]) {
                [_tracks addObject:t];
            }
        }
    }
}

- (void)saveIndex {
    NSMutableArray *arr = [NSMutableArray array];
    @synchronized(self) {
        for (ELTrack *t in _tracks) [arr addObject:[t toDictionary]];
    }
    [arr writeToFile:[self indexPath] atomically:YES];
}

- (NSArray *)downloadedTracks {
    @synchronized(self) {
        return [[_tracks copy] autorelease];
    }
}

- (BOOL)isDownloaded:(NSString *)videoId {
    if ([videoId length] == 0) return NO;
    @synchronized(self) {
        for (ELTrack *t in _tracks) {
            if ([t.videoId isEqualToString:videoId]) return YES;
        }
    }
    return NO;
}

- (BOOL)isDownloading:(NSString *)videoId {
    if ([videoId length] == 0) return NO;
    @synchronized(self) {
        if ([_cancelledIds containsObject:videoId]) return NO;
        return [_activeIds containsObject:videoId];
    }
}

- (BOOL)isQueued:(NSString *)videoId {
    if ([videoId length] == 0) return NO;
    @synchronized(self) {
        for (ELTrack *t in _pendingQueue) {
            if ([t.videoId isEqualToString:videoId]) return YES;
        }
    }
    return NO;
}

- (float)progressForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return 0.0f;
    @synchronized(self) {
        NSNumber *n = [_progressById objectForKey:videoId];
        return n ? [n floatValue] : 0.0f;
    }
}

- (void)ensureBgTaskOnMain {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) return;
    if (_dlBgTask == UIBackgroundTaskInvalid) {
        _dlBgTask = [app beginBackgroundTaskWithExpirationHandler:^{
            [self endBgTaskOnMain];
        }];
    }
}

- (void)endBgTaskOnMain {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(endBackgroundTask:)]) return;
    if (_dlBgTask != UIBackgroundTaskInvalid) {
        UIBackgroundTaskIdentifier tid = _dlBgTask;
        _dlBgTask = UIBackgroundTaskInvalid;
        [app endBackgroundTask:tid];
    }
}

- (void)postProgressOnMain:(NSDictionary *)info {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELDownloadProgressNotification
                                                        object:self
                                                      userInfo:info];
}

- (void)postChangedOnMain {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELDownloadsChangedNotification
                                                        object:self];
}

- (void)updateProgressNumber:(NSDictionary *)info {
    NSString *vid = [info objectForKey:@"videoId"];
    NSNumber *prog = [info objectForKey:@"progress"];
    @synchronized(self) {
        if ([_activeIds containsObject:vid]) {
            [_progressById setObject:prog forKey:vid];
        }
    }
    [self performSelectorOnMainThread:@selector(postProgressOnMain:) withObject:info waitUntilDone:NO];
}

- (void)pumpQueue {
    NSMutableArray *toLaunch = [NSMutableArray array];
    BOOL anyRemaining = NO;

    @synchronized(self) {
        while ([_activeIds count] < EL_MAX_CONCURRENT_DOWNLOADS && [_pendingQueue count] > 0) {
            ELTrack *next = [[[_pendingQueue objectAtIndex:0] retain] autorelease];
            [_pendingQueue removeObjectAtIndex:0];
            if ([_cancelledIds containsObject:next.videoId]) {
                [_cancelledIds removeObject:next.videoId];
                continue;
            }
            [_activeIds addObject:next.videoId];
            [_progressById setObject:[NSNumber numberWithFloat:0.01f] forKey:next.videoId];
            [toLaunch addObject:next];
        }
        anyRemaining = ([_activeIds count] > 0 || [_pendingQueue count] > 0);
    }

    if (anyRemaining) {
        [self performSelectorOnMainThread:@selector(ensureBgTaskOnMain) withObject:nil waitUntilDone:NO];
    } else {
        [self performSelectorOnMainThread:@selector(endBgTaskOnMain) withObject:nil waitUntilDone:NO];
    }

    for (ELTrack *t in toLaunch) {
        [self performSelectorOnMainThread:@selector(postProgressOnMain:)
                               withObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                           t.videoId, @"videoId",
                                           [NSNumber numberWithFloat:0.01f], @"progress",
                                           nil]
                            waitUntilDone:NO];
        [NSThread detachNewThreadSelector:@selector(downloadWorker:) toTarget:self withObject:t];
    }
}

- (void)downloadTrack:(ELTrack *)track {
    if (!track || [track.videoId length] == 0) return;
    if ([self isDownloaded:track.videoId] || [self isDownloading:track.videoId] || [self isQueued:track.videoId]) return;

    @synchronized(self) {
        [_cancelledIds removeObject:track.videoId];
        [_pendingQueue addObject:track];
    }
    [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
    [self pumpQueue];
}

- (void)downloadTracks:(NSArray *)tracks {
    if (!tracks || [tracks count] == 0) return;
    BOOL added = NO;
    @synchronized(self) {
        for (ELTrack *track in tracks) {
            if (!track || [track.videoId length] == 0) continue;
            BOOL exists = NO;
            for (ELTrack *d in _tracks) {
                if ([d.videoId isEqualToString:track.videoId]) { exists = YES; break; }
            }
            if (exists || [_activeIds containsObject:track.videoId]) continue;
            for (ELTrack *q in _pendingQueue) {
                if ([q.videoId isEqualToString:track.videoId]) { exists = YES; break; }
            }
            if (exists) continue;
            [_cancelledIds removeObject:track.videoId];
            [_pendingQueue addObject:track];
            added = YES;
        }
    }
    if (added) {
        [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
        [self pumpQueue];
    }
}

- (void)downloadWorker:(ELTrack *)track {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *vid = track.videoId;
    NSString *finalAudio = [self localAudioPathForVideoId:vid];
    NSString *tmpAudio = [finalAudio stringByAppendingString:@".part"];
    BOOL success = NO;

    NSString *err = nil;
    ELStreamInfo *stream = [[ELYouTubeClient sharedClient] resolveAudioStreamForVideoId:vid error:&err];
    if (stream && [self isDownloading:vid]) {
        NSString *artSrc = ([track.artURL length] > 0) ? track.artURL : track.thumbURL;
        if ([artSrc length] > 0) {
            NSData *jpg = [[ELImageCache sharedCache] downloadImageDataSyncForURL:artSrc];
            if (jpg) [jpg writeToFile:[self localArtPathForVideoId:vid] atomically:YES];
        }

        FILE *fp = fopen([tmpAudio UTF8String], "wb");
        if (fp) {
            el_dl_ctx_t dctx;
            memset(&dctx, 0, sizeof(dctx));
            dctx.outFile = fp;
            dctx.fmp4 = el_fmp4_create(el_dl_on_adts_frame, &dctx);
            dctx.mgr = self;
            dctx.videoId = vid;
            dctx.expectedBytes = stream.contentLength;
            dctx.lastReportedPct = 1;

            NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                                  stream.userAgent, @"User-Agent",
                                  nil];
            NSInteger status = 0;
            NSString *httpErr = nil;
            BOOL ok = [[ELHTTPClient sharedClient] streamRangeChunksGETURL:stream.url
                                                                   headers:hdrs
                                                               startOffset:0
                                                               totalLength:stream.contentLength
                                                                 chunkSize:524288
                                                                  callback:el_dl_on_http_chunk
                                                                  userData:&dctx
                                                                statusCode:&status
                                                                     error:&httpErr];
            fclose(fp);
            double parsedDur = el_fmp4_total_duration(dctx.fmp4);
            if (parsedDur > 0 && track.durationSeconds <= 0) {
                track.durationSeconds = (NSInteger)parsedDur;
                track.durationText = [ELTrack formatSeconds:parsedDur];
            }
            el_fmp4_destroy(dctx.fmp4);

            if (ok && (status == 200 || status == 206) && !dctx.writeError && [self isDownloading:vid] && dctx.receivedBytes > 1024) {
                [[NSFileManager defaultManager] removeItemAtPath:finalAudio error:nil];
                if ([[NSFileManager defaultManager] moveItemAtPath:tmpAudio toPath:finalAudio error:nil]) {
                    success = YES;
                }
            }
        }
    }

    if (!success) {
        [[NSFileManager defaultManager] removeItemAtPath:tmpAudio error:nil];
    }

    @synchronized(self) {
        [_activeIds removeObject:vid];
        [_progressById removeObjectForKey:vid];
        [_cancelledIds removeObject:vid];
        if (success) {
            for (NSInteger i = (NSInteger)[_tracks count] - 1; i >= 0; i--) {
                if ([[[_tracks objectAtIndex:i] videoId] isEqualToString:vid]) {
                    [_tracks removeObjectAtIndex:i];
                }
            }
            [_tracks insertObject:track atIndex:0];
        }
    }

    if (success) [self saveIndex];
    [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
    [self pumpQueue];
    [pool release];
}

- (void)cancelDownloadForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return;
    @synchronized(self) {
        [_cancelledIds addObject:videoId];
        [_progressById removeObjectForKey:videoId];
        for (NSInteger i = (NSInteger)[_pendingQueue count] - 1; i >= 0; i--) {
            if ([[[_pendingQueue objectAtIndex:i] videoId] isEqualToString:videoId]) {
                [_pendingQueue removeObjectAtIndex:i];
            }
        }
    }
    [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
}

- (void)deleteDownloadForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return;
    [self cancelDownloadForVideoId:videoId];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:[self localAudioPathForVideoId:videoId] error:nil];
    [fm removeItemAtPath:[self localArtPathForVideoId:videoId] error:nil];
    @synchronized(self) {
        for (NSInteger i = (NSInteger)[_tracks count] - 1; i >= 0; i--) {
            if ([[[_tracks objectAtIndex:i] videoId] isEqualToString:videoId]) {
                [_tracks removeObjectAtIndex:i];
            }
        }
    }
    [self saveIndex];
    [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
}

@end
