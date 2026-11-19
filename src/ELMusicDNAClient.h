#import <Foundation/Foundation.h>
#import "ELFeatures.h"
#import "ELTrack.h"

#if EL_FEATURE_MUSIC_DNA

@interface ELMusicDNAClient : NSObject {
    NSString *_cacheDir;
}

+ (ELMusicDNAClient *)sharedClient;

/* Synchronous — call from a background thread.
   Returns NSDictionary with keys: @"title", @"summary", @"source" (@"Wikipedia"). */
- (NSDictionary *)fetchDNAForTrack:(ELTrack *)track error:(NSString **)outError;

@end

#endif /* EL_FEATURE_MUSIC_DNA */
