#import <UIKit/UIKit.h>
#import "ELFeatures.h"

#if EL_FEATURE_OTA_UPDATER
@class ELUpdateInfo;
#endif

@interface ELAccountVC : UIViewController <
#if EL_FEATURE_OTA_UPDATER
    UIAlertViewDelegate,
#endif
    UITextFieldDelegate
> {
    UIScrollView *_scrollView;
    UIView *_statusDot;
    UILabel *_accountTitleLabel;
    UILabel *_accountSubLabel;

    UIButton *_primaryBtn;
    UIButton *_secondaryBtn;

    /* User-supplied OAuth Client ID / Secret configuration card */
    UIView *_oauthCard;
    UITextField *_clientIdField;
    UITextField *_clientSecretField;
    UIButton *_saveOAuthBtn;
    BOOL _showingOAuthConfig;

    /* Live Device OAuth code card */
    UIView *_codeCard;
    UILabel *_codeHintLabel;
    UILabel *_codeValueLabel;
    UIButton *_codeRevealBtn;
    UILabel *_codePollLabel;
    UIActivityIndicatorView *_spinner;
    NSString *_currentUserCode;
    BOOL _codeRevealed;
    NSTimer *_codeMaskTimer;

    /* Settings, Privacy & Storage card */
    UIView *_prefsCard;
#if EL_FEATURE_SHAKE_SHUFFLE
    UISwitch *_shakeSwitch;
#endif
#if EL_FEATURE_LYRICS
    UISwitch *_lyricsSwitch;
#endif
    UILabel *_cacheLabel;
    UIButton *_clearCacheBtn;

#if EL_FEATURE_OTA_UPDATER
    /* GitHub OTA Update card */
    UIView *_updateCard;
    UILabel *_updateStatusLabel;
    UIButton *_updateBtn;
    ELUpdateInfo *_pendingUpdate;
    BOOL _checkingUpdate;
    BOOL _installingUpdate;
    BOOL _relaunchReady;
#endif

    NSInteger _pollSession;
    BOOL _syncing;
}

@end
