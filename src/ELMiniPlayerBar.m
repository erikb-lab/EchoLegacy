#import "ELMiniPlayerBar.h"
#import "ELAudioEngine.h"
#import "ELImageCache.h"
#import "ELTheme.h"
#if EL_FEATURE_LIKES
#import "ELYouTubeClient.h"
#endif

@implementation ELMiniPlayerBar
@synthesize delegate = _delegate;

- (UILabel *)newLabelWithFrame:(CGRect)frame font:(UIFont *)font color:(UIColor *)color bg:(UIColor *)bg {
    UILabel *lbl = [[UILabel alloc] initWithFrame:frame];
    lbl.backgroundColor = bg;
    lbl.opaque = YES;
    lbl.font = font;
    lbl.textColor = color;
    lbl.lineBreakMode = UILineBreakModeTailTruncation;
    lbl.userInteractionEnabled = NO;
    [self addSubview:lbl];
    return lbl;
}

- (UIButton *)newIconButtonWithFrame:(CGRect)frame bg:(UIColor *)bg action:(SEL)action {
    UIButton *btn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    btn.frame = frame;
    btn.backgroundColor = bg;
    btn.opaque = YES;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:btn];
    return btn;
}

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    UIColor *bg = [ELTheme surfaceColor];
    self.backgroundColor = bg;
    self.opaque = YES;

    UIView *topLine = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, frame.size.width, 2.0f)] autorelease];
    topLine.backgroundColor = [ELTheme separatorColor];
    topLine.opaque = YES;
    [self addSubview:topLine];

    _progressFill = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 0.0f, 2.0f)];
    _progressFill.backgroundColor = [ELTheme accentColor];
    _progressFill.opaque = YES;
    [self addSubview:_progressFill];

#if EL_FEATURE_LIKES
    CGFloat rightButtonsW = 88.0f;
#else
    CGFloat rightButtonsW = 48.0f;
#endif

    UIButton *tapArea = [UIButton buttonWithType:UIButtonTypeCustom];
    tapArea.frame = CGRectMake(0.0f, 2.0f, frame.size.width - rightButtonsW, frame.size.height - 2.0f);
    [tapArea addTarget:self action:@selector(onTapOpen) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:tapArea];

    /* Pre-rendered 36x36 rounded thumbnail (zero offscreen FBO clipping) */
    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(10.0f, 9.0f, 36.0f, 36.0f)];
    _artView.contentMode = UIViewContentModeScaleToFill;
    _artView.backgroundColor = bg;
    _artView.opaque = YES;
    _artView.image = [ELTheme roundedPlaceholderArtSize:36.0f radius:5.0f];
    _artView.userInteractionEnabled = NO;
    [self addSubview:_artView];

    CGFloat textW = frame.size.width - rightButtonsW - 56.0f;
    _titleLabel = [self newLabelWithFrame:CGRectMake(54.0f, 10.0f, textW, 18.0f)
                                     font:[UIFont boldSystemFontOfSize:13.0f]
                                    color:[ELTheme textPrimaryColor]
                                       bg:bg];
    _subtitleLabel = [self newLabelWithFrame:CGRectMake(54.0f, 28.0f, textW, 15.0f)
                                        font:[UIFont systemFontOfSize:11.0f]
                                       color:[ELTheme textSecondaryColor]
                                          bg:bg];

#if EL_FEATURE_LIKES
    _likeBtn = [self newIconButtonWithFrame:CGRectMake(frame.size.width - 86.0f, 8.0f, 36.0f, 38.0f)
                                         bg:bg
                                     action:@selector(onLikeTapped)];
#endif

    _playPauseBtn = [self newIconButtonWithFrame:CGRectMake(frame.size.width - 46.0f, 7.0f, 40.0f, 40.0f)
                                              bg:bg
                                          action:@selector(onPlayPause)];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.center = _playPauseBtn.center;
    _spinner.hidesWhenStopped = YES;
    [self addSubview:_spinner];

#if EL_FEATURE_LIKES
    _lastLikeVisualState = -1;
