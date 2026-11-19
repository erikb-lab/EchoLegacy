#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#import "ELHTTPClient.h"
#import "ELYouTubeClient.h"
#import "el_fmp4_adts.h"
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

NSString *const ELPlayerStateChangedNotification = @"ELPlayerStateChangedNotification";
NSString *const ELPlayerProgressNotification = @"ELPlayerProgressNotification";
NSString *const ELPlayerToastNotification = @"ELPlayerToastNotification";

/* 8 x 16 KB = 128 KB (~8 seconds AAC buffer), lean for 128 MB RAM iPod touch 2G */
#define EL_AQ_NUM_BUFS  8
#define EL_AQ_BUF_SIZE  16384
#define EL_AQ_MAX_PKTS  128

/* 256 KB pre-next disk chunk (~16s of 128kbps AAC-LC + ftyp/moov/sidx index) */
#define EL_PRENEXT_CHUNK_BYTES  262144ULL
#define EL_PRENEXT_MAX_AGE_SEC  1800.0

static pthread_mutex_t g_prenext_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    ELAudioEngine *engine;
    NSInteger token;

    pthread_mutex_t lock;
    pthread_cond_t  cond;

    AudioFileStreamID afs;
    AudioQueueRef     aq;
    AudioQueueBufferRef bufs[EL_AQ_NUM_BUFS];
    BOOL              inUse[EL_AQ_NUM_BUFS];
    int               fillIdx;
    UInt32            fillBytes;
    UInt32            fillPkts;
    AudioStreamPacketDescription pktDescs[EL_AQ_MAX_PKTS];

    BOOL aqStarted;
    BOOL aqPaused;
    BOOL stopFlag;
    BOOL seekFlag;
    BOOL durationReported;
    double seekTargetSec;
    double sampleRate;
    double seekBaseSec;
    int queuedCount;

    el_fmp4_ctx_t *fmp4;
} el_stream_session_t;

static el_stream_session_t *g_active_stream = NULL;
static pthread_mutex_t g_active_lock = PTHREAD_MUTEX_INITIALIZER;

static void el_aq_output_cb(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    (void)inAQ;
    el_stream_session_t *s = (el_stream_session_t *)inUserData;
    pthread_mutex_lock(&s->lock);
    for (int i = 0; i < EL_AQ_NUM_BUFS; i++) {
        if (s->bufs[i] == inBuffer) {
            s->inUse[i] = NO;
            break;
        }
    }
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
}

static void el_aq_enqueue_fill(el_stream_session_t *s) {
    if (!s->aq || s->fillIdx < 0 || s->fillBytes == 0) return;

    AudioQueueBufferRef buf = s->bufs[s->fillIdx];
    buf->mAudioDataByteSize = s->fillBytes;
    s->inUse[s->fillIdx] = YES;

    OSStatus st = AudioQueueEnqueueBuffer(s->aq, buf, s->fillPkts, s->pktDescs);
    if (st != noErr) {
        s->inUse[s->fillIdx] = NO;
    } else {
        s->queuedCount++;
        if (!s->aqStarted && s->queuedCount >= 2) {
            if (!s->aqPaused) {
                AudioQueueStart(s->aq, NULL);
            }
            s->aqStarted = YES;
            [s->engine performSelectorOnMainThread:@selector(streamDidStartPlayingToken:)
                                        withObject:[NSNumber numberWithInteger:s->token]
                                     waitUntilDone:NO];
        }
    }

    s->fillIdx = -1;
    s->fillBytes = 0;
    s->fillPkts = 0;
}

static int el_aq_acquire_buf(el_stream_session_t *s) {
    pthread_mutex_lock(&s->lock);
    for (;;) {
        if (s->stopFlag || s->seekFlag) {
            pthread_mutex_unlock(&s->lock);
            return -1;
        }
        for (int i = 0; i < EL_AQ_NUM_BUFS; i++) {
            if (!s->inUse[i]) {
                pthread_mutex_unlock(&s->lock);
                return i;
            }
        }
        pthread_cond_wait(&s->cond, &s->lock);
    }
}

static void el_afs_property_cb(void *inClientData,
                               AudioFileStreamID inAFS,
                               AudioFileStreamPropertyID inPropertyID,
                               UInt32 *ioFlags) {
    (void)ioFlags;
    el_stream_session_t *s = (el_stream_session_t *)inClientData;
    if (inPropertyID == kAudioFileStreamProperty_ReadyToProducePackets) {
        if (s->aq != NULL) return;
        AudioStreamBasicDescription asbd;
        UInt32 sz = sizeof(asbd);
        if (AudioFileStreamGetProperty(inAFS, kAudioFileStreamProperty_DataFormat, &sz, &asbd) != noErr) {
            return;
        }
        if (asbd.mSampleRate > 0) s->sampleRate = asbd.mSampleRate;

        AudioQueueRef newAQ = NULL;
        OSStatus st = AudioQueueNewOutput(&asbd, el_aq_output_cb, s, NULL, NULL, 0, &newAQ);
        if (st != noErr || !newAQ) return;

        /* Copy magic cookie if present */
        UInt32 cookieSize = 0;
        Boolean writable = false;
        if (AudioFileStreamGetPropertyInfo(inAFS, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable) == noErr && cookieSize > 0) {
            void *cookie = malloc(cookieSize);
            if (cookie) {
                if (AudioFileStreamGetProperty(inAFS, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookie) == noErr) {
                    AudioQueueSetProperty(newAQ, kAudioQueueProperty_MagicCookie, cookie, cookieSize);
                }
                free(cookie);
            }
        }

        for (int i = 0; i < EL_AQ_NUM_BUFS; i++) {
            AudioQueueAllocateBuffer(newAQ, EL_AQ_BUF_SIZE, &s->bufs[i]);
            s->inUse[i] = NO;
        }
        s->fillIdx = -1;
        s->fillBytes = 0;
        s->fillPkts = 0;

        pthread_mutex_lock(&g_active_lock);
        s->aq = newAQ;
        pthread_mutex_unlock(&g_active_lock);
    }
}

static void el_afs_packets_cb(void *inClientData,
                              UInt32 inNumberBytes,
                              UInt32 inNumberPackets,
                              const void *inInputData,
                              AudioStreamPacketDescription *inPacketDescriptions) {
    el_stream_session_t *s = (el_stream_session_t *)inClientData;
    if (!s || !s->aq || s->stopFlag || s->seekFlag || !inInputData || !inPacketDescriptions) return;

    const uint8_t *base = (const uint8_t *)inInputData;
    for (UInt32 i = 0; i < inNumberPackets; i++) {
        if (s->stopFlag || s->seekFlag) return;
        SInt64 off = inPacketDescriptions[i].mStartOffset;
        UInt32 psize = inPacketDescriptions[i].mDataByteSize;
        if (off < 0 || psize == 0 || psize > EL_AQ_BUF_SIZE ||
            (uint64_t)off + (uint64_t)psize > (uint64_t)inNumberBytes) {
            continue;
        }

        if (s->fillIdx >= 0 && (s->fillBytes + psize > EL_AQ_BUF_SIZE || s->fillPkts >= EL_AQ_MAX_PKTS)) {
            el_aq_enqueue_fill(s);
        }
        if (s->fillIdx < 0) {
            s->fillIdx = el_aq_acquire_buf(s);
            if (s->fillIdx < 0) return;
            s->fillBytes = 0;
            s->fillPkts = 0;
        }

        AudioQueueBufferRef buf = s->bufs[s->fillIdx];
        memcpy((uint8_t *)buf->mAudioData + s->fillBytes, base + off, psize);
        s->pktDescs[s->fillPkts] = inPacketDescriptions[i];
        s->pktDescs[s->fillPkts].mStartOffset = s->fillBytes;
        s->fillBytes += psize;
        s->fillPkts++;
    }
}

