#import "ELTrackCell.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELImageCache.h"
#import "ELTheme.h"

static UIFont *sTitleFont = nil;
static UIFont *sSubtitleFont = nil;
#if EL_FEATURE_DOWNLOADS
static UIFont *sDownloadFont = nil;
static UIImage *sIconCheck = nil;
static UIImage *sIconDownload = nil;
#endif
static UIImage *sCardNorm = nil;
static UIImage *sCardHi = nil;
static UIImage *sPlaceholder46 = nil;

static void el_track_cell_init_statics(void) {
    if (sTitleFont) return;
    sTitleFont = [[UIFont boldSystemFontOfSize:14.0f] retain];
    sSubtitleFont = [[UIFont systemFontOfSize:12.0f] retain];
    sCardNorm = [[ELTheme stretchableCardImageWithColor:[ELTheme surfaceColor]] retain];
    sCardHi = [[ELTheme stretchableCardImageWithColor:[ELTheme surfaceHighlightColor]] retain];
    sPlaceholder46 = [[ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f] retain];
#if EL_FEATURE_DOWNLOADS
    sDownloadFont = [[UIFont boldSystemFontOfSize:10.0f] retain];
    sIconCheck = [[ELTheme iconCheckSize:20.0f color:[ELTheme successColor]] retain];
    sIconDownload = [[ELTheme iconDownloadSize:20.0f color:[ELTheme textSecondaryColor]] retain];
#endif
}

@interface ELTrackCell (Drawing)
- (void)drawRowInRect:(CGRect)rect;
@end

/* Single opaque Tweetie/ABTableViewCell-style drawing view: eliminates 4 subviews/layers per row */
@interface ELTrackCellContentView : UIView {
    ELTrackCell *_cell; /* assign, non-retaining */
}
- (id)initWithFrame:(CGRect)frame cell:(ELTrackCell *)cell;
@end

@implementation ELTrackCellContentView

- (id)initWithFrame:(CGRect)frame cell:(ELTrackCell *)cell {
    self = [super initWithFrame:frame];
    if (self) {
        _cell = cell;
        self.opaque = YES;
        self.backgroundColor = [ELTheme backgroundColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    [_cell drawRowInRect:self.bounds];
}

@end

@implementation ELTrackCell

- (NSString *)videoId {
    return _currentVideoId;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        el_track_cell_init_statics();

        UIColor *bg = [ELTheme backgroundColor];
        self.backgroundColor = bg;
        self.opaque = YES;
        self.contentView.backgroundColor = bg;
        self.contentView.opaque = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _rowView = [[ELTrackCellContentView alloc] initWithFrame:self.contentView.bounds cell:self];
        [self.contentView addSubview:_rowView];

        /* Pre-rendered opaque 46x46 rounded thumbnail as sibling so async art swaps never redraw text */
        _artView = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 8.0f, 46.0f, 46.0f)];
        _artView.contentMode = UIViewContentModeScaleToFill;
        _artView.backgroundColor = [ELTheme surfaceColor];
        _artView.opaque = YES;
        _artView.image = sPlaceholder46;
        [self.contentView addSubview:_artView];

#if EL_FEATURE_DOWNLOADS
        /* Lightweight hit-test target only (no title/image/background) */
        _downloadHitBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _downloadHitBtn.frame = CGRectMake(self.contentView.bounds.size.width - 50.0f, 8.0f, 40.0f, 46.0f);
        _downloadHitBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [_downloadHitBtn addTarget:self action:@selector(onDownloadTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_downloadHitBtn];
        _dlState = -1;
        _dlPct = -1;
#endif

        _isActiveBg = NO;
        _isCurrent = NO;
        _currentInitialized = NO;
    }
    return self;
}

- (void)dealloc {
    [_rowView release];
    [_artView release];
#if EL_FEATURE_DOWNLOADS
    [_downloadHitBtn release];
#endif
    [_currentVideoId release];
    [_currentThumbURL release];
    [_titleText release];
    [_subtitleText release];
    [_track release];
    [super dealloc];
}

