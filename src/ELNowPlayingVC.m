#import "ELNowPlayingVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#import "ELImageCache.h"
#import "ELQueueVC.h"
#import "ELTheme.h"
#import "ELYouTubeClient.h"

@implementation ELNowPlayingVC

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
}

- (void)viewWillDisappear:(BOOL)animated {
    [self resignFirstResponder];
    [super viewWillDisappear:animated];
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    (void)event;
    if (motion == UIEventSubtypeMotionShake) {
        [[ELAudioEngine sharedEngine] handleShakeToShuffle];
    }
}

- (void)applyBackdropColor:(UIColor *)dominant animated:(BOOL)animated {
    if (!_backdropGradient || !_artFadeLayer) return;
    if (!dominant) dominant = [ELTheme dominantBackdropColorFromImage:nil];
    UIColor *darker = [ELTheme darkerShadeOfColor:dominant factor:0.54f];
    UIColor *clearDom = [ELTheme colorWithColor:dominant alpha:0.0f];
    UIColor *midDom1 = [ELTheme colorWithColor:dominant alpha:0.38f];
    UIColor *midDom2 = [ELTheme colorWithColor:dominant alpha:0.86f];

    self.view.backgroundColor = dominant;

    [CATransaction begin];
    if (animated) {
        [CATransaction setAnimationDuration:0.32];
    } else {
        [CATransaction setDisableActions:YES];
    }
    _backdropGradient.colors = [NSArray arrayWithObjects:
                                (id)[dominant CGColor],
                                (id)[dominant CGColor],
                                (id)[darker CGColor],
                                nil];
    _artFadeLayer.colors = [NSArray arrayWithObjects:
                            (id)[clearDom CGColor],
                            (id)[midDom1 CGColor],
                            (id)[midDom2 CGColor],
                            (id)[dominant CGColor],
                            nil];
    [CATransaction commit];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *pillDark = [UIColor colorWithWhite:0.0f alpha:0.40f];
    UIColor *pillDarkHi = [UIColor colorWithWhite:0.0f alpha:0.62f];
    UIColor *pillLight = [UIColor colorWithWhite:1.0f alpha:0.18f];
    UIColor *pillLightHi = [UIColor colorWithWhite:1.0f alpha:0.30f];
    UIColor *secondaryWhite = [UIColor colorWithWhite:1.0f alpha:0.74f];

    /* Dynamic dominant-color full-screen vertical gradient backdrop */
    _backdropGradient = [[CAGradientLayer layer] retain];
    _backdropGradient.frame = CGRectMake(0.0f, 0.0f, 320.0f, 460.0f);
    _backdropGradient.locations = [NSArray arrayWithObjects:
                                   [NSNumber numberWithFloat:0.0f],
                                   [NSNumber numberWithFloat:0.58f],
                                   [NSNumber numberWithFloat:1.0f],
                                   nil];
    [self.view.layer insertSublayer:_backdropGradient atIndex:0];

    /* Full-bleed album art at top (zero dynamic shadowOpacity / zero offscreen cornerRadius FBO) */
    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 268.0f)];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.backgroundColor = [ELTheme surfaceColor];
    _artView.image = [ELTheme placeholderArtImage];
    [self.view addSubview:_artView];

    /* Subtle top scrim so translucent circular top pills stay readable over bright covers */
    _topScrimLayer = [[CAGradientLayer layer] retain];
    _topScrimLayer.frame = CGRectMake(0.0f, 0.0f, 320.0f, 60.0f);
    _topScrimLayer.colors = [NSArray arrayWithObjects:
                             (id)[[UIColor colorWithWhite:0.0f alpha:0.46f] CGColor],
                             (id)[[UIColor colorWithWhite:0.0f alpha:0.0f] CGColor],
                             nil];
    [_artView.layer addSublayer:_topScrimLayer];

    /* Smooth bottom art fade seamlessly melting into dominant backdrop */
    _artFadeLayer = [[CAGradientLayer layer] retain];
    _artFadeLayer.frame = CGRectMake(0.0f, 148.0f, 320.0f, 120.0f);
    _artFadeLayer.locations = [NSArray arrayWithObjects:
                               [NSNumber numberWithFloat:0.0f],
                               [NSNumber numberWithFloat:0.40f],
                               [NSNumber numberWithFloat:0.78f],
                               [NSNumber numberWithFloat:1.0f],
                               nil];
    [_artView.layer addSublayer:_artFadeLayer];

    [self applyBackdropColor:[ELTheme dominantBackdropColorFromImage:nil] animated:NO];

    /* Top bar translucent circular pills */
    UIImage *topCircleBg = [ELTheme circlePillImageWithSize:34.0f color:pillDark];
    UIImage *topCircleHi = [ELTheme circlePillImageWithSize:34.0f color:pillDarkHi];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(12.0f, 10.0f, 34.0f, 34.0f);
    [closeBtn setBackgroundImage:topCircleBg forState:UIControlStateNormal];
    [closeBtn setBackgroundImage:topCircleHi forState:UIControlStateHighlighted];
    [closeBtn setImage:[ELTheme iconCloseSize:20.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:closeBtn];

    UIImageView *sourcePillBg = [[[UIImageView alloc] initWithFrame:CGRectMake(94.0f, 16.0f, 132.0f, 22.0f)] autorelease];
    sourcePillBg.image = [ELTheme stretchablePillImageWithHeight:22.0f color:pillDark];
    [self.view addSubview:sourcePillBg];

    _sourceBadge = [[UILabel alloc] initWithFrame:sourcePillBg.frame];
    _sourceBadge.backgroundColor = [UIColor clearColor];
    _sourceBadge.font = [UIFont boldSystemFontOfSize:10.0f];
    _sourceBadge.textAlignment = UITextAlignmentCenter;
    _sourceBadge.textColor = secondaryWhite;
    [self.view addSubview:_sourceBadge];

    _queueBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _queueBtn.frame = CGRectMake(234.0f, 10.0f, 34.0f, 34.0f);
    [_queueBtn setBackgroundImage:topCircleBg forState:UIControlStateNormal];
    [_queueBtn setBackgroundImage:topCircleHi forState:UIControlStateHighlighted];
    [_queueBtn setImage:[ELTheme iconQueueSize:18.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_queueBtn addTarget:self action:@selector(onQueueTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_queueBtn];

    _downloadBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _downloadBtn.frame = CGRectMake(274.0f, 10.0f, 34.0f, 34.0f);
    [_downloadBtn setBackgroundImage:topCircleBg forState:UIControlStateNormal];
    [_downloadBtn setBackgroundImage:topCircleHi forState:UIControlStateHighlighted];
    _downloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.0f];
    [_downloadBtn addTarget:self action:@selector(onDownloadTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_downloadBtn];

    /* Left-aligned bold track title & artist + right-side circular Heart button */
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 268.0f, 232.0f, 24.0f)];
    _titleLabel.backgroundColor = [UIColor clearColor];
    _titleLabel.font = [UIFont boldSystemFontOfSize:18.0f];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.textAlignment = UITextAlignmentLeft;
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.view addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 294.0f, 232.0f, 19.0f)];
    _artistLabel.backgroundColor = [UIColor clearColor];
    _artistLabel.font = [UIFont systemFontOfSize:14.0f];
    _artistLabel.textColor = secondaryWhite;
    _artistLabel.textAlignment = UITextAlignmentLeft;
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    [self.view addSubview:_artistLabel];

    _likeBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _likeBtn.frame = CGRectMake(262.0f, 272.0f, 38.0f, 38.0f);
    [_likeBtn addTarget:self action:@selector(onLikeTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_likeBtn];

    /* Sleek rounded scrubber */
    _scrubber = [[UISlider alloc] initWithFrame:CGRectMake(20.0f, 326.0f, 280.0f, 26.0f)];
    _scrubber.minimumValue = 0.0f;
    _scrubber.maximumValue = 1.0f;
    [_scrubber setMinimumTrackImage:[ELTheme sliderTrackImageWithColor:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_scrubber setMaximumTrackImage:[ELTheme sliderTrackImageWithColor:[UIColor colorWithWhite:1.0f alpha:0.26f]] forState:UIControlStateNormal];
    [_scrubber setThumbImage:[ELTheme sliderThumbImage] forState:UIControlStateNormal];
    [_scrubber addTarget:self action:@selector(onScrubStart) forControlEvents:UIControlEventTouchDown];
    [_scrubber addTarget:self action:@selector(onScrubChanged) forControlEvents:UIControlEventValueChanged];
    [_scrubber addTarget:self action:@selector(onScrubEnd) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:_scrubber];

    _elapsedLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0f, 354.0f, 72.0f, 15.0f)];
    _elapsedLabel.backgroundColor = [UIColor clearColor];
    _elapsedLabel.font = [UIFont systemFontOfSize:11.0f];
    _elapsedLabel.textColor = secondaryWhite;
    _elapsedLabel.text = @"0:00";
    [self.view addSubview:_elapsedLabel];

    _durationLabel = [[UILabel alloc] initWithFrame:CGRectMake(228.0f, 354.0f, 72.0f, 15.0f)];
    _durationLabel.backgroundColor = [UIColor clearColor];
    _durationLabel.font = [UIFont systemFontOfSize:11.0f];
    _durationLabel.textColor = secondaryWhite;
    _durationLabel.textAlignment = UITextAlignmentRight;
    _durationLabel.text = @"0:00";
    [self.view addSubview:_durationLabel];

    /* Transport row: Shuffle | Prev | Play/Pause | Next | Repeat */
    UIImage *dotImg = [ELTheme circlePillImageWithSize:4.0f color:[UIColor whiteColor]];

    _shuffleBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _shuffleBtn.frame = CGRectMake(14.0f, 392.0f, 40.0f, 44.0f);
    [_shuffleBtn addTarget:self action:@selector(onShuffle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_shuffleBtn];

    _shuffleDot = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 37.0f, 4.0f, 4.0f)];
    _shuffleDot.image = dotImg;
    _shuffleDot.hidden = YES;
    [_shuffleBtn addSubview:_shuffleDot];

    _prevBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _prevBtn.frame = CGRectMake(64.0f, 389.0f, 48.0f, 50.0f);
    [_prevBtn setImage:[ELTheme iconPrevSize:30.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_prevBtn addTarget:self action:@selector(onPrev) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_prevBtn];

    _playPauseBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _playPauseBtn.frame = CGRectMake(128.0f, 382.0f, 64.0f, 64.0f);
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:64.0f color:pillLight] forState:UIControlStateNormal];
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:64.0f color:pillLightHi] forState:UIControlStateHighlighted];
    [_playPauseBtn addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playPauseBtn];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.center = _playPauseBtn.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _nextBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _nextBtn.frame = CGRectMake(208.0f, 389.0f, 48.0f, 50.0f);
    [_nextBtn setImage:[ELTheme iconNextSize:30.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_nextBtn addTarget:self action:@selector(onNext) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextBtn];

    _repeatBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _repeatBtn.frame = CGRectMake(266.0f, 392.0f, 40.0f, 44.0f);
    [_repeatBtn addTarget:self action:@selector(onRepeat) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_repeatBtn];

    _repeatDot = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 37.0f, 4.0f, 4.0f)];
    _repeatDot.image = dotImg;
    _repeatDot.hidden = YES;
    [_repeatBtn addSubview:_repeatDot];

    UIImageView *repBadgeBg = [[[UIImageView alloc] initWithFrame:CGRectMake(23.0f, 4.0f, 14.0f, 14.0f)] autorelease];
    repBadgeBg.image = [ELTheme circlePillImageWithSize:14.0f color:[ELTheme accentColor]];
    repBadgeBg.tag = 901;
    repBadgeBg.hidden = YES;
    [_repeatBtn addSubview:repBadgeBg];

    _repeatOneBadge = [[UILabel alloc] initWithFrame:repBadgeBg.frame];
    _repeatOneBadge.backgroundColor = [UIColor clearColor];
    _repeatOneBadge.font = [UIFont boldSystemFontOfSize:9.0f];
    _repeatOneBadge.textColor = [UIColor whiteColor];
    _repeatOneBadge.textAlignment = UITextAlignmentCenter;
    _repeatOneBadge.text = @"1";
    _repeatOneBadge.hidden = YES;
    [_repeatBtn addSubview:_repeatOneBadge];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshAll) name:ELPlayerStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshProgress) name:ELPlayerProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshDownloadBtn) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshDownloadBtn) name:ELDownloadProgressNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onLibraryUpdated) name:ELLibraryUpdatedNotification object:nil];

    [self refreshAll];
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_backdropGradient release]; _backdropGradient = nil;
    [_topScrimLayer release]; _topScrimLayer = nil;
    [_artFadeLayer release]; _artFadeLayer = nil;
    [_artView release]; _artView = nil;
    [_sourceBadge release]; _sourceBadge = nil;
    [_titleLabel release]; _titleLabel = nil;
    [_artistLabel release]; _artistLabel = nil;
    [_likeBtn release]; _likeBtn = nil;
    [_scrubber release]; _scrubber = nil;
    [_elapsedLabel release]; _elapsedLabel = nil;
    [_durationLabel release]; _durationLabel = nil;
    [_shuffleBtn release]; _shuffleBtn = nil;
    [_shuffleDot release]; _shuffleDot = nil;
    [_prevBtn release]; _prevBtn = nil;
    [_playPauseBtn release]; _playPauseBtn = nil;
    [_nextBtn release]; _nextBtn = nil;
    [_repeatBtn release]; _repeatBtn = nil;
    [_repeatDot release]; _repeatDot = nil;
    [_repeatOneBadge release]; _repeatOneBadge = nil;
    [_queueBtn release]; _queueBtn = nil;
    [_downloadBtn release]; _downloadBtn = nil;
    [_spinner release]; _spinner = nil;
    [_loadedArtKey release]; _loadedArtKey = nil;
    [_loadedArtURL release]; _loadedArtURL = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_inFlightLikeVideoId release];
    [_currentVideoId release];
    [super dealloc];
}

