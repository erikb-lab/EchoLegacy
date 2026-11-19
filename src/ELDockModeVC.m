#import "ELDockModeVC.h"

#if EL_FEATURE_DOCK_MODE

#import "ELAudioEngine.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELImageCache.h"
#if EL_FEATURE_LYRICS
#import "ELLyricsClient.h"
#endif
#import "ELTheme.h"
#import "ELTrack.h"
#import <math.h>

static const CGFloat kDockProgressWidth = 272.0f;

@implementation ELDockModeVC

- (UILabel *)newLabelWithFrame:(CGRect)frame
                          font:(UIFont *)font
                         color:(UIColor *)color
                         align:(UITextAlignment)align {
    UILabel *lbl = [[UILabel alloc] initWithFrame:frame];
    lbl.backgroundColor = [UIColor clearColor];
    lbl.font = font;
    lbl.textColor = color;
    lbl.textAlignment = align;
    [self.view addSubview:lbl];
    return lbl;
}

- (void)stopClockTimer {
    [_clockTimer invalidate];
    [_clockTimer release];
    _clockTimer = nil;
}

- (void)startClockTimer {
    [self stopClockTimer];
    _clockTimer = [[NSTimer scheduledTimerWithTimeInterval:10.0
                                                    target:self
                                                  selector:@selector(updateClock)
                                                  userInfo:nil
                                                   repeats:YES] retain];
}

- (void)updateClock {
    if (!_clockLabel || !_clockFormatter) return;
    _clockLabel.text = [_clockFormatter stringFromDate:[NSDate date]];
}

