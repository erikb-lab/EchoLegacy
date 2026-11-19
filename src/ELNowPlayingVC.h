#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "ELFeatures.h"

#define EL_NP_HAS_MORE_MENU (EL_FEATURE_RADIO_MIX || EL_FEATURE_SLEEP_TIMER || EL_FEATURE_DOWNLOADS || EL_FEATURE_DOCK_MODE || EL_FEATURE_LOCAL_PLAYLISTS)

@interface ELNowPlayingVC : UIViewController
#if EL_FEATURE_LYRICS || EL_NP_HAS_MORE_MENU
<
#if EL_FEATURE_LYRICS
    UITableViewDataSource, UITableViewDelegate
#if EL_NP_HAS_MORE_MENU
    ,
#endif
#endif
#if EL_NP_HAS_MORE_MENU
    UIActionSheetDelegate
#endif
>
#endif
{
    UIImageView *_backdropView;
    UIImageView *_topScrimView;
    UIImageView *_artFadeView;
    UIImageView *_artView;
    UILabel *_sourceBadge;
#if EL_FEATURE_LYRICS
    UIButton *_lyricsBtn;
    UIView *_lyricsContainer;
    UITableView *_lyricsTable;
    UILabel *_lyricsStatusLabel;
#endif
#if EL_FEATURE_MARQUEE
    UIView *_titleMarqueeContainer;
    UIView *_titleTrackView;
    UILabel *_titleLabelClone;
    UIView *_artistMarqueeContainer;
    UIView *_artistTrackView;
    UILabel *_artistLabelClone;
    BOOL _isViewVisible;
    NSString *_lastTitleText;
    NSString *_lastArtistText;
#endif
    UILabel *_titleLabel;
    UILabel *_artistLabel;
#if EL_NP_HAS_MORE_MENU
    UIButton *_moreBtn;
    NSInteger _moreRadioIdx;
    NSInteger _moreSleepIdx;
    NSInteger _moreDownloadIdx;
#if EL_FEATURE_DOCK_MODE
    NSInteger _moreDockIdx;
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
    NSInteger _morePlaylistIdx;
    NSArray *_pickerPlaylists;
#endif
#endif
#if EL_FEATURE_LIKES
    UIButton *_likeBtn;
    BOOL _isLiked;
    NSInteger _lastLikeVisualState;
    NSInteger _likeRequestGen;
    NSString *_inFlightLikeVideoId;
#endif
    UISlider *_scrubber;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
    UIButton *_shuffleBtn;
    UIImageView *_shuffleDot;
    NSInteger _lastShuffleState;
    UIButton *_prevBtn;
    UIButton *_playPauseBtn;
    NSInteger _lastPlayIconState;
    UIButton *_nextBtn;
    UIButton *_repeatBtn;
    UIImageView *_repeatDot;
    UILabel *_repeatOneBadge;
    NSInteger _lastRepeatState;
    UIButton *_queueBtn;
#if EL_FEATURE_DOWNLOADS
    UIButton *_downloadBtn;
#endif
    UIActivityIndicatorView *_spinner;
    BOOL _isScrubbing;
#if EL_FEATURE_LYRICS
    BOOL _showingLyrics;
    NSInteger _lyricsGen;
    NSInteger _activeLyricIndex;
    NSArray *_lyricLines;
    NSString *_lyricsVideoId;
#endif
    NSInteger _lastDisplayedElapsedSec;
    NSInteger _lastDisplayedDurationSec;
    NSString *_currentVideoId;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@end
