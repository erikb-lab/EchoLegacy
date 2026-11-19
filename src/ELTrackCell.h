#import <UIKit/UIKit.h>
#import "ELFeatures.h"
#import "ELTrack.h"

@interface ELTrackCell : UITableViewCell {
    UIImageView *_cardBgView;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
#if EL_FEATURE_DOWNLOADS
    UIButton *_downloadBtn;
#endif
    NSString *_currentVideoId;
    NSString *_currentThumbURL;
    ELTrack *_track;
    BOOL _isActiveBg;
    BOOL _bgInitialized;
}

@property (nonatomic, readonly) NSString *videoId;

- (void)configureWithTrack:(ELTrack *)track isCurrent:(BOOL)isCurrent;
- (void)refreshDownloadState;

@end
