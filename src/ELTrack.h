#import <Foundation/Foundation.h>

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