- (void)drawRowInRect:(CGRect)rect {
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;

    [[ELTheme backgroundColor] setFill];
    UIRectFill(rect);

    UIImage *card = _isActiveBg ? sCardHi : sCardNorm;
    [card drawInRect:CGRectMake(10.0f, 3.0f, w - 20.0f, h - 6.0f)];

#if EL_FEATURE_DOWNLOADS
    CGFloat labelW = w - 126.0f;
#else
    CGFloat labelW = w - 90.0f;
#endif
    if (labelW < 40.0f) labelW = 40.0f;

    if ([_titleText length] > 0) {
        [(_isCurrent ? [ELTheme accentColor] : [ELTheme textPrimaryColor]) set];
        [_titleText drawInRect:CGRectMake(74.0f, 12.0f, labelW, 19.0f)
                      withFont:sTitleFont
                 lineBreakMode:UILineBreakModeTailTruncation];
    }

    if ([_subtitleText length] > 0) {
        [[ELTheme textSecondaryColor] set];
        [_subtitleText drawInRect:CGRectMake(74.0f, 32.0f, labelW, 17.0f)
                         withFont:sSubtitleFont
                    lineBreakMode:UILineBreakModeTailTruncation];
    }

#if EL_FEATURE_DOWNLOADS
    CGFloat btnX = w - 50.0f;
    if (_dlState == ELDownloadStateDownloaded) {
        [sIconCheck drawInRect:CGRectMake(btnX + 7.0f, 21.0f, 20.0f, 20.0f)];
    } else if (_dlState == ELDownloadStateDownloading) {
        [[ELTheme accentColor] set];
        NSString *pctStr = [NSString stringWithFormat:@"%ld%%", (long)_dlPct];
        [pctStr drawInRect:CGRectMake(btnX, 24.0f, 34.0f, 14.0f)
                  withFont:sDownloadFont
             lineBreakMode:UILineBreakModeClip
                 alignment:UITextAlignmentCenter];
    } else if (_dlState == ELDownloadStateQueued) {
        [[ELTheme textSecondaryColor] set];
        [@"•••" drawInRect:CGRectMake(btnX, 24.0f, 34.0f, 14.0f)
                  withFont:sDownloadFont
             lineBreakMode:UILineBreakModeClip
                 alignment:UITextAlignmentCenter];
    } else {
        [sIconDownload drawInRect:CGRectMake(btnX + 7.0f, 21.0f, 20.0f, 20.0f)];
    }
#endif
}

- (void)applyActiveState:(BOOL)active {
    if (_isActiveBg == active) return;
    _isActiveBg = active;
    _artView.backgroundColor = active ? [ELTheme surfaceHighlightColor] : [ELTheme surfaceColor];
    [_rowView setNeedsDisplay];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    [self applyActiveState:(highlighted || self.selected)];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    [self applyActiveState:(selected || self.highlighted)];
}

- (void)setCurrent:(BOOL)isCurrent {
    if (_currentInitialized && _isCurrent == isCurrent) {
        return;
    }
    _currentInitialized = YES;
    _isCurrent = isCurrent;
    [_rowView setNeedsDisplay];
}

