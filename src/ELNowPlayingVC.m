#import "ELNowPlayingVC.h"
#import "ELAudioEngine.h"
#if EL_FEATURE_DOCK_MODE
#import "ELDockModeVC.h"
#endif
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELImageCache.h"
#if EL_FEATURE_LOCAL_PLAYLISTS
#import "ELLocalPlaylistManager.h"
#endif
#if EL_FEATURE_LYRICS
#import "ELLyricsClient.h"
#endif
#if EL_FEATURE_MUSIC_DNA
#import "ELMusicDNAVC.h"
#endif
#import "ELQueueVC.h"
#import "ELTheme.h"
#if EL_FEATURE_LIKES || EL_FEATURE_RADIO_MIX
#import "ELYouTubeClient.h"
#endif
#import <math.h>

#if EL_FEATURE_MARQUEE
static const CGFloat kELMarqueeGap = 40.0f;
static const CGFloat kELMarqueeSpeed = 32.0f;
static const CFTimeInterval kELMarqueePause = 1.6;
static NSString *const kELMarqueeAnimKey = @"elMarqueeScroll";
#endif

@interface ELNowPlayingVC ()
#if EL_FEATURE_MARQUEE
- (void)startMarqueesIfVisible;
- (void)stopMarquees;
#endif
#if EL_FEATURE_LYRICS
- (void)loadLyricsForCurrentTrack;
- (void)updateActiveLyricForTime:(double)curTime;
#endif
@end

@implementation ELNowPlayingVC

- (UIButton *)newCirclePillButtonWithFrame:(CGRect)frame
                                        bg:(UIImage *)bg
                                      bgHi:(UIImage *)bgHi
                                      icon:(UIImage *)icon
                                    action:(SEL)action {
    UIButton *btn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    btn.frame = frame;
    if (bg) [btn setBackgroundImage:bg forState:UIControlStateNormal];
    if (bgHi) [btn setBackgroundImage:bgHi forState:UIControlStateHighlighted];
    if (icon) [btn setImage:icon forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    return btn;
}

- (UILabel *)newClearLabelWithFrame:(CGRect)frame
                               font:(UIFont *)font
                              color:(UIColor *)color
                              align:(UITextAlignment)align
                             parent:(UIView *)parent {
    UILabel *lbl = [[UILabel alloc] initWithFrame:frame];
    lbl.backgroundColor = [UIColor clearColor];
    lbl.font = font;
    lbl.textColor = color;
    lbl.textAlignment = align;
    [parent addSubview:lbl];
    return lbl;
}

#if EL_FEATURE_MARQUEE
- (void)setupMarqueeRowWithFrame:(CGRect)frame
                            font:(UIFont *)font
                           color:(UIColor *)color
                    containerOut:(UIView **)containerOut
                        trackOut:(UIView **)trackOut
                        labelOut:(UILabel **)labelOut
                        cloneOut:(UILabel **)cloneOut {
    UIView *container = [[UIView alloc] initWithFrame:frame];
    container.backgroundColor = [UIColor clearColor];
    container.clipsToBounds = YES;
    container.userInteractionEnabled = NO;
    [self.view addSubview:container];

    UIView *track = [[UIView alloc] initWithFrame:container.bounds];
    track.backgroundColor = [UIColor clearColor];
    [container addSubview:track];

    UILabel *label = [self newClearLabelWithFrame:container.bounds font:font color:color align:UITextAlignmentLeft parent:track];
    label.lineBreakMode = UILineBreakModeClip;

    UILabel *clone = [self newClearLabelWithFrame:container.bounds font:font color:color align:UITextAlignmentLeft parent:track];
    clone.lineBreakMode = UILineBreakModeClip;
    clone.hidden = YES;

    *containerOut = container;
    *trackOut = track;
    *labelOut = label;
    *cloneOut = clone;
}
#endif

#if EL_FEATURE_SHAKE_SHUFFLE
- (BOOL)canBecomeFirstResponder {
    return YES;
}
#endif

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
#if EL_FEATURE_SHAKE_SHUFFLE
    [self becomeFirstResponder];
#endif
#if EL_FEATURE_MARQUEE
    _isViewVisible = YES;
#endif
    _lastDisplayedElapsedSec = -1;
    _lastDisplayedDurationSec = -1;
    [self refreshProgress];
#if EL_FEATURE_MARQUEE
    [self startMarqueesIfVisible];
#endif
}

- (void)viewWillDisappear:(BOOL)animated {
#if EL_FEATURE_MARQUEE
    _isViewVisible = NO;
    [self stopMarquees];
#endif
#if EL_FEATURE_SHAKE_SHUFFLE
    [self resignFirstResponder];
#endif
    [super viewWillDisappear:animated];
}

#if EL_FEATURE_SHAKE_SHUFFLE
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    (void)event;
    if (motion == UIEventSubtypeMotionShake) {
        [[ELAudioEngine sharedEngine] handleShakeToShuffle];
    }
}
#endif

- (void)applyBackdropColor:(UIColor *)dominant animated:(BOOL)animated {
    (void)animated;
    if (!_backdropView) return;
    if (!dominant) dominant = [ELTheme dominantBackdropColorFromImage:nil];
    UIColor *topCol = [ELTheme darkerShadeOfColor:dominant factor:0.78f];
    UIColor *midCol = [ELTheme darkerShadeOfColor:dominant factor:0.52f];
    UIColor *botCol = [ELTheme darkerShadeOfColor:dominant factor:0.24f];

    self.view.backgroundColor = botCol;
    _backdropView.image = [ELTheme verticalGradientImageWithHeight:460.0f
                                                          topColor:topCol
                                                          midColor:midCol
                                                       midLocation:0.52f
                                                       bottomColor:botCol
                                                            opaque:YES];
}

