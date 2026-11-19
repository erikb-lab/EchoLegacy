#import "ELAccountVC.h"
#import "ELAudioEngine.h"
#import "ELAuthManager.h"
#import "ELHTTPClient.h"
#import "ELImageCache.h"
#import "ELTheme.h"
#if EL_FEATURE_OTA_UPDATER
#import "ELUpdater.h"
#endif
#import "ELYouTubeClient.h"

#if EL_FEATURE_LYRICS
static NSString *const kOnlineLyricsDefaultsKey = @"ELOnlineLyricsEnabled";
#endif

@implementation ELAccountVC

- (UIView *)newCardWithFrame:(CGRect)frame {
    UIView *card = [[UIView alloc] initWithFrame:frame];
    card.backgroundColor = [ELTheme surfaceColor];
    card.layer.cornerRadius = 12.0f;
    card.layer.masksToBounds = YES;
    [_scrollView addSubview:card];
    return card;
}

- (UILabel *)newLabelWithFrame:(CGRect)frame font:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines parent:(UIView *)parent {
    UILabel *lbl = [[UILabel alloc] initWithFrame:frame];
    lbl.backgroundColor = [UIColor clearColor];
    lbl.font = font;
    lbl.textColor = color;
    if (lines != 1) lbl.numberOfLines = lines;
    [parent addSubview:lbl];
    return lbl;
}

- (UITextField *)newOAuthFieldWithFrame:(CGRect)frame placeholder:(NSString *)placeholder secure:(BOOL)secure parent:(UIView *)parent {
    UITextField *tf = [[UITextField alloc] initWithFrame:frame];
    tf.backgroundColor = [ELTheme backgroundColor];
    tf.textColor = [ELTheme textPrimaryColor];
    tf.font = [UIFont systemFontOfSize:12.0f];
    tf.placeholder = placeholder;
    tf.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.secureTextEntry = secure;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    [parent addSubview:tf];
    return tf;
}

- (void)addSeparatorAtY:(CGFloat)y toView:(UIView *)parent {
    UIView *div = [[[UIView alloc] initWithFrame:CGRectMake(16.0f, y, 256.0f, 1.0f)] autorelease];
    div.backgroundColor = [ELTheme separatorColor];
    [parent addSubview:div];
}

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

- (void)invalidateCodeMaskTimer {
    [_codeMaskTimer invalidate];
    [_codeMaskTimer release];
    _codeMaskTimer = nil;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self invalidateCodeMaskTimer];
    [_scrollView release]; _scrollView = nil;
    [_statusDot release]; _statusDot = nil;
    [_accountTitleLabel release]; _accountTitleLabel = nil;
    [_accountSubLabel release]; _accountSubLabel = nil;
    [_primaryBtn release]; _primaryBtn = nil;
    [_secondaryBtn release]; _secondaryBtn = nil;
    [_oauthCard release]; _oauthCard = nil;
    [_clientIdField release]; _clientIdField = nil;
    [_clientSecretField release]; _clientSecretField = nil;
    [_saveOAuthBtn release]; _saveOAuthBtn = nil;
    [_codeCard release]; _codeCard = nil;
    [_codeHintLabel release]; _codeHintLabel = nil;
    [_codeValueLabel release]; _codeValueLabel = nil;
    [_codeRevealBtn release]; _codeRevealBtn = nil;
    [_codePollLabel release]; _codePollLabel = nil;
    [_spinner release]; _spinner = nil;
    [_prefsCard release]; _prefsCard = nil;
#if EL_FEATURE_SHAKE_SHUFFLE
    [_shakeSwitch release]; _shakeSwitch = nil;
#endif
#if EL_FEATURE_LYRICS
    [_lyricsSwitch release]; _lyricsSwitch = nil;
#endif
    [_cacheLabel release]; _cacheLabel = nil;
    [_clearCacheBtn release]; _clearCacheBtn = nil;