- (void)configureWithTrack:(ELTrack *)track isCurrent:(BOOL)isCurrent {
    [_track release];
    _track = [track retain];
    [_currentVideoId release];
    _currentVideoId = [track.videoId copy];

    BOOL dirty = NO;
    NSString *newTitle = track.title ? track.title : @"";
    if (![_titleText isEqualToString:newTitle]) {
        [_titleText release];
        _titleText = [newTitle copy];
        dirty = YES;
    }

    NSString *newSub = track.subtitleText ? track.subtitleText : @"";
    if (![_subtitleText isEqualToString:newSub]) {
        [_subtitleText release];
        _subtitleText = [newSub copy];
        dirty = YES;
    }

    if (!_currentInitialized || _isCurrent != isCurrent) {
        _currentInitialized = YES;
        _isCurrent = isCurrent;
        dirty = YES;
    }

    BOOL active = (self.selected || self.highlighted);
    if (_isActiveBg != active) {
        _isActiveBg = active;
        _artView.backgroundColor = active ? [ELTheme surfaceHighlightColor] : [ELTheme surfaceColor];
        dirty = YES;
    }

#if EL_FEATURE_DOWNLOADS
    float prog = 0.0f;
    ELDownloadState st = [[ELDownloadManager sharedManager] stateForVideoId:_track.videoId progress:&prog];
    NSInteger pct = (st == ELDownloadStateDownloading) ? (NSInteger)(prog * 100.0f) : -1;
    if (_dlState != (NSInteger)st || _dlPct != pct) {
        _dlState = (NSInteger)st;
        _dlPct = pct;
        dirty = YES;
    }
#endif

    if (dirty) {
        [_rowView setNeedsDisplay];
    }

    /* O(1) RAM-only rounded thumbnail lookup: zero main-thread disk stat(), JPEG decode, or CG context render */
    NSString *url = ([track.thumbURL length] > 0) ? track.thumbURL : track.artURL;
    [_currentThumbURL release];
    _currentThumbURL = [url copy];

    NSString *localKey = ([track.videoId length] > 0)
        ? [NSString stringWithFormat:@"local:%@", track.videoId]
        : @"";
    NSString *cacheKey = ([url length] > 0) ? url : localKey;

    UIImage *hit = nil;
    if ([cacheKey length] > 0) {
        hit = [ELTheme cachedRoundedThumbnailForSize:46.0f radius:6.0f cacheKey:cacheKey];
    }
    if (!hit && [localKey length] > 0 && ![localKey isEqualToString:cacheKey]) {
        hit = [ELTheme cachedRoundedThumbnailForSize:46.0f radius:6.0f cacheKey:localKey];
    }

    if (hit) {
        _artView.image = hit;
        return;
    }

    _artView.image = sPlaceholder46;
    [[ELImageCache sharedCache] loadRoundedThumbnailForURL:url
                                                   videoId:track.videoId
                                                      size:46.0f
                                                    radius:6.0f
                                                    target:self
                                                    action:@selector(onArtLoaded:)];
}

- (void)onArtLoaded:(NSDictionary *)info {
    UIImage *img = [info objectForKey:@"image"];
    if (!img) return;
    NSString *vid = [info objectForKey:@"videoId"];
    NSString *url = [info objectForKey:@"url"];
    BOOL matchVid = ([_currentVideoId length] > 0 && [vid length] > 0 && [_currentVideoId isEqualToString:vid]);
    BOOL matchUrl = ([_currentThumbURL length] > 0 && [url length] > 0 && [_currentThumbURL isEqualToString:url]);
    if (matchVid || matchUrl) {
        _artView.image = img;
    }
}

- (void)refreshDownloadState {
#if EL_FEATURE_DOWNLOADS
    if (!_track) return;
    float prog = 0.0f;
    ELDownloadState st = [[ELDownloadManager sharedManager] stateForVideoId:_track.videoId progress:&prog];
    NSInteger pct = (st == ELDownloadStateDownloading) ? (NSInteger)(prog * 100.0f) : -1;
    if (_dlState == (NSInteger)st && _dlPct == pct) {
        return;
    }
    _dlState = (NSInteger)st;
    _dlPct = pct;
    [_rowView setNeedsDisplay];
#endif
}

#if EL_FEATURE_DOWNLOADS
- (void)onDownloadTapped {
    if (!_track) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    ELDownloadState st = [dm stateForVideoId:_track.videoId progress:NULL];
    if (st == ELDownloadStateDownloaded) {
        return;
    }
    if (st == ELDownloadStateDownloading || st == ELDownloadStateQueued) {
        [dm cancelDownloadForVideoId:_track.videoId];
    } else {
        [dm downloadTrack:_track];
    }
    [self refreshDownloadState];
}
#endif

@end