static void el_stream_on_adts(const uint8_t *adts, size_t len, void *userData) {
    el_stream_session_t *s = (el_stream_session_t *)userData;
    if (!s || s->stopFlag || s->seekFlag || !s->afs) return;
    AudioFileStreamParseBytes(s->afs, (UInt32)len, adts, 0);
}

static BOOL el_stream_on_http_chunk(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    (void)contentLength;
    el_stream_session_t *s = (el_stream_session_t *)userData;
    if (!s || s->stopFlag || s->seekFlag) return NO;
    if (el_fmp4_feed(s->fmp4, bytes, length) < 0) return NO;
    if (!s->durationReported) {
        double d = el_fmp4_total_duration(s->fmp4);
        if (d > 0.0) {
            s->durationReported = YES;
            [s->engine notifyDuration:d forToken:s->token];
        }
    }
    return (!s->stopFlag && !s->seekFlag);
}

static void el_stream_teardown_aq(el_stream_session_t *s, BOOL immediate) {
    AudioQueueRef aqToDispose = NULL;
    pthread_mutex_lock(&g_active_lock);
    aqToDispose = s->aq;
    s->aq = NULL;
    s->aqStarted = NO;
    pthread_mutex_unlock(&g_active_lock);

    if (aqToDispose) {
        AudioQueueStop(aqToDispose, immediate ? true : false);
        AudioQueueDispose(aqToDispose, true);
    }
    if (s->afs) {
        AudioFileStreamClose(s->afs);
        s->afs = NULL;
    }
    pthread_mutex_lock(&s->lock);
    for (int i = 0; i < EL_AQ_NUM_BUFS; i++) {
        s->bufs[i] = NULL;
        s->inUse[i] = NO;
    }
    s->fillIdx = -1;
    s->fillBytes = 0;
    s->fillPkts = 0;
    s->queuedCount = 0;
    pthread_mutex_unlock(&s->lock);
}

static void el_audio_interruption_cb(void *inClientData, UInt32 inInterruptionState) {
    ELAudioEngine *eng = (ELAudioEngine *)inClientData;
    if (!eng) return;
    if (inInterruptionState == kAudioSessionBeginInterruption) {
        [eng performSelectorOnMainThread:@selector(handleAudioInterruptionBegin) withObject:nil waitUntilDone:NO];
    } else if (inInterruptionState == kAudioSessionEndInterruption) {
        [eng performSelectorOnMainThread:@selector(handleAudioInterruptionEnd) withObject:nil waitUntilDone:NO];
    }
}

static void el_audio_route_change_cb(void *inClientData,
                                     AudioSessionPropertyID inID,
                                     UInt32 inDataSize,
                                     const void *inData) {
    (void)inDataSize;
    if (inID != kAudioSessionProperty_AudioRouteChange || !inData) return;
    CFDictionaryRef dict = (CFDictionaryRef)inData;
    CFNumberRef reasonNum = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR(kAudioSession_AudioRouteChangeKey_Reason));
    if (reasonNum) {
        SInt32 reason = 0;
        CFNumberGetValue(reasonNum, kCFNumberSInt32Type, &reason);
        if (reason == kAudioSessionRouteChangeReason_OldDeviceUnavailable) {
            ELAudioEngine *eng = (ELAudioEngine *)inClientData;
            [eng performSelectorOnMainThread:@selector(pause) withObject:nil waitUntilDone:NO];
        }
    }
}

typedef struct {
    ELAudioEngine *engine;
    NSInteger gen;
    FILE *fp;
    uint64_t targetBytes;
    uint64_t writtenBytes;
    long long fullContentLength;
    BOOL writeError;
    BOOL reachedTarget;
} el_prenext_dl_ctx_t;

@interface ELAudioEngine (InternalHelpers)
- (BOOL)isPreNextGenCurrent:(NSInteger)gen;
- (void)notifyDuration:(double)duration forToken:(NSInteger)token;
@end

static BOOL el_prenext_on_http_chunk(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_prenext_dl_ctx_t *p = (el_prenext_dl_ctx_t *)userData;
    if (!p || !p->fp || p->writeError) return NO;
    if (![p->engine isPreNextGenCurrent:p->gen]) return NO;

    if (contentLength > 0 && p->fullContentLength <= 0) {
        p->fullContentLength = contentLength;
    }

    uint64_t rem = (p->targetBytes > p->writtenBytes) ? (p->targetBytes - p->writtenBytes) : 0;
    if (rem == 0) {
        p->reachedTarget = YES;
        return NO;
    }
    size_t toWrite = ((uint64_t)length < rem) ? (size_t)length : (size_t)rem;
    if (toWrite > 0) {
        if (fwrite(bytes, 1, toWrite, p->fp) != toWrite) {
            p->writeError = YES;
            return NO;
        }
        p->writtenBytes += (uint64_t)toWrite;
    }
    if (p->writtenBytes >= p->targetBytes) {
        p->reachedTarget = YES;
        return NO;
    }
    return YES;
}

@implementation ELAudioEngine

+ (ELAudioEngine *)sharedEngine {
    static ELAudioEngine *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELAudioEngine alloc] init];
    }
    return shared;
}

- (void)activateAudioSession {
    UInt32 category = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
    AudioSessionSetActive(true);

    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];
}

- (void)beginBgTransitionTask {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(beginBackgroundTaskWithExpirationHandler:)]) return;
    if (_bgTask != UIBackgroundTaskInvalid) return;
    _bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        [self endBgTransitionTask];
    }];
}

- (void)endBgTransitionTask {
    UIApplication *app = [UIApplication sharedApplication];
    if (![app respondsToSelector:@selector(endBackgroundTask:)]) return;
    if (_bgTask != UIBackgroundTaskInvalid) {
        UIBackgroundTaskIdentifier tid = _bgTask;
        _bgTask = UIBackgroundTaskInvalid;
        [app endBackgroundTask:tid];
    }
}

- (void)handleAudioInterruptionBegin {
    _resumeAfterInterruption = (_state == ELPlayerStatePlaying);
    if (_resumeAfterInterruption) {
        [self pause];
    }
}

- (void)handleAudioInterruptionEnd {
    [self activateAudioSession];
    if (_resumeAfterInterruption) {
        _resumeAfterInterruption = NO;
        [self resume];
    }
}