- (void)applyBackdropColor:(UIColor *)dominant {
    if (!_backdropView) return;
    if (!dominant) dominant = [ELTheme dominantBackdropColorFromImage:nil];
    UIColor *darkTop = [ELTheme darkerShadeOfColor:dominant factor:0.42f];
    UIColor *darkBot = [ELTheme darkerShadeOfColor:dominant factor:0.14f];
    self.view.backgroundColor = darkBot;
    _backdropView.image = [ELTheme verticalGradientImageWithHeight:460.0f
                                                          topColor:darkTop
                                                          midColor:nil
                                                       midLocation:0.0f
                                                       bottomColor:darkBot
                                                            opaque:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    UIColor *pillBg = [UIColor colorWithWhite:1.0f alpha:0.16f];
    UIColor *pillHi = [UIColor colorWithWhite:1.0f alpha:0.28f];
    UIColor *secondaryWhite = [UIColor colorWithWhite:1.0f alpha:0.70f];

    _backdropView = [[UIImageView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 460.0f)];
    _backdropView.contentMode = UIViewContentModeScaleToFill;
    _backdropView.opaque = YES;
    _backdropView.userInteractionEnabled = NO;
    [self.view addSubview:_backdropView];
    [self applyBackdropColor:nil];

    _clockFormatter = [[NSDateFormatter alloc] init];
    [_clockFormatter setDateFormat:@"h:mm a"];

    /* Top row: live clock + Dim toggle + Exit */
    _clockLabel = [self newLabelWithFrame:CGRectMake(16.0f, 10.0f, 152.0f, 36.0f)
                                     font:[UIFont boldSystemFontOfSize:26.0f]
                                    color:[UIColor whiteColor]
                                    align:UITextAlignmentLeft];

    UIImage *btnPill = [ELTheme stretchablePillImageWithHeight:30.0f color:pillBg];
    UIImage *btnPillHi = [ELTheme stretchablePillImageWithHeight:30.0f color:pillHi];

    _dimBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _dimBtn.frame = CGRectMake(174.0f, 13.0f, 70.0f, 30.0f);
    [_dimBtn setBackgroundImage:btnPill forState:UIControlStateNormal];
    [_dimBtn setBackgroundImage:btnPillHi forState:UIControlStateHighlighted];
    [_dimBtn setTitle:@"Dim" forState:UIControlStateNormal];
    [_dimBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _dimBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
    [_dimBtn addTarget:self action:@selector(onDimTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_dimBtn];

    UIButton *exitBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    exitBtn.frame = CGRectMake(250.0f, 13.0f, 54.0f, 30.0f);
    [exitBtn setBackgroundImage:btnPill forState:UIControlStateNormal];
    [exitBtn setBackgroundImage:btnPillHi forState:UIControlStateHighlighted];
    [exitBtn setTitle:@"Exit" forState:UIControlStateNormal];
    [exitBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    exitBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
    [exitBtn addTarget:self action:@selector(onExitTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:exitBtn];

    /* Center: crisp album art, title, artist, thin progress bar */
    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(64.0f, 58.0f, 192.0f, 192.0f)];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.opaque = YES;
    _artView.backgroundColor = [ELTheme surfaceColor];
    _artView.image = [ELTheme placeholderArtImage];
    [self.view addSubview:_artView];

    _titleLabel = [self newLabelWithFrame:CGRectMake(20.0f, 258.0f, 280.0f, 24.0f)
                                     font:[UIFont boldSystemFontOfSize:18.0f]
                                    color:[UIColor whiteColor]
                                    align:UITextAlignmentCenter];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;

    _artistLabel = [self newLabelWithFrame:CGRectMake(20.0f, 283.0f, 280.0f, 18.0f)
                                      font:[UIFont systemFontOfSize:13.0f]
                                     color:secondaryWhite
                                     align:UITextAlignmentCenter];
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;

    UIView *progressTrack = [[[UIView alloc] initWithFrame:CGRectMake(24.0f, 309.0f, kDockProgressWidth, 3.0f)] autorelease];
    progressTrack.backgroundColor = [UIColor colorWithWhite:1.0f alpha:0.22f];
    [self.view addSubview:progressTrack];

    _progressFill = [[UIView alloc] initWithFrame:CGRectMake(24.0f, 309.0f, 0.0f, 3.0f)];
    _progressFill.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:_progressFill];

    _elapsedLabel = [self newLabelWithFrame:CGRectMake(24.0f, 315.0f, 70.0f, 14.0f)
                                       font:[UIFont systemFontOfSize:10.0f]
                                      color:secondaryWhite
                                      align:UITextAlignmentLeft];
    _elapsedLabel.text = @"0:00";

    _durationLabel = [self newLabelWithFrame:CGRectMake(226.0f, 315.0f, 70.0f, 14.0f)
                                        font:[UIFont systemFontOfSize:10.0f]
                                       color:secondaryWhite
                                       align:UITextAlignmentRight];
    _durationLabel.text = @"0:00";

#if EL_FEATURE_LYRICS
    _lyricLabel = [self newLabelWithFrame:CGRectMake(20.0f, 333.0f, 280.0f, 36.0f)
                                     font:[UIFont boldSystemFontOfSize:13.0f]
                                    color:[UIColor colorWithWhite:1.0f alpha:0.86f]
                                    align:UITextAlignmentCenter];
    _lyricLabel.numberOfLines = 2;
    _lyricLabel.lineBreakMode = UILineBreakModeTailTruncation;
    _activeLyricIndex = -1;
#endif

    /* Bottom: oversized transport controls */
    _prevBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _prevBtn.frame = CGRectMake(34.0f, 384.0f, 68.0f, 58.0f);
    [_prevBtn setImage:[ELTheme iconPrevSize:34.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_prevBtn addTarget:self action:@selector(onPrev) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_prevBtn];

    _playPauseBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _playPauseBtn.frame = CGRectMake(124.0f, 376.0f, 72.0f, 72.0f);
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:72.0f color:pillBg] forState:UIControlStateNormal];
    [_playPauseBtn setBackgroundImage:[ELTheme circlePillImageWithSize:72.0f color:pillHi] forState:UIControlStateHighlighted];
    [_playPauseBtn addTarget:self action:@selector(onPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_playPauseBtn];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.center = _playPauseBtn.center;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _nextBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _nextBtn.frame = CGRectMake(218.0f, 384.0f, 68.0f, 58.0f);
    [_nextBtn setImage:[ELTheme iconNextSize:34.0f color:[UIColor whiteColor]] forState:UIControlStateNormal];
    [_nextBtn addTarget:self action:@selector(onNext) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_nextBtn];

    /* Full-screen touch-passthrough dimmer overlay */
    _dimOverlay = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 460.0f)];
    _dimOverlay.backgroundColor = [UIColor blackColor];
    _dimOverlay.alpha = 0.0f;
    _dimOverlay.hidden = YES;
    _dimOverlay.userInteractionEnabled = NO;
    [self.view addSubview:_dimOverlay];

    _lastElapsedSec = -1;
    _lastDurationSec = -1;
    _lastPlayIconState = -1;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refreshAll) name:ELPlayerStateChangedNotification object:nil];
    [nc addObserver:self selector:@selector(onProgressNotification:) name:ELPlayerProgressNotification object:nil];
    [nc addObserver:self selector:@selector(onAppDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(onAppWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];

    [self updateClock];
    [self refreshAll];
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopClockTimer];
    [_backdropView release]; _backdropView = nil;
    [_clockLabel release]; _clockLabel = nil;
    [_dimBtn release]; _dimBtn = nil;
    [_artView release]; _artView = nil;
    [_titleLabel release]; _titleLabel = nil;
    [_artistLabel release]; _artistLabel = nil;
    [_progressFill release]; _progressFill = nil;
    [_elapsedLabel release]; _elapsedLabel = nil;
    [_durationLabel release]; _durationLabel = nil;
#if EL_FEATURE_LYRICS
    [_lyricLabel release]; _lyricLabel = nil;
#endif
    [_prevBtn release]; _prevBtn = nil;
    [_playPauseBtn release]; _playPauseBtn = nil;
    [_nextBtn release]; _nextBtn = nil;
    [_spinner release]; _spinner = nil;
    [_dimOverlay release]; _dimOverlay = nil;
    [_clockFormatter release]; _clockFormatter = nil;
    [_loadedArtKey release]; _loadedArtKey = nil;
    [_loadedArtURL release]; _loadedArtURL = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    _isVisible = NO;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self releaseViewOutlets];
