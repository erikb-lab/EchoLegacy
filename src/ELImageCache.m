#import "ELImageCache.h"
#import "ELAudioEngine.h"
#import "ELHTTPClient.h"
#import "ELDownloadManager.h"
#import "ELTheme.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static double el_image_worker_priority(BOOL isThumb) {
    ELPlayerState st = [[ELAudioEngine sharedEngine] state];
    BOOL audioActive = (st == ELPlayerStatePlaying || st == ELPlayerStateLoading);
    if (isThumb) {
        return audioActive ? 0.18 : 0.35;
    }
    return audioActive ? 0.22 : 0.38;
}

/* Lean cap for 128 MB RAM iPod touch 2G — disk cache keeps thumbnails fast without holding bitmaps in RAM */
#define EL_MAX_MEM_IMAGES       14
#define EL_MAX_THUMB_WORKERS    2
#define EL_MAX_THUMB_QUEUE      18
#define EL_MAX_IMAGE_BYTES      (2U * 1024U * 1024U)
#define EL_MAX_IMAGE_DIMENSION  2048U
#define EL_MAX_DECODED_ART_DIM  320U
#define EL_MAX_DISK_CACHE_BYTES (16ULL * 1024ULL * 1024ULL)
#define EL_DISK_CACHE_TARGET    (12ULL * 1024ULL * 1024ULL)

static NSString *el_sha1_hex(NSString *input) {
    const char *cstr = [input UTF8String];
    if (!cstr) return @"";
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static BOOL el_is_valid_image_magic(NSData *data) {
    if (!data) return NO;
    NSUInteger len = [data length];
    if (len < 64 || len > EL_MAX_IMAGE_BYTES) return NO;
    const uint8_t *b = (const uint8_t *)[data bytes];
    if (!b) return NO;
    /* JPEG: FF D8 FF */
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
        return YES;
    }
    /* PNG: 89 50 4E 47 0D 0A 1A 0A */
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
        return YES;
    }
    return NO;
}

static BOOL el_is_valid_image_content_type(NSDictionary *headers) {
    if (!headers || [headers count] == 0) return NO;
    NSString *ct = nil;
    for (id key in headers) {
        if ([key isKindOfClass:[NSString class]] &&
            [(NSString *)key caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
            id val = [headers objectForKey:key];
            if ([val isKindOfClass:[NSString class]]) ct = (NSString *)val;
            break;
        }
    }
    if ([ct length] == 0) return NO;
    NSString *lower = [[ct stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    return [lower hasPrefix:@"image/"];
}

static BOOL el_is_valid_decoded_image(UIImage *img) {
    if (!img) return NO;
    CGImageRef cg = [img CGImage];
    if (!cg) return NO;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);
    if (w == 0 || h == 0 || w > EL_MAX_IMAGE_DIMENSION || h > EL_MAX_IMAGE_DIMENSION) {
        return NO;
    }
    return YES;
}

/* Force-decodes & downscales full artwork off-main-thread into native opaque BGRX (<= maxDim px) */
static UIImage *el_force_decode_opaque_image(UIImage *src, size_t maxDim) {
    if (!el_is_valid_decoded_image(src)) return nil;
    CGImageRef cg = [src CGImage];
    size_t srcW = CGImageGetWidth(cg);
    size_t srcH = CGImageGetHeight(cg);

    size_t dstW = srcW;
    size_t dstH = srcH;
    if (dstW > maxDim || dstH > maxDim) {
        if (dstW >= dstH) {
            dstH = (size_t)((double)dstH * (double)maxDim / (double)dstW + 0.5);
            dstW = maxDim;
        } else {
            dstW = (size_t)((double)dstW * (double)maxDim / (double)dstH + 0.5);
            dstH = maxDim;
        }
        if (dstW == 0) dstW = 1;
        if (dstH == 0) dstH = 1;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return src;
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             dstW,
                                             dstH,
                                             8,
                                             dstW * 4,
                                             cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return src;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0.0f, 0.0f, (CGFloat)dstW, (CGFloat)dstH), cg);
    CGImageRef decodedCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!decodedCG) return src;

    UIImage *out = [UIImage imageWithCGImage:decodedCG];
    CGImageRelease(decodedCG);
    return out ? out : src;
}

static NSInteger el_compare_cache_entry_mtime(id a, id b, void *ctx) {
    (void)ctx;
    long long ta = [[(NSDictionary *)a objectForKey:@"mtime"] longLongValue];
    long long tb = [[(NSDictionary *)b objectForKey:@"mtime"] longLongValue];
    if (ta < tb) return NSOrderedAscending;
    if (ta > tb) return NSOrderedDescending;
    return NSOrderedSame;
}

