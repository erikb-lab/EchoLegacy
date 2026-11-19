#import <UIKit/UIKit.h>
#include <pthread.h>

@interface ELImageCache : NSObject {
    pthread_mutex_t _memLock;
    pthread_mutex_t _queueLock;
    pthread_mutex_t _diskLock;
    NSMutableDictionary *_memCache;
    NSMutableArray *_lruKeys;
    NSMutableSet *_inFlight;
    NSMutableArray *_thumbQueue;
    NSInteger _activeThumbWorkers;
    NSInteger _diskWritesSincePrune;
    BOOL _isPruningDiskCache;
    unsigned long long _diskCacheBytes;
    NSString *_diskDir;
}

+ (ELImageCache *)sharedCache;

/* RAM-only lookup (zero disk I/O; safe on main thread) */
- (UIImage *)memoryCachedImageForURL:(NSString *)urlString;

/* Returns cached image immediately if in memory/disk, else nil */
- (UIImage *)cachedImageForURL:(NSString *)urlString;

/* Loads image asynchronously over TLS 1.2 if needed and calls target/selector on main thread with NSDictionary {url, image} */
- (void)loadImageForURL:(NSString *)urlString target:(id)target action:(SEL)action;

/* Bounded LIFO async loader + off-main-thread rounded thumbnail renderer for table cells */
- (void)loadRoundedThumbnailForURL:(NSString *)urlString
                           videoId:(NSString *)videoId
                              size:(CGFloat)size
                            radius:(CGFloat)radius
                            target:(id)target
                            action:(SEL)action;

- (void)loadRoundedThumbnailForURL:(NSString *)urlString
                           videoId:(NSString *)videoId
                              size:(CGFloat)size
                            radius:(CGFloat)radius
                        matteColor:(UIColor *)matteColor
                            target:(id)target
                            action:(SEL)action;

/* Synchronously fetches and returns raw JPEG bytes (for offline download storage) */
- (NSData *)downloadImageDataSyncForURL:(NSString *)urlString;

/* RAM optimization: flushes in-memory decoded bitmaps while keeping disk cache intact */
- (void)clearMemoryCache;

/* Clears both RAM and disk thumbnail cache; returns bytes freed from disk */
- (unsigned long long)clearAllCache;
- (unsigned long long)diskCacheBytes;

@end
