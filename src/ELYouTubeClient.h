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
    NSSet *_cachedLikedIds;
    NSArray *_cachedPlaylists;
    NSTimeInterval _lastSyncTime;
    NSString *_visitorData;
    NSMutableDictionary *_streamInfoCache;
    NSMutableArray *_streamInfoLRU;
    NSMutableDictionary *_playlistTrackLRU;
    NSMutableArray *_playlistTrackLRUOrder;
}

+ (ELYouTubeClient *)sharedClient;

@property (nonatomic, readonly) NSArray *cachedLikedSongs;
@property (nonatomic, readonly) NSArray *cachedPlaylists;
@property (nonatomic, readonly) NSTimeInterval lastSyncTime;

/* All network methods are synchronous — call from a background thread */
- (NSArray *)searchSongs:(NSString *)query error:(NSString **)outError;
- (NSArray *)searchTracksForQuery:(NSString *)query
                        songsOnly:(BOOL)songsOnly
                       hideShorts:(BOOL)hideShorts
                            error:(NSString **)outError;
- (NSArray *)fetchSearchSuggestionsForQuery:(NSString *)query;
- (NSArray *)fetchHomeTracksForMood:(NSString *)mood error:(NSString **)outError;
- (NSArray *)fetchRadioTracksForVideoId:(NSString *)videoId error:(NSString **)outError;
- (ELStreamInfo *)resolveAudioStreamForVideoId:(NSString *)videoId error:(NSString **)outError;
- (void)invalidateCachedStreamForVideoId:(NSString *)videoId;
- (BOOL)syncLibraryWithError:(NSString **)outError;
- (NSArray *)fetchTracksForPlaylistId:(NSString *)playlistId error:(NSString **)outError;
- (NSArray *)fetchPlaylistPageForId:(NSString *)playlistId
                  continuationToken:(NSString *)contToken
              nextContinuationToken:(NSString **)outNextToken
                              error:(NSString **)outError;
- (NSArray *)cachedTracksForPlaylistId:(NSString *)playlistId;
- (void)saveCachedTracks:(NSArray *)tracks forPlaylistId:(NSString *)playlistId;
- (BOOL)isTrackLiked:(NSString *)videoId;
- (BOOL)setLiked:(BOOL)liked forTrack:(ELTrack *)track error:(NSString **)outError;
- (void)clearLibraryCache;

@end
