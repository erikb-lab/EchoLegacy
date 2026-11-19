#import <UIKit/UIKit.h>

@class ELUpdateInfo;

@interface ELAccountVC : UIViewController <UIAlertViewDelegate> {
    UIScrollView *_scrollView;
    UIView *_statusDot;
    UILabel *_accountTitleLabel;
    UILabel *_accountSubLabel;

    UIButton *_primaryBtn;
    UIButton *_secondaryBtn;

    /* Live Device OAuth code card */
    UIView *_codeCard;
    UILabel *_codeHintLabel;
    UILabel *_codeValueLabel;
    UILabel *_codePollLabel;
    UIActivityIndicatorView *_spinner;

    /* Settings & Storage card */
    UIView *_prefsCard;
    UISwitch *_shakeSwitch;
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
