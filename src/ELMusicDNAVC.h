#import <UIKit/UIKit.h>
#import "ELFeatures.h"

#if EL_FEATURE_MUSIC_DNA

@class ELTrack;

@interface ELMusicDNAVC : UIViewController {
    ELTrack *_track;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UILabel *_sourceBadge;
    UITextView *_summaryView;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    NSInteger _loadGen;
}

- (id)initWithTrack:(ELTrack *)track;

@end

#endif /* EL_FEATURE_MUSIC_DNA */
