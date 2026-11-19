#import <Foundation/Foundation.h>

/* Validates YouTube videoId against ^[A-Za-z0-9_-]{11}$ to block path traversal and injection. */
static inline BOOL el_is_valid_video_id(NSString *videoId) {
    if (!videoId || ![videoId isKindOfClass:[NSString class]]) return NO;
    if ([videoId length] != 11) return NO;
    for (NSUInteger i = 0; i < 11; i++) {
        unichar c = [videoId characterAtIndex:i];
        BOOL ok = ((c >= 'A' && c <= 'Z') ||
                   (c >= 'a' && c <= 'z') ||
                   (c >= '0' && c <= '9') ||
                   c == '_' || c == '-');
        if (!ok) return NO;
    }
    return YES;
}

@interface ELTrack : NSObject {
    NSString *_videoId;
    NSString *_title;
    NSString *_artist;
    NSString *_album;
    NSString *_durationText;
    NSInteger _durationSeconds;
    NSString *_thumbURL;
    NSString *_artURL;
}

@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *durationText;
@property (nonatomic, assign) NSInteger durationSeconds;
@property (nonatomic, copy) NSString *thumbURL;
@property (nonatomic, copy) NSString *artURL;

- (NSDictionary *)toDictionary;
+ (ELTrack *)trackFromDictionary:(NSDictionary *)dict;
+ (NSString *)formatSeconds:(double)sec;

@end

@interface ELPlaylist : NSObject {
    NSString *_playlistId;
    NSString *_title;
    NSString *_subtitle;
    NSString *_thumbURL;
}

@property (nonatomic, copy) NSString *playlistId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *thumbURL;

- (NSDictionary *)toDictionary;
+ (ELPlaylist *)playlistFromDictionary:(NSDictionary *)dict;

@end
