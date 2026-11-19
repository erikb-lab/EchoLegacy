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
        _memCache = [[NSMutableDictionary alloc] init];
        _lruKeys = [[NSMutableArray alloc] init];
        _inFlight = [[NSMutableSet alloc] init];
        _thumbQueue = [[NSMutableArray alloc] init];
        _activeThumbWorkers = 0;

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
    [super dealloc];
}

- (void)clearMemoryCache {
    @synchronized(self) {
        [_memCache removeAllObjects];
        [_lruKeys removeAllObjects];
    }
}

- (unsigned long long)diskCacheBytes {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    unsigned long long total = 0;
    for (NSString *f in files) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:[_diskDir stringByAppendingPathComponent:f] error:nil];
        total += [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
    }
    return total;
}

- (unsigned long long)clearAllCache {
    [self clearMemoryCache];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    unsigned long long freed = 0;
    for (NSString *f in files) {
        NSString *full = [_diskDir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        freed += [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
        [fm removeItemAtPath:full error:nil];
    }
    return freed;
}

- (NSString *)diskPathForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    return [_diskDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", el_sha1_hex(urlString)]];
}

- (void)enforceDiskCacheQuota {
    BOOL shouldRun = NO;
    @synchronized(self) {
        if (!_isPruningDiskCache) {
            _isPruningDiskCache = YES;
            shouldRun = YES;
        }
    }
    if (!shouldRun) return;

    /* Run directory scan & lstat outside @synchronized(self) so UI/thumbnail reads never stall */
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSArray *files = [fm contentsOfDirectoryAtPath:_diskDir error:nil];
    if ([files count] > 0) {
        unsigned long long total = 0;
        NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[files count]];
        for (NSString *f in files) {
            NSString *full = [_diskDir stringByAppendingPathComponent:f];
            struct stat st;
            if (lstat([full UTF8String], &st) == 0 && S_ISREG(st.st_mode)) {
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
                if (unlink([p UTF8String]) == 0) {
                    total = (total > sz) ? (total - sz) : 0;
                }
            }
        }
    }

    @synchronized(self) {
        _isPruningDiskCache = NO;
    }
}

- (void)storeInMemory:(UIImage *)img forKey:(NSString *)urlString {
    if (!el_is_valid_decoded_image(img) || !urlString) return;
    @synchronized(self) {
        [_memCache setObject:img forKey:urlString];
        [_lruKeys removeObject:urlString];
        [_lruKeys addObject:urlString];
        while ([_lruKeys count] > EL_MAX_MEM_IMAGES) {
            NSString *evict = [_lruKeys objectAtIndex:0];
            [_memCache removeObjectForKey:evict];
            [_lruKeys removeObjectAtIndex:0];
        }
    }
}

- (UIImage *)cachedImageForURL:(NSString *)urlString {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryThumbnail, NULL, NULL, NULL)) return nil;
    @synchronized(self) {
        UIImage *img = [_memCache objectForKey:urlString];
        if (img) return [[img retain] autorelease];
    }
    NSString *path = [self diskPathForURL:urlString];
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *raw = [NSData dataWithContentsOfFile:path];
        if (!el_is_valid_image_magic(raw)) {
            unlink([path UTF8String]);
            return nil;
        }
        UIImage *img = [UIImage imageWithData:raw];
        if (el_is_valid_decoded_image(img)) {
            utimes([path UTF8String], NULL);
            [self storeInMemory:img forKey:urlString];
            return img;
        } else {
            unlink([path UTF8String]);
        }
    }
    return nil;
}

- (UIImage *)memoryCachedImageForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    @synchronized(self) {
        UIImage *img = [_memCache objectForKey:urlString];
        if (img) return [[img retain] autorelease];
    }
    return nil;
}

- (NSData *)downloadImageDataSyncForURL:(NSString *)urlString {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryThumbnail, NULL, NULL, NULL)) return nil;
    NSString *path = [self diskPathForURL:urlString];
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *existing = [NSData dataWithContentsOfFile:path];
        if (el_is_valid_image_magic(existing)) {
            UIImage *diskImg = [UIImage imageWithData:existing];
            if (el_is_valid_decoded_image(diskImg)) {
                utimes([path UTF8String], NULL);
                [self storeInMemory:diskImg forKey:urlString];
                return existing;
            }
        }
        unlink([path UTF8String]);
    }
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:urlString
                                                       headers:nil
                                                      maxBytes:EL_MAX_IMAGE_BYTES];
    if (resp && resp.statusCode == 200 &&
        el_is_valid_image_content_type(resp.headers) &&
        el_is_valid_image_magic(resp.body)) {
        UIImage *decoded = [UIImage imageWithData:resp.body];
        if (!el_is_valid_decoded_image(decoded)) {
            return nil;
        }
        if (path) {
            [resp.body writeToFile:path atomically:YES];
            BOOL triggerPrune = NO;
            @synchronized(self) {
                _diskWritesSincePrune++;
                if (_diskWritesSincePrune >= 25) {
                    _diskWritesSincePrune = 0;
                    triggerPrune = YES;
                }
            }
            if (triggerPrune) {
                [self enforceDiskCacheQuota];
            }
        }
        [self storeInMemory:decoded forKey:urlString];
        return resp.body;
    }
    return nil;
}