- (void)onClose     { [self dismissModalViewControllerAnimated:YES]; }
- (void)onPlayPause { [[ELAudioEngine sharedEngine] togglePlayPause]; }
- (void)onPrev      { [[ELAudioEngine sharedEngine] playPrevious]; }
- (void)onNext      { [[ELAudioEngine sharedEngine] playNext]; }
- (void)onShuffle   { [[ELAudioEngine sharedEngine] toggleShuffle]; }
- (void)onRepeat    { [[ELAudioEngine sharedEngine] cycleRepeatMode]; }

- (void)onQueueTapped {
    ELQueueVC *qvc = [[[ELQueueVC alloc] init] autorelease];
    [self presentModalViewController:qvc animated:YES];
}

- (void)onScrubStart   { _isScrubbing = YES; }
- (void)onScrubChanged {
    double dur = [[ELAudioEngine sharedEngine] duration];
    _elapsedLabel.text = [ELTrack formatSeconds:_scrubber.value * dur];
}
- (void)onScrubEnd {
    _isScrubbing = NO;
    double dur = [[ELAudioEngine sharedEngine] duration];
    if (dur > 0.0) {
        [[ELAudioEngine sharedEngine] seekToSeconds:_scrubber.value * dur];
    }
}

#pragma mark - Like / Unlike Flow

