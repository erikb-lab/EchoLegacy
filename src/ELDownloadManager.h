#import <UIKit/UIKit.h>
#import "ELTrack.h"

extern NSString *const ELDownloadsChangedNotification;
extern NSString *const ELDownloadProgressNotification; /* userInfo: videoId, progress (NSNumber float) */

@interface ELDownloadManager : NSObject {
    NSMutableArray *_tracks;
    NSMutableArray *_pendingQueue;
    NSMutableDictionary *_progressById;
    NSMutableSet *_activeIds;
    NSMutableSet *_cancelledIds;
    NSString *_downloadsDir;
    UIBackgroundTaskIdentifier _dlBgTask;
}

+ (ELDownloadManager *)sharedManager;

- (NSArray *)downloadedTracks;
- (BOOL)isDownloaded:(NSString *)videoId;
- (BOOL)isDownloading:(NSString *)videoId;
- (BOOL)isQueued:(NSString *)videoId;
- (float)progressForVideoId:(NSString *)videoId;
- (unsigned long long)totalDownloadedBytes;

- (NSString *)localAudioPathForVideoId:(NSString *)videoId;
- (NSString *)localArtPathForVideoId:(NSString *)videoId;
- (UIImage *)localArtImageForVideoId:(NSString *)videoId;

- (void)downloadTrack:(ELTrack *)track;
- (void)downloadTracks:(NSArray *)tracks;
- (void)cancelDownloadForVideoId:(NSString *)videoId;
- (void)deleteDownloadForVideoId:(NSString *)videoId;

@end