#if EL_FEATURE_OTA_UPDATER
    [_updateCard release]; _updateCard = nil;
    [_updateStatusLabel release]; _updateStatusLabel = nil;
    [_updateBtn release]; _updateBtn = nil;
#endif
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    _pollSession++;
    [self releaseViewOutlets];
    [_currentUserCode release];
#if EL_FEATURE_OTA_UPDATER
    [_pendingUpdate release];
#endif
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.contentSize = CGSizeMake(320, 560);
    _scrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self.view addSubview:_scrollView];

    /* 1. Google Account Status Card */
    UIView *card = [[self newCardWithFrame:CGRectMake(16, 14, 288, 150)] autorelease];

    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(16, 20, 10, 10)];
    _statusDot.layer.cornerRadius = 5.0f;
    _statusDot.layer.masksToBounds = YES;
    [card addSubview:_statusDot];

    _accountTitleLabel = [self newLabelWithFrame:CGRectMake(34, 13, 238, 24)
                                            font:[UIFont boldSystemFontOfSize:17.0f]
                                           color:[ELTheme textPrimaryColor]
                                           lines:1
                                          parent:card];
    _accountSubLabel = [self newLabelWithFrame:CGRectMake(16, 42, 256, 36)
                                          font:[UIFont systemFontOfSize:12.0f]
                                         color:[ELTheme textSecondaryColor]
                                         lines:2
                                        parent:card];

    _primaryBtn = [[ELTheme pillButtonWithTitle:@"Sign In with Google"
                                          color:[ELTheme accentColor]
                                          frame:CGRectMake(16, 92, 256, 40)] retain];
    [_primaryBtn addTarget:self action:@selector(onPrimaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:_primaryBtn];

    /* Secondary Action Button (Sign Out when signed in, Configure OAuth Client when signed out) */
    _secondaryBtn = [[ELTheme pillButtonWithTitle:@"Configure OAuth Client"
                                            color:[ELTheme surfaceHighlightColor]
                                            frame:CGRectMake(16, 174, 288, 36)] retain];
    [_secondaryBtn addTarget:self action:@selector(onSecondaryTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_secondaryBtn];

    /* User-Supplied OAuth Client ID & Secret Configuration Card (Flaw #3) */
    _oauthCard = [self newCardWithFrame:CGRectMake(16, 218, 288, 162)];
    _oauthCard.hidden = YES;

    UILabel *oaTitle = [[self newLabelWithFrame:CGRectMake(14, 10, 260, 16)
                                           font:[UIFont boldSystemFontOfSize:11.0f]
                                          color:[ELTheme textSecondaryColor]
                                          lines:1
                                         parent:_oauthCard] autorelease];
    oaTitle.text = @"GOOGLE OAUTH CLIENT (TV / DEVICE FLOW)";

    _clientIdField = [self newOAuthFieldWithFrame:CGRectMake(14, 32, 260, 32)
                                      placeholder:@"Client ID (.apps.googleusercontent.com)"
                                           secure:NO
                                           parent:_oauthCard];
    _clientSecretField = [self newOAuthFieldWithFrame:CGRectMake(14, 72, 260, 32)
                                          placeholder:@"Client Secret (optional, Keychain)"
                                               secure:YES
                                               parent:_oauthCard];

    _saveOAuthBtn = [[ELTheme pillButtonWithTitle:@"Save OAuth Credentials"
                                            color:[ELTheme accentColor]
                                            frame:CGRectMake(14, 114, 260, 34)] retain];
    _saveOAuthBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13.0f];
    [_saveOAuthBtn addTarget:self action:@selector(onSaveOAuthTapped) forControlEvents:UIControlEventTouchUpInside];
    [_oauthCard addSubview:_saveOAuthBtn];

    /* Device OAuth Code Card (shown during sign-in, masked by default - Flaw #22) */
    _codeCard = [self newCardWithFrame:CGRectMake(16, 218, 288, 160)];
    _codeCard.hidden = YES;

    _codeHintLabel = [self newLabelWithFrame:CGRectMake(14, 10, 260, 38)
                                        font:[UIFont systemFontOfSize:11.0f]
                                       color:[ELTheme textSecondaryColor]
                                       lines:2
                                      parent:_codeCard];
    _codeHintLabel.textAlignment = UITextAlignmentCenter;

    _codeValueLabel = [self newLabelWithFrame:CGRectMake(14, 54, 260, 44)
                                         font:[UIFont boldSystemFontOfSize:20.0f]
                                        color:[ELTheme textPrimaryColor]
                                        lines:1
                                       parent:_codeCard];
    _codeValueLabel.backgroundColor = [ELTheme backgroundColor];
    _codeValueLabel.layer.cornerRadius = 8.0f;
    _codeValueLabel.layer.masksToBounds = YES;
    _codeValueLabel.textAlignment = UITextAlignmentCenter;

    _codeRevealBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _codeRevealBtn.frame = _codeValueLabel.frame;
    [_codeRevealBtn addTarget:self action:@selector(onCodeRevealTapped) forControlEvents:UIControlEventTouchUpInside];
    [_codeCard addSubview:_codeRevealBtn];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.frame = CGRectMake(22, 114, 20, 20);
    _spinner.hidesWhenStopped = YES;
    [_codeCard addSubview:_spinner];

    _codePollLabel = [self newLabelWithFrame:CGRectMake(48, 110, 226, 30)
                                        font:[UIFont systemFontOfSize:12.0f]
                                       color:[ELTheme textSecondaryColor]
                                       lines:2
                                      parent:_codeCard];

    /* 2. Playback, Privacy & Storage Preferences Card (Flaw #9) */
    _prefsCard = [self newCardWithFrame:CGRectMake(16, 224, 288, 192)];

    UILabel *pTitle = [[self newLabelWithFrame:CGRectMake(16, 12, 256, 18)
                                          font:[UIFont boldSystemFontOfSize:12.0f]
                                         color:[ELTheme textSecondaryColor]
                                         lines:1
                                        parent:_prefsCard] autorelease];
    pTitle.text = @"PLAYBACK, PRIVACY & STORAGE";

    CGFloat py = 38.0f;
#if EL_FEATURE_SHAKE_SHUFFLE
    UILabel *shakeLbl = [[self newLabelWithFrame:CGRectMake(16, py + 2.0f, 165, 24)
                                            font:[UIFont boldSystemFontOfSize:14.0f]
                                           color:[ELTheme textPrimaryColor]
                                           lines:1
                                          parent:_prefsCard] autorelease];
    shakeLbl.text = @"Shake to Shuffle";

    _shakeSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(184, py, 94, 27)];
    _shakeSwitch.on = [[ELAudioEngine sharedEngine] shakeToShuffleEnabled];
    [_shakeSwitch addTarget:self action:@selector(onShakeToggled) forControlEvents:UIControlEventValueChanged];
    [_prefsCard addSubview:_shakeSwitch];

    py += 36.0f;
    [self addSeparatorAtY:py toView:_prefsCard];
    py += 8.0f;