- (id)init {
    self = [super init];
    if (self) {
        _originalQueue = [[NSArray alloc] init];
        _queue = [[NSArray alloc] init];
        _currentIndex = -1;
        _state = ELPlayerStateStopped;
        _repeatMode = ELRepeatModeOff;
        _shuffleEnabled = NO;
        _bgTask = UIBackgroundTaskInvalid;

        NSArray *cpaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *caches = ([cpaths count] > 0) ? [cpaths objectAtIndex:0] : NSTemporaryDirectory();
        _preNextDir = [[caches stringByAppendingPathComponent:@"EchoLegacy"] retain];
        NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
        [fm createDirectoryAtPath:_preNextDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
        [self cleanupAllPreNextFilesInDir];

        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([ud objectForKey:@"ELShakeToShuffle"] == nil) {
            _shakeToShuffleEnabled = YES;
        } else {
            _shakeToShuffleEnabled = [ud boolForKey:@"ELShakeToShuffle"];
        }

        /* CoreAudio C AudioSession + AVAudioSession (both required on iOS 4.1 for AudioQueue background/lock playback) */
        AudioSessionInitialize(NULL, NULL, el_audio_interruption_cb, self);
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, el_audio_route_change_cb, self);
        [self activateAudioSession];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(onAppDidEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(onAppDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_sleepTimer invalidate];
    [_sleepTimer release]; _sleepTimer = nil;
    [_sleepFireDate release]; _sleepFireDate = nil;
    [self stop];
    [self clearPreNextBuffer];
    [_preNextDir release];
    [_originalQueue release];
    [_queue release];
    [_lastError release];
    [super dealloc];
}

- (NSString *)preNextPartPathForGen:(NSInteger)gen {
    return [_preNextDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"prenext_%ld.fmp4.part", (long)gen]];
}

- (NSString *)preNextReadyPath {
    return [_preNextDir stringByAppendingPathComponent:@"prenext.fmp4"];
}

- (NSString *)preNextActivePathForToken:(NSInteger)token {
    return [_preNextDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"prenext_active_%ld.fmp4", (long)token]];
}

- (void)cleanupAllPreNextFilesInDir {
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSArray *files = [fm contentsOfDirectoryAtPath:_preNextDir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"prenext"]) {
            unlink([[_preNextDir stringByAppendingPathComponent:f] UTF8String]);
        }
    }
}

- (BOOL)isPreNextGenCurrent:(NSInteger)gen {
    BOOL ok = NO;
    pthread_mutex_lock(&g_prenext_lock);
    ok = (gen == _preNextGen);
    pthread_mutex_unlock(&g_prenext_lock);
    return ok;
}

- (void)resetPreNextStateLocked:(BOOL)clearInFlight
                     clearReady:(BOOL)clearReady
                 clearAttempted:(BOOL)clearAttempted {
    if (clearInFlight) {
        NSInteger oldGen = _preNextGen;
        _preNextGen++;
        [_preNextInFlightVideoId release];
        _preNextInFlightVideoId = nil;
        unlink([[self preNextPartPathForGen:oldGen] UTF8String]);
    }
    if (clearReady) {
        [_preNextReadyVideoId release];
        _preNextReadyVideoId = nil;
        [_preNextStreamInfo release];
        _preNextStreamInfo = nil;
        _preNextByteLength = 0;
        _preNextReadyTime = 0;
        unlink([[self preNextReadyPath] UTF8String]);
    }
    if (clearAttempted) {
        [_preNextAttemptedVideoId release];
        _preNextAttemptedVideoId = nil;
        _preNextAttemptedSessionToken = 0;
    }
}

- (void)clearPreNextBuffer {
    pthread_mutex_lock(&g_prenext_lock);
    [self resetPreNextStateLocked:YES clearReady:YES clearAttempted:YES];
    pthread_mutex_unlock(&g_prenext_lock);
}

/* Determine upcoming track respecting Repeat One, Repeat All, Shuffle, and queue bounds.
   Returns nil if there is no upcoming track or if it is already downloaded/downloading offline. */
- (ELTrack *)nextCandidateTrack {
    NSUInteger count = [_queue count];
    if (count == 0 || _currentIndex < 0 || _currentIndex >= (NSInteger)count) {
        return nil;
    }
    ELTrack *cand = nil;
    if (_repeatMode == ELRepeatModeOne) {
        cand = [_queue objectAtIndex:(NSUInteger)_currentIndex];
    } else if (_currentIndex + 1 < (NSInteger)count) {
        cand = [_queue objectAtIndex:(NSUInteger)(_currentIndex + 1)];
    } else if (_repeatMode == ELRepeatModeAll) {
        cand = [_queue objectAtIndex:0];
    }
    if (!cand || [cand.videoId length] == 0) return nil;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if ([dm isDownloaded:cand.videoId] || [dm isDownloading:cand.videoId]) {
        return nil;
    }
    return cand;
}

- (void)syncPreNextWithCandidate {
    ELTrack *cand = [self nextCandidateTrack];
    NSString *candId = cand ? cand.videoId : nil;

    pthread_mutex_lock(&g_prenext_lock);
    BOOL matchReady = (candId && _preNextReadyVideoId && [_preNextReadyVideoId isEqualToString:candId]);
    BOOL matchInFlight = (candId && _preNextInFlightVideoId && [_preNextInFlightVideoId isEqualToString:candId]);
    if (!matchReady && !matchInFlight) {
        [self resetPreNextStateLocked:YES clearReady:YES clearAttempted:YES];
    }
    pthread_mutex_unlock(&g_prenext_lock);
}

- (void)maybeTriggerPreNextBuffer {
    if (_state != ELPlayerStatePlaying) return;

    double cur = [self currentTime];
    double dur = [self duration];
    /* Wait until current track has played smoothly for >= 10s (or >= 50% / <= 25s remaining on short tracks) */
    BOOL readyToPreBuffer = (cur >= 10.0) ||
                            (dur > 0.0 && cur >= 2.0 && ((dur - cur) <= 25.0 || cur >= dur * 0.5));
    if (!readyToPreBuffer) return;

    ELTrack *cand = [self nextCandidateTrack];
    if (!cand) {
        [self syncPreNextWithCandidate];
        return;
    }

    NSString *vid = cand.videoId;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger launchGen = 0;
    BOOL shouldLaunch = NO;

    pthread_mutex_lock(&g_prenext_lock);
    if (_preNextReadyVideoId && [_preNextReadyVideoId isEqualToString:vid]) {
        if (_preNextStreamInfo && _preNextByteLength > 0 &&
            (now - _preNextReadyTime) >= 0.0 && (now - _preNextReadyTime) < EL_PRENEXT_MAX_AGE_SEC) {
            /* Already pre-buffered and fresh! */
            pthread_mutex_unlock(&g_prenext_lock);
            return;
        }
        /* Expired ready buffer: clear attempted state so we immediately re-buffer a fresh copy */
        [self resetPreNextStateLocked:NO clearReady:YES clearAttempted:YES];
    }
    if (_preNextInFlightVideoId && [_preNextInFlightVideoId isEqualToString:vid]) {
        /* Already in flight for this videoId */
        pthread_mutex_unlock(&g_prenext_lock);
        return;
    }
    if (_preNextAttemptedSessionToken == _sessionToken &&
        _preNextAttemptedVideoId && [_preNextAttemptedVideoId isEqualToString:vid]) {
        /* Already attempted for this videoId during the current track session */
        pthread_mutex_unlock(&g_prenext_lock);
        return;
    }

    [self resetPreNextStateLocked:YES clearReady:YES clearAttempted:NO];
    launchGen = _preNextGen;
    _preNextInFlightVideoId = [vid copy];
    _preNextAttemptedSessionToken = _sessionToken;
    [_preNextAttemptedVideoId release];
    _preNextAttemptedVideoId = [vid copy];
    unlink([[self preNextPartPathForGen:launchGen] UTF8String]);
    shouldLaunch = YES;
    pthread_mutex_unlock(&g_prenext_lock);

    if (shouldLaunch) {
        NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                              vid, @"videoId",
                              [NSNumber numberWithInteger:launchGen], @"gen",
                              nil];
        [NSThread detachNewThreadSelector:@selector(preNextThreadMain:) toTarget:self withObject:args];
    }
}