#if EL_FEATURE_LYRICS
    [_cachedLyrics release];
    [_lyricsVideoId release];
#endif
    [super dealloc];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    _isVisible = YES;
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self updateClock];
    [self startClockTimer];
    [self refreshAll];
}

- (void)viewWillDisappear:(BOOL)animated {
    _isVisible = NO;
    [self stopClockTimer];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [super viewWillDisappear:animated];
}

- (void)onAppDidBecomeActive {
    if (!_isVisible) return;
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self updateClock];
    [self startClockTimer];
}

- (void)onAppWillResignActive {
    [self stopClockTimer];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)onExitTapped {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)onDimTapped {
    _dimLevel = (_dimLevel + 1) % 3;
    static const CGFloat kDimAlphas[] = { 0.0f, 0.45f, 0.70f };
    static NSString *const kDimTitles[] = { @"Dim", @"Dim 45%", @"Dim 70%" };
    _dimOverlay.alpha = kDimAlphas[_dimLevel];
    _dimOverlay.hidden = (_dimLevel == 0);
    [_dimBtn setTitle:kDimTitles[_dimLevel] forState:UIControlStateNormal];
}

- (void)onPlayPause { [[ELAudioEngine sharedEngine] togglePlayPause]; }
- (void)onPrev      { [[ELAudioEngine sharedEngine] playPrevious]; }
- (void)onNext      { [[ELAudioEngine sharedEngine] playNext]; }

