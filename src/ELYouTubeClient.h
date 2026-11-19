#import <Foundation/Foundation.h>
#import "ELTrack.h"

extern NSString *const ELLibraryUpdatedNotification;

@interface ELStreamInfo : NSObject {
    NSString *_url;
    NSString *_userAgent;
    NSInteger _itag;
    long long _contentLength;
    double _durationSeconds;
}
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic, assign) NSInteger itag;
@property (nonatomic, assign) long long contentLength;
@property (nonatomic, assign) double durationSeconds;
@end

@interface ELYouTubeClient : NSObject {
    NSArray *_cachedLikedSongs;
    NSArray *_cachedPlaylists;
    NSTimeInterval _lastSyncTime;
    NSString *_visitorData;
    NSMutableDictionary *_streamInfoCache;
    NSMutableArray *_streamInfoLRU;
}

+ (ELYouTubeClient *)sharedClient;

@property (nonatomic, readonly) NSArray *cachedLikedSongs;
@property (nonatomic, readonly) NSArray *cachedPlaylists;
@property (nonatomic, readonly) NSTimeInterval lastSyncTime;

/* All network methods are synchronous — call from a background thread */
- (NSArray *)searchSongs:(NSString *)query error:(NSString **)outError;
- (NSArray *)fetchHomeTracksForMood:(NSString *)mood error:(NSString **)outError;
- (NSArray *)fetchRadioTracksForVideoId:(NSString *)videoId error:(NSString **)outError;
- (ELStreamInfo *)resolveAudioStreamForVideoId:(NSString *)videoId error:(NSString **)outError;
- (void)invalidateCachedStreamForVideoId:(NSString *)videoId;
- (BOOL)syncLibraryWithError:(NSString **)outError;
- (NSArray *)fetchTracksForPlaylistId:(NSString *)playlistId error:(NSString **)outError;
- (BOOL)isTrackLiked:(NSString *)videoId;
- (BOOL)setLiked:(BOOL)liked forTrack:(ELTrack *)track error:(NSString **)outError;
- (void)clearLibraryCache;

@end