- (UIButton *)newUtilityPillWithTitle:(NSString *)title icon:(UIImage *)icon action:(SEL)action {
    UIButton *btn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    UIColor *bg = [UIColor colorWithWhite:1.0f alpha:0.14f];
    UIColor *bgHi = [UIColor colorWithWhite:1.0f alpha:0.26f];
    [btn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:bg] forState:UIControlStateNormal];
    [btn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:bgHi] forState:UIControlStateHighlighted];
    if (icon) [btn setImage:icon forState:UIControlStateNormal];
    if (title) [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:10.0f];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    return btn;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *pillDark = [UIColor colorWithWhite:0.0f alpha:0.32f];
    UIColor *pillDarkHi = [UIColor colorWithWhite:0.0f alpha:0.52f];
    UIColor *pillLight = [UIColor colorWithWhite:1.0f alpha:0.16f];
    UIColor *pillLightHi = [UIColor colorWithWhite:1.0f alpha:0.28f];
    UIColor *secondaryWhite = [UIColor colorWithWhite:1.0f alpha:0.78f];

    /* Rich full-screen 1x460 dominant-color vertical gradient backdrop */
    _backdropView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 460.0f)];
    _backdropView.contentMode = UIViewContentModeScaleToFill;
    _backdropView.opaque = YES;
    _backdropView.userInteractionEnabled = NO;
    [self.view addSubview:_backdropView];
    [self applyBackdropColor:[ELTheme dominantBackdropColorFromImage:nil] animated:NO];

    /* Top bar (y=8..42): subtle Close, centered slim Source pill, clean Queue */
    UIImage *topCircleBg = [ELTheme circlePillImageWithSize:34.0f color:pillDark];
    UIImage *topCircleHi = [ELTheme circlePillImageWithSize:34.0f color:pillDarkHi];

    [[self newCirclePillButtonWithFrame:CGRectMake(14.0f, 8.0f, 34.0f, 34.0f)
                                     bg:topCircleBg
                                   bgHi:topCircleHi
                                   icon:[ELTheme iconCloseSize:18.0f color:[UIColor whiteColor]]
                                 action:@selector(onClose)] autorelease];

    UIImageView *sourcePillBg = [[[UIImageView alloc] initWithFrame:CGRectMake(104.0f, 14.0f, 112.0f, 22.0f)] autorelease];
    sourcePillBg.image = [ELTheme stretchablePillImageWithHeight:22.0f color:pillDark];
    [self.view addSubview:sourcePillBg];

    _sourceBadge = [self newClearLabelWithFrame:sourcePillBg.frame
                                           font:[UIFont boldSystemFontOfSize:10.0f]
                                          color:secondaryWhite
                                          align:UITextAlignmentCenter
                                         parent:self.view];

    _queueBtn = [self newCirclePillButtonWithFrame:CGRectMake(272.0f, 8.0f, 34.0f, 34.0f)
                                                bg:topCircleBg
                                              bgHi:topCircleHi
                                              icon:[ELTheme iconQueueSize:18.0f color:[UIColor whiteColor]]
                                            action:@selector(onQueueTapped)];

    /* Centered 212x212 Square Album Art over pre-rendered soft shadow frame (zero offscreen FBO) */
    CGRect artFrame = CGRectMake(54.0f, 46.0f, 212.0f, 212.0f);
    UIImageView *artShadow = [[[UIImageView alloc] initWithFrame:CGRectInset(artFrame, -12.0f, -12.0f)] autorelease];
    artShadow.image = [ELTheme artShadowFrameImageWithSize:212.0f radius:12.0f];
    artShadow.userInteractionEnabled = NO;
    [self.view addSubview:artShadow];

    _artView = [[UIImageView alloc] initWithFrame:artFrame];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.opaque = YES;
    _artView.backgroundColor = [ELTheme surfaceColor];
    _artView.image = [ELTheme placeholderArtImage];
    [self.view addSubview:_artView];

#if EL_FEATURE_LYRICS
    /* Dark-translucent synced lyrics overlay aligned over the album art area */
    _lyricsContainer = [[UIView alloc] initWithFrame:CGRectMake(16.0f, 46.0f, 288.0f, 216.0f)];
    _lyricsContainer.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.72f];
    _lyricsContainer.hidden = YES;
    [self.view addSubview:_lyricsContainer];

    _lyricsTable = [[UITableView alloc] initWithFrame:_lyricsContainer.bounds style:UITableViewStylePlain];
    _lyricsTable.backgroundColor = [UIColor clearColor];
    _lyricsTable.separatorStyle = UITableViewCellSeparatorStyleNone;
    _lyricsTable.showsVerticalScrollIndicator = NO;
    _lyricsTable.rowHeight = 38.0f;
    _lyricsTable.contentInset = UIEdgeInsetsMake(64.0f, 0.0f, 64.0f, 0.0f);
    _lyricsTable.dataSource = self;
    _lyricsTable.delegate = self;
    [_lyricsContainer addSubview:_lyricsTable];

    _lyricsStatusLabel = [self newClearLabelWithFrame:CGRectMake(16.0f, 76.0f, 256.0f, 60.0f)
                                                 font:[UIFont systemFontOfSize:14.0f]
                                                color:secondaryWhite
                                                align:UITextAlignmentCenter
                                               parent:_lyricsContainer];
    _lyricsStatusLabel.numberOfLines = 2;
    _lyricsStatusLabel.text = @"Searching lyrics...";

    _activeLyricIndex = -1;
#endif
    _lastDisplayedElapsedSec = -1;
    _lastDisplayedDurationSec = -1;

    /* Track Title + Artist row (y=272..318) + Heart & More pills */
    UIFont *titleFont = [UIFont boldSystemFontOfSize:19.0f];
    UIFont *artistFont = [UIFont systemFontOfSize:14.0f];
#if EL_FEATURE_MARQUEE
    [self setupMarqueeRowWithFrame:CGRectMake(20.0f, 272.0f, 216.0f, 24.0f)
                              font:titleFont
                             color:[UIColor whiteColor]
                      containerOut:&_titleMarqueeContainer
                          trackOut:&_titleTrackView
                          labelOut:&_titleLabel
                          cloneOut:&_titleLabelClone];
    [self setupMarqueeRowWithFrame:CGRectMake(20.0f, 297.0f, 216.0f, 19.0f)
                              font:artistFont
                             color:secondaryWhite
                      containerOut:&_artistMarqueeContainer
                          trackOut:&_artistTrackView
                          labelOut:&_artistLabel
                          cloneOut:&_artistLabelClone];
#else
    _titleLabel = [self newClearLabelWithFrame:CGRectMake(20.0f, 272.0f, 216.0f, 24.0f)
                                          font:titleFont
                                         color:[UIColor whiteColor]
                                         align:UITextAlignmentLeft
                                        parent:self.view];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    _artistLabel = [self newClearLabelWithFrame:CGRectMake(20.0f, 297.0f, 216.0f, 19.0f)
                                           font:artistFont
                                          color:secondaryWhite
                                          align:UITextAlignmentLeft
                                         parent:self.view];
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
#endif

#if EL_FEATURE_LIKES
    _likeBtn = [self newCirclePillButtonWithFrame:CGRectMake(240.0f, 276.0f, 34.0f, 34.0f)
                                               bg:nil
                                             bgHi:nil
                                             icon:nil
                                           action:@selector(onLikeTapped)];
#endif

#if EL_NP_HAS_MORE_MENU
    _moreBtn = [self newCirclePillButtonWithFrame:CGRectMake(276.0f, 276.0f, 34.0f, 34.0f)
                                               bg:[ELTheme circlePillImageWithSize:34.0f color:pillLight]
                                             bgHi:[ELTheme circlePillImageWithSize:34.0f color:pillLightHi]
                                             icon:[ELTheme iconMoreSize:17.0f color:[UIColor whiteColor]]
                                           action:@selector(onMoreTapped)];
