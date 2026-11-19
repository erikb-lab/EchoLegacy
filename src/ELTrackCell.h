#import <UIKit/UIKit.h>
#import "ELFeatures.h"
#import "ELTrack.h"

@class ELTrackCellContentView;

@interface ELTrackCell : UITableViewCell {
    ELTrackCellContentView *_rowView;
    UIImageView *_artView;
#if EL_FEATURE_DOWNLOADS
    UIButton *_downloadHitBtn;
    NSInteger _dlState;
    NSInteger _dlPct;
#endif
    NSString *_currentVideoId;
    NSString *_currentThumbURL;
    NSString *_titleText;
    NSString *_subtitleText;
    ELTrack *_track;
    BOOL _isActiveBg;
    BOOL _isCurrent;
    BOOL _currentInitialized;
}

@property (nonatomic, readonly) NSString *videoId;

- (void)configureWithTrack:(ELTrack *)track isCurrent:(BOOL)isCurrent;
- (void)setCurrent:(BOOL)isCurrent;
- (void)refreshDownloadState;

@end
