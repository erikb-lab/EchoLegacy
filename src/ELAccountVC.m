#import "ELAccountVC.h"
#import "ELAudioEngine.h"
#import "ELAuthManager.h"
#import "ELImageCache.h"
#import "ELTheme.h"
#import "ELYouTubeClient.h"

@implementation ELAccountVC

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"Account";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Account"
                                                         image:[ELTheme tabIconAccount]
                                                           tag:3] autorelease];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _pollSession++;
    [_scrollView release];
    [_statusDot release];
    [_accountTitleLabel release];
    [_accountSubLabel release];
    [_primaryBtn release];
    [_secondaryBtn release];
    [_codeCard release];
    [_codeHintLabel release];
    [_codeValueLabel release];
    [_codePollLabel release];
    [_spinner release];
    [_prefsCard release];
    [_shakeSwitch release];
    [_cacheLabel release];
    [_clearCacheBtn release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.contentSize = CGSizeMake(320, 490);
    _scrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:_scrollView];

    /* 1. Google Account Status Card */
    UIView *card = [[[UIView alloc] initWithFrame:CGRectMake(16, 14, 288, 150)] autorelease];
    card.backgroundColor = [ELTheme surfaceColor];
    card.layer.cornerRadius = 12.0f;
    card.layer.masksToBounds = YES;
    [_scrollView addSubview:card];

    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(16, 20, 10, 10)];
    _statusDot.layer.cornerRadius = 5.0f;
    _statusDot.layer.masksToBounds = YES;
    [card addSubview:_statusDot];

    _accountTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 13, 238, 24)];
    _accountTitleLabel.backgroundColor = [UIColor clearColor];
    _accountTitleLabel.font = [UIFont boldSystemFontOfSize:17.0f];
    _accountTitleLabel.textColor = [ELTheme textPrimaryColor];
    [card addSubview:_accountTitleLabel];

    _accountSubLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 42, 256, 36)];
    _accountSubLabel.backgroundColor = [UIColor clearColor];
    _accountSubLabel.font = [UIFont systemFontOfSize:12.0f];
    _accountSubLabel.textColor = [ELTheme textSecondaryColor];
    _accountSubLabel.numberOfLines = 2;
    [card addSubview:_accountSubLabel];

    _primaryBtn = [[ELTheme pillButtonWithTitle:@"Sign In with Google"
                                          color:[ELTheme accentColor]
                                          frame:CGRectMake(16, 92, 256, 40)] retain];
    [_primaryBtn addTarget:self action:@selector(onPrimaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_primaryBtn];

    /* Secondary Action Button (Sign Out) */
    _secondaryBtn = [[ELTheme pillButtonWithTitle:@"Sign Out"
                                            color:[ELTheme surfaceHighlightColor]
                                            frame:CGRectMake(16, 174, 288, 36)] retain];
    [_secondaryBtn addTarget:self action:@selector(onSecondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_secondaryBtn];

    /* Device OAuth Code Card (shown during sign-in) */
    _codeCard = [[UIView alloc] initWithFrame:CGRectMake(16, 174, 288, 160)];
    _codeCard.backgroundColor = [ELTheme surfaceColor];
    _codeCard.layer.cornerRadius = 12.0f;
    _codeCard.layer.masksToBounds = YES;
    _codeCard.hidden = YES;
    [_scrollView addSubview:_codeCard];

    _codeHintLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 260, 36)];
    _codeHintLabel.backgroundColor = [UIColor clearColor];
    _codeHintLabel.font = [UIFont systemFontOfSize:12.0f];
    _codeHintLabel.textColor = [ELTheme textSecondaryColor];
    _codeHintLabel.textAlignment = UITextAlignmentCenter;
    _codeHintLabel.numberOfLines = 2;
    [_codeCard addSubview:_codeHintLabel];

    _codeValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 54, 260, 44)];
    _codeValueLabel.backgroundColor = [ELTheme backgroundColor];
    _codeValueLabel.layer.cornerRadius = 8.0f;
    _codeValueLabel.layer.masksToBounds = YES;
    _codeValueLabel.font = [UIFont boldSystemFontOfSize:24.0f];
    _codeValueLabel.textColor = [ELTheme textPrimaryColor];
    _codeValueLabel.textAlignment = UITextAlignmentCenter;
    [_codeCard addSubview:_codeValueLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.frame = CGRectMake(22, 114, 20, 20);
    _spinner.hidesWhenStopped = YES;
    [_codeCard addSubview:_spinner];

    _codePollLabel = [[UILabel alloc] initWithFrame:CGRectMake(48, 110, 226, 30)];
    _codePollLabel.backgroundColor = [UIColor clearColor];
    _codePollLabel.font = [UIFont systemFontOfSize:12.0f];
    _codePollLabel.textColor = [ELTheme textSecondaryColor];
    [_codeCard addSubview:_codePollLabel];

    /* 2. Playback & Storage Preferences Card */
    _prefsCard = [[UIView alloc] initWithFrame:CGRectMake(16, 224, 288, 134)];
    _prefsCard.backgroundColor = [ELTheme surfaceColor];
    _prefsCard.layer.cornerRadius = 12.0f;
    _prefsCard.layer.masksToBounds = YES;
    [_scrollView addSubview:_prefsCard];

    UILabel *pTitle = [[[UILabel alloc] initWithFrame:CGRectMake(16, 12, 256, 18)] autorelease];
    pTitle.backgroundColor = [UIColor clearColor];
    pTitle.font = [UIFont boldSystemFontOfSize:12.0f];
    pTitle.textColor = [ELTheme textSecondaryColor];
    pTitle.text = @"PLAYBACK & MEMORY";
    [_prefsCard addSubview:pTitle];

    UILabel *shakeLbl = [[[UILabel alloc] initWithFrame:CGRectMake(16, 40, 165, 24)] autorelease];
    shakeLbl.backgroundColor = [UIColor clearColor];
    shakeLbl.font = [UIFont boldSystemFontOfSize:14.0f];
    shakeLbl.textColor = [ELTheme textPrimaryColor];
    shakeLbl.text = @"Shake to Shuffle";
    [_prefsCard addSubview:shakeLbl];

    _shakeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(184, 38, 94, 27)];
    _shakeSwitch.on = [[ELAudioEngine sharedEngine] shakeToShuffleEnabled];
    [_shakeSwitch addTarget:self action:@selector(onShakeToggled) forControlEvents:UIControlEventValueChanged];
    [_prefsCard addSubview:_shakeSwitch];

    UIView *div = [[[UIView alloc] initWithFrame:CGRectMake(16, 76, 256, 1)] autorelease];
    div.backgroundColor = [ELTheme separatorColor];
    [_prefsCard addSubview:div];

    _cacheLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 89, 152, 32)];
    _cacheLabel.backgroundColor = [UIColor clearColor];
    _cacheLabel.font = [UIFont systemFontOfSize:12.0f];
    _cacheLabel.textColor = [ELTheme textSecondaryColor];
    _cacheLabel.numberOfLines = 2;
    [_prefsCard addSubview:_cacheLabel];

    _clearCacheBtn = [[ELTheme pillButtonWithTitle:@"Clear Cache"
                                             color:[ELTheme surfaceHighlightColor]
                                             frame:CGRectMake(174, 88, 98, 32)] retain];
    _clearCacheBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [_clearCacheBtn addTarget:self action:@selector(onClearCacheTapped) forControlEvents:UIControlEventTouchUpInside];
    [_prefsCard addSubview:_clearCacheBtn];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshUI) name:ELAuthStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshUI) name:ELLibraryUpdatedNotification object:nil];

    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshUI];
}

