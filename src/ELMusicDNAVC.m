#import "ELMusicDNAVC.h"

#if EL_FEATURE_MUSIC_DNA

#import "ELImageCache.h"
#import "ELMusicDNAClient.h"
#import "ELTheme.h"
#import "ELTrack.h"

@implementation ELMusicDNAVC

- (id)initWithTrack:(ELTrack *)track {
    self = [super init];
    if (self) {
        _track = [track retain];
    }
    return self;
}

- (void)releaseViewOutlets {
    _loadGen++;
    [_artView release]; _artView = nil;
    [_titleLabel release]; _titleLabel = nil;
    [_artistLabel release]; _artistLabel = nil;
    [_sourceBadge release]; _sourceBadge = nil;
    [_summaryView release]; _summaryView = nil;
    [_spinner release]; _spinner = nil;
    [_statusLabel release]; _statusLabel = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_track release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIColor *bg = [ELTheme backgroundColor];
    UIColor *surf = [ELTheme surfaceColor];
    self.view.backgroundColor = bg;

    /* Header bar */
    UIView *hdr = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 48.0f)] autorelease];
    hdr.backgroundColor = surf;
    hdr.opaque = YES;
    [self.view addSubview:hdr];

    UIView *hdrLine = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 47.0f, 320.0f, 1.0f)] autorelease];
    hdrLine.backgroundColor = [ELTheme separatorColor];
    hdrLine.opaque = YES;
    [hdr addSubview:hdrLine];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(8.0f, 6.0f, 40.0f, 36.0f);
    [closeBtn setImage:[ELTheme iconCloseSize:22.0f color:[ELTheme textPrimaryColor]] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:closeBtn];

    UILabel *hdrTitle = [[[UILabel alloc] initWithFrame:CGRectMake(56.0f, 12.0f, 208.0f, 24.0f)] autorelease];
    hdrTitle.backgroundColor = surf;
    hdrTitle.opaque = YES;
    hdrTitle.font = [UIFont boldSystemFontOfSize:16.0f];
    hdrTitle.textColor = [ELTheme textPrimaryColor];
    hdrTitle.textAlignment = UITextAlignmentCenter;
    hdrTitle.text = @"Music DNA";
    [hdr addSubview:hdrTitle];

    /* Track summary card */
    UIImageView *card = [[[UIImageView alloc] initWithFrame:CGRectMake(14.0f, 58.0f, 292.0f, 82.0f)] autorelease];
    card.image = [ELTheme stretchableCardImageWithColor:surf];
    card.backgroundColor = bg;
    card.opaque = YES;
    [self.view addSubview:card];

    _artView = [[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 11.0f, 60.0f, 60.0f)];
    _artView.contentMode = UIViewContentModeScaleToFill;
    _artView.backgroundColor = surf;
    _artView.opaque = YES;
    _artView.image = [ELTheme roundedPlaceholderArtSize:60.0f radius:8.0f matteColor:surf];
    [card addSubview:_artView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(82.0f, 12.0f, 198.0f, 20.0f)];
    _titleLabel.backgroundColor = surf;
    _titleLabel.opaque = YES;
    _titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
    _titleLabel.textColor = [ELTheme textPrimaryColor];
    _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
    _titleLabel.text = _track.title ? _track.title : @"Unknown Track";
    [card addSubview:_titleLabel];

    _artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(82.0f, 33.0f, 198.0f, 17.0f)];
    _artistLabel.backgroundColor = surf;
    _artistLabel.opaque = YES;
    _artistLabel.font = [UIFont systemFontOfSize:12.0f];
    _artistLabel.textColor = [ELTheme textSecondaryColor];
    _artistLabel.lineBreakMode = UILineBreakModeTailTruncation;
    _artistLabel.text = _track.artist ? _track.artist : @"";
    [card addSubview:_artistLabel];

    UIImageView *pillBg = [[[UIImageView alloc] initWithFrame:CGRectMake(82.0f, 54.0f, 86.0f, 18.0f)] autorelease];
    pillBg.image = [ELTheme stretchablePillImageWithHeight:18.0f color:[ELTheme surfaceHighlightColor]];
    [card addSubview:pillBg];

    _sourceBadge = [[UILabel alloc] initWithFrame:pillBg.frame];
    _sourceBadge.backgroundColor = [UIColor clearColor];
    _sourceBadge.font = [UIFont boldSystemFontOfSize:10.0f];
    _sourceBadge.textColor = [ELTheme accentColor];
    _sourceBadge.textAlignment = UITextAlignmentCenter;
    _sourceBadge.text = @"WIKIPEDIA";
    [card addSubview:_sourceBadge];

    /* Backstory text view */
    _summaryView = [[UITextView alloc] initWithFrame:CGRectMake(14.0f, 150.0f, 292.0f, self.view.bounds.size.height - 162.0f)];
    _summaryView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _summaryView.backgroundColor = bg;
    _summaryView.opaque = YES;
    _summaryView.editable = NO;
    _summaryView.font = [UIFont systemFontOfSize:14.0f];
    _summaryView.textColor = [ELTheme textPrimaryColor];
    _summaryView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _summaryView.hidden = YES;
    [self.view addSubview:_summaryView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    _spinner.center = CGPointMake(160.0f, 236.0f);
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(24.0f, 254.0f, 272.0f, 44.0f)];
    _statusLabel.backgroundColor = bg;
    _statusLabel.opaque = YES;
    _statusLabel.font = [UIFont systemFontOfSize:13.0f];
    _statusLabel.textColor = [ELTheme textSecondaryColor];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.text = @"Fetching track backstory...";
    [self.view addSubview:_statusLabel];

    [self loadArtwork];
    [self loadMusicDNA];
}

