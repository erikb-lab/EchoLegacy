#import <Foundation/Foundation.h>
#import "ELFeatures.h"
#import "ELTrack.h"

#if EL_FEATURE_LOCAL_PLAYLISTS

extern NSString *const ELLocalPlaylistsChangedNotification;

@interface ELLocalPlaylist : NSObject {
    NSString *_playlistId;
    NSString *_name;
    NSMutableArray *_tracks;
}

@property (nonatomic, copy) NSString *playlistId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, retain) NSMutableArray *tracks;

@end

@interface ELLocalPlaylistManager : NSObject {
    NSMutableArray *_playlists;
    NSString *_storePath;
    NSUInteger _nextIdCounter;
    NSCondition *_saveCond;
    NSArray *_pendingSaveSnapshot;
    BOOL _saveThreadStarted;
}

+ (ELLocalPlaylistManager *)sharedManager;

- (NSArray *)playlists;
- (ELLocalPlaylist *)playlistWithId:(NSString *)playlistId;
- (ELLocalPlaylist *)createPlaylistNamed:(NSString *)name;
- (void)renamePlaylistId:(NSString *)playlistId toName:(NSString *)newName;
- (void)deletePlaylistId:(NSString *)playlistId;
- (BOOL)addTrack:(ELTrack *)track toPlaylistId:(NSString *)playlistId;
- (void)removeTrackAtIndex:(NSUInteger)index fromPlaylistId:(NSString *)playlistId;
- (void)moveTrackAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex inPlaylistId:(NSString *)playlistId;
- (BOOL)playlistId:(NSString *)playlistId containsVideoId:(NSString *)videoId;

@end

#endif /* EL_FEATURE_LOCAL_PLAYLISTS */
