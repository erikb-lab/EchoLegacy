#import <UIKit/UIKit.h>
#import "ELTrack.h"

extern NSString *const ELDownloadsChangedNotification;
extern NSString *const ELDownloadProgressNotification; /* userInfo: videoId, progress (NSNumber float) */
extern NSString *const ELDownloadBatchProgressNotification; /* userInfo: title, total, completed, active */

@interface ELDownloadManager : NSObject {
    NSMutableArray *_tracks;
    NSMutableSet *_downloadedIds;
    NSMutableArray *_pendingQueue;
    NSMutableSet *_queuedIds;
    NSMutableDictionary *_progressById;
    NSMutableSet *_activeIds;
    NSMutableSet *_cancelledIds;
    NSMutableDictionary *_retryCountById;
    NSMutableSet *_batchIds;
    NSString *_batchTitle;
    NSInteger _batchTotal;
    NSInteger _batchCompleted;
    BOOL _isBackgrounded;
    NSString *_downloadsDir;
    UIBackgroundTaskIdentifier _dlBgTask;
}

+ (ELDownloadManager *)sharedManager;

@property (nonatomic, readonly) NSInteger batchTotal;
@property (nonatomic, readonly) NSInteger batchCompleted;
@property (nonatomic, readonly) BOOL isBatchDownloading;

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
- (void)downloadPlaylistTracks:(NSArray *)tracks title:(NSString *)title;
- (void)cancelBatchDownload;
- (void)cancelDownloadForVideoId:(NSString *)videoId;
- (void)deleteDownloadForVideoId:(NSString *)videoId;

@end
