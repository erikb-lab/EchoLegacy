#import <UIKit/UIKit.h>
#import "ELMiniPlayerBar.h"

@interface ELWindow : UIWindow
@end

@interface ELAppDelegate : NSObject <UIApplicationDelegate, ELMiniPlayerBarDelegate> {
    ELWindow *_window;
    UITabBarController *_tabBarController;
    ELMiniPlayerBar *_miniPlayerBar;
    UILabel *_toastLabel;
    NSTimer *_toastTimer;
}

@property (nonatomic, retain) ELWindow *window;

@end
