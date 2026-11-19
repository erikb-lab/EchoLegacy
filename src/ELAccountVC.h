#import <UIKit/UIKit.h>

@class ELUpdateInfo;

@interface ELAccountVC : UIViewController <UIAlertViewDelegate, UITextFieldDelegate> {
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
    UISwitch *_shakeSwitch;
    UISwitch *_lyricsSwitch;
    UILabel *_cacheLabel;
    UIButton *_clearCacheBtn;

    /* GitHub OTA Update card */
    UIView *_updateCard;
    UILabel *_updateStatusLabel;
    UIButton *_updateBtn;
    ELUpdateInfo *_pendingUpdate;
    BOOL _checkingUpdate;
    BOOL _installingUpdate;
    BOOL _relaunchReady;

    NSInteger _pollSession;
    BOOL _syncing;
}

@end