@implementation ELImageCache

+ (ELImageCache *)sharedCache {
    static ELImageCache *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELImageCache alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        pthread_mutex_init(&_memLock, NULL);
        pthread_mutex_init(&_queueLock, NULL);
        pthread_mutex_init(&_diskLock, NULL);

        _memCache = [[NSMutableDictionary alloc] init];
        _lruKeys = [[NSMutableArray alloc] init];
        _inFlight = [[NSMutableSet alloc] init];
        _thumbQueue = [[NSMutableArray alloc] init];
        _activeThumbWorkers = 0;
        _diskCacheBytes = 0;

        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *caches = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        _diskDir = [[caches stringByAppendingPathComponent:@"EchoLegacy/art"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemoryCache)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        [NSThread detachNewThreadSelector:@selector(seedDiskCacheBytesWorker) toTarget:self withObject:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_memCache release];
    [_lruKeys release];
    [_inFlight release];
    [_thumbQueue release];
    [_diskDir release];
    pthread_mutex_destroy(&_memLock);
    pthread_mutex_destroy(&_queueLock);
    pthread_mutex_destroy(&_diskLock);
    [super dealloc];
}

- (void)seedDiskCacheBytesWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.15];
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    unsigned long long total = 0;
    for (NSString *f in files) {
        NSString *full = [_diskDir stringByAppendingPathComponent:f];
        struct stat st;
        if (lstat([full fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode)) {
            total += (unsigned long long)st.st_size;
        }
    }
    pthread_mutex_lock(&_diskLock);
    _diskCacheBytes = total;
    pthread_mutex_unlock(&_diskLock);
    [pool release];
}

- (void)clearMemoryCache {
    pthread_mutex_lock(&_memLock);
    [_memCache removeAllObjects];
    [_lruKeys removeAllObjects];
    pthread_mutex_unlock(&_memLock);
}

- (unsigned long long)diskCacheBytes {
    pthread_mutex_lock(&_diskLock);
    unsigned long long total = _diskCacheBytes;
    pthread_mutex_unlock(&_diskLock);
    return total;
}

- (void)clearDiskCacheWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    for (NSString *f in files) {
        NSString *full = [_diskDir stringByAppendingPathComponent:f];
        unlink([full fileSystemRepresentation]);
    }
    [pool release];
}

- (unsigned long long)clearAllCache {
    [self clearMemoryCache];
    pthread_mutex_lock(&_diskLock);
    unsigned long long freed = _diskCacheBytes;
    _diskCacheBytes = 0;
    _diskWritesSincePrune = 0;
    pthread_mutex_unlock(&_diskLock);
    [NSThread detachNewThreadSelector:@selector(clearDiskCacheWorker) toTarget:self withObject:nil];
    return freed;
}

- (NSString *)diskPathForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    return [_diskDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", el_sha1_hex(urlString)]];
}

- (void)enforceDiskCacheQuota {
    BOOL shouldRun = NO;
    pthread_mutex_lock(&_diskLock);
    if (!_isPruningDiskCache) {
        _isPruningDiskCache = YES;
        shouldRun = YES;
    }
    pthread_mutex_unlock(&_diskLock);
    if (!shouldRun) return;

    unsigned long long total = 0;
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    if ([files count] > 0) {
        NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[files count]];
        for (NSString *f in files) {
            NSString *full = [_diskDir stringByAppendingPathComponent:f];
            struct stat st;
            if (lstat([full fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode)) {
                unsigned long long fsz = (unsigned long long)st.st_size;
                total += fsz;
                [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                    full, @"path",
                                    [NSNumber numberWithUnsignedLongLong:fsz], @"size",
                                    [NSNumber numberWithLongLong:(long long)st.st_mtime], @"mtime",
                                    nil]];
            }
        }
        if (total > EL_MAX_DISK_CACHE_BYTES) {
            [entries sortUsingFunction:el_compare_cache_entry_mtime context:NULL];
            for (NSDictionary *entry in entries) {
                if (total <= EL_DISK_CACHE_TARGET) break;
                NSString *p = [entry objectForKey:@"path"];
                unsigned long long sz = [[entry objectForKey:@"size"] unsignedLongLongValue];
                if (unlink([p fileSystemRepresentation]) == 0) {
                    total = (total > sz) ? (total - sz) : 0;
                }
            }
        }
    }

    pthread_mutex_lock(&_diskLock);
    _diskCacheBytes = total;
    _isPruningDiskCache = NO;
    pthread_mutex_unlock(&_diskLock);
}