- (void)onClose {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)loadArtwork {
    if (!_track) return;
    NSString *url = ([_track.thumbURL length] > 0) ? _track.thumbURL : _track.artURL;
    UIColor *surf = [ELTheme surfaceColor];
    if ([url length] > 0) {
        UIImage *hit = [ELTheme cachedRoundedThumbnailForSize:60.0f radius:8.0f matteColor:surf cacheKey:url];
        if (hit) {
            _artView.image = hit;
            return;
        }
    }
    [[ELImageCache sharedCache] loadRoundedThumbnailForURL:url
                                                   videoId:_track.videoId
                                                      size:60.0f
                                                    radius:8.0f
                                                matteColor:surf
                                                    target:self
                                                    action:@selector(onArtLoaded:)];
}

- (void)onArtLoaded:(NSDictionary *)info {
    UIImage *img = [info objectForKey:@"image"];
    if (img && _artView) {
        _artView.image = img;
    }
}

- (void)loadMusicDNA {
    if (!_track) {
        _statusLabel.text = @"No track selected.";
        return;
    }
    _loadGen++;
    [_spinner startAnimating];
    _statusLabel.text = @"Fetching track backstory...";
    _statusLabel.hidden = NO;
    _summaryView.hidden = YES;

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          _track, @"track",
                          [NSNumber numberWithInteger:_loadGen], @"gen",
                          nil];
    [NSThread detachNewThreadSelector:@selector(dnaWorker:) toTarget:self withObject:args];
}

- (void)dnaWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    ELTrack *track = [args objectForKey:@"track"];
    NSNumber *gen = [args objectForKey:@"gen"];
    NSString *err = nil;
    NSDictionary *dna = [[ELMusicDNAClient sharedClient] fetchDNAForTrack:track error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:gen forKey:@"gen"];
    if (dna) [res setObject:dna forKey:@"dna"];
    if (err) [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onDNALoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onDNALoaded:(NSDictionary *)res {
    if ([[res objectForKey:@"gen"] integerValue] != _loadGen) return;
    [_spinner stopAnimating];
    NSDictionary *dna = [res objectForKey:@"dna"];
    NSString *err = [res objectForKey:@"error"];
    NSString *summary = [dna objectForKey:@"summary"];
    if ([summary length] > 0) {
        NSString *pageTitle = [dna objectForKey:@"title"];
        NSString *source = [dna objectForKey:@"source"];
        if ([source length] > 0) {
            _sourceBadge.text = [source uppercaseString];
        }
        _summaryView.text = ([pageTitle length] > 0)
            ? [NSString stringWithFormat:@"%@\n\n%@", pageTitle, summary]
            : summary;
        _summaryView.hidden = NO;
        _statusLabel.hidden = YES;
    } else {
        _summaryView.hidden = YES;
        _statusLabel.hidden = NO;
        _statusLabel.text = err ? err : @"No Wikipedia backstory found for this track.";
    }
}

@end

#endif /* EL_FEATURE_MUSIC_DNA */