- (void)loadWorker:(NSDictionary *)info {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:el_image_worker_priority(NO)];
    NSString *urlString = [info objectForKey:@"url"];
    id target = [info objectForKey:@"target"];
    SEL action = NSSelectorFromString([info objectForKey:@"action"]);

    UIImage *img = [self cachedImageForURL:urlString];
    if (!img) {
        NSData *data = [self downloadImageDataSyncForURL:urlString];
        if (data) {
            /* downloadImageDataSyncForURL already decoded and stored the UIImage in _memCache */
            img = [self memoryCachedImageForURL:urlString];
            if (!img) {
                img = [UIImage imageWithData:data];
                if (img) [self storeInMemory:img forKey:urlString];
            }
        }
    }

    @synchronized(self) {
        [_inFlight removeObject:urlString];
    }

    if (img && target && [target respondsToSelector:action]) {
        NSDictionary *res = [NSDictionary dictionaryWithObjectsAndKeys:
                             urlString, @"url",
                             img, @"image",
                             nil];
        [target performSelectorOnMainThread:action withObject:res waitUntilDone:NO];
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

    @synchronized(self) {
        if ([_inFlight containsObject:urlString]) return;
        [_inFlight addObject:urlString];
    }

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
        @synchronized(self) {
            NSUInteger count = [_thumbQueue count];
            if (count == 0) {
                _activeThumbWorkers--;
                [innerPool release];
                break;
            }
            /* LIFO: pop most recent request so currently visible cells load first during fast scrolling */
            req = [[_thumbQueue objectAtIndex:count - 1] retain];
            [_thumbQueue removeObjectAtIndex:count - 1];
        }

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
        id target = [req objectForKey:@"target"];
        SEL action = NSSelectorFromString([req objectForKey:@"action"]);

        UIImage *roundedImg = [ELTheme cachedRoundedThumbnailForSize:size radius:radius cacheKey:cacheKey];
        if (!roundedImg && [videoId length] > 0) {
            NSString *localKey = [NSString stringWithFormat:@"local:%@", videoId];
            roundedImg = [ELTheme cachedRoundedThumbnailForSize:size radius:radius cacheKey:localKey];
        }

        if (!roundedImg) {
            UIImage *rawImg = nil;
            if ([videoId length] > 0 && [[ELDownloadManager sharedManager] isDownloaded:videoId]) {
                rawImg = [[ELDownloadManager sharedManager] localArtImageForVideoId:videoId];
            }
            if (!rawImg && [urlString length] > 0) {
                rawImg = [self cachedImageForURL:urlString];
                if (!rawImg) {
                    NSData *data = [self downloadImageDataSyncForURL:urlString];
                    if (data) {
                        /* downloadImageDataSyncForURL already decoded and stored UIImage in _memCache */
                        rawImg = [self memoryCachedImageForURL:urlString];
                        if (!rawImg) {
                            rawImg = [UIImage imageWithData:data];
                            if (rawImg) {
                                [self storeInMemory:rawImg forKey:urlString];
                            }
                        }
                    }
                }
            }
            if (rawImg) {
                roundedImg = [ELTheme roundedThumbnailFromImage:rawImg size:size radius:radius cacheKey:cacheKey];
            }
        }

        if (roundedImg && target && [target respondsToSelector:action]) {
            NSDictionary *res = [NSDictionary dictionaryWithObjectsAndKeys:
                                 (cacheKey ? cacheKey : @""), @"cacheKey",
                                 (videoId ? videoId : @""), @"videoId",
                                 (urlString ? urlString : @""), @"url",
                                 roundedImg, @"image",
                                 nil];
            [target performSelectorOnMainThread:action withObject:res waitUntilDone:NO];
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
    if (!target || !action) return;
    NSString *safeURL = (urlString ? urlString : @"");
    NSString *safeVid = (videoId ? videoId : @"");
    if ([safeURL length] == 0 && [safeVid length] == 0) return;

    NSString *cacheKey = ([safeURL length] > 0)
        ? safeURL
        : [NSString stringWithFormat:@"local:%@", safeVid];

    NSDictionary *req = [NSDictionary dictionaryWithObjectsAndKeys:
                         cacheKey, @"cacheKey",
                         safeURL, @"url",
                         safeVid, @"videoId",
                         [NSNumber numberWithFloat:(float)size], @"size",
                         [NSNumber numberWithFloat:(float)radius], @"radius",
                         target, @"target",
                         NSStringFromSelector(action), @"action",
                         nil];

    BOOL spawnWorker = NO;
    @synchronized(self) {
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
    }

    if (spawnWorker) {
        [NSThread detachNewThreadSelector:@selector(thumbWorkerLoop) toTarget:self withObject:nil];
    }
}

@end