- (void)preNextThreadMain:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.2];

    NSString *videoId = [args objectForKey:@"videoId"];
    NSInteger myGen = [[args objectForKey:@"gen"] integerValue];

    if (![self isPreNextGenCurrent:myGen]) {
        [pool release];
        return;
    }

    NSString *resolveErr = nil;
    ELStreamInfo *info = [[ELYouTubeClient sharedClient] resolveAudioStreamForVideoId:videoId error:&resolveErr];
    if (!info || ![self isPreNextGenCurrent:myGen]) {
        pthread_mutex_lock(&g_prenext_lock);
        if (_preNextGen == myGen) {
            [_preNextInFlightVideoId release];
            _preNextInFlightVideoId = nil;
        }
        pthread_mutex_unlock(&g_prenext_lock);
        [pool release];
        return;
    }

    uint64_t targetBytes = EL_PRENEXT_CHUNK_BYTES;
    if (info.contentLength > 0 && (uint64_t)info.contentLength < targetBytes) {
        targetBytes = (uint64_t)info.contentLength;
    }

    NSString *partPath = [self preNextPartPathForGen:myGen];
    NSString *readyPath = [self preNextReadyPath];
    FILE *fp = fopen([partPath UTF8String], "wb");
    if (!fp) {
        pthread_mutex_lock(&g_prenext_lock);
        if (_preNextGen == myGen) {
            [_preNextInFlightVideoId release];
            _preNextInFlightVideoId = nil;
        }
        pthread_mutex_unlock(&g_prenext_lock);
        [pool release];
        return;
    }

    el_prenext_dl_ctx_t pctx;
    memset(&pctx, 0, sizeof(pctx));
    pctx.engine = self;
    pctx.gen = myGen;
    pctx.fp = fp;
    pctx.targetBytes = targetBytes;

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          info.userAgent ? info.userAgent : @"", @"User-Agent",
                          [NSString stringWithFormat:@"bytes=0-%llu", (unsigned long long)(targetBytes - 1)], @"Range",
                          nil];
    NSInteger status = 0;
    long long respCL = -1;
    NSString *httpErr = nil;
    BOOL ok = [[ELHTTPClient sharedClient] streamGETURL:info.url
                                                headers:hdrs
                                               callback:el_prenext_on_http_chunk
                                               userData:&pctx
                                             statusCode:&status
                                          contentLength:&respCL
                                                  error:&httpErr];
    fclose(fp);

    BOOL validChunk = (!pctx.writeError && pctx.writtenBytes > 2048 &&
                       (status == 200 || status == 206) && (ok || pctx.reachedTarget));

    pthread_mutex_lock(&g_prenext_lock);
    if (_preNextGen == myGen) {
        [_preNextInFlightVideoId release];
        _preNextInFlightVideoId = nil;
        if (validChunk) {
            unlink([readyPath UTF8String]);
            if (rename([partPath UTF8String], [readyPath UTF8String]) == 0) {
                ELStreamInfo *readyInfo = info;
                if (info.contentLength <= 0 && status == 200 && pctx.fullContentLength > 0) {
                    readyInfo = [[[ELStreamInfo alloc] init] autorelease];
                    readyInfo.url = info.url;
                    readyInfo.userAgent = info.userAgent;
                    readyInfo.itag = info.itag;
                    readyInfo.contentLength = pctx.fullContentLength;
                    readyInfo.durationSeconds = info.durationSeconds;
                }
                [_preNextReadyVideoId release];
                _preNextReadyVideoId = [videoId copy];
                [_preNextStreamInfo release];
                _preNextStreamInfo = [readyInfo retain];
                _preNextByteLength = pctx.writtenBytes;
                _preNextReadyTime = [[NSDate date] timeIntervalSince1970];
            } else {
                unlink([partPath UTF8String]);
            }
        } else {
            unlink([partPath UTF8String]);
        }
    } else {
        unlink([partPath UTF8String]);
    }
    pthread_mutex_unlock(&g_prenext_lock);

    [pool release];
}

- (ELTrack *)currentTrack {
    if (_currentIndex >= 0 && _currentIndex < (NSInteger)[_queue count]) {
        return [_queue objectAtIndex:_currentIndex];
    }
    return nil;
}

- (NSArray *)queue { return _queue; }
- (NSInteger)currentIndex { return _currentIndex; }
- (ELPlayerState)state { return _state; }
- (BOOL)isPlayingOffline { return _playingOffline; }
- (NSString *)lastError { return _lastError; }
- (BOOL)shuffleEnabled { return _shuffleEnabled; }
- (ELRepeatMode)repeatMode { return _repeatMode; }
- (BOOL)shakeToShuffleEnabled { return _shakeToShuffleEnabled; }

- (void)setShakeToShuffleEnabled:(BOOL)enabled {
    _shakeToShuffleEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ELShakeToShuffle"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)postToast:(NSString *)message {
    if ([message length] == 0) return;
    NSDictionary *ui = [NSDictionary dictionaryWithObject:message forKey:@"message"];
    [[NSNotificationCenter defaultCenter] postNotificationName:ELPlayerToastNotification object:self userInfo:ui];
}

- (NSInteger)sleepTimerRemainingSeconds {
    if (!_sleepFireDate) return 0;
    NSTimeInterval rem = [_sleepFireDate timeIntervalSinceNow];
    if (rem <= 0) return 0;
    return (NSInteger)ceil(rem);
}

- (void)setSleepTimerMinutes:(NSInteger)minutes {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(setSleepTimerMinutesNumber:)
                               withObject:[NSNumber numberWithInteger:minutes]
                            waitUntilDone:NO];
        return;
    }
    [_sleepTimer invalidate];
    [_sleepTimer release]; _sleepTimer = nil;
    [_sleepFireDate release]; _sleepFireDate = nil;

    if (minutes <= 0) {
        _sleepTimerRemainingSeconds = 0;
        [self postToast:@"Sleep timer off"];
        return;
    }

    NSTimeInterval secs = (NSTimeInterval)minutes * 60.0;
    _sleepFireDate = [[NSDate dateWithTimeIntervalSinceNow:secs] retain];
    _sleepTimerRemainingSeconds = minutes * 60;
    _sleepTimer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                     target:self
                                                   selector:@selector(onSleepTimerTick:)
                                                   userInfo:nil
                                                    repeats:YES] retain];
    [self postToast:[NSString stringWithFormat:@"Sleep timer: %ld min", (long)minutes]];
}

- (void)setSleepTimerMinutesNumber:(NSNumber *)num {
    [self setSleepTimerMinutes:[num integerValue]];
}

- (void)onSleepTimerTick:(NSTimer *)timer {
    if (!_sleepFireDate) {
        [_sleepTimer invalidate];
        [_sleepTimer release]; _sleepTimer = nil;
        _sleepTimerRemainingSeconds = 0;
        return;
    }
    NSTimeInterval rem = [_sleepFireDate timeIntervalSinceNow];
    if (rem <= 0) {
        [_sleepTimer invalidate];
        [_sleepTimer release]; _sleepTimer = nil;
        [_sleepFireDate release]; _sleepFireDate = nil;
        _sleepTimerRemainingSeconds = 0;
        [self pause];
        [self postToast:@"Sleep timer ended"];
    } else {
        _sleepTimerRemainingSeconds = (NSInteger)ceil(rem);
    }
}