#endif

#if EL_FEATURE_LYRICS
    UILabel *lyricsLbl = [[self newLabelWithFrame:CGRectMake(16, py, 165, 18)
                                             font:[UIFont boldSystemFontOfSize:13.0f]
                                            color:[ELTheme textPrimaryColor]
                                            lines:1
                                           parent:_prefsCard] autorelease];
    lyricsLbl.text = @"Online Lyrics";

    UILabel *lyricsSub = [[self newLabelWithFrame:CGRectMake(16, py + 18.0f, 165, 16)
                                             font:[UIFont systemFontOfSize:10.0f]
                                            color:[ELTheme textSecondaryColor]
                                            lines:1
                                           parent:_prefsCard] autorelease];
    lyricsSub.text = @"Query lrclib.net for track lyrics";

    _lyricsSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(184, py + 4.0f, 94, 27)];
    _lyricsSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:kOnlineLyricsDefaultsKey];
    [_lyricsSwitch addTarget:self action:@selector(onLyricsToggled) forControlEvents:UIControlEventValueChanged];
    [_prefsCard addSubview:_lyricsSwitch];

    py += 46.0f;
    [self addSeparatorAtY:py toView:_prefsCard];
    py += 13.0f;
#endif

    _cacheLabel = [self newLabelWithFrame:CGRectMake(16, py, 152, 34)
                                     font:[UIFont systemFontOfSize:12.0f]
                                    color:[ELTheme textSecondaryColor]
                                    lines:2
                                   parent:_prefsCard];

    _clearCacheBtn = [[ELTheme pillButtonWithTitle:@"Clear Cache"
                                             color:[ELTheme surfaceHighlightColor]
                                             frame:CGRectMake(174, py + 1.0f, 98, 32)] retain];
    _clearCacheBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [_clearCacheBtn addTarget:self action:@selector(onClearCacheTapped) forControlEvents:UIControlEventTouchUpInside];
    [_prefsCard addSubview:_clearCacheBtn];

    _prefsCard.frame = CGRectMake(16, 224, 288, py + 51.0f);