- (void)storeInMemory:(UIImage *)img forKey:(NSString *)urlString {
    if (!el_is_valid_decoded_image(img) || !urlString) return;
    pthread_mutex_lock(&_memLock);
    [_memCache setObject:img forKey:urlString];
    [_lruKeys removeObject:urlString];
    [_lruKeys addObject:urlString];
    while ([_lruKeys count] > EL_MAX_MEM_IMAGES) {
        NSString *evict = [_lruKeys objectAtIndex:0];
        [_memCache removeObjectForKey:evict];
        [_lruKeys removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&_memLock);
}

- (UIImage *)memoryCachedImageForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    UIImage *img = nil;
    pthread_mutex_lock(&_memLock);
    img = [_memCache objectForKey:urlString];
    if (img) [[img retain] autorelease];
    pthread_mutex_unlock(&_memLock);
    return img;
}

- (UIImage *)cachedImageForURL:(NSString *)urlString {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryThumbnail, NULL, NULL, NULL)) return nil;
    UIImage *hit = [self memoryCachedImageForURL:urlString];
    if (hit) return hit;

    NSString *path = [self diskPathForURL:urlString];
    const char *cpath = path ? [path fileSystemRepresentation] : NULL;
    if (cpath && access(cpath, R_OK) == 0) {
        NSData *raw = [NSData dataWithContentsOfFile:path];
        if (!el_is_valid_image_magic(raw)) {
            unlink(cpath);
            return nil;
        }
        UIImage *img = el_force_decode_opaque_image([UIImage imageWithData:raw], EL_MAX_DECODED_ART_DIM);
        if (img) {
            utimes(cpath, NULL);
            [self storeInMemory:img forKey:urlString];
            return img;
        }
        unlink(cpath);
    }
    return nil;
}

/* Fetches raw validated image bytes (disk or HTTPS) without polluting _memCache */
- (NSData *)fetchRawImageDataSyncForURL:(NSString *)urlString {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryThumbnail, NULL, NULL, NULL)) return nil;
    NSString *path = [self diskPathForURL:urlString];
    const char *cpath = path ? [path fileSystemRepresentation] : NULL;
    if (cpath && access(cpath, R_OK) == 0) {
        NSData *existing = [NSData dataWithContentsOfFile:path];
        if (el_is_valid_image_magic(existing)) {
            UIImage *probe = [UIImage imageWithData:existing];
            if (el_is_valid_decoded_image(probe)) {
                utimes(cpath, NULL);
                return existing;
            }
        }
        unlink(cpath);
    }

    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:urlString
                                                       headers:nil
                                                      maxBytes:EL_MAX_IMAGE_BYTES];
    if (!resp || resp.statusCode != 200 ||
        !el_is_valid_image_content_type(resp.headers) ||
        !el_is_valid_image_magic(resp.body)) {
        return nil;
    }

    UIImage *probe = [UIImage imageWithData:resp.body];
    if (!el_is_valid_decoded_image(probe)) {
        return nil;
    }

    if (path) {
        struct stat prevSt;
        unsigned long long prevSize = 0;
        if (cpath && lstat(cpath, &prevSt) == 0 && S_ISREG(prevSt.st_mode)) {
            prevSize = (unsigned long long)prevSt.st_size;
        }
        if ([resp.body writeToFile:path atomically:YES]) {
            unsigned long long newSize = (unsigned long long)[resp.body length];
            BOOL triggerPrune = NO;
            pthread_mutex_lock(&_diskLock);
            if (_diskCacheBytes >= prevSize) {
                _diskCacheBytes -= prevSize;
            } else {
                _diskCacheBytes = 0;
            }
            _diskCacheBytes += newSize;
            _diskWritesSincePrune++;
            if (_diskWritesSincePrune >= 25) {
                _diskWritesSincePrune = 0;
                triggerPrune = YES;
            }
            pthread_mutex_unlock(&_diskLock);
            if (triggerPrune) {
                [self enforceDiskCacheQuota];
            }
        }
    }
    return resp.body;
}

- (NSData *)downloadImageDataSyncForURL:(NSString *)urlString {
    return [self fetchRawImageDataSyncForURL:urlString];
}