#endif

    /* Sleek rounded scrubber + tabular elapsed/duration (y=324..362) */
    _scrubber = [[UISlider alloc] initWithFrame:CGRectMake(20.0f, 324.0f, 280.0f, 24.0f)];
    _scrubber.minimumValue = 0.0f;
    _scrubber.maximumValue = 1.0f;
    [_scrubber setMinimumTrackImage:[ELTheme sliderTrackImageWithColor:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_scrubber setMaximumTrackImage:[ELTheme sliderTrackImageWithColor:[UIColor colorWithWhite:1.0f alpha:0.26f]] forState:UIControlStateNormal];
    [_scrubber setThumbImage:[ELTheme sliderThumbImage] forState:UIControlStateNormal];
    [_scrubber addTarget:self action:@selector(onScrubStart) forControlEvents:UIControlEventTouchDown];
    [_scrubber addTarget:self action:@selector(onScrubChanged) forControlEvents:UIControlEventValueChanged];
    [_scrubber addTarget:self action:@selector(onScrubEnd) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:_scrubber];

    _elapsedLabel = [self newClearLabelWithFrame:CGRectMake(20.0f, 348.0f, 72.0f, 15.0f)
                                            font:[UIFont systemFontOfSize:11.0f]
                                           color:secondaryWhite
                                           align:UITextAlignmentLeft
                                          parent:self.view];
    _elapsedLabel.text = @"0:00";

    _durationLabel = [self newClearLabelWithFrame:CGRectMake(228.0f, 348.0f, 72.0f, 15.0f)
                                             font:[UIFont systemFontOfSize:11.0f]
                                            color:secondaryWhite
                                            align:UITextAlignmentRight
                                           parent:self.view];
    _durationLabel.text = @"0:00";

    /* Iconic Transport row (y=366..424): solid-white 56x56 Play/Pause with dark icon */
    UIImage *dotImg = [ELTheme circlePillImageWithSize:4.0f color:[ELTheme accentColor]];

    _shuffleBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _shuffleBtn.frame = CGRectMake(18.0f, 376.0f, 40.0f, 42.0f);
    [_shuffleBtn addTarget:self action:@selector(onShuffle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_shuffleBtn];

    _shuffleDot = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 36.0f, 4.0f, 4.0f)];
    _shuffleDot.image = dotImg;
    _shuffleDot.hidden = YES;
    [_shuffleBtn addSubview:_shuffleDot];

    _prevBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _prevBtn.frame = CGRectMake(68.0f, 372.0f, 48.0f, 48.0f);
    [_prevBtn setImage:[ELTheme iconPrevSize:28.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_prevBtn addTarget:self action:@selector(onPrev) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_prevBtn];

    _playPauseBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _playPauseBtn.frame = CGRectMake(132.0f, 368.0f, 56.0f, 56.0f);
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:56.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:56.0f color:[UIColor colorWithWhite:0.84f alpha:1.0f]] forState:UIControlStateHighlighted];
    [_playPauseBtn addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playPauseBtn];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.center = _playPauseBtn.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _nextBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _nextBtn.frame = CGRectMake(204.0f, 372.0f, 48.0f, 48.0f);
    [_nextBtn setImage:[ELTheme iconNextSize:28.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_nextBtn addTarget:self action:@selector(onNext) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextBtn];

    _repeatBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _repeatBtn.frame = CGRectMake(262.0f, 376.0f, 40.0f, 42.0f);
    [_repeatBtn addTarget:self action:@selector(onRepeat) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_repeatBtn];

    _repeatDot = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 36.0f, 4.0f, 4.0f)];
    _repeatDot.image = dotImg;
    _repeatDot.hidden = YES;
    [_repeatBtn addSubview:_repeatDot];

    UIImageView *repBadgeBg = [[[UIImageView alloc] initWithFrame:CGRectMake(23.0f, 4.0f, 14.0f, 14.0f)] autorelease];
    repBadgeBg.image = [ELTheme circlePillImageWithSize:14.0f color:[ELTheme accentColor]];
    repBadgeBg.tag = 901;
    repBadgeBg.hidden = YES;
    [_repeatBtn addSubview:repBadgeBg];

    _repeatOneBadge = [self newClearLabelWithFrame:repBadgeBg.frame
                                              font:[UIFont boldSystemFontOfSize:9.0f]
                                             color:[UIColor whiteColor]
                                             align:UITextAlignmentCenter
                                            parent:_repeatBtn];
    _repeatOneBadge.text = @"1";
    _repeatOneBadge.hidden = YES;

    /* Clean Bottom Utility Row (y=430..456): Lyrics | Download | Dock | DNA */
    NSMutableArray *utilBtns = [NSMutableArray arrayWithCapacity:4];
#if EL_FEATURE_LYRICS
    _lyricsBtn = [self newUtilityPillWithTitle:@" Lyrics"
                                          icon:[ELTheme iconLyricsSize:12.0f color:[UIColor whiteColor]]
                                        action:@selector(onLyricsTapped)];
    [utilBtns addObject:_lyricsBtn];
#endif
#if EL_FEATURE_DOWNLOADS
    _downloadBtn = [self newUtilityPillWithTitle:nil
                                            icon:nil
                                          action:@selector(onDownloadTapped)];
    [utilBtns addObject:_downloadBtn];
#endif
#if EL_FEATURE_DOCK_MODE
    _dockBtn = [self newUtilityPillWithTitle:@"Dock"
                                        icon:nil
                                      action:@selector(onDockTapped)];
    [utilBtns addObject:_dockBtn];
#endif
#if EL_FEATURE_MUSIC_DNA
    _dnaBtn = [self newUtilityPillWithTitle:@"DNA"
                                       icon:nil
                                     action:@selector(onMusicDNATapped)];
    [utilBtns addObject:_dnaBtn];
#endif
    NSUInteger uCount = [utilBtns count];
    if (uCount > 0) {
        CGFloat gap = 8.0f;
        CGFloat totalW = 288.0f;
        CGFloat btnW = floorf((totalW - gap * (CGFloat)(uCount - 1)) / (CGFloat)uCount);
        CGFloat startX = floorf((320.0f - (btnW * (CGFloat)uCount + gap * (CGFloat)(uCount - 1))) * 0.5f);
        for (NSUInteger i = 0; i < uCount; i++) {
            UIButton *b = [utilBtns objectAtIndex:i];
            b.frame = CGRectMake(startX + (CGFloat)i * (btnW + gap), 430.0f, btnW, 26.0f);
        }
    }

#if EL_FEATURE_LIKES
    _lastLikeVisualState = -1;
#endif
    _lastShuffleState = -1;
    _lastPlayIconState = -1;
    _lastRepeatState = -1;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refreshAll) name:ELPlayerStateChangedNotification object:nil];
    [nc addObserver:self selector:@selector(onProgressNotification:) name:ELPlayerProgressNotification object:nil];
#if EL_FEATURE_DOWNLOADS
    [nc addObserver:self selector:@selector(refreshDownloadBtn) name:ELDownloadsChangedNotification object:nil];
    [nc addObserver:self selector:@selector(onDownloadProgressNote:) name:ELDownloadProgressNotification object:nil];
#endif
#if EL_FEATURE_LIKES
    [nc addObserver:self selector:@selector(onLibraryUpdated) name:ELLibraryUpdatedNotification object:nil];