- (void)setArtworkImage:(UIImage *)img forKey:(NSString *)artKey {
    if (!img) img = [ELTheme placeholderArtImage];
    _artView.image = img;
    [_loadedArtKey release];
    _loadedArtKey = [artKey copy];
    [self applyBackdropColor:[ELTheme dominantBackdropColorFromImage:img cacheKey:artKey]];
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
        [self setArtworkImage:img forKey:localKey];
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

- (void)refreshArtworkForTrack:(ELTrack *)track {
    NSString *url = ([track.artURL length] > 0) ? track.artURL : track.thumbURL;
    NSString *localKey = ([track.videoId length] > 0)
        ? [NSString stringWithFormat:@"local:%@", track.videoId]
        : nil;
    if (localKey && [_loadedArtKey isEqualToString:localKey]) return;
    if ([url length] > 0 && [_loadedArtKey isEqualToString:url]) return;

    if ([url length] > 0) {
        UIImage *mem = [[ELImageCache sharedCache] memoryCachedImageForURL:url];
        if (mem) {
            [_loadedArtURL release];
            _loadedArtURL = [url copy];
            [self setArtworkImage:mem forKey:url];
            return;
        }
    }

#if EL_FEATURE_DOWNLOADS
    if ([track.videoId length] > 0 && [[ELDownloadManager sharedManager] isDownloaded:track.videoId]) {
        NSString *pendingKey = [NSString stringWithFormat:@"pending:local:%@", track.videoId];
        if (![_loadedArtKey isEqualToString:pendingKey]) {
            [_loadedArtURL release];
            _loadedArtURL = [url copy];
            [self setArtworkImage:[ELTheme placeholderArtImage] forKey:pendingKey];
            NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                                  track.videoId, @"videoId",
                                  url ? url : @"", @"url",
                                  nil];
            [NSThread detachNewThreadSelector:@selector(localArtWorker:) toTarget:self withObject:args];
        }
        return;
    }
#endif

    if ([url length] == 0) {
        if (![_loadedArtKey isEqualToString:@"placeholder"]) {
            [_loadedArtURL release];
            _loadedArtURL = nil;
            [self setArtworkImage:[ELTheme placeholderArtImage] forKey:@"placeholder"];
        }
        return;
    }

    NSString *pendingKey = [NSString stringWithFormat:@"pending:%@", url];
    if (![_loadedArtKey isEqualToString:pendingKey]) {
        [_loadedArtURL release];
        _loadedArtURL = [url copy];
        [self setArtworkImage:[ELTheme placeholderArtImage] forKey:pendingKey];
        [[ELImageCache sharedCache] loadImageForURL:url target:self action:@selector(onArtLoaded:)];
    }
}

- (void)onArtLoaded:(NSDictionary *)info {
    NSString *url = [info objectForKey:@"url"];
    UIImage *img = [info objectForKey:@"image"];
    if (img && _loadedArtURL && [url isEqualToString:_loadedArtURL]) {
        [self setArtworkImage:img forKey:url];
    }
}

