#import "ELTrackCell.h"
#import "ELDownloadManager.h"
#import "ELImageCache.h"
#import "ELTheme.h"

@implementation ELTrackCell

- (NSString *)videoId {
    return _currentVideoId;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        UIColor *bg = [ELTheme backgroundColor];
        UIColor *cardBg = [ELTheme surfaceColor];
        self.backgroundColor = bg;
        self.opaque = YES;
        self.contentView.backgroundColor = bg;
        self.contentView.opaque = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        /* Stretchable rounded card surface: zero offscreen cornerRadius FBOs */
        _cardBgView = [[UIImageView alloc] initWithFrame:CGRectMake(10.0f, 3.0f, 300.0f, 56.0f)];
        _cardBgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardBgView.image = [ELTheme stretchableCardImageWithColor:cardBg];
        [self.contentView addSubview:_cardBgView];

        /* Pre-rendered 46x46 rounded thumbnail: zero cornerRadius+masksToBounds offscreen FBO stalls */
        _artView = [[UIImageView alloc] initWithFrame:CGRectMake(18.0f, 8.0f, 46.0f, 46.0f)];
        _artView.contentMode = UIViewContentModeScaleToFill;
        _artView.backgroundColor = [UIColor clearColor];
        _artView.image = [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
        [self.contentView addSubview:_artView];

        /* Opaque labels matching card surface eliminate MBX Lite alpha-blending overdraw */
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(74.0f, 12.0f, 194.0f, 19.0f)];
        _titleLabel.backgroundColor = cardBg;
        _titleLabel.opaque = YES;
        _titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
        _titleLabel.textColor = [ELTheme textPrimaryColor];
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(74.0f, 32.0f, 194.0f, 17.0f)];
        _subtitleLabel.backgroundColor = cardBg;
        _subtitleLabel.opaque = YES;
        _subtitleLabel.font = [UIFont systemFontOfSize:12.0f];
        _subtitleLabel.textColor = [ELTheme textSecondaryColor];
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self.contentView addSubview:_subtitleLabel];

        _downloadBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _downloadBtn.frame = CGRectMake(270.0f, 12.0f, 34.0f, 38.0f);
        _downloadBtn.backgroundColor = cardBg;
        _downloadBtn.opaque = YES;
        _downloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.0f];
        [_downloadBtn addTarget:self action:@selector(onDownloadTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_downloadBtn];

        _isActiveBg = NO;
        _bgInitialized = YES;
    }
    return self;
}

- (void)dealloc {
    [_cardBgView release];
    [_artView release];
    [_titleLabel release];
    [_subtitleLabel release];
    [_downloadBtn release];
    [_currentVideoId release];
    [_currentThumbURL release];
    [_track release];
    [super dealloc];
}

- (void)applyOpaqueBackgroundActive:(BOOL)active {
    if (_bgInitialized && _isActiveBg == active) {
        return;
    }
    _bgInitialized = YES;
    _isActiveBg = active;
    UIColor *cardBg = active ? [ELTheme surfaceHighlightColor] : [ELTheme surfaceColor];
    _cardBgView.image = [ELTheme stretchableCardImageWithColor:cardBg];
    _titleLabel.backgroundColor = cardBg;
    _subtitleLabel.backgroundColor = cardBg;
    _downloadBtn.backgroundColor = cardBg;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    [self applyOpaqueBackgroundActive:(highlighted || self.selected)];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    [self applyOpaqueBackgroundActive:(selected || self.highlighted)];
}

- (void)configureWithTrack:(ELTrack *)track isCurrent:(BOOL)isCurrent {
    [_track release];
    _track = [track retain];
    [_currentVideoId release];
    _currentVideoId = [track.videoId copy];

    _titleLabel.text = track.title;
    _titleLabel.textColor = isCurrent ? [ELTheme accentColor] : [ELTheme textPrimaryColor];

    if ([track.durationText length] > 0) {
        _subtitleLabel.text = [NSString stringWithFormat:@"%@  •  %@", track.artist, track.durationText];
    } else {
        _subtitleLabel.text = track.artist;
    }

    [self applyOpaqueBackgroundActive:(self.selected || self.highlighted)];
    [self refreshDownloadState];

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

    _artView.image = [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
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
    if (!_track) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if ([dm isDownloaded:_track.videoId]) {
        [_downloadBtn setTitle:nil forState:UIControlStateNormal];
        [_downloadBtn setImage:[ELTheme iconCheckSize:20.0f color:[ELTheme successColor]] forState:UIControlStateNormal];
    } else if ([dm isDownloading:_track.videoId]) {
        float pct = [dm progressForVideoId:_track.videoId] * 100.0f;
        [_downloadBtn setImage:nil forState:UIControlStateNormal];
        [_downloadBtn setTitle:[NSString stringWithFormat:@"%d%%", (int)pct] forState:UIControlStateNormal];
        [_downloadBtn setTitleColor:[ELTheme accentColor] forState:UIControlStateNormal];
    } else if ([dm isQueued:_track.videoId]) {
        [_downloadBtn setImage:nil forState:UIControlStateNormal];
        [_downloadBtn setTitle:@"•••" forState:UIControlStateNormal];
        [_downloadBtn setTitleColor:[ELTheme textSecondaryColor] forState:UIControlStateNormal];
    } else {
        [_downloadBtn setTitle:nil forState:UIControlStateNormal];
        [_downloadBtn setImage:[ELTheme iconDownloadSize:20.0f color:[ELTheme textSecondaryColor]] forState:UIControlStateNormal];
    }
}

- (void)onDownloadTapped {
    if (!_track) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if ([dm isDownloaded:_track.videoId]) {
        return;
    }
    if ([dm isDownloading:_track.videoId] || [dm isQueued:_track.videoId]) {
        [dm cancelDownloadForVideoId:_track.videoId];
    } else {
        [dm downloadTrack:_track];
    }
    [self refreshDownloadState];
}

@end
