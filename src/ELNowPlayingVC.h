#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface ELNowPlayingVC : UIViewController {
    CAGradientLayer *_backdropGradient;
    CAGradientLayer *_topScrimLayer;
    CAGradientLayer *_artFadeLayer;
    UIImageView *_artView;
    UILabel *_sourceBadge;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_likeBtn;
    UISlider *_scrubber;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UIButton *_shuffleBtn;
    UIImageView *_shuffleDot;
    UIButton *_prevBtn;
    UIButton *_playPauseBtn;
    UIButton *_nextBtn;
    UIButton *_repeatBtn;
    UIImageView *_repeatDot;
    UILabel *_repeatOneBadge;
    UIButton *_queueBtn;
    UIButton *_downloadBtn;
    UIActivityIndicatorView *_spinner;
    BOOL _isScrubbing;
    BOOL _isLiked;
    NSInteger _likeRequestGen;
    NSString *_inFlightLikeVideoId;
    NSString *_currentVideoId;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@end