- (double)currentTime {
    if (_playingOffline && _offlinePlayer) {
        return _offlinePlayer.currentTime;
    }
    double t = _streamSeekBaseSec;
    pthread_mutex_lock(&g_active_lock);
    if (g_active_stream && g_active_stream->aq && g_active_stream->aqStarted && g_active_stream->sampleRate > 0) {
        AudioTimeStamp ts;
        if (AudioQueueGetCurrentTime(g_active_stream->aq, NULL, &ts, NULL) == noErr &&
            (ts.mFlags & kAudioTimeStampSampleTimeValid)) {
            double elapsed = ts.mSampleTime / g_active_stream->sampleRate;
            if (elapsed >= 0) t = g_active_stream->seekBaseSec + elapsed;
        }
    }
    pthread_mutex_unlock(&g_active_lock);
    return t;
}

- (double)duration {
    if (_playingOffline && _offlinePlayer && _offlinePlayer.duration > 0) {
        return _offlinePlayer.duration;
    }
    if (_streamDuration > 0) return _streamDuration;
    ELTrack *cur = [self currentTrack];
    return cur ? (double)cur.durationSeconds : 0.0;
}

- (void)postStateChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELPlayerStateChangedNotification object:self];
}

- (BOOL)needsBackgroundPreNextTimer {
    if (_state != ELPlayerStatePlaying) return NO;
    ELTrack *cand = [self nextCandidateTrack];
    if (!cand) return NO;
    BOOL alreadyAttempted = NO;
    pthread_mutex_lock(&g_prenext_lock);
    alreadyAttempted = (_preNextAttemptedSessionToken == _sessionToken &&
                        _preNextAttemptedVideoId &&
                        [_preNextAttemptedVideoId isEqualToString:cand.videoId]);
    pthread_mutex_unlock(&g_prenext_lock);
    return !alreadyAttempted;
}

- (void)startProgressTimer {
    [_progressTimer invalidate];
    [_progressTimer release];
    _progressTimer = nil;

    if (_state != ELPlayerStatePlaying) return;

    if (_isBackgrounded) {
        /* While backgrounded/screen-locked, only run a sparse 3s timer until pre-next buffering triggers */
        if (![self needsBackgroundPreNextTimer]) return;
        _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:3.0
                                                           target:self
                                                         selector:@selector(onProgressTick)
                                                         userInfo:nil
                                                          repeats:YES] retain];
        return;
    }

    _progressTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
                                                       target:self
                                                     selector:@selector(onProgressTick)
                                                     userInfo:nil
                                                      repeats:YES] retain];
}

- (void)stopProgressTimer {
    [_progressTimer invalidate];
    [_progressTimer release];
    _progressTimer = nil;
}

- (void)onAppDidEnterBackground:(NSNotification *)note {
    (void)note;
    _isBackgrounded = YES;
    if (_state == ELPlayerStatePlaying) {
        [self startProgressTimer];
    } else {
        [self stopProgressTimer];
    }
}

- (void)onAppDidBecomeActive:(NSNotification *)note {
    (void)note;
    _isBackgrounded = NO;
    if (_state == ELPlayerStatePlaying) {
        [self startProgressTimer];
        [self onProgressTick];
    }
}

- (void)onProgressTick {
    if (!_isBackgrounded) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ELPlayerProgressNotification object:self];
    }
    [self maybeTriggerPreNextBuffer];
    if (_isBackgrounded && ![self needsBackgroundPreNextTimer]) {
        [self stopProgressTimer];
    }
}

- (void)signalStopActiveStream {
    pthread_mutex_lock(&g_active_lock);
    _sessionToken++;
    if (g_active_stream) {
        pthread_mutex_lock(&g_active_stream->lock);
        g_active_stream->stopFlag = YES;
        pthread_cond_broadcast(&g_active_stream->cond);
        pthread_mutex_unlock(&g_active_stream->lock);
    }
    pthread_mutex_unlock(&g_active_lock);
}

- (void)stopInternal:(BOOL)clearError {
    [self signalStopActiveStream];

    if (_offlinePlayer) {
        _offlinePlayer.delegate = nil;
        [_offlinePlayer stop];
        [_offlinePlayer release];
        _offlinePlayer = nil;
    }

    _playingOffline = NO;
    _streamDuration = 0;
    _streamSeekBaseSec = 0;
    _streamPaused = NO;
    [self endBgTransitionTask];
    [self stopProgressTimer];
    if (clearError) {
        [_lastError release];
        _lastError = nil;
    }
}

- (void)stop {
    [self stopInternal:YES];
    [self clearPreNextBuffer];
    _state = ELPlayerStateStopped;
    [self postStateChanged];
}

static NSArray *el_shuffled_array_keeping_first(NSArray *items, ELTrack *firstTrack) {
    NSMutableArray *pool = [NSMutableArray arrayWithArray:items];
    if (firstTrack) {
        for (NSInteger i = (NSInteger)[pool count] - 1; i >= 0; i--) {
            if ([[[pool objectAtIndex:i] videoId] isEqualToString:firstTrack.videoId]) {
                [pool removeObjectAtIndex:i];
                break;
            }
        }
    }
    NSUInteger n = [pool count];
    for (NSUInteger i = n; i > 1; i--) {
        NSUInteger j = arc4random() % i;
        [pool exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
    if (firstTrack) {
        [pool insertObject:firstTrack atIndex:0];
    }
    return [[pool copy] autorelease];
}

- (void)playTrack:(ELTrack *)track {
    if (!track) return;
    [self playTracks:[NSArray arrayWithObject:track] startingAtIndex:0];
}

- (void)playTracks:(NSArray *)tracks startingAtIndex:(NSInteger)index {
    if (!tracks || [tracks count] == 0) return;
    if (index < 0 || index >= (NSInteger)[tracks count]) index = 0;

    [_originalQueue release];
    _originalQueue = [tracks copy];

    ELTrack *picked = [tracks objectAtIndex:index];
    if (_shuffleEnabled && [tracks count] > 1) {
        [_queue release];
        _queue = [el_shuffled_array_keeping_first(tracks, picked) retain];
        _currentIndex = 0;
    } else {
        [_queue release];
        _queue = [tracks copy];
        _currentIndex = index;
    }
    [self startCurrentTrack];
}

- (void)playTracksShuffled:(NSArray *)tracks {
    if (!tracks || [tracks count] == 0) return;
    _shuffleEnabled = YES;
    NSUInteger pick = arc4random() % [tracks count];
    [self playTracks:tracks startingAtIndex:(NSInteger)pick];
}

- (void)jumpToQueueIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)[_queue count]) return;
    _currentIndex = index;
    [self startCurrentTrack];
}

- (void)toggleShuffle {
    _shuffleEnabled = !_shuffleEnabled;
    ELTrack *cur = [self currentTrack];
    if ([_originalQueue count] > 1) {
        if (_shuffleEnabled) {
            [_queue release];
            _queue = [el_shuffled_array_keeping_first(_originalQueue, cur) retain];
            _currentIndex = cur ? 0 : _currentIndex;
        } else {
            [_queue release];
            _queue = [_originalQueue copy];
            _currentIndex = 0;
            if (cur) {
                for (NSUInteger i = 0; i < [_queue count]; i++) {
                    if ([[[_queue objectAtIndex:i] videoId] isEqualToString:cur.videoId]) {
                        _currentIndex = (NSInteger)i;
                        break;
                    }
                }
            }
        }
    }
    [self syncPreNextWithCandidate];
    [self postStateChanged];
    [self postToast:(_shuffleEnabled ? @"Shuffle: On" : @"Shuffle: Off")];
}

