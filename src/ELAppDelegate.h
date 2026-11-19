#import <UIKit/UIKit.h>
#import "ELMiniPlayerBar.h"

@interface ELWindow : UIWindow
@end

@interface ELAppDelegate : NSObject <UIApplicationDelegate, ELMiniPlayerBarDelegate> {
    ELWindow *_window;
    UITabBarController *_tabBarController;
    ELMiniPlayerBar *_miniPlayerBar;
    UIImageView *_toastBgView;
    UILabel *_toastLabel;
    NSTimer *_toastTimer;
    UIView *_privacyShieldView;
}

@property (nonatomic, retain) ELWindow *window;

/* Wraps rootVC in a styled UINavigationController and appends it to tabs. */
- (void)appendTabWithController:(UIViewController *)rootVC toArray:(NSMutableArray *)tabs;

@end