#if EL_FEATURE_OTA_UPDATER
    /* 3. GitHub Updates Card */
    _updateCard = [self newCardWithFrame:CGRectMake(16, 428, 288, 122)];

    UILabel *uTitle = [[self newLabelWithFrame:CGRectMake(16, 12, 256, 18)
                                          font:[UIFont boldSystemFontOfSize:12.0f]
                                         color:[ELTheme textSecondaryColor]
                                         lines:1
                                        parent:_updateCard] autorelease];
    uTitle.text = @"GITHUB UPDATES";

    _updateStatusLabel = [self newLabelWithFrame:CGRectMake(16, 34, 256, 34)
                                            font:[UIFont systemFontOfSize:12.0f]
                                           color:[ELTheme textPrimaryColor]
                                           lines:2
                                          parent:_updateCard];
    _updateStatusLabel.text = [NSString stringWithFormat:@"Installed: %@\nTap below to check GitHub Releases.",
                               [[ELUpdater sharedUpdater] installedVersionLabel]];

    _updateBtn = [[ELTheme pillButtonWithTitle:@"Check for Updates"
                                         color:[ELTheme surfaceHighlightColor]
                                         frame:CGRectMake(16, 74, 256, 36)] retain];
    [_updateBtn addTarget:self action:@selector(onUpdateBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [_updateCard addSubview:_updateBtn];
#endif

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshUI) name:ELAuthStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshUI) name:ELLibraryUpdatedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(maskUserCodeImmediately) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(maskUserCodeImmediately) name:UIApplicationDidEnterBackgroundNotification object:nil];

    [self populateOAuthFields];
    [self refreshUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self populateOAuthFields];
    [self refreshUI];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self maskUserCodeImmediately];
    [_clientIdField resignFirstResponder];
    [_clientSecretField resignFirstResponder];
    [super viewWillDisappear:animated];
}

- (void)populateOAuthFields {
    ELAuthManager *auth = [ELAuthManager sharedManager];
    NSString *cid = [auth clientId];
    _clientIdField.text = ([cid length] > 0) ? cid : @"";
    _clientSecretField.text = ([[auth clientSecret] length] > 0) ? [auth clientSecret] : @"";
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)onSaveOAuthTapped {
    [_clientIdField resignFirstResponder];
    [_clientSecretField resignFirstResponder];
    ELAuthManager *auth = [ELAuthManager sharedManager];
    [auth setClientId:_clientIdField.text];
    [auth setClientSecret:_clientSecretField.text];
    _showingOAuthConfig = NO;
    [self populateOAuthFields];
    [self refreshUI];
    if ([auth hasConfiguredClientId]) {
        [[ELAudioEngine sharedEngine] postToast:@"Saved OAuth Client credentials"];
    } else {
        [[ELAudioEngine sharedEngine] postToast:@"Cleared OAuth Client credentials"];
    }
}