- (void)cycleRepeatMode {
    if (_repeatMode == ELRepeatModeOff) {
        _repeatMode = ELRepeatModeAll;
        [self postToast:@"Repeat: All"];
    } else if (_repeatMode == ELRepeatModeAll) {
        _repeatMode = ELRepeatModeOne;
        [self postToast:@"Repeat: One"];
    } else {
        _repeatMode = ELRepeatModeOff;
        [self postToast:@"Repeat: Off"];
    }
    [self syncPreNextWithCandidate];
    [self postStateChanged];
}

- (void)handleShakeToShuffle {
    if (!_shakeToShuffleEnabled) return;
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(applicationState)] &&
        [app applicationState] != UIApplicationStateActive) {
        return;
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastShakeTime < 1.2) return;
    _lastShakeTime = now;

    if ([_originalQueue count] > 1) {
        _shuffleEnabled = YES;
        ELTrack *cur = [self currentTrack];
        /* Pick a different random track from the queue */
        NSMutableArray *candidates = [NSMutableArray arrayWithArray:_originalQueue];
        if (cur) {
            for (NSInteger i = (NSInteger)[candidates count] - 1; i >= 0; i--) {
                if ([[[candidates objectAtIndex:i] videoId] isEqualToString:cur.videoId]) {
                    [candidates removeObjectAtIndex:i];
                    break;
                }
            }
        }
        ELTrack *nextPick = ([candidates count] > 0) ? [candidates objectAtIndex:(arc4random() % [candidates count])] : cur;
        [_queue release];
        _queue = [el_shuffled_array_keeping_first(_originalQueue, nextPick) retain];
        _currentIndex = 0;
        [self startCurrentTrack];
        [self postToast:[NSString stringWithFormat:@"Shuffled: %@", nextPick.title]];
        return;
    }

    /* Nothing queued yet: auto-shuffle Downloads, or synced Liked Songs! */
    NSArray *fallback = [[ELDownloadManager sharedManager] downloadedTracks];
    if ([fallback count] == 0) {
        fallback = [[ELYouTubeClient sharedClient] cachedLikedSongs];
    }
    if ([fallback count] > 0) {
        [self playTracksShuffled:fallback];
        ELTrack *cur = [self currentTrack];
        [self postToast:cur ? [NSString stringWithFormat:@"Shuffled: %@", cur.title] : @"Shuffled!"];
    } else {
        [self postToast:@"No tracks to shuffle yet"];
    }
}

- (void)startCurrentTrack {
    ELTrack *track = [self currentTrack];
    if (!track) {
        [self stop];
        return;
    }

    [self stopInternal:YES];
    NSInteger myToken = _sessionToken;
    _streamDuration = (double)track.durationSeconds;

    /* Re-assert MediaPlayback audio session + hold short bg task across track transition */
    [self beginBgTransitionTask];
    [self activateAudioSession];

    /* Check if downloaded offline first */
    if ([[ELDownloadManager sharedManager] isDownloaded:track.videoId]) {
        [self syncPreNextWithCandidate];
        NSString *localPath = [[ELDownloadManager sharedManager] localAudioPathForVideoId:track.videoId];
        NSURL *fileURL = [NSURL fileURLWithPath:localPath];
        NSError *err = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:fileURL error:&err];
        if (player) {
            _offlinePlayer = player;
            _offlinePlayer.delegate = self;
            [_offlinePlayer prepareToPlay];
            [_offlinePlayer play];
            _playingOffline = YES;
            _state = ELPlayerStatePlaying;
            [self endBgTransitionTask];
            [self startProgressTimer];
            [self postStateChanged];
            return;
        }
    }

    /* Check if this track was pre-buffered on disk in Caches/EchoLegacy/prenext.fmp4 */
    ELStreamInfo *claimedStreamInfo = nil;
    NSString *claimedPreNextFile = nil;
    unsigned long long claimedPreNextBytes = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    pthread_mutex_lock(&g_prenext_lock);
    /* Always cancel any unfinished in-flight pre-next worker so it doesn't compete for bandwidth */
    [self resetPreNextStateLocked:YES clearReady:NO clearAttempted:NO];
    if (_preNextReadyVideoId && [_preNextReadyVideoId isEqualToString:track.videoId] &&
        _preNextStreamInfo && _preNextByteLength > 0 &&
        (now - _preNextReadyTime) >= 0.0 && (now - _preNextReadyTime) < EL_PRENEXT_MAX_AGE_SEC) {
        NSString *readyPath = [self preNextReadyPath];
        NSString *activePath = [self preNextActivePathForToken:myToken];
        unlink([activePath UTF8String]);
        if (rename([readyPath UTF8String], [activePath UTF8String]) == 0) {
            claimedStreamInfo = [[_preNextStreamInfo retain] autorelease];
            claimedPreNextFile = activePath;
            claimedPreNextBytes = _preNextByteLength;
        }
    }
    [self resetPreNextStateLocked:NO clearReady:YES clearAttempted:YES];
    pthread_mutex_unlock(&g_prenext_lock);

    /* Stream live over TLS 1.2 (or instant start from prenext_active.fmp4 + seamless continuation) */
    _playingOffline = NO;
    _state = ELPlayerStateLoading;
    [self postStateChanged];

    NSMutableDictionary *args = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                 track, @"track",
                                 [NSNumber numberWithInteger:myToken], @"token",
                                 nil];
    if (claimedStreamInfo && claimedPreNextFile && claimedPreNextBytes > 0) {
        [args setObject:claimedStreamInfo forKey:@"preStreamInfo"];
        [args setObject:claimedPreNextFile forKey:@"preNextFile"];
        [args setObject:[NSNumber numberWithUnsignedLongLong:claimedPreNextBytes] forKey:@"preNextBytes"];
    }
    [NSThread detachNewThreadSelector:@selector(streamThreadMain:) toTarget:self withObject:args];
}

- (void)streamDidStartPlayingToken:(NSNumber *)tokenNum {
    if ([tokenNum integerValue] != _sessionToken) return;
    [self endBgTransitionTask];
    if (_state == ELPlayerStateLoading) {
        _state = _streamPaused ? ELPlayerStatePaused : ELPlayerStatePlaying;
        [self startProgressTimer];
        [self postStateChanged];
    }
}

- (void)streamDidUpdateDuration:(NSDictionary *)info {
    if ([[info objectForKey:@"token"] integerValue] != _sessionToken) return;
    double d = [[info objectForKey:@"duration"] doubleValue];
    if (d > 0) _streamDuration = d;
    [self onProgressTick];
}

- (void)streamDidFail:(NSDictionary *)info {
    if ([[info objectForKey:@"token"] integerValue] != _sessionToken) return;
    [self endBgTransitionTask];
    [_lastError release];
    _lastError = [[info objectForKey:@"error"] copy];
    _state = ELPlayerStateError;
    [self stopProgressTimer];
    [self postStateChanged];
}

- (void)streamDidFinishNaturallyToken:(NSNumber *)tokenNum {
    if ([tokenNum integerValue] != _sessionToken) return;
    [self advanceOnTrackEnd];
}

- (void)advanceOnTrackEnd {
    if ([_queue count] == 0) { [self stop]; return; }
    if (_repeatMode == ELRepeatModeOne) {
        [self startCurrentTrack];
        return;
    }
    if (_currentIndex + 1 < (NSInteger)[_queue count]) {
        _currentIndex++;
        [self startCurrentTrack];
    } else if (_repeatMode == ELRepeatModeAll) {
        _currentIndex = 0;
        [self startCurrentTrack];
    } else {
        [self stop];
    }
}

