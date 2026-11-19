#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "ELFeatures.h"

#if EL_FEATURE_DOCK_MODE

@interface ELDockModeVC : UIViewController {
    UIImageView *_backdropView;
    UILabel *_clockLabel;
    UIButton *_dimBtn;
    UIImageView *_artView;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    UIView *_progressFill;
    UILabel *_elapsedLabel;
    UILabel *_durationLabel;
#if EL_FEATURE_LYRICS
    UILabel *_lyricLabel;
    NSArray *_cachedLyrics;
    NSString *_lyricsVideoId;
    NSInteger _activeLyricIndex;
    NSInteger _lyricsLoadGen;
#endif
    UIButton *_prevBtn;
    UIButton *_playPauseBtn;
    NSInteger _lastPlayIconState;
    UIButton *_nextBtn;
    UIActivityIndicatorView *_spinner;
    UIView *_dimOverlay;

    NSDateFormatter *_clockFormatter;
    NSTimer *_clockTimer;
    NSInteger _dimLevel;
    BOOL _isVisible;
    NSInteger _lastElapsedSec;
    NSInteger _lastDurationSec;
    NSString *_loadedArtKey;
    NSString *_loadedArtURL;
}

@end

#endif /* EL_FEATURE_DOCK_MODE */
