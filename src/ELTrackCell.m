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
        self.backgroundColor = bg;
        self.opaque = YES;
        self.contentView.backgroundColor = bg;
        self.contentView.opaque = YES;

        UIView *selBg = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        selBg.backgroundColor = [ELTheme surfaceHighlightColor];
        selBg.opaque = YES;
        self.selectedBackgroundView = selBg;

        /* Pre-rendered 46x46 rounded thumbnail: zero cornerRadius+masksToBounds offscreen FBO stalls */
        _artView = [[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 8.0f, 46.0f, 46.0f)];
        _artView.contentMode = UIViewContentModeScaleToFill;
        _artView.backgroundColor = [UIColor clearColor];
        _artView.image = [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
        [self.contentView addSubview:_artView];

        /* Opaque labels matching cell background eliminate MBX Lite alpha-blending overdraw */
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(68.0f, 11.0f, 206.0f, 20.0f)];
        _titleLabel.backgroundColor = bg;
        _titleLabel.opaque = YES;
        _titleLabel.font = [UIFont boldSystemFontOfSize:14.0f];
        _titleLabel.textColor = [ELTheme textPrimaryColor];
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(68.0f, 32.0f, 206.0f, 17.0f)];
        _subtitleLabel.backgroundColor = bg;
        _subtitleLabel.opaque = YES;
        _subtitleLabel.font = [UIFont systemFontOfSize:12.0f];
        _subtitleLabel.textColor = [ELTheme textSecondaryColor];
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self.contentView addSubview:_subtitleLabel];

        _downloadBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
        _downloadBtn.frame = CGRectMake(278.0f, 12.0f, 36.0f, 38.0f);
        _downloadBtn.backgroundColor = bg;
        _downloadBtn.opaque = YES;
        _downloadBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10.0f];
        [_downloadBtn addTarget:self action:@selector(onDownloadTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView addSubview:_downloadBtn];
    }
    return self;
}

- (void)dealloc {
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
    UIColor *bg = active ? [ELTheme surfaceHighlightColor] : [ELTheme backgroundColor];
    _titleLabel.backgroundColor = bg;
    _subtitleLabel.backgroundColor = bg;
    _downloadBtn.backgroundColor = bg;
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

    /* Load album art: pre-clipped 46x46 rounded bitmap from local offline art or async TLS cache */
    UIImage *localArt = [[ELDownloadManager sharedManager] localArtImageForVideoId:track.videoId];
    if (localArt) {
        NSString *localKey = [NSString stringWithFormat:@"local:%@", track.videoId];
        _artView.image = [ELTheme roundedThumbnailFromImage:localArt size:46.0f radius:6.0f cacheKey:localKey];
        [_currentThumbURL release];
        _currentThumbURL = nil;
        return;
    }

    NSString *url = ([track.thumbURL length] > 0) ? track.thumbURL : track.artURL;
    [_currentThumbURL release];
    _currentThumbURL = [url copy];

    if ([url length] == 0) {
        _artView.image = [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
        return;
    }

    UIImage *cached = [[ELImageCache sharedCache] cachedImageForURL:url];
    if (cached) {
        _artView.image = [ELTheme roundedThumbnailFromImage:cached size:46.0f radius:6.0f cacheKey:url];
    } else {
        _artView.image = [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
        [[ELImageCache sharedCache] loadImageForURL:url target:self action:@selector(onArtLoaded:)];
    }
}

- (void)onArtLoaded:(NSDictionary *)info {
    NSString *url = [info objectForKey:@"url"];
    UIImage *img = [info objectForKey:@"image"];
    if (img && _currentThumbURL && [_currentThumbURL isEqualToString:url]) {
        _artView.image = [ELTheme roundedThumbnailFromImage:img size:46.0f radius:6.0f cacheKey:url];
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