- (void)onShakeToggled {
    [[ELAudioEngine sharedEngine] setShakeToShuffleEnabled:_shakeSwitch.on];
    [[ELAudioEngine sharedEngine] postToast:(_shakeSwitch.on ? @"Shake to Shuffle: On" : @"Shake to Shuffle: Off")];
}

- (void)onClearCacheTapped {
    unsigned long long freed = [[ELImageCache sharedCache] clearAllCache];
    double mb = (double)freed / (1024.0 * 1024.0);
    [self refreshUI];
    [[ELAudioEngine sharedEngine] postToast:[NSString stringWithFormat:@"Freed %.1f MB cache", mb]];
}

- (void)refreshUI {
    ELAuthManager *auth = [ELAuthManager sharedManager];
    ELYouTubeClient *yt = [ELYouTubeClient sharedClient];

    _shakeSwitch.on = [[ELAudioEngine sharedEngine] shakeToShuffleEnabled];
    double cacheMB = (double)[[ELImageCache sharedCache] diskCacheBytes] / (1024.0 * 1024.0);
    _cacheLabel.text = [NSString stringWithFormat:@"Album Art Cache\n%.1f MB on disk", cacheMB];

    if ([auth isSignedIn]) {
        _statusDot.backgroundColor = [ELTheme successColor];
        NSString *name = [auth accountName];
        _accountTitleLabel.text = ([name length] > 0) ? name : @"Google Account";
        NSUInteger plCount = [[yt cachedPlaylists] count];
        NSUInteger songCount = [[yt cachedLikedSongs] count];
        _accountSubLabel.text = [NSString stringWithFormat:@"Signed in to YouTube Music\n%lu playlists  •  %lu liked songs synced",
                                 (unsigned long)plCount, (unsigned long)songCount];
        [_primaryBtn setTitle:(_syncing ? @"Syncing Library..." : @"Sync Library Now") forState:UIControlStateNormal];
        _primaryBtn.enabled = !_syncing;
        _secondaryBtn.hidden = NO;
        _codeCard.hidden = YES;
        [_spinner stopAnimating];
        _prefsCard.frame = CGRectMake(16, 224, 288, 134);
        _scrollView.contentSize = CGSizeMake(320, 440);
    } else {
        _statusDot.backgroundColor = [ELTheme textSecondaryColor];
        _accountTitleLabel.text = @"Not Signed In";
        _accountSubLabel.text = @"Sign in with Google to sync your YouTube Music playlists and liked songs directly on this iPod.";
        [_primaryBtn setTitle:@"Sign In with Google" forState:UIControlStateNormal];
        _primaryBtn.enabled = YES;
        _secondaryBtn.hidden = YES;
        CGFloat py = _codeCard.hidden ? 178.0f : 346.0f;
        _prefsCard.frame = CGRectMake(16, py, 288, 134);
        _scrollView.contentSize = CGSizeMake(320, py + 200.0f);
    }
}