#if EL_FEATURE_SHAKE_SHUFFLE
- (void)onShakeToggled {
    [[ELAudioEngine sharedEngine] setShakeToShuffleEnabled:_shakeSwitch.on];
    [[ELAudioEngine sharedEngine] postToast:(_shakeSwitch.on ? @"Shake to Shuffle: On" : @"Shake to Shuffle: Off")];
}
#endif

#if EL_FEATURE_LYRICS
- (void)onLyricsToggled {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setBool:_lyricsSwitch.on forKey:kOnlineLyricsDefaultsKey];
    [defs synchronize];
    [[ELAudioEngine sharedEngine] postToast:(_lyricsSwitch.on ? @"Online Lyrics: On (lrclib.net)" : @"Online Lyrics: Off (cached only)")];
}
#endif

- (void)onClearCacheTapped {
    unsigned long long freed = [[ELImageCache sharedCache] clearAllCache];
    double mb = (double)freed / (1024.0 * 1024.0);
    [self refreshUI];
    [[ELAudioEngine sharedEngine] postToast:[NSString stringWithFormat:@"Freed %.1f MB cache", mb]];
}

#pragma mark - Device Code Masking (Flaw #22)

- (void)updateCodeLabelText {
    if ([_currentUserCode length] == 0) {
        _codeValueLabel.text = @"----";
        _codeValueLabel.font = [UIFont boldSystemFontOfSize:22.0f];
        return;
    }
    if (_codeRevealed) {
        _codeValueLabel.text = _currentUserCode;
        _codeValueLabel.font = [UIFont boldSystemFontOfSize:24.0f];
    } else {
        _codeValueLabel.text = @"•••• - ••••  (Tap to Reveal)";
        _codeValueLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    }
}

- (void)maskUserCodeImmediately {
    [self invalidateCodeMaskTimer];
    _codeRevealed = NO;
    if (_codeValueLabel) {
        [self updateCodeLabelText];
    }
}

- (void)onCodeRevealTapped {
    if ([_currentUserCode length] == 0) return;
    _codeRevealed = !_codeRevealed;
    [self invalidateCodeMaskTimer];
    if (_codeRevealed) {
        _codeMaskTimer = [[NSTimer scheduledTimerWithTimeInterval:15.0
                                                           target:self
                                                         selector:@selector(maskUserCodeImmediately)
                                                         userInfo:nil
                                                          repeats:NO] retain];
    }
    [self updateCodeLabelText];
}

#if EL_FEATURE_OTA_UPDATER
#pragma mark - GitHub Updates

- (void)onUpdateBtnTapped {
    if (_checkingUpdate || _installingUpdate) return;
    if (_relaunchReady) {
        exit(0);
        return;
    }
    if (_pendingUpdate && _pendingUpdate.updateAvailable) {
        [self startInstallPendingUpdate];
        return;
    }
    _checkingUpdate = YES;
    _updateBtn.enabled = NO;
    [_updateBtn setTitle:@"Checking GitHub..." forState:UIControlStateNormal];
    _updateStatusLabel.text = @"Connecting to api.github.com via TLS 1.2...";
    [NSThread detachNewThreadSelector:@selector(checkUpdateWorker) toTarget:self withObject:nil];
}