#endif
#if EL_FEATURE_MARQUEE
    [nc addObserver:self selector:@selector(onAppDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onAppWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
#endif

    [self refreshAll];
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#if EL_FEATURE_MARQUEE
    _isViewVisible = NO;
    [self stopMarquees];
    [_titleMarqueeContainer release]; _titleMarqueeContainer = nil;
    [_titleTrackView release]; _titleTrackView = nil;
    [_titleLabelClone release]; _titleLabelClone = nil;
    [_artistMarqueeContainer release]; _artistMarqueeContainer = nil;
    [_artistTrackView release]; _artistTrackView = nil;
    [_artistLabelClone release]; _artistLabelClone = nil;
    [_lastTitleText release]; _lastTitleText = nil;
    [_lastArtistText release]; _lastArtistText = nil;
#endif
    [_backdropView release]; _backdropView = nil;
    [_artView release]; _artView = nil;
    [_sourceBadge release]; _sourceBadge = nil;
#if EL_FEATURE_LYRICS
    [_lyricsBtn release]; _lyricsBtn = nil;
    [_lyricsContainer release]; _lyricsContainer = nil;
    [_lyricsTable release]; _lyricsTable = nil;
    [_lyricsStatusLabel release]; _lyricsStatusLabel = nil;
#endif
    [_titleLabel release]; _titleLabel = nil;
    [_artistLabel release]; _artistLabel = nil;
#if EL_NP_HAS_MORE_MENU
    [_moreBtn release]; _moreBtn = nil;
#endif
#if EL_FEATURE_LIKES
    [_likeBtn release]; _likeBtn = nil;
#endif
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
#if EL_FEATURE_DOWNLOADS
    [_downloadBtn release]; _downloadBtn = nil;
#endif
#if EL_FEATURE_DOCK_MODE
    [_dockBtn release]; _dockBtn = nil;
#endif
#if EL_FEATURE_MUSIC_DNA
    [_dnaBtn release]; _dnaBtn = nil;
#endif
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
#if EL_FEATURE_LYRICS
    [_lyricLines release];
    [_lyricsVideoId release];
#endif
#if EL_FEATURE_LIKES
    [_inFlightLikeVideoId release];
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
    [_pickerPlaylists release];
#endif
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

#if EL_FEATURE_DOCK_MODE
- (void)onDockTapped {
    ELDockModeVC *dvc = [[[ELDockModeVC alloc] init] autorelease];
    [self presentModalViewController:dvc animated:YES];
}
#endif

#if EL_FEATURE_MUSIC_DNA
- (void)onMusicDNATapped {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track) return;
    ELMusicDNAVC *mvc = [[[ELMusicDNAVC alloc] initWithTrack:track] autorelease];
    [self presentModalViewController:mvc animated:YES];
}
#endif

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

#if EL_FEATURE_LIKES
#pragma mark - Like / Unlike Flow

- (void)updateLikeButtonVisual {
    NSInteger state = _isLiked ? 1 : 0;
    if (state == _lastLikeVisualState) return;
    _lastLikeVisualState = state;
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
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:34.0f color:likedBg] forState:UIControlStateNormal];
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:34.0f color:likedBgHi] forState:UIControlStateHighlighted];
        [_likeBtn setImage:[ELTheme iconHeartFilledSize:18.0f color:[ELTheme accentColor]] forState:UIControlStateNormal];
    } else {
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:34.0f color:unlikedBg] forState:UIControlStateNormal];
        [_likeBtn setBackgroundImage:[ELTheme circlePillImageWithSize:34.0f color:unlikedBgHi] forState:UIControlStateHighlighted];
        [_likeBtn setImage:[ELTheme iconHeartOutlineSize:18.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
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
    [NSThread setThreadPriority:0.25];
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
#endif

#pragma mark - Downloads & Refresh

#if EL_FEATURE_DOWNLOADS
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

- (void)onDownloadProgressNote:(NSNotification *)note {
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (vid && track && ![vid isEqualToString:track.videoId]) return;
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
#endif

- (void)updateProgressWithCurrentTime:(double)cur duration:(double)dur {
    if (![self isViewLoaded] || !self.view.window) return;
    NSInteger durSec = (dur > 0.0) ? (NSInteger)dur : 0;
    if (durSec != _lastDisplayedDurationSec) {
        _lastDisplayedDurationSec = durSec;
        _durationLabel.text = [ELTrack formatSeconds:dur];
    }
    if (!_isScrubbing) {
        NSInteger curSec = (cur > 0.0) ? (NSInteger)cur : 0;
        if (curSec != _lastDisplayedElapsedSec) {
            _lastDisplayedElapsedSec = curSec;
            _elapsedLabel.text = [ELTrack formatSeconds:cur];
        }
        float targetVal = (dur > 0.0) ? (float)(cur / dur) : 0.0f;
        if (targetVal < 0.0f) targetVal = 0.0f;
        if (targetVal > 1.0f) targetVal = 1.0f;
        if (fabsf(_scrubber.value - targetVal) >= 0.002f) {
            _scrubber.value = targetVal;
        }
    }
#if EL_FEATURE_LYRICS
    if (_showingLyrics && [_lyricLines count] > 0) {
        [self updateActiveLyricForTime:cur];
    }
#endif
}

- (void)onProgressNotification:(NSNotification *)note {
    NSDictionary *info = [note userInfo];
    NSNumber *curNum = [info objectForKey:@"currentTime"];
    NSNumber *durNum = [info objectForKey:@"duration"];
    if (curNum && durNum) {
        [self updateProgressWithCurrentTime:[curNum doubleValue] duration:[durNum doubleValue]];
    } else {
        [self refreshProgress];
    }
}

- (void)refreshProgress {
    if (![self isViewLoaded] || !self.view.window) return;
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    [self updateProgressWithCurrentTime:[eng currentTime] duration:[eng duration]];
}

#if EL_FEATURE_MARQUEE
#pragma mark - Marquee Scrolling

- (void)stopMarqueeOnTrackView:(UIView *)trackView {
    if (!trackView) return;
    [trackView.layer removeAnimationForKey:kELMarqueeAnimKey];
}

- (void)configureMarqueeForContainer:(UIView *)container
                           trackView:(UIView *)trackView
                               label:(UILabel *)label
                               clone:(UILabel *)clone
                                text:(NSString *)text
                         shouldStart:(BOOL)shouldStart {
    if (!container || !trackView || !label || !clone) return;
    NSString *safeText = text ? text : @"";
    label.text = safeText;
    clone.text = safeText;

    [trackView.layer removeAnimationForKey:kELMarqueeAnimKey];

    CGFloat containerW = container.bounds.size.width;
    CGFloat containerH = container.bounds.size.height;
    CGSize measured = [safeText sizeWithFont:label.font];
    CGFloat textW = ceilf((float)measured.width);

    if (textW <= containerW + 0.5f || [safeText length] == 0) {
        label.lineBreakMode = UILineBreakModeClip;
        clone.lineBreakMode = UILineBreakModeClip;
        trackView.frame = CGRectMake(0.0f, 0.0f, containerW, containerH);
        label.frame = CGRectMake(0.0f, 0.0f, containerW, containerH);
        clone.hidden = YES;
        return;
    }

    /* PowerVR MBX Lite (iPod touch 2G) max layer texture width is 1024px */
    if (textW > 960.0f) {
        textW = 960.0f;
        label.lineBreakMode = UILineBreakModeTailTruncation;
        clone.lineBreakMode = UILineBreakModeTailTruncation;
    } else {
        label.lineBreakMode = UILineBreakModeClip;
        clone.lineBreakMode = UILineBreakModeClip;
    }

    CGFloat scrollDist = textW + kELMarqueeGap;
    trackView.frame = CGRectMake(0.0f, 0.0f, scrollDist + textW, containerH);
    label.frame = CGRectMake(0.0f, 0.0f, textW, containerH);
    clone.frame = CGRectMake(scrollDist, 0.0f, textW, containerH);
    clone.hidden = NO;

    if (!shouldStart) return;

    CFTimeInterval scrollDur = (CFTimeInterval)(scrollDist / kELMarqueeSpeed);
    if (scrollDur < 2.0) scrollDur = 2.0;
    CFTimeInterval totalDur = kELMarqueePause + scrollDur;
    double pauseFrac = kELMarqueePause / totalDur;

    CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    anim.values = [NSArray arrayWithObjects:
                   [NSNumber numberWithFloat:0.0f],
                   [NSNumber numberWithFloat:0.0f],
                   [NSNumber numberWithFloat:(float)(-scrollDist)],
                   nil];
    anim.keyTimes = [NSArray arrayWithObjects:
                     [NSNumber numberWithDouble:0.0],
                     [NSNumber numberWithDouble:pauseFrac],
                     [NSNumber numberWithDouble:1.0],
                     nil];
    CAMediaTimingFunction *linear = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    anim.timingFunctions = [NSArray arrayWithObjects:linear, linear, nil];
    anim.duration = totalDur;
    anim.repeatCount = HUGE_VALF;
    anim.removedOnCompletion = NO;
    [trackView.layer addAnimation:anim forKey:kELMarqueeAnimKey];
}

- (void)startMarqueesIfVisible {
    if (!_isViewVisible) return;
    [self configureMarqueeForContainer:_titleMarqueeContainer
                             trackView:_titleTrackView
                                 label:_titleLabel
                                 clone:_titleLabelClone
                                  text:_lastTitleText
                           shouldStart:YES];
    [self configureMarqueeForContainer:_artistMarqueeContainer
                             trackView:_artistTrackView
                                 label:_artistLabel
                                 clone:_artistLabelClone
                                  text:_lastArtistText
                           shouldStart:YES];
}

- (void)stopMarquees {
    [self stopMarqueeOnTrackView:_titleTrackView];
    [self stopMarqueeOnTrackView:_artistTrackView];
}

- (void)onAppDidBecomeActive {
    [self startMarqueesIfVisible];
}

- (void)onAppWillResignActive {
    [self stopMarquees];
}
#endif

- (void)setArtworkImage:(UIImage *)img forKey:(NSString *)artKey animated:(BOOL)animated {
    if (!img) img = [ELTheme placeholderArtImage];
    _artView.image = img;
    [_loadedArtKey release];
    _loadedArtKey = [artKey copy];
    [self applyBackdropColor:[ELTheme dominantBackdropColorFromImage:img cacheKey:artKey] animated:animated];
}

- (void)refreshAll {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELTrack *track = [eng currentTrack];

    /* Update Shuffle & Repeat visual state */
    static UIColor *dimWhite = nil;
    if (!dimWhite) dimWhite = [[UIColor colorWithWhite:1.0f alpha:0.46f] retain];
    static UIColor *streamBadgeColor = nil;
    if (!streamBadgeColor) streamBadgeColor = [[UIColor colorWithWhite:1.0f alpha:0.86f] retain];

    NSInteger shufState = eng.shuffleEnabled ? 1 : 0;
    if (shufState != _lastShuffleState) {
        _lastShuffleState = shufState;
        UIColor *shufCol = eng.shuffleEnabled ? [UIColor whiteColor] : dimWhite;
        [_shuffleBtn setImage:[ELTheme iconShuffleSize:22.0f color:shufCol] forState:UIControlStateNormal];
        _shuffleDot.hidden = !eng.shuffleEnabled;
    }

    NSInteger repState = (NSInteger)eng.repeatMode;
    if (repState != _lastRepeatState) {
        _lastRepeatState = repState;
        BOOL repActive = (eng.repeatMode != ELRepeatModeOff);
        UIColor *repCol = repActive ? [UIColor whiteColor] : dimWhite;
        [_repeatBtn setImage:[ELTheme iconRepeatSize:22.0f color:repCol] forState:UIControlStateNormal];
        _repeatDot.hidden = !repActive;
        BOOL repOne = (eng.repeatMode == ELRepeatModeOne);
        _repeatOneBadge.hidden = !repOne;
        UIView *repBadgeBg = [_repeatBtn viewWithTag:901];
        if (repBadgeBg) repBadgeBg.hidden = !repOne;
    }

    if (!track) return;

    BOOL trackChanged = (!_currentVideoId || ![_currentVideoId isEqualToString:track.videoId]);
    if (trackChanged) {
        [_currentVideoId release];
        _currentVideoId = [track.videoId copy];
#if EL_FEATURE_LYRICS
        if (_showingLyrics) {
            [self loadLyricsForCurrentTrack];
        }
#endif
    }

    NSString *titleText = track.title ? track.title : @"";
    NSString *artistText = track.artist ? track.artist : @"";

    if (eng.isPlayingOffline) {
        _sourceBadge.text = @"OFFLINE AAC";
        _sourceBadge.textColor = [ELTheme successColor];
    } else if (eng.state == ELPlayerStateLoading) {
        _sourceBadge.text = @"BUFFERING...";
        _sourceBadge.textColor = [ELTheme accentColor];
    } else if (eng.state == ELPlayerStateError) {
        _sourceBadge.text = @"STREAM ERROR";
        _sourceBadge.textColor = [ELTheme accentColor];
        if (eng.lastError) artistText = eng.lastError;
    } else {
        _sourceBadge.text = @"STREAMING";
        _sourceBadge.textColor = streamBadgeColor;
    }

#if EL_FEATURE_MARQUEE
    if (!_lastTitleText || ![_lastTitleText isEqualToString:titleText]) {
        [_lastTitleText release];
        _lastTitleText = [titleText copy];
        [self configureMarqueeForContainer:_titleMarqueeContainer
                                 trackView:_titleTrackView
                                     label:_titleLabel
                                     clone:_titleLabelClone
                                      text:_lastTitleText
                               shouldStart:_isViewVisible];
    }
    if (!_lastArtistText || ![_lastArtistText isEqualToString:artistText]) {
        [_lastArtistText release];
        _lastArtistText = [artistText copy];
        [self configureMarqueeForContainer:_artistMarqueeContainer
                                 trackView:_artistTrackView
                                     label:_artistLabel
                                     clone:_artistLabelClone
                                      text:_lastArtistText
                               shouldStart:_isViewVisible];
    }
#else
    _titleLabel.text = titleText;
    _artistLabel.text = artistText;
#endif

    if (eng.state == ELPlayerStateLoading) {
        if (_lastPlayIconState != 2) {
            _lastPlayIconState = 2;
            [_playPauseBtn setImage:nil forState:UIControlStateNormal];
        }
        [_spinner startAnimating];
    } else {
        [_spinner stopAnimating];
        NSInteger iconState = (eng.state == ELPlayerStatePlaying) ? 1 : 0;
        if (_lastPlayIconState != iconState) {
            _lastPlayIconState = iconState;
            UIColor *darkIcon = [UIColor colorWithWhite:0.08f alpha:1.0f];
            UIImage *icon = (iconState == 1)
                ? [ELTheme iconPauseSize:28.0f color:darkIcon]
                : [ELTheme iconPlaySize:28.0f color:darkIcon];
            [_playPauseBtn setImage:icon forState:UIControlStateNormal];
        }
    }

    /* Update full-bleed album art + dynamic dominant backdrop without main-thread disk I/O */
    NSString *url = ([track.artURL length] > 0) ? track.artURL : track.thumbURL;
    NSString *localKey = ([track.videoId length] > 0)
        ? [NSString stringWithFormat:@"local:%@", track.videoId]
        : nil;
    BOOL artAlreadyLoaded = (localKey && [_loadedArtKey isEqualToString:localKey])
        || ([url length] > 0 && [_loadedArtKey isEqualToString:url]);

    if (!artAlreadyLoaded) {
        UIImage *mem = ([url length] > 0) ? [[ELImageCache sharedCache] memoryCachedImageForURL:url] : nil;
        if (mem) {
            BOOL wasLoaded = (_loadedArtKey != nil);
            [_loadedArtURL release];
            _loadedArtURL = [url copy];
            [self setArtworkImage:mem forKey:url animated:wasLoaded];
        }
#if EL_FEATURE_DOWNLOADS
        else if ([track.videoId length] > 0 && [[ELDownloadManager sharedManager] isDownloaded:track.videoId]) {
            NSString *pendingKey = [NSString stringWithFormat:@"pending:local:%@", track.videoId];
            if (![_loadedArtKey isEqualToString:pendingKey]) {
                BOOL wasLoaded = (_loadedArtKey != nil);
                [_loadedArtURL release];
                _loadedArtURL = [url copy];
                [self setArtworkImage:[ELTheme placeholderArtImage] forKey:pendingKey animated:wasLoaded];
                NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                                      track.videoId, @"videoId",
                                      url ? url : @"", @"url",
                                      nil];
                [NSThread detachNewThreadSelector:@selector(localArtWorker:) toTarget:self withObject:args];
            }
        }
#endif
        else if ([url length] > 0) {
            NSString *pendingKey = [NSString stringWithFormat:@"pending:%@", url];
            if (![_loadedArtKey isEqualToString:pendingKey]) {
                BOOL wasLoaded = (_loadedArtKey != nil);
                [_loadedArtURL release];
                _loadedArtURL = [url copy];
                [self setArtworkImage:[ELTheme placeholderArtImage] forKey:pendingKey animated:wasLoaded];
                [[ELImageCache sharedCache] loadImageForURL:url target:self action:@selector(onArtLoaded:)];
            }
        } else if (![_loadedArtKey isEqualToString:@"placeholder"]) {
            [_loadedArtURL release];
            _loadedArtURL = nil;
            [self setArtworkImage:[ELTheme placeholderArtImage] forKey:@"placeholder" animated:(_loadedArtKey != nil)];
        }
    }

#if EL_FEATURE_LIKES
    [self refreshLikeState];
#endif
#if EL_FEATURE_DOWNLOADS
    [self refreshDownloadBtn];
#endif
    [self refreshProgress];
}

#if EL_FEATURE_DOWNLOADS
- (void)localArtWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSString *vid = [args objectForKey:@"videoId"];
    NSString *url = [args objectForKey:@"url"];
    UIImage *img = [[ELDownloadManager sharedManager] localArtImageForVideoId:vid];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                vid ? vid : @"", @"videoId",
                                url ? url : @"", @"url",
                                nil];
    if (img) [res setObject:img forKey:@"image"];
    [self performSelectorOnMainThread:@selector(onLocalArtLoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onLocalArtLoaded:(NSDictionary *)res {
    NSString *vid = [res objectForKey:@"videoId"];
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    if (!cur || ![cur.videoId isEqualToString:vid]) return;
    UIImage *img = [res objectForKey:@"image"];
    if (img) {
        NSString *localKey = [NSString stringWithFormat:@"local:%@", vid];
        [_loadedArtURL release];
        _loadedArtURL = nil;
        [self setArtworkImage:img forKey:localKey animated:YES];
        return;
    }
    NSString *url = [res objectForKey:@"url"];
    if ([url length] > 0) {
        [_loadedArtURL release];
        _loadedArtURL = [url copy];
        [[ELImageCache sharedCache] loadImageForURL:url target:self action:@selector(onArtLoaded:)];
    }
}
#endif

- (void)onArtLoaded:(NSDictionary *)info {
    NSString *url = [info objectForKey:@"url"];
    UIImage *img = [info objectForKey:@"image"];
    if (img && _loadedArtURL && [url isEqualToString:_loadedArtURL]) {
        [self setArtworkImage:img forKey:url animated:YES];
    }
}

#if EL_FEATURE_LYRICS
#pragma mark - Synced Lyrics

- (void)updateLyricsButtonVisual {
    UIColor *bg = _showingLyrics ? [ELTheme accentColor] : [UIColor colorWithWhite:1.0f alpha:0.14f];
    UIColor *bgHi = _showingLyrics ? [ELTheme darkerShadeOfColor:[ELTheme accentColor] factor:0.78f] : [UIColor colorWithWhite:1.0f alpha:0.26f];
    [_lyricsBtn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:bg] forState:UIControlStateNormal];
    [_lyricsBtn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:bgHi] forState:UIControlStateHighlighted];
}

- (void)onLyricsTapped {
    _showingLyrics = !_showingLyrics;
    _lyricsContainer.hidden = !_showingLyrics;
    [self updateLyricsButtonVisual];
    if (_showingLyrics) {
        ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
        if (track && (!_lyricsVideoId || ![_lyricsVideoId isEqualToString:track.videoId])) {
            [self loadLyricsForCurrentTrack];
        } else if ([_lyricLines count] > 0) {
            [self updateActiveLyricForTime:[[ELAudioEngine sharedEngine] currentTime]];
        }
    }
}

- (void)loadLyricsForCurrentTrack {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track || [track.videoId length] == 0) return;

    _lyricsGen++;
    _activeLyricIndex = -1;
    _lastDisplayedElapsedSec = -1;
    _lastDisplayedDurationSec = -1;
    [_lyricsVideoId release];
    _lyricsVideoId = [track.videoId copy];
    [_lyricLines release];
    _lyricLines = nil;
    [_lyricsTable reloadData];
    _lyricsStatusLabel.text = @"Searching lyrics...";
    _lyricsStatusLabel.hidden = NO;

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          track, @"track",
                          [NSNumber numberWithInteger:_lyricsGen], @"gen",
                          nil];
    [NSThread detachNewThreadSelector:@selector(lyricsWorker:) toTarget:self withObject:args];
}