- (void)onPrimaryTapped {
    if ([[ELAuthManager sharedManager] isSignedIn]) {
        [self startLibrarySync];
    } else {
        [self startGoogleDeviceSignIn];
    }
}

- (void)onSecondaryTapped {
    _pollSession++;
    [[ELAuthManager sharedManager] signOut];
    [[ELYouTubeClient sharedClient] clearLibraryCache];
    [self refreshUI];
}

- (void)startGoogleDeviceSignIn {
    _pollSession++;
    NSInteger session = _pollSession;

    _codeCard.hidden = NO;
    _codeHintLabel.text = @"Requesting code from Google...";
    _codeValueLabel.text = @"----";
    _codePollLabel.text = @"Connecting via TLS 1.2...";
    [_spinner startAnimating];
    [self refreshUI];

    [NSThread detachNewThreadSelector:@selector(deviceSignInWorker:)
                             toTarget:self
                           withObject:[NSNumber numberWithInteger:session]];
}

- (void)deviceSignInWorker:(NSNumber *)sessionNum {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSInteger session = [sessionNum integerValue];

    NSString *err = nil;
    ELDeviceCodeInfo *info = [[ELAuthManager sharedManager] requestDeviceCodeWithError:&err];
    if (session != _pollSession) { [pool release]; return; }

    if (!info) {
        [self performSelectorOnMainThread:@selector(onDeviceCodeError:)
                               withObject:(err ? err : @"Failed to get Google device code")
                            waitUntilDone:NO];
        [pool release];
        return;
    }

    [self performSelectorOnMainThread:@selector(onDeviceCodeReady:) withObject:info waitUntilDone:NO];

    NSInteger interval = info.interval;
    if (interval < 5) interval = 5;
    NSTimeInterval deadline = [[NSDate date] timeIntervalSince1970] + info.expiresIn;

    while (session == _pollSession && [[NSDate date] timeIntervalSince1970] < deadline) {
        [NSThread sleepForTimeInterval:(NSTimeInterval)interval];
        if (session != _pollSession) break;

        NSString *pollErr = nil;
        ELAuthPollResult res = [[ELAuthManager sharedManager] pollTokenForDeviceCode:info.deviceCode error:&pollErr];
        if (res == ELAuthPollSuccess) {
            [self performSelectorOnMainThread:@selector(onDeviceSignInSucceeded) withObject:nil waitUntilDone:NO];
            break;
        } else if (res == ELAuthPollSlowDown) {
            interval += 5;
        } else if (res == ELAuthPollDeniedOrExpired) {
            [self performSelectorOnMainThread:@selector(onDeviceCodeError:)
                                   withObject:(pollErr ? pollErr : @"Sign-in expired or cancelled")
                                waitUntilDone:NO];
            break;
        }
    }

    [pool release];
}

- (void)onDeviceCodeReady:(ELDeviceCodeInfo *)info {
    _codeHintLabel.text = [NSString stringWithFormat:@"Open %@\non any phone or computer and enter:",
                           info.verificationURL];
    _codeValueLabel.text = info.userCode;
    _codePollLabel.text = @"Waiting for Google approval...";
}

- (void)onDeviceCodeError:(NSString *)err {
    [_spinner stopAnimating];
    _codePollLabel.text = err;
}

- (void)onDeviceSignInSucceeded {
    [_spinner stopAnimating];
    _codeCard.hidden = YES;
    [self refreshUI];
    [self startLibrarySync];
}

- (void)startLibrarySync {
    if (_syncing) return;
    _syncing = YES;
    [self refreshUI];
    [NSThread detachNewThreadSelector:@selector(syncWorker) toTarget:self withObject:nil];
}

- (void)syncWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *err = nil;
    BOOL ok = [[ELYouTubeClient sharedClient] syncLibraryWithError:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithBool:ok] forKey:@"ok"];
    if (err) [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onSyncDone:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onSyncDone:(NSDictionary *)res {
    _syncing = NO;
    [self refreshUI];
    if (![[res objectForKey:@"ok"] boolValue]) {
        NSString *err = [res objectForKey:@"error"];
        UIAlertView *av = [[[UIAlertView alloc] initWithTitle:@"Sync Error"
                                                      message:(err ? err : @"Could not sync YouTube Music library.")
                                                     delegate:nil
                                            cancelButtonTitle:@"OK"
                                            otherButtonTitles:nil] autorelease];
        [av show];
    }
}

@end