- (void)checkUpdateWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *err = nil;
    ELUpdateInfo *info = [[ELUpdater sharedUpdater] checkForUpdateWithError:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    if (info) [res setObject:info forKey:@"info"];
    if (err)  [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onCheckUpdateDone:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onCheckUpdateDone:(NSDictionary *)res {
    _checkingUpdate = NO;
    _updateBtn.enabled = YES;
    ELUpdateInfo *info = [res objectForKey:@"info"];
    NSString *err = [res objectForKey:@"error"];
    if (!info) {
        [_updateBtn setTitle:@"Check for Updates" forState:UIControlStateNormal];
        _updateStatusLabel.text = err ? err : @"Could not check GitHub.";
        return;
    }

    [_pendingUpdate release];
    _pendingUpdate = [info retain];
    if (info.updateAvailable) {
        NSString *sz = (info.binarySize > 0)
            ? [NSString stringWithFormat:@" (%.0f KB)", (double)info.binarySize / 1024.0]
            : @"";
        _updateStatusLabel.text = [NSString stringWithFormat:@"New build ready: %@%@", info.releaseTitle, sz];
        _updateBtn.backgroundColor = [ELTheme accentColor];
        [_updateBtn setTitle:@"Install Update from GitHub" forState:UIControlStateNormal];
    } else {
        _updateStatusLabel.text = [NSString stringWithFormat:@"Up to date (%@)", info.releaseTitle];
        _updateBtn.backgroundColor = [ELTheme surfaceHighlightColor];
        [_updateBtn setTitle:@"Re-check GitHub" forState:UIControlStateNormal];
    }
}

- (void)startInstallPendingUpdate {
    if (!_pendingUpdate || _installingUpdate) return;
    _installingUpdate = YES;
    _updateBtn.enabled = NO;
    [_updateBtn setTitle:@"Downloading Update..." forState:UIControlStateNormal];
    _updateStatusLabel.text = @"Downloading verified armv6 build from GitHub...";
    [NSThread detachNewThreadSelector:@selector(installUpdateWorker:) toTarget:self withObject:_pendingUpdate];
}

- (void)installUpdateWorker:(ELUpdateInfo *)info {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *err = nil;
    NSString *ipaPath = nil;
    BOOL ok = [[ELUpdater sharedUpdater] installUpdate:info savedIPAPath:&ipaPath error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithBool:ok] forKey:@"ok"];
    if (ipaPath) [res setObject:ipaPath forKey:@"ipaPath"];
    if (err)     [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onInstallUpdateDone:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onInstallUpdateDone:(NSDictionary *)res {
    _installingUpdate = NO;
    _updateBtn.enabled = YES;
    BOOL ok = [[res objectForKey:@"ok"] boolValue];
    NSString *ipaPath = [res objectForKey:@"ipaPath"];
    NSString *err = [res objectForKey:@"error"];
    if (ok && !ipaPath) {
        _relaunchReady = YES;
        [_pendingUpdate release];
        _pendingUpdate = nil;
        _updateStatusLabel.text = [NSString stringWithFormat:@"Updated to %@!\nTap below to close and relaunch.",
                                   [[ELUpdater sharedUpdater] installedVersionLabel]];
        _updateBtn.backgroundColor = [ELTheme successColor];
        [_updateBtn setTitle:@"Close App to Relaunch" forState:UIControlStateNormal];
        UIAlertView *av = [[[UIAlertView alloc] initWithTitle:@"Update Installed"
                                                      message:@"EchoLegacy has been updated from GitHub. Tap Relaunch to close the app, then tap the EchoLegacy icon."
                                                     delegate:self
                                            cancelButtonTitle:@"Later"
                                            otherButtonTitles:@"Relaunch", nil] autorelease];
        [av show];
    } else if (ok && ipaPath) {
        _updateStatusLabel.text = [NSString stringWithFormat:@"Verified IPA saved to %@", [ipaPath lastPathComponent]];
        [_updateBtn setTitle:@"Check for Updates" forState:UIControlStateNormal];
    } else {
        _updateStatusLabel.text = err ? err : @"Update failed.";
        [_updateBtn setTitle:@"Retry Update" forState:UIControlStateNormal];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    (void)alertView;
    if (buttonIndex == 1 && _relaunchReady) {
        exit(0);
    }
}
#endif

#pragma mark - UI Layout & Account Actions

- (void)refreshUI {
    ELAuthManager *auth = [ELAuthManager sharedManager];
    ELYouTubeClient *yt = [ELYouTubeClient sharedClient];

#if EL_FEATURE_SHAKE_SHUFFLE
    _shakeSwitch.on = [[ELAudioEngine sharedEngine] shakeToShuffleEnabled];
#endif
#if EL_FEATURE_LYRICS
    _lyricsSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:kOnlineLyricsDefaultsKey];
#endif
    double cacheMB = (double)[[ELImageCache sharedCache] diskCacheBytes] / (1024.0 * 1024.0);
    _cacheLabel.text = [NSString stringWithFormat:@"Album Art Cache\n%.1f MB on disk", cacheMB];

    CGFloat nextY = 222.0f;
    if ([auth isSignedIn]) {
        _statusDot.backgroundColor = [ELTheme successColor];
        NSString *name = [auth accountName];
        _accountTitleLabel.text = ([name length] > 0) ? name : @"Google Account";
        NSUInteger plCount = [[yt cachedPlaylists] count];
        NSUInteger songCount = [[yt cachedLikedSongs] count];
        _accountSubLabel.text = [NSString stringWithFormat:@"Signed in to YouTube Music (Read-Only)\n%lu playlists  •  %lu liked songs synced",
                                 (unsigned long)plCount, (unsigned long)songCount];
        [_primaryBtn setTitle:(_syncing ? @"Syncing Library..." : @"Sync Library Now") forState:UIControlStateNormal];
        _primaryBtn.enabled = !_syncing;
        [_secondaryBtn setTitle:@"Sign Out" forState:UIControlStateNormal];
        _secondaryBtn.hidden = NO;
        _showingOAuthConfig = NO;
        _oauthCard.hidden = YES;
        _codeCard.hidden = YES;
        [_spinner stopAnimating];
        [self maskUserCodeImmediately];
    } else {
        BOOL hasCID = [auth hasConfiguredClientId];
        _statusDot.backgroundColor = hasCID ? [ELTheme accentColor] : [ELTheme textSecondaryColor];
        _accountTitleLabel.text = @"Not Signed In";
        if (hasCID) {
            _accountSubLabel.text = @"OAuth Client ID configured. Sign in with Google to sync your YouTube Music playlists and liked songs.";
        } else {
            _accountSubLabel.text = @"Configure your Google OAuth Client ID below to sign in and sync your YouTube Music library.";
        }

        if (!_codeCard.hidden) {
            [_primaryBtn setTitle:@"Cancel Sign-In" forState:UIControlStateNormal];
        } else {
            [_primaryBtn setTitle:@"Sign In with Google" forState:UIControlStateNormal];
        }
        _primaryBtn.enabled = YES;

        [_secondaryBtn setTitle:(_showingOAuthConfig ? @"Hide OAuth Client Settings" : @"Configure OAuth Client")
                       forState:UIControlStateNormal];
        _secondaryBtn.hidden = NO;
        _oauthCard.hidden = !_showingOAuthConfig;

        if (!_oauthCard.hidden) {
            _oauthCard.frame = CGRectMake(16, nextY, 288, 162);
            nextY += 172.0f;
        }
        if (!_codeCard.hidden) {
            _codeCard.frame = CGRectMake(16, nextY, 288, 160);
            nextY += 170.0f;
        }
    }

    CGFloat prefsH = _prefsCard.frame.size.height;
    _prefsCard.frame = CGRectMake(16, nextY, 288, prefsH);
    CGFloat bottomY = nextY + prefsH + 12.0f;
#if EL_FEATURE_OTA_UPDATER
    _updateCard.frame = CGRectMake(16, bottomY, 288, 122);
    bottomY += 122.0f;
#endif
    _scrollView.contentSize = CGSizeMake(320, bottomY + 66.0f);
}

- (void)onPrimaryTapped {
    [_clientIdField resignFirstResponder];
    [_clientSecretField resignFirstResponder];

    ELAuthManager *auth = [ELAuthManager sharedManager];
    if ([auth isSignedIn]) {
        [self startLibrarySync];
        return;
    }
    if (!_codeCard.hidden) {
        /* Cancel active device sign-in polling */
        _pollSession++;
        [_spinner stopAnimating];
        [_currentUserCode release];
        _currentUserCode = nil;
        [self maskUserCodeImmediately];
        _codeCard.hidden = YES;
        [self refreshUI];
        return;
    }
    if (![auth hasConfiguredClientId]) {
        _showingOAuthConfig = YES;
        [self populateOAuthFields];
        [self refreshUI];
        [[ELAudioEngine sharedEngine] postToast:@"Enter your Google OAuth Client ID first"];
        return;
    }
    [self startGoogleDeviceSignIn];
}

- (void)onSecondaryTapped {
    [_clientIdField resignFirstResponder];
    [_clientSecretField resignFirstResponder];

    if ([[ELAuthManager sharedManager] isSignedIn]) {
        _pollSession++;
        [_currentUserCode release];
        _currentUserCode = nil;
        [self maskUserCodeImmediately];
        _codeCard.hidden = YES;
        [[ELAuthManager sharedManager] signOut];
        [[ELYouTubeClient sharedClient] clearLibraryCache];
        [self refreshUI];
        [[ELAudioEngine sharedEngine] postToast:@"Signed out of Google Account"];
    } else {
        _showingOAuthConfig = !_showingOAuthConfig;
        if (_showingOAuthConfig) {
            [self populateOAuthFields];
        }
        [self refreshUI];
    }
}

- (void)startGoogleDeviceSignIn {
    _pollSession++;
    NSInteger session = _pollSession;

    [_currentUserCode release];
    _currentUserCode = nil;
    [self maskUserCodeImmediately];

    _showingOAuthConfig = NO;
    _oauthCard.hidden = YES;
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
    if (interval > 60) interval = 60;

    NSInteger maxWait = info.expiresIn;
    if (maxWait < 60) maxWait = 60;
    if (maxWait > 900) maxWait = 900;

    NSTimeInterval deadline = [ELHTTPClient syncedCurrentTime] + (NSTimeInterval)maxWait;
    BOOL finished = NO;

    while (session == _pollSession && [ELHTTPClient syncedCurrentTime] < deadline) {
        [NSThread sleepForTimeInterval:(NSTimeInterval)interval];
        if (session != _pollSession) { finished = YES; break; }

        NSString *pollErr = nil;
        ELAuthPollResult res = [[ELAuthManager sharedManager] pollTokenForDeviceCode:info.deviceCode error:&pollErr];
        if (res == ELAuthPollSuccess) {
            finished = YES;
            [self performSelectorOnMainThread:@selector(onDeviceSignInSucceeded) withObject:nil waitUntilDone:NO];
            break;
        } else if (res == ELAuthPollSlowDown) {
            interval += 5;
            if (interval > 60) interval = 60;
        } else if (res == ELAuthPollDeniedOrExpired) {
            finished = YES;
            [self performSelectorOnMainThread:@selector(onDeviceCodeError:)
                                   withObject:(pollErr ? pollErr : @"Sign-in expired or cancelled")
                                waitUntilDone:NO];
            break;
        }
    }

    if (!finished && session == _pollSession) {
        [self performSelectorOnMainThread:@selector(onDeviceCodeError:)
                               withObject:@"Device code expired (15 min limit)."
                            waitUntilDone:NO];
    }

    [pool release];
}

- (void)onDeviceCodeReady:(ELDeviceCodeInfo *)info {
    [_currentUserCode release];
    _currentUserCode = [info.userCode copy];
    _codeRevealed = NO;
    [self invalidateCodeMaskTimer];
    _codeHintLabel.text = [NSString stringWithFormat:@"Open %@\non any phone/computer, then tap below to reveal code:",
                           info.verificationURL];
    [self updateCodeLabelText];
    _codePollLabel.text = @"Waiting for Google approval...";
}

- (void)onDeviceCodeError:(NSString *)err {
    [_spinner stopAnimating];
    [_currentUserCode release];
    _currentUserCode = nil;
    [self maskUserCodeImmediately];
    _codePollLabel.text = err;
}

- (void)onDeviceSignInSucceeded {
    [_spinner stopAnimating];
    [_currentUserCode release];
    _currentUserCode = nil;
    [self maskUserCodeImmediately];
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