- (void)notifyDuration:(double)duration forToken:(NSInteger)token {
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInteger:token], @"token",
                          [NSNumber numberWithDouble:duration], @"duration",
                          nil];
    [self performSelectorOnMainThread:@selector(streamDidUpdateDuration:)
                           withObject:info
                        waitUntilDone:NO];
}

- (void)notifyStreamFailed:(NSString *)error forToken:(NSInteger)token {
    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSNumber numberWithInteger:token], @"token",
                          error ? error : @"Stream failed", @"error",
                          nil];
    [self performSelectorOnMainThread:@selector(streamDidFail:)
                           withObject:info
                        waitUntilDone:NO];
}

- (uint64_t)applySeekForSession:(el_stream_session_t *)s {
    uint64_t newOff = 0;
    double actualSec = 0.0;
    if (el_fmp4_find_seek_offset(s->fmp4, s->seekTargetSec, &newOff, &actualSec) != 0) {
        newOff = 0;
        actualSec = 0.0;
    }
    s->seekBaseSec = actualSec;
    _streamSeekBaseSec = actualSec;
    el_fmp4_reset_for_seek(s->fmp4, newOff);
    el_stream_teardown_aq(s, YES);
    return newOff;
}

- (void)streamThreadMain:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.65];
    ELTrack *track = [args objectForKey:@"track"];
    NSInteger myToken = [[args objectForKey:@"token"] integerValue];
    ELStreamInfo *preStreamInfo = [args objectForKey:@"preStreamInfo"];
    NSString *preNextFile = [args objectForKey:@"preNextFile"];
    uint64_t preNextBytes = [[args objectForKey:@"preNextBytes"] unsignedLongLongValue];

    NSString *resolveErr = nil;
    ELStreamInfo *streamInfo = preStreamInfo;
    BOOL usedPreStreamInfo = (streamInfo != nil);
    if (!streamInfo) {
        streamInfo = [[ELYouTubeClient sharedClient] resolveAudioStreamForVideoId:track.videoId error:&resolveErr];
    }
    if (myToken != _sessionToken) {
        if (preNextFile) unlink([preNextFile UTF8String]);
        [pool release];
        return;
    }
    if (!streamInfo) {
        if (preNextFile) unlink([preNextFile UTF8String]);
        [self notifyStreamFailed:(resolveErr ? resolveErr : @"Could not resolve stream") forToken:myToken];
        [pool release];
        return;
    }

    if (streamInfo.durationSeconds > 0) {
        [self notifyDuration:streamInfo.durationSeconds forToken:myToken];
    }

    el_stream_session_t *s = (el_stream_session_t *)calloc(1, sizeof(el_stream_session_t));
    s->engine = self;
    s->token = myToken;
    s->fillIdx = -1;
    s->sampleRate = 44100.0;
    s->aqPaused = _streamPaused;
    s->fmp4 = el_fmp4_create(el_stream_on_adts, s);
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);

    pthread_mutex_lock(&g_active_lock);
    if (myToken == _sessionToken) {
        if (g_active_stream) {
            pthread_mutex_lock(&g_active_stream->lock);
            g_active_stream->stopFlag = YES;
            pthread_cond_broadcast(&g_active_stream->cond);
            pthread_mutex_unlock(&g_active_stream->lock);
        }
        g_active_stream = s;
    } else {
        s->stopFlag = YES;
    }
    pthread_mutex_unlock(&g_active_lock);

    uint64_t rangeStart = 0;
    BOOL hasPreNextFile = (preNextFile != nil && preNextBytes > 0);
    BOOL retriedFreshStream = NO;
    BOOL finishedNaturally = NO;

    while (!s->stopFlag && myToken == _sessionToken) {
        s->seekFlag = NO;
        if (!s->afs && AudioFileStreamOpen(s, el_afs_property_cb, el_afs_packets_cb, kAudioFileAAC_ADTSType, &s->afs) != noErr) {
            if (hasPreNextFile && preNextFile) {
                unlink([preNextFile UTF8String]);
                hasPreNextFile = NO;
            }
            break;
        }

        /* Step 1: If we have a pre-buffered initial chunk on disk, feed it immediately into
           el_fmp4_adts -> AudioFileStream -> AudioQueue so playback starts instantaneously! */
        if (hasPreNextFile && rangeStart == 0) {
            hasPreNextFile = NO;
            FILE *pfp = fopen([preNextFile UTF8String], "rb");
            if (pfp) {
                uint8_t fbuf[16384];
                uint64_t fedFromFile = 0;
                BOOL fileParseOk = YES;
                while (!s->stopFlag && !s->seekFlag && myToken == _sessionToken && fedFromFile < preNextBytes) {
                    size_t want = sizeof(fbuf);
                    if ((preNextBytes - fedFromFile) < (uint64_t)want) {
                        want = (size_t)(preNextBytes - fedFromFile);
                    }
                    size_t got = fread(fbuf, 1, want, pfp);
                    if (got == 0) break;
                    if (el_fmp4_feed(s->fmp4, fbuf, got) < 0) {
                        fileParseOk = NO;
                        break;
                    }
                    fedFromFile += (uint64_t)got;
                    if (!s->durationReported) {
                        double d = el_fmp4_total_duration(s->fmp4);
                        if (d > 0.0) {
                            s->durationReported = YES;
                            [self notifyDuration:d forToken:myToken];
                        }
                    }
                }
                fclose(pfp);
                unlink([preNextFile UTF8String]);

                if (s->stopFlag || myToken != _sessionToken) {
                    el_stream_teardown_aq(s, YES);
                    break;
                }
                if (s->seekFlag) {
                    rangeStart = [self applySeekForSession:s];
                    continue;
                }
                if (fileParseOk && fedFromFile > 0) {
                    rangeStart = fedFromFile;
                } else {
                    rangeStart = 0;
                    s->seekBaseSec = 0.0;
                    _streamSeekBaseSec = 0.0;
                    el_fmp4_reset_for_seek(s->fmp4, 0);
                    el_stream_teardown_aq(s, YES);
                    continue;
                }
            } else {
                unlink([preNextFile UTF8String]);
            }
        }

        /* Step 2: Seamlessly continue fetching the remainder of the track from byte offset = rangeStart */
        NSInteger status = 206;
        NSString *httpErr = nil;
        BOOL ok = YES;
        if (streamInfo.contentLength <= 0 || (long long)rangeStart < streamInfo.contentLength) {
            NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                                  streamInfo.userAgent ? streamInfo.userAgent : @"", @"User-Agent",
                                  nil];
            ok = [[ELHTTPClient sharedClient] streamRangeChunksGETURL:streamInfo.url
                                                              headers:hdrs
                                                          startOffset:rangeStart
                                                          totalLength:streamInfo.contentLength
                                                            chunkSize:524288
                                                             callback:el_stream_on_http_chunk
                                                             userData:s
                                                           statusCode:&status
                                                                error:&httpErr];
        }

        double fmp4Dur = el_fmp4_total_duration(s->fmp4);
        if (fmp4Dur > 0) {
            [self notifyDuration:fmp4Dur forToken:myToken];
        }

        if (s->stopFlag || myToken != _sessionToken) {
            el_stream_teardown_aq(s, YES);
            break;
        }

        if (s->seekFlag) {
            rangeStart = [self applySeekForSession:s];
            continue;
        }

        if (!ok || (status != 200 && status != 206)) {
            /* If a cached/pre-buffered stream URL expired before continuation finished, refresh once */
            if (usedPreStreamInfo && !retriedFreshStream && !s->stopFlag && myToken == _sessionToken) {
                retriedFreshStream = YES;
                [[ELYouTubeClient sharedClient] invalidateCachedStreamForVideoId:track.videoId];
                ELStreamInfo *fresh = [[ELYouTubeClient sharedClient] resolveAudioStreamForVideoId:track.videoId error:&resolveErr];
                if (fresh) {
                    NSInteger prevItag = streamInfo.itag;
                    streamInfo = fresh;
                    uint64_t resumeOff = el_fmp4_stream_offset(s->fmp4);
                    if (fresh.itag == prevItag && el_fmp4_has_config(s->fmp4) && resumeOff > 0) {
                        rangeStart = resumeOff;
                    } else {
                        rangeStart = 0;
                        s->seekBaseSec = 0.0;
                        _streamSeekBaseSec = 0.0;
                        el_fmp4_reset_for_seek(s->fmp4, 0);
                        el_stream_teardown_aq(s, YES);
                    }
                    continue;
                }
            }
            el_stream_teardown_aq(s, YES);
            [self notifyStreamFailed:(httpErr ? httpErr : [NSString stringWithFormat:@"Stream HTTP %ld", (long)status])
                            forToken:myToken];
            break;
        }

        /* Flush last partial buffer & start queue if short track */
        if (s->fillIdx >= 0 && s->fillBytes > 0) {
            el_aq_enqueue_fill(s);
        }
        if (s->aq && !s->aqStarted && s->queuedCount > 0) {
            if (!s->aqPaused) AudioQueueStart(s->aq, NULL);
            s->aqStarted = YES;
            [self performSelectorOnMainThread:@selector(streamDidStartPlayingToken:)
                                   withObject:[NSNumber numberWithInteger:myToken]
                                waitUntilDone:NO];
        }

        /* Wait for queued buffers to drain naturally unless stopped or seeked */
        if (s->aq && s->aqStarted) {
            AudioQueueFlush(s->aq);
            pthread_mutex_lock(&s->lock);
            while (!s->stopFlag && !s->seekFlag) {
                BOOL anyInUse = NO;
                for (int i = 0; i < EL_AQ_NUM_BUFS; i++) {
                    if (s->inUse[i]) { anyInUse = YES; break; }
                }
                if (!anyInUse) break;
                pthread_cond_wait(&s->cond, &s->lock);
            }
            pthread_mutex_unlock(&s->lock);
        }

        if (s->seekFlag) {
            rangeStart = [self applySeekForSession:s];
            continue;
        }

        el_stream_teardown_aq(s, YES);
        if (!s->stopFlag && myToken == _sessionToken) {
            finishedNaturally = YES;
        }
        break;
    }

    if (hasPreNextFile && preNextFile) {
        unlink([preNextFile UTF8String]);
        hasPreNextFile = NO;
    }

    pthread_mutex_lock(&g_active_lock);
    if (g_active_stream == s) g_active_stream = NULL;
    pthread_mutex_unlock(&g_active_lock);

    el_fmp4_destroy(s->fmp4);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->cond);
    free(s);

    if (finishedNaturally) {
        [self performSelectorOnMainThread:@selector(streamDidFinishNaturallyToken:)
                               withObject:[NSNumber numberWithInteger:myToken]
                            waitUntilDone:NO];
    }

    [pool release];
}

