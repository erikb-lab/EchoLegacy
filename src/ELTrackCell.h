#import <UIKit/UIKit.h>
#import "ELTrack.h"

@interface ELTrackCell : UITableViewCell {
    UIImageView *_cardBgView;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_downloadBtn;
    NSString *_currentVideoId;
    NSString *_currentThumbURL;
    ELTrack *_track;
}

@property (nonatomic, readonly) NSString *videoId;

- (void)configureWithTrack:(ELTrack *)track isCurrent:(BOOL)isCurrent;
- (void)refreshDownloadState;

@end
