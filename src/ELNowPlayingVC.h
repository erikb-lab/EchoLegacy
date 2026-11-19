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
    UIView *_titleMarqueeContainer;
    UIView *_titleTrackView;
    UILabel *_titleLabel;
    UILabel *_titleLabelClone;
    UIView *_artistMarqueeContainer;
    UIView *_artistTrackView;
    UILabel *_artistLabel;
    UILabel *_artistLabelClone;
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
    BOOL _isViewVisible;
    NSInteger _likeRequestGen;
    NSInteger _lyricsGen;
    NSInteger _activeLyricIndex;
    NSInteger _lastDisplayedElapsedSec;
    NSInteger _lastDisplayedDurationSec;
    NSArray *_lyricLines;
    NSString *_lyricsVideoId;
    NSString *_inFlightLikeVideoId;
    NSString *_currentVideoId;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
    NSString *_lastTitleText;
    NSString *_lastArtistText;
}

@end