- (void)pause {
    [self stopProgressTimer];
    if (_playingOffline && _offlinePlayer) {
        [_offlinePlayer pause];
        _state = ELPlayerStatePaused;
        [self postStateChanged];
        return;
    }
    _streamPaused = YES;
    pthread_mutex_lock(&g_active_lock);
    if (g_active_stream) {
        g_active_stream->aqPaused = YES;
        if (g_active_stream->aq) AudioQueuePause(g_active_stream->aq);
    }
    pthread_mutex_unlock(&g_active_lock);
    if (_state == ELPlayerStatePlaying) {
        _state = ELPlayerStatePaused;
        [self postStateChanged];
    }
}

- (void)resume {
    if (_playingOffline && _offlinePlayer) {
        [_offlinePlayer play];
        _state = ELPlayerStatePlaying;
        [self startProgressTimer];
        [self postStateChanged];
        return;
    }
    _streamPaused = NO;
    pthread_mutex_lock(&g_active_lock);
    if (g_active_stream) {
        g_active_stream->aqPaused = NO;
        if (g_active_stream->aq && g_active_stream->aqStarted) {
            AudioQueueStart(g_active_stream->aq, NULL);
        }
    }
    pthread_mutex_unlock(&g_active_lock);
    if (_state == ELPlayerStatePaused) {
        _state = ELPlayerStatePlaying;
        [self startProgressTimer];
        [self postStateChanged];
    }
}

- (void)togglePlayPause {
    if (_state == ELPlayerStatePlaying) {
        [self pause];
    } else if (_state == ELPlayerStatePaused) {
        [self resume];
    } else if (_state == ELPlayerStateError || _state == ELPlayerStateStopped) {
        if ([self currentTrack]) [self startCurrentTrack];
    }
}

- (void)playNext {
    if ([_queue count] == 0) return;
    if (_currentIndex + 1 < (NSInteger)[_queue count]) {
        _currentIndex++;
        [self startCurrentTrack];
    } else if (_repeatMode == ELRepeatModeAll || _shuffleEnabled) {
        _currentIndex = 0;
        [self startCurrentTrack];
    } else {
        [self stop];
    }
}

- (void)playPrevious {
    if ([_queue count] == 0) return;
    if ([self currentTime] > 3.0) {
        [self seekToSeconds:0.0];
        return;
    }
    if (_currentIndex > 0) {
        _currentIndex--;
        [self startCurrentTrack];
    } else if (_repeatMode == ELRepeatModeAll) {
        _currentIndex = (NSInteger)[_queue count] - 1;
        [self startCurrentTrack];
    } else {
        [self seekToSeconds:0.0];
    }
}

- (void)seekToSeconds:(double)seconds {
    if (seconds < 0.0) seconds = 0.0;
    if (_playingOffline && _offlinePlayer) {
        if (seconds > _offlinePlayer.duration) seconds = _offlinePlayer.duration;
        _offlinePlayer.currentTime = seconds;
        [self onProgressTick];
        return;
    }

    /* Cancel any in-flight pre-next worker so seek gets full Wi-Fi bandwidth; allow retry once playback settles */
    pthread_mutex_lock(&g_prenext_lock);
    if (_preNextInFlightVideoId) {
        [self resetPreNextStateLocked:YES clearReady:NO clearAttempted:YES];
    }
    pthread_mutex_unlock(&g_prenext_lock);

    pthread_mutex_lock(&g_active_lock);
    if (g_active_stream) {
        pthread_mutex_lock(&g_active_stream->lock);
        g_active_stream->seekTargetSec = seconds;
        g_active_stream->seekFlag = YES;
        pthread_cond_broadcast(&g_active_stream->cond);
        pthread_mutex_unlock(&g_active_stream->lock);
    }
    pthread_mutex_unlock(&g_active_lock);
}

#pragma mark - AVAudioPlayerDelegate

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player;
    if (flag) [self advanceOnTrackEnd];
}

#pragma mark - Remote Control (Lock Screen / Headphone Buttons)

- (void)handleRemoteControlEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay:
            [self resume];
            break;
        case UIEventSubtypeRemoteControlPause:
            [self pause];
            break;
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [self togglePlayPause];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [self playNext];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [self playPrevious];
            break;
        default:
            break;
    }
}

@end
