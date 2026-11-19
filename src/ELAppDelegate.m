#import "ELAppDelegate.h"
#import "ELAccountVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadsVC.h"
#import "ELHomeVC.h"
#import "ELImageCache.h"
#import "ELLibraryVC.h"
#import "ELNowPlayingVC.h"
#import "ELSearchVC.h"
#import "ELTheme.h"

@implementation ELWindow

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    [[ELAudioEngine sharedEngine] handleRemoteControlEvent:event];
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    (void)event;
    if (motion == UIEventSubtypeMotionShake) {
        [[ELAudioEngine sharedEngine] handleShakeToShuffle];
    }
}

@end

@implementation ELAppDelegate
@synthesize window = _window;

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)launchOptions;

    [application setStatusBarStyle:UIStatusBarStyleBlackOpaque];

    [ELAudioEngine sharedEngine];
    [application beginReceivingRemoteControlEvents];

    CGRect bounds = [[UIScreen mainScreen] bounds];
    _window = [[ELWindow alloc] initWithFrame:bounds];
    _window.backgroundColor = [ELTheme backgroundColor];

    ELHomeVC *homeVC = [[[ELHomeVC alloc] init] autorelease];
    ELSearchVC *searchVC = [[[ELSearchVC alloc] init] autorelease];
    ELLibraryVC *libVC = [[[ELLibraryVC alloc] init] autorelease];
    ELDownloadsVC *dlVC = [[[ELDownloadsVC alloc] init] autorelease];
    ELAccountVC *acctVC = [[[ELAccountVC alloc] init] autorelease];

    UINavigationController *homeNav = [[[UINavigationController alloc] initWithRootViewController:homeVC] autorelease];
    UINavigationController *searchNav = [[[UINavigationController alloc] initWithRootViewController:searchVC] autorelease];
    UINavigationController *libNav = [[[UINavigationController alloc] initWithRootViewController:libVC] autorelease];
    UINavigationController *dlNav = [[[UINavigationController alloc] initWithRootViewController:dlVC] autorelease];
    UINavigationController *acctNav = [[[UINavigationController alloc] initWithRootViewController:acctVC] autorelease];

    [ELTheme styleNavBar:homeNav.navigationBar];
    [ELTheme styleNavBar:searchNav.navigationBar];
    [ELTheme styleNavBar:libNav.navigationBar];
    [ELTheme styleNavBar:dlNav.navigationBar];
    [ELTheme styleNavBar:acctNav.navigationBar];

    _tabBarController = [[UITabBarController alloc] init];
    _tabBarController.viewControllers = [NSArray arrayWithObjects:homeNav, searchNav, libNav, dlNav, acctNav, nil];
    _tabBarController.selectedIndex = 0;

    [_window addSubview:_tabBarController.view];

    /* Persistent Mini-Player Bar pinned directly above the 49px UITabBar */
    CGFloat tabBarH = 49.0f;
    CGFloat miniH = 52.0f;
    CGRect tbBounds = _tabBarController.view.bounds;
    _miniPlayerBar = [[ELMiniPlayerBar alloc] initWithFrame:CGRectMake(0, tbBounds.size.height - tabBarH - miniH, tbBounds.size.width, miniH)];
    _miniPlayerBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    _miniPlayerBar.delegate = self;
    [_tabBarController.view addSubview:_miniPlayerBar];

    /* Floating dark toast pill for Shake-to-Shuffle / Shuffle / Repeat feedback */
    _toastLabel = [[UILabel alloc] initWithFrame:CGRectMake(40, 32, 240, 30)];
    _toastLabel.backgroundColor = [UIColor colorWithRed:0.12f green:0.12f blue:0.17f alpha:0.94f];
    _toastLabel.layer.cornerRadius = 15.0f;
    _toastLabel.layer.borderColor = [[ELTheme accentColor] CGColor];
    _toastLabel.layer.borderWidth = 1.0f;
    _toastLabel.layer.masksToBounds = YES;
    _toastLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    _toastLabel.textColor = [UIColor whiteColor];
    _toastLabel.textAlignment = UITextAlignmentCenter;
    _toastLabel.alpha = 0.0f;
    _toastLabel.userInteractionEnabled = NO;
    [_window addSubview:_toastLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onToastNotification:)
                                                 name:ELPlayerToastNotification
                                               object:nil];

    [_window makeKeyAndVisible];
    [_window becomeFirstResponder];
    return YES;
}

- (void)onToastNotification:(NSNotification *)note {
    NSString *msg = [[note userInfo] objectForKey:@"message"];
    if ([msg length] == 0) return;
    _toastLabel.text = msg;
    [_window bringSubviewToFront:_toastLabel];

    [_toastTimer invalidate];
    [_toastTimer release];
    _toastTimer = nil;

    [UIView beginAnimations:@"toastIn" context:NULL];
    [UIView setAnimationDuration:0.18];
    _toastLabel.alpha = 1.0f;
    [UIView commitAnimations];

    _toastTimer = [[NSTimer scheduledTimerWithTimeInterval:1.6
                                                    target:self
                                                  selector:@selector(hideToast)
                                                  userInfo:nil
                                                   repeats:NO] retain];
}

- (void)hideToast {
    [_toastTimer invalidate];
    [_toastTimer release];
    _toastTimer = nil;

    [UIView beginAnimations:@"toastOut" context:NULL];
    [UIView setAnimationDuration:0.25];
    _toastLabel.alpha = 0.0f;
    [UIView commitAnimations];
}

- (void)miniPlayerBarDidTapOpen:(id)bar {
    (void)bar;
    ELNowPlayingVC *np = [[[ELNowPlayingVC alloc] init] autorelease];
    [_tabBarController presentModalViewController:np animated:YES];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [application beginReceivingRemoteControlEvents];
    [_window becomeFirstResponder];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    [application beginReceivingRemoteControlEvents];
    [_window becomeFirstResponder];
    /* RAM optimization: flush decoded album art bitmaps while backgrounded (disk cache stays intact) */
    [[ELImageCache sharedCache] clearMemoryCache];
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    (void)application;
    [[ELImageCache sharedCache] clearMemoryCache];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [application endReceivingRemoteControlEvents];
    [[ELAudioEngine sharedEngine] stop];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_toastTimer invalidate];
    [_toastTimer release];
    [_toastLabel release];
    [_miniPlayerBar release];
    [_tabBarController release];
    [_window release];
    [super dealloc];
}

@end