#endif
    _lastPlayIconState = -1;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refresh) name:ELPlayerStateChangedNotification object:nil];
    [nc addObserver:self selector:@selector(onProgressNotification:) name:ELPlayerProgressNotification object:nil];
#if EL_FEATURE_LIKES
    [nc addObserver:self selector:@selector(refreshLikeState) name:ELLibraryUpdatedNotification object:nil];
#endif

    [self refresh];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_progressFill release];
    [_artView release];
    [_titleLabel release];
    [_subtitleLabel release];
#if EL_FEATURE_LIKES
    [_likeBtn release];
    [_inFlightLikeVideoId release];
#endif
    [_playPauseBtn release];
    [_spinner release];
    [_loadedArtKey release];
    [_loadedArtURL release];
    [super dealloc];
}

- (void)onTapOpen {
    if (_delegate && [_delegate respondsToSelector:@selector(miniPlayerBarDidTapOpen:)]) {
        [_delegate miniPlayerBarDidTapOpen:self];
    }
}

- (void)onPlayPause {
    [[ELAudioEngine sharedEngine] togglePlayPause];
}

#if EL_FEATURE_LIKES
- (void)updateLikeVisual {
    NSInteger state = _isLiked ? 1 : 0;
    if (state == _lastLikeVisualState) return;
    _lastLikeVisualState = state;
    UIImage *img = _isLiked
        ? [ELTheme iconHeartFilledSize:18.0f color:[ELTheme accentColor]]
        : [ELTheme iconHeartOutlineSize:18.0f color:[ELTheme textSecondaryColor]];
    [_likeBtn setImage:img forState:UIControlStateNormal];
}

- (void)refreshLikeState {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track || [track.videoId length] == 0) {
        _isLiked = NO;
        [self updateLikeVisual];
        return;
    }
    if (_inFlightLikeVideoId && [_inFlightLikeVideoId isEqualToString:track.videoId]) {
        [self updateLikeVisual];
        return;
    }
    _isLiked = [[ELYouTubeClient sharedClient] isTrackLiked:track.videoId];
    [self updateLikeVisual];
}

- (void)onLikeTapped {
    ELTrack *track = [[ELAudioEngine sharedEngine] currentTrack];
    if (!track || [track.videoId length] == 0) return;
    if (_inFlightLikeVideoId && [_inFlightLikeVideoId isEqualToString:track.videoId]) return;

    BOOL prevLiked = _isLiked;
    BOOL targetLiked = !prevLiked;

    _isLiked = targetLiked;
    _likeRequestGen++;
    [_inFlightLikeVideoId release];
    _inFlightLikeVideoId = [track.videoId copy];
    [self updateLikeVisual];
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
            [self updateLikeVisual];
        }
        [[ELAudioEngine sharedEngine] postToast:(err ? err : @"Could not update Like")];
    } else {
        [self refreshLikeState];
    }
}
#endif

- (void)updateProgressWithCurrentTime:(double)cur duration:(double)dur {
    if (self.hidden || !self.window) return;
    CGFloat frac = (dur > 0.0) ? (CGFloat)(cur / dur) : 0.0f;
    if (frac < 0.0f) frac = 0.0f;
    if (frac > 1.0f) frac = 1.0f;
    CGFloat targetW = floorf(self.frame.size.width * frac);
    if (_progressFill.frame.size.width != targetW) {
        _progressFill.frame = CGRectMake(0.0f, 0.0f, targetW, 2.0f);
    }
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
    if (self.hidden || !self.window) return;
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    [self updateProgressWithCurrentTime:[eng currentTime] duration:[eng duration]];
}

