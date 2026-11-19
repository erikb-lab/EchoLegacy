#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface ELNowPlayingVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate> {
    CAGradientLayer *_backdropGradient;
    CAGradientLayer *_topScrimLayer;
    CAGradientLayer *_artFadeLayer;
    UIImageView *_artView;
    UILabel *_sourceBadge;
    UIButton *_lyricsBtn;
    UIView *_lyricsContainer;
    UITableView *_lyricsTable;
    UILabel *_lyricsStatusLabel;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIButton *_moreBtn;
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
    BOOL _showingLyrics;
    NSInteger _likeRequestGen;
    NSInteger _lyricsGen;
    NSInteger _activeLyricIndex;
    NSArray *_lyricLines;
    NSString *_lyricsVideoId;
    NSString *_inFlightLikeVideoId;
    NSString *_currentVideoId;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@end
