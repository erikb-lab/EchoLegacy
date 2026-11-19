#import <Foundation/Foundation.h>
#import "ELTrack.h"

@interface ELLyricLine : NSObject {
    double _timeSeconds;
    NSString *_text;
}
@property (nonatomic, assign) double timeSeconds; /* -1.0 for plain/unsynced lyrics */
@property (nonatomic, copy) NSString *text;
@end

@interface ELLyricsClient : NSObject {
    NSString *_lyricsDir;
}

+ (ELLyricsClient *)sharedClient;

- (NSString *)lyricsFilePathForVideoId:(NSString *)videoId;
- (NSArray *)cachedLyricsForVideoId:(NSString *)videoId;
/* Synchronous — call from a background thread */
- (NSArray *)fetchLyricsForTrack:(ELTrack *)track error:(NSString **)outError;
- (void)deleteCachedLyricsForVideoId:(NSString *)videoId;

@end