- (void)updateLikeButtonVisual {
    static UIColor *likedBg = nil;
    static UIColor *likedBgHi = nil;
    static UIColor *unlikedBg = nil;
    static UIColor *unlikedBgHi = nil;
    if (!likedBg) {
        likedBg = [[ELTheme colorWithColor:[ELTheme accentColor] alpha:0.26f] retain];
        likedBgHi = [[ELTheme colorWithColor:[ELTheme accentColor] alpha:0.42f] retain];
        unlikedBg = [[UIColor colorWithWhite:1.0f alpha:0.16f] retain];
        unlikedBgHi = [[UIColor colorWithWhite:1.0f alpha:0.28f] retain];
    }
    if (_isLiked) {
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:38.0f color:likedBg] forState:UIControlStateNormal];
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:38.0f color:likedBgHi] forState:UIControlStateHighlighted];
        [_likeBtn setImage:[ELTheme iconHeartFilledSize:20.0f color:[ELTheme accentColor]] forState:UIControlStateNormal];
    } else {
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:38.0f color:unlikedBg] forState:UIControlStateNormal];
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:38.0f color:unlikedBgHi] forState:UIControlStateHighlighted];
        [_likeBtn setImage:[ELTheme iconHeartOutlineSize:20.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    }
}

- (void)refreshLikeState {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track || [track.videoId length] == 0) {
        _isLiked = NO;
        [self updateLikeButtonVisual];
        return;
    }
    if (_inFlightLikeVideoId && [_inFlightLikeVideoId isEqualToString:track.videoId]) {
        /* Preserve optimistic state while this track's Like POST is in flight */
        [self updateLikeButtonVisual];
        return;
    }
    _isLiked = [[ELYouTubeClient sharedClient] isTrackLiked:track.videoId];
    [self updateLikeButtonVisual];
}

