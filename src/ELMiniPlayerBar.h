#import <UIKit/UIKit.h>

@protocol ELMiniPlayerBarDelegate <NSObject>
- (void)miniPlayerBarDidTapOpen:(id)bar;
@end

@interface ELMiniPlayerBar : UIView {
    id<ELMiniPlayerBarDelegate> _delegate;
    UIView *_progressFill;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UIButton *_likeBtn;
    UIButton *_playPauseBtn;
    UIActivityIndicatorView *_spinner;
    BOOL _isLiked;
    NSInteger _likeRequestGen;
    NSString *_inFlightLikeVideoId;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@property (nonatomic, assign) id<ELMiniPlayerBarDelegate> delegate;

- (void)refresh;

@end