- (void)lyricsWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    ELTrack *track = [args objectForKey:@"track"];
    NSNumber *gen = [args objectForKey:@"gen"];

    NSArray *lines = [[ELLyricsClient sharedClient] cachedLyricsForVideoId:track.videoId];
    NSString *err = nil;
    if (!lines || [lines count] == 0) {
        lines = [[ELLyricsClient sharedClient] fetchLyricsForTrack:track error:&err];
    }

    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                gen, @"gen",
                                track.videoId ? track.videoId : @"", @"videoId",
                                nil];
    if (lines) [res setObject:lines forKey:@"lines"];
    if (err)   [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onLyricsFinished:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onLyricsFinished:(NSDictionary *)res {
    if ([[res objectForKey:@"gen"] integerValue] != _lyricsGen) return;
    NSArray *lines = [res objectForKey:@"lines"];
    [_lyricLines release];
    if (lines && [lines count] > 0) {
        _lyricLines = [lines retain];
        _lyricsStatusLabel.hidden = YES;
        _activeLyricIndex = -1;
    _lastDisplayedElapsedSec = -1;
    _lastDisplayedDurationSec = -1;
        [_lyricsTable reloadData];
        [self updateActiveLyricForTime:[[ELAudioEngine sharedEngine] currentTime]];
    } else {
        _lyricLines = nil;
        _lyricsStatusLabel.text = @"No synced lyrics found";
        _lyricsStatusLabel.hidden = NO;
        [_lyricsTable reloadData];
    }
}

- (void)styleLyricCell:(UITableViewCell *)cell forRow:(NSInteger)row line:(ELLyricLine *)line {
    if (!cell || !line) return;
    static UIFont *sRegularFont = nil;
    static UIFont *sActiveFont = nil;
    static UIColor *sUnsyncedColor = nil;
    static UIColor *sSungColor = nil;
    static UIColor *sUpcomingColor = nil;
    if (!sRegularFont) {
        sRegularFont = [[UIFont systemFontOfSize:14.0f] retain];
        sActiveFont = [[UIFont boldSystemFontOfSize:16.0f] retain];
        sUnsyncedColor = [[UIColor colorWithWhite:1.0f alpha:0.86f] retain];
        sSungColor = [[UIColor colorWithWhite:1.0f alpha:0.34f] retain];
        sUpcomingColor = [[UIColor colorWithWhite:1.0f alpha:0.58f] retain];
    }
    if (line.timeSeconds < 0.0) {
        cell.textLabel.font = sRegularFont;
        cell.textLabel.textColor = sUnsyncedColor;
    } else if (row == _activeLyricIndex) {
        cell.textLabel.font = sActiveFont;
        cell.textLabel.textColor = [UIColor whiteColor];
    } else if (_activeLyricIndex >= 0 && row < _activeLyricIndex) {
        cell.textLabel.font = sRegularFont;
        cell.textLabel.textColor = sSungColor;
    } else {
        cell.textLabel.font = sRegularFont;
        cell.textLabel.textColor = sUpcomingColor;
    }
}

- (void)setActiveLyricIndex:(NSInteger)newIndex scroll:(BOOL)shouldScroll {
    NSInteger count = (NSInteger)[_lyricLines count];
    NSInteger prevIdx = _activeLyricIndex;
    _activeLyricIndex = newIndex;
    if (prevIdx >= 0 && newIndex == prevIdx + 1 && newIndex < count) {
        NSIndexPath *oldIp = [NSIndexPath indexPathForRow:prevIdx inSection:0];
        NSIndexPath *newIp = [NSIndexPath indexPathForRow:newIndex inSection:0];
        [self styleLyricCell:[_lyricsTable cellForRowAtIndexPath:oldIp]
                      forRow:prevIdx
                        line:[_lyricLines objectAtIndex:(NSUInteger)prevIdx]];
        [self styleLyricCell:[_lyricsTable cellForRowAtIndexPath:newIp]
                      forRow:newIndex
                        line:[_lyricLines objectAtIndex:(NSUInteger)newIndex]];
    } else {
        for (NSIndexPath *ip in [_lyricsTable indexPathsForVisibleRows]) {
            if ((NSInteger)ip.row >= 0 && (NSInteger)ip.row < count) {
                UITableViewCell *cell = [_lyricsTable cellForRowAtIndexPath:ip];
                [self styleLyricCell:cell forRow:(NSInteger)ip.row line:[_lyricLines objectAtIndex:ip.row]];
            }
        }
    }
    if (shouldScroll && _activeLyricIndex >= 0 && _activeLyricIndex < count) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:_activeLyricIndex inSection:0];
        [_lyricsTable scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
    }
}