- (void)onLibraryUpdated {
    [self refreshLikeState];
}

- (void)onLikeTapped {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track || [track.videoId length] == 0) return;

    if (_inFlightLikeVideoId && [_inFlightLikeVideoId isEqualToString:track.videoId]) {
        return;
    }

    BOOL prevLiked = _isLiked;
    BOOL targetLiked = !prevLiked;

    /* Optimistic UI flip + toast immediately */
    _isLiked = targetLiked;
    _likeRequestGen++;
    [_inFlightLikeVideoId release];
    _inFlightLikeVideoId = [track.videoId copy];
    [self updateLikeButtonVisual];
    [[ELAudioEngine sharedEngine] postToast:(targetLiked ? @"Liked" : @"Removed from Liked")];

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          track, @"track",
                          [NSNumber numberWithBool:targetLiked], @"targetLiked",
                          [NSNumber numberWithBool:prevLiked], @"prevLiked",
                          [NSNumber numberWithInteger:_likeRequestGen], @"gen",
                          nil];
    [NSThread detachNewThreadSelector:@selector(likeWorker:) toTarget:self withObject:args];
}

- (void)likeWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ELTrack *track = [args objectForKey:@"track"];
    BOOL targetLiked = [[args objectForKey:@"targetLiked"] boolValue];
    NSString *err = nil;
    BOOL ok = [[ELYouTubeClient sharedClient] setLiked:targetLiked forTrack:track error:&err];

    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithBool:ok], @"ok",
                                [args objectForKey:@"prevLiked"], @"prevLiked",
                                [args objectForKey:@"gen"], @"gen",
                                track.videoId ? track.videoId : @"", @"videoId",
                                nil];
    if (err) [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onLikeFinished:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onLikeFinished:(NSDictionary *)res {
    BOOL ok = [[res objectForKey:@"ok"] boolValue];
    BOOL prevLiked = [[res objectForKey:@"prevLiked"] boolValue];
    NSInteger gen = [[res objectForKey:@"gen"] integerValue];
    NSString *vid = [res objectForKey:@"videoId"];
    NSString *err = [res objectForKey:@"error"];

    if (gen == _likeRequestGen && _inFlightLikeVideoId && [_inFlightLikeVideoId isEqualToString:vid]) {
        [_inFlightLikeVideoId release];
        _inFlightLikeVideoId = nil;
    }

    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    if (!ok) {
        if (cur && [cur.videoId isEqualToString:vid]) {
            _isLiked = prevLiked;
            [self updateLikeButtonVisual];
        }
        [[ELAudioEngine sharedEngine] postToast:(err ? err : @"Could not update Like")];
    } else {
        [self refreshLikeState];
    }
}

#pragma mark - Downloads & Refresh

- (void)onDownloadTapped {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if ([dm isDownloaded:track.videoId]) return;
    if ([dm isDownloading:track.videoId] || [dm isQueued:track.videoId]) {
        [dm cancelDownloadForVideoId:track.videoId];
    } else {
        [dm downloadTrack:track];
    }
    [self refreshDownloadBtn];
}

- (void)refreshDownloadBtn {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if ([dm isDownloaded:track.videoId]) {
        [_downloadBtn setTitle:nil forState:UIControlStateNormal];
        [_downloadBtn setImage:[ELTheme iconCheckSize:18.0f color:[ELTheme successColor]] forState:UIControlStateNormal];
    } else if ([dm isDownloading:track.videoId]) {
        int pct = (int)([dm progressForVideoId:track.videoId] * 100.0f);
        [_downloadBtn setImage:nil forState:UIControlStateNormal];
        [_downloadBtn setTitle:[NSString stringWithFormat:@"%d%%", pct] forState:UIControlStateNormal];
        [_downloadBtn setTitleColor:[ELTheme accentColor] forState:UIControlStateNormal];
    } else if ([dm isQueued:track.videoId]) {
        [_downloadBtn setImage:nil forState:UIControlStateNormal];
        [_downloadBtn setTitle:@"•••" forState:UIControlStateNormal];
        [_downloadBtn setTitleColor:[UIColor colorWithWhite:1.0f alpha:0.75f] forState:UIControlStateNormal];
    } else {
        [_downloadBtn setTitle:nil forState:UIControlStateNormal];
        [_downloadBtn setImage:[ELTheme iconDownloadSize:18.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    }
}

- (void)refreshProgress {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    double dur = [eng duration];
    double cur = [eng currentTime];
    _durationLabel.text = [ELTrack formatSeconds:dur];
    if (!_isScrubbing) {
        _elapsedLabel.text = [ELTrack formatSeconds:cur];
        _scrubber.value = (dur > 0.0) ? (float)(cur / dur) : 0.0f;
    }
}

- (void)setArtworkImage:(UIImage *)img forKey:(NSString *)artKey animated:(BOOL)animated {
    if (!img) img = [ELTheme placeholderArtImage];
    _artView.image = img;
    [_loadedArtKey release];
    _loadedArtKey = [artKey copy];
    [self applyBackdropColor:[ELTheme dominantBackdropColorFromImage:img] animated:animated];
}

- (void)refreshAll {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELTrack *track = [eng currentTrack];

    /* Update Shuffle & Repeat visual state */
    static UIColor *dimWhite = nil;
    if (!dimWhite) dimWhite = [[UIColor colorWithWhite:1.0f alpha:0.46f] retain];
    static UIColor *streamBadgeColor = nil;
    if (!streamBadgeColor) streamBadgeColor = [[UIColor colorWithWhite:1.0f alpha:0.86f] retain];
    UIColor *shufCol = eng.shuffleEnabled ? [UIColor whiteColor] : dimWhite;
    [_shuffleBtn setImage:[ELTheme iconShuffleSize:22.0f color:shufCol] forState:UIControlStateNormal];
    _shuffleDot.hidden = !eng.shuffleEnabled;

    BOOL repActive = (eng.repeatMode != ELRepeatModeOff);
    UIColor *repCol = repActive ? [UIColor whiteColor] : dimWhite;
    [_repeatBtn setImage:[ELTheme iconRepeatSize:22.0f color:repCol] forState:UIControlStateNormal];
    _repeatDot.hidden = !repActive;
    BOOL repOne = (eng.repeatMode == ELRepeatModeOne);
    _repeatOneBadge.hidden = !repOne;
    UIView *repBadgeBg = [_repeatBtn viewWithTag:901];
    if (repBadgeBg) repBadgeBg.hidden = !repOne;

    if (!track) return;

    BOOL trackChanged = (!_currentVideoId || ![_currentVideoId isEqualToString:track.videoId]);
    if (trackChanged) {
        [_currentVideoId release];
        _currentVideoId = [track.videoId copy];
    }

    _titleLabel.text = track.title;
    _artistLabel.text = track.artist;

    if (eng.isPlayingOffline) {
        _sourceBadge.text = @"OFFLINE AAC";
        _sourceBadge.textColor = [ELTheme successColor];
    } else if (eng.state == ELPlayerStateLoading) {
        _sourceBadge.text = @"BUFFERING...";
        _sourceBadge.textColor = [ELTheme accentColor];
    } else if (eng.state == ELPlayerStateError) {
        _sourceBadge.text = @"STREAM ERROR";
        _sourceBadge.textColor = [ELTheme accentColor];
        if (eng.lastError) _artistLabel.text = eng.lastError;
    } else {
        _sourceBadge.text = @"STREAMING";
        _sourceBadge.textColor = streamBadgeColor;
    }

    if (eng.state == ELPlayerStateLoading) {
        [_playPauseBtn setImage:nil forState:UIControlStateNormal];
        [_spinner startAnimating];
    } else {
        [_spinner stopAnimating];
        UIImage *icon = (eng.state == ELPlayerStatePlaying)
            ? [ELTheme iconPauseSize:34.0f color:[UIColor whiteColor]]
            : [ELTheme iconPlaySize:34.0f color:[UIColor whiteColor]];
        [_playPauseBtn setImage:icon forState:UIControlStateNormal];
    }

    /* Update full-bleed album art + dynamic dominant backdrop when artwork changes */
    UIImage *localArt = [[ELDownloadManager sharedManager] localArtImageForVideoId:track.videoId];
    if (localArt) {
        NSString *localKey = [NSString stringWithFormat:@"local:%@", track.videoId];
        if (![_loadedArtKey isEqualToString:localKey]) {
            [_loadedArtURL release];
            _loadedArtURL = nil;
            [self setArtworkImage:localArt forKey:localKey animated:(_loadedArtKey != nil)];
        }
    } else {
        NSString *url = ([track.artURL length] > 0) ? track.artURL : track.thumbURL;
        if ([url length] > 0) {
            if (![_loadedArtKey isEqualToString:url]) {
                BOOL wasLoaded = (_loadedArtKey != nil);
                NSString *pendingKey = [NSString stringWithFormat:@"pending:%@", url];
                UIImage *c = [[ELImageCache sharedCache] cachedImageForURL:url];
                if (c) {
                    [_loadedArtURL release];
                    _loadedArtURL = [url copy];
                    [self setArtworkImage:c forKey:url animated:wasLoaded];
                } else if (![_loadedArtKey isEqualToString:pendingKey]) {
                    [_loadedArtURL release];
                    _loadedArtURL = [url copy];
                    [self setArtworkImage:[ELTheme placeholderArtImage] forKey:pendingKey animated:wasLoaded];
                    [[ELImageCache sharedCache] loadImageForURL:url target:self action:@selector(onArtLoaded:)];
                }
            }
        } else if (![_loadedArtKey isEqualToString:@"placeholder"]) {
            [_loadedArtURL release];
            _loadedArtURL = nil;
            [self setArtworkImage:[ELTheme placeholderArtImage] forKey:@"placeholder" animated:(_loadedArtKey != nil)];
        }
    }

    [self refreshLikeState];
    [self refreshDownloadBtn];
    [self refreshProgress];
}

- (void)onArtLoaded:(NSDictionary *)info {
    NSString *url = [info objectForKey:@"url"];
    UIImage *img = [info objectForKey:@"image"];
    if (img && _loadedArtURL && [url isEqualToString:_loadedArtURL]) {
        [self setArtworkImage:img forKey:url animated:YES];
    }
}

@end
