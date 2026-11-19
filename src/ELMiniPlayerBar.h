#import <UIKit/UIKit.h>
#import "ELFeatures.h"

@protocol ELMiniPlayerBarDelegate <NSObject>
- (void)miniPlayerBarDidTapOpen:(id)bar;
@end

@interface ELMiniPlayerBar : UIView {
    id<ELMiniPlayerBarDelegate> _delegate;
    UIView *_progressFill;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
#if EL_FEATURE_LIKES
    UIButton *_likeBtn;
    BOOL _isLiked;
    NSInteger _likeRequestGen;
    NSString *_inFlightLikeVideoId;
#endif
    UIButton *_playPauseBtn;
    UIActivityIndicatorView *_spinner;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@property (nonatomic, assign) id<ELMiniPlayerBarDelegate> delegate;

- (void)refresh;

@end