- (UIImage *)fetchOrCachedImageSyncForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    UIImage *img = [self memoryCachedImageForURL:urlString];
    if (img) return img;

    NSData *data = [self fetchRawImageDataSyncForURL:urlString];
    if (!data) return nil;

    img = el_force_decode_opaque_image([UIImage imageWithData:data], EL_MAX_DECODED_ART_DIM);
    if (img) {
        [self storeInMemory:img forKey:urlString];
    }
    return img;
}

- (void)loadWorker:(NSDictionary *)info {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:el_image_worker_priority(NO)];
    NSString *urlString = [info objectForKey:@"url"];
    id target = [info objectForKey:@"target"];
    SEL action = NSSelectorFromString([info objectForKey:@"action"]);

    UIImage *img = [self fetchOrCachedImageSyncForURL:urlString];
    if (img) {
        /* Precompute dominant backdrop color off-main-thread so Now Playing / Dock Mode hit warm cache */
        [ELTheme dominantBackdropColorFromImage:img cacheKey:urlString];
    }

    pthread_mutex_lock(&_queueLock);
    [_inFlight removeObject:urlString];
    pthread_mutex_unlock(&_queueLock);

    if (img && target && [target respondsToSelector:action]) {
        NSDictionary *res = [NSDictionary dictionaryWithObjectsAndKeys:
                             urlString, @"url",
                             img, @"image",
                             nil];
        [target performSelectorOnMainThread:action
                                 withObject:res
                              waitUntilDone:NO
                                      modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
    }
    [pool release];
}

- (void)loadImageForURL:(NSString *)urlString target:(id)target action:(SEL)action {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryThumbnail, NULL, NULL, NULL)) return;
    /* Check RAM cache only on main thread; defer any disk read/JPEG decode to loadWorker */
    UIImage *existing = [self memoryCachedImageForURL:urlString];
    if (existing) {
        if (target && [target respondsToSelector:action]) {
            NSDictionary *res = [NSDictionary dictionaryWithObjectsAndKeys:
                                 urlString, @"url",
                                 existing, @"image",
                                 nil];
            [target performSelector:action withObject:res];
        }
        return;
    }

    pthread_mutex_lock(&_queueLock);
    BOOL alreadyInFlight = [_inFlight containsObject:urlString];
    if (!alreadyInFlight) {
        [_inFlight addObject:urlString];
    }
    pthread_mutex_unlock(&_queueLock);
    if (alreadyInFlight) return;

    NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:
                          urlString, @"url",
                          target, @"target",
                          NSStringFromSelector(action), @"action",
                          nil];
    [NSThread detachNewThreadSelector:@selector(loadWorker:) toTarget:self withObject:info];
}