- (void)updateActiveLyricForTime:(double)curTime {
    if (!_lyricLines || [_lyricLines count] == 0) return;
    ELLyricLine *first = [_lyricLines objectAtIndex:0];
    if (first.timeSeconds < 0.0) return;

    NSInteger found = -1;
    NSInteger count = (NSInteger)[_lyricLines count];
    for (NSInteger i = 0; i < count; i++) {
        ELLyricLine *line = [_lyricLines objectAtIndex:(NSUInteger)i];
        if (line.timeSeconds >= 0.0 && line.timeSeconds <= curTime + 0.25) {
            found = i;
        } else if (line.timeSeconds > curTime + 0.25) {
            break;
        }
    }

    if (found != _activeLyricIndex) {
        [self setActiveLyricIndex:found scroll:YES];
    }
}

#pragma mark - Lyrics UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return _lyricLines ? (NSInteger)[_lyricLines count] : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *lid = @"ELLyricCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:lid];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:lid] autorelease];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.textAlignment = UITextAlignmentCenter;
        cell.textLabel.numberOfLines = 2;
        cell.textLabel.lineBreakMode = UILineBreakModeWordWrap;
    }
    ELLyricLine *line = [_lyricLines objectAtIndex:indexPath.row];
    cell.textLabel.text = line.text;
    [self styleLyricCell:cell forRow:(NSInteger)indexPath.row line:line];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_lyricLines || indexPath.row >= [_lyricLines count]) return;
    ELLyricLine *line = [_lyricLines objectAtIndex:indexPath.row];
    if (line.timeSeconds < 0.0) return;
    [[ELAudioEngine sharedEngine] seekToSeconds:line.timeSeconds];
    [self setActiveLyricIndex:(NSInteger)indexPath.row scroll:YES];
}
#endif