#if EL_FEATURE_LYRICS
- (void)cachedLyricsWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSString *vid = [args objectForKey:@"videoId"];
    NSNumber *gen = [args objectForKey:@"gen"];
    NSArray *lines = [[ELLyricsClient sharedClient] cachedLyricsForVideoId:vid];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                vid ? vid : @"", @"videoId",
                                gen, @"gen",
                                nil];
    if (lines) [res setObject:lines forKey:@"lines"];
    [self performSelectorOnMainThread:@selector(onCachedLyricsLoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onCachedLyricsLoaded:(NSDictionary *)res {
    if ([[res objectForKey:@"gen"] integerValue] != _lyricsLoadGen) return;
    NSArray *lines = [res objectForKey:@"lines"];
    [_cachedLyrics release];
    _cachedLyrics = [lines retain];
    _activeLyricIndex = -1;
    [self updateActiveLyricForTime:[[ELAudioEngine sharedEngine] currentTime]];
}

- (void)refreshCachedLyricsForTrack:(ELTrack *)track {
    if (!track || [track.videoId length] == 0) {
        _lyricsLoadGen++;
        [_lyricsVideoId release]; _lyricsVideoId = nil;
        [_cachedLyrics release]; _cachedLyrics = nil;
        _activeLyricIndex = -1;
        _lyricLabel.text = @"";
        return;
    }
    if (_lyricsVideoId && [_lyricsVideoId isEqualToString:track.videoId]) return;

    _lyricsLoadGen++;
    [_lyricsVideoId release];
    _lyricsVideoId = [track.videoId copy];
    [_cachedLyrics release];
    _cachedLyrics = nil;
    _activeLyricIndex = -1;
    _lyricLabel.text = @"";
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          track.videoId, @"videoId",
                          [NSNumber numberWithInteger:_lyricsLoadGen], @"gen",
                          nil];
    [NSThread detachNewThreadSelector:@selector(cachedLyricsWorker:) toTarget:self withObject:args];
}

- (void)updateActiveLyricForTime:(double)curTime {
    if (!_cachedLyrics || [_cachedLyrics count] == 0) return;
    ELLyricLine *first = [_cachedLyrics objectAtIndex:0];
    if (first.timeSeconds < 0.0) return;

    NSInteger found = -1;
    NSInteger count = (NSInteger)[_cachedLyrics count];
    for (NSInteger i = 0; i < count; i++) {
        ELLyricLine *line = [_cachedLyrics objectAtIndex:(NSUInteger)i];
        if (line.timeSeconds >= 0.0 && line.timeSeconds <= curTime + 0.25) {
            found = i;
        } else if (line.timeSeconds > curTime + 0.25) {
            break;
        }
    }
    if (found != _activeLyricIndex) {
        _activeLyricIndex = found;
        if (found >= 0 && found < count) {
            ELLyricLine *line = [_cachedLyrics objectAtIndex:(NSUInteger)found];
            _lyricLabel.text = line.text ? line.text : @"";
        } else {
            _lyricLabel.text = @"";
        }
    }
}
#endif

- (void)updateProgressWithCurrentTime:(double)cur duration:(double)dur {
    if (![self isViewLoaded] || !self.view.window) return;

    NSInteger durSec = (dur > 0.0) ? (NSInteger)dur : 0;
    if (durSec != _lastDurationSec) {
        _lastDurationSec = durSec;
        _durationLabel.text = [ELTrack formatSeconds:dur];
    }
    NSInteger curSec = (cur > 0.0) ? (NSInteger)cur : 0;
    if (curSec != _lastElapsedSec) {
        _lastElapsedSec = curSec;
        _elapsedLabel.text = [ELTrack formatSeconds:cur];
    }

    CGFloat frac = (dur > 0.0) ? (CGFloat)(cur / dur) : 0.0f;
    if (frac < 0.0f) frac = 0.0f;
    if (frac > 1.0f) frac = 1.0f;
    CGFloat targetW = floorf(kDockProgressWidth * frac);
    if (_progressFill.frame.size.width != targetW) {
        _progressFill.frame = CGRectMake(24.0f, 309.0f, targetW, 3.0f);
    }

#if EL_FEATURE_LYRICS
    [self updateActiveLyricForTime:cur];
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

- (void)refreshAll {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELTrack *track = [eng currentTrack];

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
            UIImage *icon = (iconState == 1)
                ? [ELTheme iconPauseSize:36.0f color:[UIColor whiteColor]]
                : [ELTheme iconPlaySize:36.0f color:[UIColor whiteColor]];
            [_playPauseBtn setImage:icon forState:UIControlStateNormal];
        }
    }

    if (!track) {
        _titleLabel.text = @"Nothing Playing";
        _artistLabel.text = @"";
        return;
    }

    _titleLabel.text = track.title ? track.title : @"";
    _artistLabel.text = track.artist ? track.artist : @"";
    [self refreshArtworkForTrack:track];
#if EL_FEATURE_LYRICS
    [self refreshCachedLyricsForTrack:track];
#endif
    [self refreshProgress];
}

@end

#endif /* EL_FEATURE_DOCK_MODE */
