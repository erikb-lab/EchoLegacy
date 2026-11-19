#import "ELImageCache.h"
#import "ELHTTPClient.h"
#import <CommonCrypto/CommonDigest.h>

/* Lean cap for 128 MB RAM iPod touch 2G — disk cache keeps thumbnails fast without holding bitmaps in RAM */
#define EL_MAX_MEM_IMAGES 14

static NSString *el_sha1_hex(NSString *input) {
    const char *cstr = [input UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
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
    return [_diskDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", el_sha1_hex(urlString)]];
}

- (void)storeInMemory:(UIImage *)img forKey:(NSString *)urlString {
    if (!img || !urlString) return;
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
    if ([urlString length] == 0) return nil;
    @synchronized(self) {
        UIImage *img = [_memCache objectForKey:urlString];
        if (img) return [[img retain] autorelease];
    }
    NSString *path = [self diskPathForURL:urlString];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        UIImage *img = [UIImage imageWithContentsOfFile:path];
        if (img) {
            [self storeInMemory:img forKey:urlString];
            return img;
        }
    }
    return nil;
}

- (NSData *)downloadImageDataSyncForURL:(NSString *)urlString {
    if ([urlString length] == 0) return nil;
    NSString *path = [self diskPathForURL:urlString];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [NSData dataWithContentsOfFile:path];
    }
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:urlString headers:nil];
    if (resp.statusCode == 200 && [resp.body length] > 128) {
        [resp.body writeToFile:path atomically:YES];
        return resp.body;
    }
    return nil;
}

- (void)loadWorker:(NSDictionary *)info {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *urlString = [info objectForKey:@"url"];
    id target = [info objectForKey:@"target"];
    SEL action = NSSelectorFromString([info objectForKey:@"action"]);

    UIImage *img = [self cachedImageForURL:urlString];
    if (!img) {
        NSData *data = [self downloadImageDataSyncForURL:urlString];
        if (data) {
            img = [UIImage imageWithData:data];
            if (img) [self storeInMemory:img forKey:urlString];
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
    if ([urlString length] == 0) return;
    UIImage *existing = [self cachedImageForURL:urlString];
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

@end