#if EL_NP_HAS_MORE_MENU
#pragma mark - More Actions (Radio Mix, Sleep Timer, Download)

- (void)onMoreTapped {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track) return;

    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:track.title
                                                        delegate:self
                                               cancelButtonTitle:nil
                                          destructiveButtonTitle:nil
                                               otherButtonTitles:nil] autorelease];
    _moreRadioIdx = -1;
    _moreSleepIdx = -1;
    _moreDownloadIdx = -1;
#if EL_FEATURE_DOCK_MODE
    _moreDockIdx = -1;
#endif
#if EL_FEATURE_MUSIC_DNA
    _moreDNAIdx = -1;
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
    _morePlaylistIdx = -1;
#endif

#if EL_FEATURE_RADIO_MIX
    _moreRadioIdx = [sheet addButtonWithTitle:@"Start Radio Mix"];
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
    _morePlaylistIdx = [sheet addButtonWithTitle:@"Add to Offline Playlist"];
#endif
#if EL_FEATURE_DOCK_MODE
    _moreDockIdx = [sheet addButtonWithTitle:@"Dock Mode"];
#endif
#if EL_FEATURE_MUSIC_DNA
    _moreDNAIdx = [sheet addButtonWithTitle:@"Music DNA"];
#endif
#if EL_FEATURE_SLEEP_TIMER
    NSInteger rem = [[ELAudioEngine sharedEngine] sleepTimerRemainingSeconds];
    NSString *sleepTitle = (rem > 0)
        ? [NSString stringWithFormat:@"Sleep Timer (%ldm left)", (long)((rem + 59) / 60)]
        : @"Sleep Timer";
    _moreSleepIdx = [sheet addButtonWithTitle:sleepTitle];