- (void)thumbWorkerLoop {
    NSAutoreleasePool *outerPool = [[NSAutoreleasePool alloc] init];
    double lastPrio = el_image_worker_priority(YES);
    [NSThread setThreadPriority:lastPrio];

    while (1) {
        NSAutoreleasePool *innerPool = [[NSAutoreleasePool alloc] init];
        NSDictionary *req = nil;
        pthread_mutex_lock(&_queueLock);
        NSUInteger count = [_thumbQueue count];
        if (count == 0) {
            _activeThumbWorkers--;
            pthread_mutex_unlock(&_queueLock);
            [innerPool release];
            break;
        }
        /* LIFO: pop most recent request so currently visible cells load first during fast scrolling */
        req = [[_thumbQueue objectAtIndex:count - 1] retain];
        [_thumbQueue removeObjectAtIndex:count - 1];
        pthread_mutex_unlock(&_queueLock);

        double targetPrio = el_image_worker_priority(YES);
        if (targetPrio != lastPrio) {
            lastPrio = targetPrio;
            [NSThread setThreadPriority:targetPrio];
        }

        NSString *urlString = [req objectForKey:@"url"];
        NSString *videoId = [req objectForKey:@"videoId"];
        NSString *cacheKey = [req objectForKey:@"cacheKey"];
        CGFloat size = [[req objectForKey:@"size"] floatValue];
        CGFloat radius = [[req objectForKey:@"radius"] floatValue];
        UIColor *matteColor = [req objectForKey:@"matteColor"];
        id target = [req objectForKey:@"target"];
        SEL action = NSSelectorFromString([req objectForKey:@"action"]);

        UIImage *roundedImg = [ELTheme cachedRoundedThumbnailForSize:size radius:radius matteColor:matteColor cacheKey:cacheKey];
        if (!roundedImg && [videoId length] > 0) {
            NSString *localKey = [NSString stringWithFormat:@"local:%@", videoId];
            roundedImg = [ELTheme cachedRoundedThumbnailForSize:size radius:radius matteColor:matteColor cacheKey:localKey];
        }

        if (!roundedImg) {
            UIImage *rawImg = nil;
            if ([videoId length] > 0 && [[ELDownloadManager sharedManager] isDownloaded:videoId]) {
                rawImg = [[ELDownloadManager sharedManager] localArtImageForVideoId:videoId];
            }
            if (!rawImg && [urlString length] > 0) {
                rawImg = [self memoryCachedImageForURL:urlString];
                if (!rawImg) {
                    /* Fetch raw bytes without polluting _memCache with full-size bitmaps */
                    NSData *rawData = [self fetchRawImageDataSyncForURL:urlString];
                    if (rawData) {
                        rawImg = [UIImage imageWithData:rawData];
                    }
                }
            }
            if (rawImg) {
                roundedImg = [ELTheme roundedThumbnailFromImage:rawImg
                                                           size:size
                                                         radius:radius
                                                     matteColor:matteColor
                                                       cacheKey:cacheKey];
            }
        }

        if (roundedImg && target && [target respondsToSelector:action]) {
            NSDictionary *res = [NSDictionary dictionaryWithObjectsAndKeys:
                                 (cacheKey ? cacheKey : @""), @"cacheKey",
                                 (videoId ? videoId : @""), @"videoId",
                                 (urlString ? urlString : @""), @"url",
                                 roundedImg, @"image",
                                 nil];
            [target performSelectorOnMainThread:action
                                     withObject:res
                                  waitUntilDone:NO
                                          modes:[NSArray arrayWithObject:NSDefaultRunLoopMode]];
        }

        [req release];
        [innerPool release];
    }

    [outerPool release];
}

- (void)loadRoundedThumbnailForURL:(NSString *)urlString
                           videoId:(NSString *)videoId
                              size:(CGFloat)size
                            radius:(CGFloat)radius
                            target:(id)target
                            action:(SEL)action {
    [self loadRoundedThumbnailForURL:urlString
                             videoId:videoId
                                size:size
                              radius:radius
                          matteColor:[ELTheme surfaceColor]
                              target:target
                              action:action];
}

- (void)loadRoundedThumbnailForURL:(NSString *)urlString
                           videoId:(NSString *)videoId
                              size:(CGFloat)size
                            radius:(CGFloat)radius
                        matteColor:(UIColor *)matteColor
                            target:(id)target
                            action:(SEL)action {
    if (!target || !action) return;
    NSString *safeURL = (urlString ? urlString : @"");
    NSString *safeVid = (videoId ? videoId : @"");
    if ([safeURL length] == 0 && [safeVid length] == 0) return;

    NSString *cacheKey = ([safeURL length] > 0)
        ? safeURL
        : [NSString stringWithFormat:@"local:%@", safeVid];

    NSMutableDictionary *req = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                cacheKey, @"cacheKey",
                                safeURL, @"url",
                                safeVid, @"videoId",
                                [NSNumber numberWithFloat:(float)size], @"size",
                                [NSNumber numberWithFloat:(float)radius], @"radius",
                                target, @"target",
                                NSStringFromSelector(action), @"action",
                                nil];
    if (matteColor) {
        [req setObject:matteColor forKey:@"matteColor"];
    }

    BOOL spawnWorker = NO;
    pthread_mutex_lock(&_queueLock);
    /* Drop any stale pending request for this reused cell target */
    for (NSInteger i = (NSInteger)[_thumbQueue count] - 1; i >= 0; i--) {
        NSDictionary *item = [_thumbQueue objectAtIndex:(NSUInteger)i];
        if ([item objectForKey:@"target"] == target) {
            [_thumbQueue removeObjectAtIndex:(NSUInteger)i];
        }
    }
    if ([_thumbQueue count] >= EL_MAX_THUMB_QUEUE) {
        [_thumbQueue removeObjectAtIndex:0];
    }
    [_thumbQueue addObject:req];
    if (_activeThumbWorkers < EL_MAX_THUMB_WORKERS) {
        _activeThumbWorkers++;
        spawnWorker = YES;
    }
    pthread_mutex_unlock(&_queueLock);

    if (spawnWorker) {
        [NSThread detachNewThreadSelector:@selector(thumbWorkerLoop) toTarget:self withObject:nil];
    }
}

@end
