#import "ELAppDelegate.h"
#import "ELAccountVC.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#import "ELHTTPClient.h"
#import "ELImageCache.h"
#import "ELNowPlayingVC.h"
#import "ELTheme.h"

#if EL_FEATURE_HOME_TAB
#import "ELHomeVC.h"
#endif
#if EL_FEATURE_SEARCH_TAB
#import "ELSearchVC.h"
#endif
#if EL_FEATURE_LIBRARY_TAB
#import "ELLibraryVC.h"
#endif
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadsVC.h"
#endif

@implementation ELWindow

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    [[ELAudioEngine sharedEngine] handleRemoteControlEvent:event];
}

#if EL_FEATURE_SHAKE_SHUFFLE
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    (void)event;
    if (motion == UIEventSubtypeMotionShake) {
        [[ELAudioEngine sharedEngine] handleShakeToShuffle];
    }
}
#endif

@end

@interface ELAppDelegate ()
- (NSArray *)buildTabViewControllers;
- (void)setupMiniPlayerBar;
- (void)setupToastLabel;
- (void)setupPrivacyShieldWithBounds:(CGRect)bounds;
- (void)clearToastTimer;
- (void)showPrivacyShield;
- (void)hidePrivacyShield;
@end

@implementation ELAppDelegate
@synthesize window = _window;

- (void)appendTabWithController:(UIViewController *)rootVC toArray:(NSMutableArray *)tabs {
    if (!rootVC || !tabs) return;
    UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:rootVC] autorelease];
    [ELTheme styleNavBar:nav.navigationBar];
    [tabs addObject:nav];
}

- (NSArray *)buildTabViewControllers {
    NSMutableArray *tabs = [NSMutableArray arrayWithCapacity:5];
#if EL_FEATURE_HOME_TAB
    [self appendTabWithController:[[[ELHomeVC alloc] init] autorelease] toArray:tabs];
#endif
#if EL_FEATURE_SEARCH_TAB
    [self appendTabWithController:[[[ELSearchVC alloc] init] autorelease] toArray:tabs];
#endif
#if EL_FEATURE_LIBRARY_TAB
    [self appendTabWithController:[[[ELLibraryVC alloc] init] autorelease] toArray:tabs];
#endif
#if EL_FEATURE_DOWNLOADS
    [self appendTabWithController:[[[ELDownloadsVC alloc] init] autorelease] toArray:tabs];
#endif
    /* Account stays mounted so sign-in and diagnostics remain reachable even if other tabs are disabled. */
    [self appendTabWithController:[[[ELAccountVC alloc] init] autorelease] toArray:tabs];
    return tabs;
}

- (void)setupMiniPlayerBar {
    /* Persistent Mini-Player Bar pinned directly above the 49px UITabBar */
    CGFloat tabBarH = 49.0f;
    CGFloat miniH = 52.0f;
    CGRect tbBounds = _tabBarController.view.bounds;
    _miniPlayerBar = [[ELMiniPlayerBar alloc] initWithFrame:CGRectMake(0.0f, tbBounds.size.height - tabBarH - miniH, tbBounds.size.width, miniH)];
    _miniPlayerBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _miniPlayerBar.delegate = self;
    [_tabBarController.view addSubview:_miniPlayerBar];
}

- (void)setupToastLabel {
    /* Floating dark toast pill using pre-rendered image (zero offscreen cornerRadius FBO) */
    CGRect toastFrame = CGRectMake(40.0f, 32.0f, 240.0f, 30.0f);
    UIColor *toastFill = [UIColor colorWithRed:0.12f green:0.12f blue:0.17f alpha:0.94f];
    UIImage *pillImg = [ELTheme roundedRectImageWithSize:toastFrame.size
                                                  radius:15.0f
                                               fillColor:toastFill
                                             borderColor:[ELTheme accentColor]];
    _toastBgView = [[UIImageView alloc] initWithFrame:toastFrame];
    _toastBgView.image = pillImg;
    _toastBgView.alpha = 0.0f;
    _toastBgView.userInteractionEnabled = NO;

    _toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(10.0f, 0.0f, toastFrame.size.width - 20.0f, toastFrame.size.height)];
    _toastLabel.backgroundColor = [UIColor clearColor];
    _toastLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    _toastLabel.textColor = [UIColor whiteColor];
    _toastLabel.textAlignment = UITextAlignmentCenter;
    _toastLabel.userInteractionEnabled = NO;
    [_toastBgView addSubview:_toastLabel];
    [_window addSubview:_toastBgView];
}