- (void)refreshArtworkForTrack:(ELTrack *)track {
    NSString *url = ([track.thumbURL length] > 0) ? track.thumbURL : track.artURL;
    NSString *localKey = ([track.videoId length] > 0)
        ? [NSString stringWithFormat:@"local:%@", track.videoId]
        : @"";
    NSString *cacheKey = ([url length] > 0) ? url : localKey;

    if ([cacheKey length] == 0) {
        if (![_loadedArtKey isEqualToString:@"placeholder"]) {
            [_loadedArtKey release];
            _loadedArtKey = [@"placeholder" copy];
            [_loadedArtURL release];
            _loadedArtURL = nil;
            _artView.image = [ELTheme roundedPlaceholderArtSize:36.0f radius:5.0f];
        }
        return;
    }
    if ([_loadedArtKey isEqualToString:cacheKey]) return;

    /* O(1) RAM lookup for pre-rendered 36x36 rounded thumbnail first */
    UIImage *hit = [ELTheme cachedRoundedThumbnailForSize:36.0f radius:5.0f cacheKey:cacheKey];
    if (!hit && [localKey length] > 0 && ![localKey isEqualToString:cacheKey]) {
        hit = [ELTheme cachedRoundedThumbnailForSize:36.0f radius:5.0f cacheKey:localKey];
    }
    if (hit) {
        [_loadedArtKey release];
        _loadedArtKey = [cacheKey copy];
        [_loadedArtURL release];
        _loadedArtURL = [url copy];
        _artView.image = hit;
        return;
    }

    NSString *pendingKey = [NSString stringWithFormat:@"pending:%@", cacheKey];
    if ([_loadedArtKey isEqualToString:pendingKey]) return;

    [_loadedArtKey release];
    _loadedArtKey = [pendingKey copy];
    [_loadedArtURL release];
    _loadedArtURL = [url copy];
    _artView.image = [ELTheme roundedPlaceholderArtSize:36.0f radius:5.0f];
    [[ELImageCache sharedCache] loadRoundedThumbnailForURL:url
                                                   videoId:track.videoId
                                                      size:36.0f
                                                    radius:5.0f
                                                    target:self
                                                    action:@selector(onArtLoaded:)];
}

- (void)refresh {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELTrack *track = [eng currentTrack];
    if (!track) {
        self.hidden = YES;
        return;
    }
    self.hidden = NO;
    _titleLabel.text = track.title;

    if (eng.state == ELPlayerStateLoading) {
        _subtitleLabel.text = @"Buffering stream...";
        _playPauseBtn.hidden = YES;
        [_spinner startAnimating];
    } else if (eng.state == ELPlayerStateError) {
        _subtitleLabel.text = eng.lastError ? eng.lastError : @"Playback error";
        [_spinner stopAnimating];
        _playPauseBtn.hidden = NO;
        if (_lastPlayIconState != 2) {
            _lastPlayIconState = 2;
            [_playPauseBtn setImage:[ELTheme iconPlaySize:22.0f color:[ELTheme accentColor]] forState:UIControlStateNormal];
        }
    } else {
        _subtitleLabel.text = track.artist;
        [_spinner stopAnimating];
        _playPauseBtn.hidden = NO;
        NSInteger iconState = (eng.state == ELPlayerStatePlaying) ? 1 : 0;
        if (_lastPlayIconState != iconState) {
            _lastPlayIconState = iconState;
            UIImage *icon = (iconState == 1)
                ? [ELTheme iconPauseSize:22.0f color:[ELTheme textPrimaryColor]]
                : [ELTheme iconPlaySize:22.0f color:[ELTheme textPrimaryColor]];
            [_playPauseBtn setImage:icon forState:UIControlStateNormal];
        }
    }

    [self refreshArtworkForTrack:track];
#if EL_FEATURE_LIKES
    [self refreshLikeState];
#endif
    [self refreshProgress];
}

- (void)onArtLoaded:(NSDictionary *)info {
    UIImage *img = [info objectForKey:@"image"];
    if (!img) return;
    NSString *url = [info objectForKey:@"url"];
    NSString *vid = [info objectForKey:@"videoId"];
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    BOOL matchUrl = ([_loadedArtURL length] > 0 && [url length] > 0 && [_loadedArtURL isEqualToString:url]);
    BOOL matchVid = (cur && [cur.videoId length] > 0 && [vid length] > 0 && [cur.videoId isEqualToString:vid]);
    if (matchUrl || matchVid) {
        NSString *key = ([url length] > 0) ? url : [NSString stringWithFormat:@"local:%@", vid];
        [_loadedArtKey release];
        _loadedArtKey = [key copy];
        _artView.image = img;
    }
}

@end
