#import "ELDownloadManager.h"
#import "ELAudioEngine.h"
#import "ELHTTPClient.h"
#import "ELImageCache.h"
#import "ELYouTubeClient.h"
#import "ELLyricsClient.h"
#import "el_fmp4_adts.h"
#include <stdio.h>

NSString *const ELDownloadsChangedNotification = @"ELDownloadsChangedNotification";
NSString *const ELDownloadProgressNotification = @"ELDownloadProgressNotification";
NSString *const ELDownloadBatchProgressNotification = @"ELDownloadBatchProgressNotification";

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
    double lastPriority;
    BOOL writeError;
} el_dl_ctx_t;

static void el_dl_on_adts_frame(const uint8_t *adts, size_t len, void *userData) {
    el_dl_ctx_t *d = (el_dl_ctx_t *)userData;
    if (!d || !d->outFile || d->writeError) return;
    if (fwrite(adts, 1, len, d->outFile) != len) {
        d->writeError = YES;
    }
}

@interface ELDownloadManager (Internal)
- (double)currentWorkerPriority;
- (NSUInteger)currentMaxConcurrentDownloads;
- (void)loadIndex;
- (void)pumpQueue;
@end

static BOOL el_dl_on_http_chunk(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_dl_ctx_t *d = (el_dl_ctx_t *)userData;
    if (!d || d->writeError) return NO;
    if (![d->mgr isDownloading:d->videoId]) return NO; /* Cancelled */

    double targetPrio = [d->mgr currentWorkerPriority];
    if (targetPrio != d->lastPriority) {
        d->lastPriority = targetPrio;
        [NSThread setThreadPriority:targetPrio];
    }

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
        _downloadedIds = [[NSMutableSet alloc] init];
        _pendingQueue = [[NSMutableArray alloc] init];
        _queuedIds = [[NSMutableSet alloc] init];
        _progressById = [[NSMutableDictionary alloc] init];
        _activeIds = [[NSMutableSet alloc] init];
        _cancelledIds = [[NSMutableSet alloc] init];
        _retryCountById = [[NSMutableDictionary alloc] init];
        _batchIds = [[NSMutableSet alloc] init];
        _dlBgTask = UIBackgroundTaskInvalid;

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        _downloadsDir = [[docs stringByAppendingPathComponent:@"EchoLegacy/downloads"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:_downloadsDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        [self loadIndex];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onPlayerStateChanged:) name:ELPlayerStateChangedNotification object:nil];
        [nc addObserver:self selector:@selector(onAppDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(onAppDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tracks release];
    [_downloadedIds release];
    [_pendingQueue release];
    [_queuedIds release];
    [_progressById release];
    [_activeIds release];
    [_cancelledIds release];
    [_retryCountById release];
    [_batchIds release];
    [_batchTitle release];
    [_downloadsDir release];
    [super dealloc];
}

- (NSInteger)batchTotal {
    @synchronized(self) { return _batchTotal; }
}

- (NSInteger)batchCompleted {
    @synchronized(self) { return _batchCompleted; }
}

- (BOOL)isBatchDownloading {
    @synchronized(self) { return ([_batchIds count] > 0 && _batchTotal > 0); }
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
        [_downloadedIds removeAllObjects];
        for (id item in arr) {
            ELTrack *t = [ELTrack trackFromDictionary:item];
            if (t && [t.videoId length] > 0 && [fm fileExistsAtPath:[self localAudioPathForVideoId:t.videoId]]) {
                if (![_downloadedIds containsObject:t.videoId]) {
                    [_tracks addObject:t];
                    [_downloadedIds addObject:t.videoId];
                }
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
        return [_downloadedIds containsObject:videoId];
    }
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
        return [_queuedIds containsObject:videoId];
    }
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

- (void)postBatchProgressOnMain:(NSDictionary *)info {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELDownloadBatchProgressNotification
                                                        object:self
                                                      userInfo:info];
}

- (void)postBatchToastOnMain:(NSString *)msg {
    if ([msg length] == 0) return;
    NSDictionary *ui = [NSDictionary dictionaryWithObject:msg forKey:@"message"];
    [[NSNotificationCenter defaultCenter] postNotificationName:ELPlayerToastNotification
                                                        object:self
                                                      userInfo:ui];
}

- (void)dispatchBatchProgressNotification {
    NSDictionary *info = nil;
    @synchronized(self) {
        BOOL active = ([_batchIds count] > 0 && _batchTotal > 0);
        info = [NSDictionary dictionaryWithObjectsAndKeys:
                (_batchTitle ? _batchTitle : @""), @"title",
                [NSNumber numberWithInteger:_batchTotal], @"total",
                [NSNumber numberWithInteger:_batchCompleted], @"completed",
                [NSNumber numberWithBool:active], @"active",
                nil];
    }
    [self performSelectorOnMainThread:@selector(postBatchProgressOnMain:) withObject:info waitUntilDone:NO];
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

- (BOOL)isLiveStreamingActive {
    BOOL bg = NO;
    @synchronized(self) { bg = _isBackgrounded; }
    if (bg) return NO;
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELPlayerState st = eng.state;
    return (st == ELPlayerStateLoading || (st == ELPlayerStatePlaying && !eng.isPlayingOffline));
}

- (double)currentWorkerPriority {
    return [self isLiveStreamingActive] ? 0.15 : 0.55;
}

- (NSUInteger)currentMaxConcurrentDownloads {
    return [self isLiveStreamingActive] ? 1 : EL_MAX_CONCURRENT_DOWNLOADS;
}

- (void)onPlayerStateChanged:(NSNotification *)note {
    [self pumpQueue];
}

- (void)onAppDidEnterBackground:(NSNotification *)note {
    @synchronized(self) { _isBackgrounded = YES; }
    [self pumpQueue];
}

- (void)onAppDidBecomeActive:(NSNotification *)note {
    @synchronized(self) { _isBackgrounded = NO; }
    [self pumpQueue];
}

- (void)pumpQueue {
    NSMutableArray *toLaunch = [NSMutableArray array];
    BOOL anyRemaining = NO;
    NSUInteger maxConcurrent = [self currentMaxConcurrentDownloads];

    @synchronized(self) {
        while ([_activeIds count] < maxConcurrent && [_pendingQueue count] > 0) {
            ELTrack *next = [[[_pendingQueue objectAtIndex:0] retain] autorelease];
            [_pendingQueue removeObjectAtIndex:0];
            [_queuedIds removeObject:next.videoId];
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

    @synchronized(self) {
        if ([_downloadedIds containsObject:track.videoId] ||
            ([_activeIds containsObject:track.videoId] && ![_cancelledIds containsObject:track.videoId]) ||
            [_queuedIds containsObject:track.videoId]) {
            return;
        }
        [_cancelledIds removeObject:track.videoId];
        [_pendingQueue addObject:track];
        [_queuedIds addObject:track.videoId];
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
            if ([_downloadedIds containsObject:track.videoId] ||
                [_activeIds containsObject:track.videoId] ||
                [_queuedIds containsObject:track.videoId]) {
                continue;
            }
            [_cancelledIds removeObject:track.videoId];
            [_pendingQueue addObject:track];
            [_queuedIds addObject:track.videoId];
            added = YES;
        }
    }
    if (added) {
        [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
        [self pumpQueue];
    }
}

- (void)downloadPlaylistTracks:(NSArray *)tracks title:(NSString *)title {
    if (!tracks || [tracks count] == 0) return;

    NSInteger totalCount = 0;
    NSInteger alreadyCount = 0;
    BOOL hasPending = NO;

    @synchronized(self) {
        [_batchIds removeAllObjects];
        [_batchTitle release];
        _batchTitle = [title copy];
        _batchTotal = 0;
        _batchCompleted = 0;

        NSMutableSet *seenBatch = [NSMutableSet set];
        for (ELTrack *track in tracks) {
            if (!track || [track.videoId length] == 0) continue;
            if ([seenBatch containsObject:track.videoId]) continue;
            [seenBatch addObject:track.videoId];

            totalCount++;
            if ([_downloadedIds containsObject:track.videoId]) {
                alreadyCount++;
                continue;
            }

            [_batchIds addObject:track.videoId];
            [_retryCountById removeObjectForKey:track.videoId];

            BOOL inFlight = ([_activeIds containsObject:track.videoId] || [_queuedIds containsObject:track.videoId]);
            if (!inFlight) {
                [_cancelledIds removeObject:track.videoId];
                [_pendingQueue addObject:track];
                [_queuedIds addObject:track.videoId];
            }
        }

        _batchTotal = totalCount;
        _batchCompleted = alreadyCount;
        hasPending = ([_batchIds count] > 0);
    }

    [self dispatchBatchProgressNotification];
    if (!hasPending && totalCount > 0) {
        NSString *msg = [NSString stringWithFormat:@"Playlist saved (%ld tracks)", (long)totalCount];
        [self performSelectorOnMainThread:@selector(postBatchToastOnMain:) withObject:msg waitUntilDone:NO];
        @synchronized(self) {
            _batchTotal = 0;
            _batchCompleted = 0;
            [_batchTitle release]; _batchTitle = nil;
        }
    } else if (hasPending) {
        [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
        [self pumpQueue];
    }
}

- (void)cancelBatchDownload {
    NSArray *idsToCancel = nil;
    @synchronized(self) {
        idsToCancel = [_batchIds allObjects];
        [_batchIds removeAllObjects];
        _batchTotal = 0;
        _batchCompleted = 0;
        [_batchTitle release]; _batchTitle = nil;
    }
    for (NSString *vid in idsToCancel) {
        [self cancelDownloadForVideoId:vid];
    }
    [self dispatchBatchProgressNotification];
}

- (void)downloadWorker:(ELTrack *)track {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    double initPrio = [self currentWorkerPriority];
    [NSThread setThreadPriority:initPrio];
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
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
            dctx.lastPriority = initPrio;

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
                [fm removeItemAtPath:finalAudio error:nil];
                if ([fm moveItemAtPath:tmpAudio toPath:finalAudio error:nil]) {
                    success = YES;
                }
            }
        }
    }

    if (!success) {
        [fm removeItemAtPath:tmpAudio error:nil];
    }

    BOOL requeued = NO;
    BOOL batchUpdated = NO;
    BOOL batchFinished = NO;
    NSInteger batchSavedCount = 0;

    @synchronized(self) {
        BOOL wasCancelled = [_cancelledIds containsObject:vid];
        [_activeIds removeObject:vid];
        [_progressById removeObjectForKey:vid];
        [_cancelledIds removeObject:vid];
        if (success && !wasCancelled) {
            [_retryCountById removeObjectForKey:vid];
            for (NSInteger i = (NSInteger)[_tracks count] - 1; i >= 0; i--) {
                if ([[[_tracks objectAtIndex:i] videoId] isEqualToString:vid]) {
                    [_tracks removeObjectAtIndex:i];
                }
            }
            [_tracks insertObject:track atIndex:0];
            [_downloadedIds addObject:vid];
        } else if (!wasCancelled) {
            NSInteger retries = [[_retryCountById objectForKey:vid] integerValue];
            if (retries < 2) {
                [_retryCountById setObject:[NSNumber numberWithInteger:retries + 1] forKey:vid];
                if (![_queuedIds containsObject:vid] && ![_downloadedIds containsObject:vid]) {
                    [_pendingQueue addObject:track];
                    [_queuedIds addObject:vid];
                }
                requeued = YES;
            } else {
                [_retryCountById removeObjectForKey:vid];
            }
        } else {
            success = NO;
            [_retryCountById removeObjectForKey:vid];
        }

        if (!requeued && [_batchIds containsObject:vid]) {
            [_batchIds removeObject:vid];
            _batchCompleted++;
            batchUpdated = YES;
            if ([_batchIds count] == 0 && _batchTotal > 0) {
                batchFinished = YES;
                batchSavedCount = _batchCompleted;
            }
        }
    }

    if (success) {
        [self saveIndex];
    } else {
        [fm removeItemAtPath:finalAudio error:nil];
    }
    [self performSelectorOnMainThread:@selector(postChangedOnMain) withObject:nil waitUntilDone:NO];
    if (batchUpdated) {
        [self dispatchBatchProgressNotification];
    }
    if (batchFinished) {
        NSString *msg = [NSString stringWithFormat:@"Playlist saved (%ld tracks)", (long)batchSavedCount];
        [self performSelectorOnMainThread:@selector(postBatchToastOnMain:) withObject:msg waitUntilDone:NO];
        @synchronized(self) {
            _batchTotal = 0;
            _batchCompleted = 0;
            [_batchTitle release]; _batchTitle = nil;
        }
    }
    if (success && ![[ELLyricsClient sharedClient] cachedLyricsForVideoId:vid]) {
        [[ELLyricsClient sharedClient] fetchLyricsForTrack:track error:nil];
    }
    [self pumpQueue];
    [pool release];
}

- (void)cancelDownloadForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return;
    @synchronized(self) {
        [_cancelledIds addObject:videoId];
        [_queuedIds removeObject:videoId];
        [_progressById removeObjectForKey:videoId];
        [_retryCountById removeObjectForKey:videoId];
        [_batchIds removeObject:videoId];
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
    [[ELLyricsClient sharedClient] deleteCachedLyricsForVideoId:videoId];
    @synchronized(self) {
        [_downloadedIds removeObject:videoId];
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