- (void)setupPrivacyShieldWithBounds:(CGRect)bounds {
    /* Opaque full-screen privacy shield to prevent iOS app-switcher snapshots from capturing OAuth codes */
    _privacyShieldView = [[UIView alloc] initWithFrame:bounds];
    _privacyShieldView.backgroundColor = [ELTheme backgroundColor];
    _privacyShieldView.opaque = YES;
    _privacyShieldView.hidden = YES;
    _privacyShieldView.userInteractionEnabled = NO;

    UILabel *shieldTitle = [[[UILabel alloc] initWithFrame:CGRectMake(20.0f, 210.0f, 280.0f, 40.0f)] autorelease];
    shieldTitle.backgroundColor = [UIColor clearColor];
    shieldTitle.font = [UIFont boldSystemFontOfSize:24.0f];
    shieldTitle.textColor = [ELTheme textPrimaryColor];
    shieldTitle.textAlignment = UITextAlignmentCenter;
    shieldTitle.text = @"EchoLegacy";
    [_privacyShieldView addSubview:shieldTitle];
    [_window addSubview:_privacyShieldView];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;

    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque];
    [ELAudioEngine sharedEngine];
    [application beginReceivingRemoteControlEvents];

    CGRect bounds = [[UIScreen mainScreen] bounds];
    _window = [[ELWindow alloc] initWithFrame:bounds];
    _window.backgroundColor = [ELTheme backgroundColor];

    _tabBarController = [[UITabBarController alloc] init];
    _tabBarController.viewControllers = [self buildTabViewControllers];
    _tabBarController.selectedIndex = 0;
    [_window addSubview:_tabBarController.view];

    [self setupMiniPlayerBar];
    [self setupToastLabel];
    [self setupPrivacyShieldWithBounds:bounds];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onToastNotification:)
                                                 name:ELPlayerToastNotification
                                               object:nil];

    [_window makeKeyAndVisible];
    [_window becomeFirstResponder];
    return YES;
}

- (void)clearToastTimer {
    [_toastTimer invalidate];
    [_toastTimer release];
    _toastTimer = nil;
}

- (void)onToastNotification:(NSNotification *)note {
    NSString *msg = [[note userInfo] objectForKey:@"message"];
    if ([msg length] == 0) return;

    _toastLabel.text = msg;
    [_window bringSubviewToFront:_toastBgView];
    [self clearToastTimer];

    [UIView beginAnimations:@"toastIn" context:NULL];
    [UIView setAnimationDuration:0.18];
    _toastBgView.alpha = 1.0f;
    [UIView commitAnimations];

    _toastTimer = [[NSTimer scheduledTimerWithTimeInterval:1.6
                                                    target:self
                                                  selector:@selector(hideToast)
                                                  userInfo:nil
                                                   repeats:NO] retain];
}

- (void)hideToast {
    [self clearToastTimer];

    [UIView beginAnimations:@"toastOut" context:NULL];
    [UIView setAnimationDuration:0.25];
    _toastBgView.alpha = 0.0f;
    [UIView commitAnimations];
}

- (void)miniPlayerBarDidTapOpen:(id)bar {
    (void)bar;
    ELNowPlayingVC *np = [[[ELNowPlayingVC alloc] init] autorelease];
    [_tabBarController presentModalViewController:np animated:YES];
}

- (void)showPrivacyShield {
    if (!_privacyShieldView) return;
    [_window bringSubviewToFront:_privacyShieldView];
    _privacyShieldView.hidden = NO;
}

- (void)hidePrivacyShield {
    if (!_privacyShieldView) return;
    _privacyShieldView.hidden = YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
    [self showPrivacyShield];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self hidePrivacyShield];
    [application beginReceivingRemoteControlEvents];
    [_window becomeFirstResponder];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [self showPrivacyShield];
    [application beginReceivingRemoteControlEvents];
    [_window becomeFirstResponder];
    /* RAM optimization: flush decoded bitmaps, theme caches, and idle TLS sockets while backgrounded */
    [[ELImageCache sharedCache] clearMemoryCache];
    [ELTheme flushMemoryCaches];
    [ELHTTPClient clearKeepAlivePool];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    (void)application;
    [self hidePrivacyShield];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    (void)application;
    [[ELImageCache sharedCache] clearMemoryCache];
    [ELTheme flushMemoryCaches];
    [ELHTTPClient clearKeepAlivePool];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [application endReceivingRemoteControlEvents];
    [[ELAudioEngine sharedEngine] stop];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self clearToastTimer];
    [_privacyShieldView release];
    [_toastLabel release];
    [_toastBgView release];
    [_miniPlayerBar release];
    [_tabBarController release];
    [_window release];
    [super dealloc];
}

@end