#endif
#if EL_FEATURE_DOWNLOADS
    BOOL downloaded = [[ELDownloadManager sharedManager] isDownloaded:track.videoId];
    NSString *dlTitle = downloaded ? @"Remove Offline Download" : @"Download for Offline";
    _moreDownloadIdx = [sheet addButtonWithTitle:dlTitle];
#endif
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    sheet.tag = 1;
    [sheet showInView:self.view];
}

#if EL_FEATURE_LOCAL_PLAYLISTS
- (void)showAddToPlaylistSheet {
    [_pickerPlaylists release];
    _pickerPlaylists = [[[ELLocalPlaylistManager sharedManager] playlists] retain];

    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:@"Add to Offline Playlist"
                                                        delegate:self
                                               cancelButtonTitle:nil
                                          destructiveButtonTitle:nil
                                               otherButtonTitles:nil] autorelease];
    for (ELLocalPlaylist *pl in _pickerPlaylists) {
        [sheet addButtonWithTitle:pl.name];
    }
    [sheet addButtonWithTitle:@"New 'Favorites' Playlist"];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    sheet.tag = 3;
    [sheet showInView:self.view];
}
#endif

#if EL_FEATURE_SLEEP_TIMER
- (void)showSleepTimerSheet {
    UIActionSheet *sheet = [[[UIActionSheet alloc] initWithTitle:@"Sleep Timer"
                                                        delegate:self
                                               cancelButtonTitle:@"Cancel"
                                          destructiveButtonTitle:nil
                                               otherButtonTitles:@"15 min", @"30 min", @"60 min", @"Turn Off", nil] autorelease];
    sheet.actionSheetStyle = UIActionSheetStyleBlackTranslucent;
    sheet.tag = 2;
    [sheet showInView:self.view];
}
#endif

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;

    if (actionSheet.tag == 1) {
        ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
        if (!track) return;
#if EL_FEATURE_RADIO_MIX
        if (buttonIndex == _moreRadioIdx) {
            [[ELAudioEngine sharedEngine] postToast:@"Starting Radio Mix..."];
            [NSThread detachNewThreadSelector:@selector(radioWorker:) toTarget:self withObject:track.videoId];
            return;
        }
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
        if (buttonIndex == _morePlaylistIdx) {
            [self showAddToPlaylistSheet];
            return;
        }
#endif
#if EL_FEATURE_DOCK_MODE
        if (buttonIndex == _moreDockIdx) {
            [self onDockTapped];
            return;
        }
#endif
#if EL_FEATURE_MUSIC_DNA
        if (buttonIndex == _moreDNAIdx) {
            [self onMusicDNATapped];
            return;
        }
#endif
#if EL_FEATURE_SLEEP_TIMER
        if (buttonIndex == _moreSleepIdx) {
            [self showSleepTimerSheet];
            return;
        }
#endif
#if EL_FEATURE_DOWNLOADS
        if (buttonIndex == _moreDownloadIdx) {
            ELDownloadManager *dm = [ELDownloadManager sharedManager];
            if ([dm isDownloaded:track.videoId]) {
                [dm deleteDownloadForVideoId:track.videoId];
                [[ELAudioEngine sharedEngine] postToast:@"Removed offline download"];
            } else {
                [dm downloadTrack:track];
                [[ELAudioEngine sharedEngine] postToast:@"Downloading..."];
            }
            [self refreshDownloadBtn];
            return;
        }
#endif
    }
#if EL_FEATURE_SLEEP_TIMER
    else if (actionSheet.tag == 2) {
        static const NSInteger kSleepOptions[] = { 15, 30, 60, 0 };
        NSInteger mins = (buttonIndex >= 0 && buttonIndex < 4) ? kSleepOptions[buttonIndex] : 0;
        [[ELAudioEngine sharedEngine] setSleepTimerMinutes:mins];
        NSString *msg = (mins > 0)
            ? [NSString stringWithFormat:@"Sleep timer: %ld min", (long)mins]
            : @"Sleep timer off";
        [[ELAudioEngine sharedEngine] postToast:msg];
    }
#endif
#if EL_FEATURE_LOCAL_PLAYLISTS
    else if (actionSheet.tag == 3) {
        ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
        if (!track) return;
        ELLocalPlaylistManager *mgr = [ELLocalPlaylistManager sharedManager];
        if (buttonIndex >= 0 && (NSUInteger)buttonIndex < [_pickerPlaylists count]) {
            ELLocalPlaylist *pl = [_pickerPlaylists objectAtIndex:(NSUInteger)buttonIndex];
            BOOL added = [mgr addTrack:track toPlaylistId:pl.playlistId];
            NSString *msg = added
                ? [NSString stringWithFormat:@"Added to %@", pl.name]
                : [NSString stringWithFormat:@"Already in %@", pl.name];
            [[ELAudioEngine sharedEngine] postToast:msg];
        } else {
            ELLocalPlaylist *pl = [mgr createPlaylistNamed:@"Favorites"];
            if (pl) {
                [mgr addTrack:track toPlaylistId:pl.playlistId];
                [[ELAudioEngine sharedEngine] postToast:[NSString stringWithFormat:@"Added to %@", pl.name]];
            }
        }
        [_pickerPlaylists release];
        _pickerPlaylists = nil;
    }
#endif
}

#if EL_FEATURE_RADIO_MIX
- (void)radioWorker:(NSString *)videoId {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSString *err = nil;
    NSArray *tracks = [[ELYouTubeClient sharedClient] fetchRadioTracksForVideoId:videoId error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    if (tracks) [res setObject:tracks forKey:@"tracks"];
    if (err)    [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onRadioFinished:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onRadioFinished:(NSDictionary *)res {
    NSArray *tracks = [res objectForKey:@"tracks"];
    NSString *err = [res objectForKey:@"error"];
    if (tracks && [tracks count] > 0) {
        [[ELAudioEngine sharedEngine] playTracks:tracks startingAtIndex:0];
        [[ELAudioEngine sharedEngine] postToast:@"Radio Mix started"];
    } else {
        [[ELAudioEngine sharedEngine] postToast:(err ? err : @"Could not start Radio Mix")];
    }
}
#endif
#endif

@end
