#import "ELLibraryVC.h"
#import "ELAudioEngine.h"
#import "ELAuthManager.h"
#import "ELDownloadManager.h"
#import "ELImageCache.h"
#import "ELPlaylistVC.h"
#import "ELTheme.h"
#import "ELTrackCell.h"
#import "ELYouTubeClient.h"

@implementation ELLibraryVC

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"Library";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Library"
                                                         image:[ELTheme tabIconLibrary]
                                                           tag:2] autorelease];
        _playlists = [[NSArray alloc] init];
        _likedSongs = [[NSArray alloc] init];
        _filterButtons = [[NSMutableArray alloc] init];
        _filterMode = 0;
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release]; _tableView = nil;
    [_quickTilesHeader release]; _quickTilesHeader = nil;
    [_likedCountLabel release]; _likedCountLabel = nil;
    [_downloadsCountLabel release]; _downloadsCountLabel = nil;
    [_shuffleSubLabel release]; _shuffleSubLabel = nil;
    [_syncTitleLabel release]; _syncTitleLabel = nil;
    [_syncSubLabel release]; _syncSubLabel = nil;
    [_syncIconView release]; _syncIconView = nil;
    [_emptyFooter release]; _emptyFooter = nil;
    [_emptyLabel release]; _emptyLabel = nil;
    [_emptyActionBtn release]; _emptyActionBtn = nil;
    [_filterButtons removeAllObjects];
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_playlists release];
    [_likedSongs release];
    [_filterButtons release];
    [super dealloc];
}

- (UIButton *)createQuickTileAtFrame:(CGRect)frame
                                icon:(UIImage *)icon
                               title:(NSString *)title
                            subtitle:(NSString *)subtitle
                              action:(SEL)action
                           outTitle:(UILabel **)outTitle
                        outSubtitle:(UILabel **)outSubtitle
                        outIconView:(UIImageView **)outIconView {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [UIColor clearColor];

    UIImage *bgNorm = [ELTheme roundedRectImageWithSize:frame.size
                                                 radius:10.0f
                                              fillColor:[ELTheme surfaceColor]
                                            borderColor:[ELTheme separatorColor]];
    UIImage *bgHi = [ELTheme roundedRectImageWithSize:frame.size
                                               radius:10.0f
                                            fillColor:[ELTheme surfaceHighlightColor]
                                          borderColor:[ELTheme separatorColor]];
    [btn setBackgroundImage:bgNorm forState:UIControlStateNormal];
    [btn setBackgroundImage:bgHi forState:UIControlStateHighlighted];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UIImageView *iv = [[[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 17.0f, 22.0f, 22.0f)] autorelease];
    iv.image = icon;
    iv.contentMode = UIViewContentModeCenter;
    iv.userInteractionEnabled = NO;
    [btn addSubview:iv];
    if (outIconView) *outIconView = [iv retain];

    UILabel *tLbl = [[[UILabel alloc] initWithFrame:CGRectMake(42.0f, 10.0f, frame.size.width - 50.0f, 18.0f)] autorelease];
    tLbl.backgroundColor = [UIColor clearColor];
    tLbl.font = [UIFont boldSystemFontOfSize:14.0f];
    tLbl.textColor = [ELTheme textPrimaryColor];
    tLbl.lineBreakMode = UILineBreakModeTailTruncation;
    tLbl.text = title;
    tLbl.userInteractionEnabled = NO;
    [btn addSubview:tLbl];
    if (outTitle) *outTitle = [tLbl retain];

    UILabel *sLbl = [[[UILabel alloc] initWithFrame:CGRectMake(42.0f, 29.0f, frame.size.width - 50.0f, 16.0f)] autorelease];
    sLbl.backgroundColor = [UIColor clearColor];
    sLbl.font = [UIFont systemFontOfSize:11.0f];
    sLbl.textColor = [ELTheme textSecondaryColor];
    sLbl.lineBreakMode = UILineBreakModeTailTruncation;
    sLbl.text = subtitle;
    sLbl.userInteractionEnabled = NO;
    [btn addSubview:sLbl];
    if (outSubtitle) *outSubtitle = [sLbl retain];

    return btn;
}

- (void)updateFilterChips {
    UIImage *selBg = [ELTheme stretchablePillImageWithHeight:28.0f color:[ELTheme accentColor]];
    UIImage *unselBg = [ELTheme stretchablePillImageWithHeight:28.0f color:[ELTheme surfaceColor]];
    for (NSUInteger i = 0; i < [_filterButtons count]; i++) {
        UIButton *btn = [_filterButtons objectAtIndex:i];
        BOOL active = ((NSInteger)i == _filterMode);
        [btn setBackgroundImage:(active ? selBg : unselBg) forState:UIControlStateNormal];
        [btn setTitleColor:(active ? [UIColor whiteColor] : [ELTheme textSecondaryColor]) forState:UIControlStateNormal];
    }
}

- (void)onFilterChipTapped:(UIButton *)sender {
    _filterMode = sender.tag;
    [self updateFilterChips];
    [_tableView reloadData];
}

- (void)buildQuickTilesHeader {
    _quickTilesHeader = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 182.0f)];
    _quickTilesHeader.backgroundColor = [ELTheme backgroundColor];
    _quickTilesHeader.opaque = YES;

    UIButton *likedBtn = [self createQuickTileAtFrame:CGRectMake(12.0f, 12.0f, 143.0f, 56.0f)
                                                 icon:[ELTheme iconHeartFilledSize:20.0f color:[ELTheme accentColor]]
                                                title:@"Liked"
                                             subtitle:@"0 songs"
                                               action:@selector(onPlayLiked)
                                             outTitle:NULL
                                          outSubtitle:&_likedCountLabel
                                          outIconView:NULL];
    [_quickTilesHeader addSubview:likedBtn];

    UIButton *dlBtn = [self createQuickTileAtFrame:CGRectMake(165.0f, 12.0f, 143.0f, 56.0f)
                                              icon:[ELTheme iconCheckCircleSize:20.0f color:[ELTheme successColor]]
                                             title:@"Downloads"
                                          subtitle:@"0 offline"
                                            action:@selector(onOpenDownloads)
                                          outTitle:NULL
                                       outSubtitle:&_downloadsCountLabel
                                       outIconView:NULL];
    [_quickTilesHeader addSubview:dlBtn];

    UIButton *shufBtn = [self createQuickTileAtFrame:CGRectMake(12.0f, 78.0f, 143.0f, 56.0f)
                                                icon:[ELTheme iconShuffleSize:20.0f color:[ELTheme textPrimaryColor]]
                                               title:@"Shuffle"
                                            subtitle:@"Liked Songs"
                                              action:@selector(onShuffleQuick)
                                            outTitle:NULL
                                         outSubtitle:&_shuffleSubLabel
                                         outIconView:NULL];
    [_quickTilesHeader addSubview:shufBtn];

    UIButton *syncBtn = [self createQuickTileAtFrame:CGRectMake(165.0f, 78.0f, 143.0f, 56.0f)
                                                icon:[ELTheme iconSyncSize:20.0f color:[ELTheme textSecondaryColor]]
                                               title:@"Sync"
                                            subtitle:@"Tap to sync"
                                              action:@selector(onSyncTapped)
                                            outTitle:&_syncTitleLabel
                                         outSubtitle:&_syncSubLabel
                                         outIconView:&_syncIconView];
    [_quickTilesHeader addSubview:syncBtn];

    [_filterButtons removeAllObjects];
    NSArray *titles = [NSArray arrayWithObjects:@"All", @"Playlists", @"Liked", nil];
    CGFloat chipX = 12.0f;
    for (NSUInteger i = 0; i < [titles count]; i++) {
        NSString *t = [titles objectAtIndex:i];
        CGFloat w = (i == 0) ? 56.0f : ((i == 1) ? 84.0f : 68.0f);
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.frame = CGRectMake(chipX, 144.0f, w, 28.0f);
        chip.tag = (NSInteger)i;
        chip.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
        [chip setTitle:t forState:UIControlStateNormal];
        [chip addTarget:self action:@selector(onFilterChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_quickTilesHeader addSubview:chip];
        [_filterButtons addObject:chip];
        chipX += w + 8.0f;
    }
    [self updateFilterChips];
}

- (void)buildEmptyFooter {
    _emptyFooter = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 174.0f)];
    _emptyFooter.backgroundColor = [ELTheme backgroundColor];
    _emptyFooter.opaque = YES;

    UIImageView *cardBg = [[[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 4.0f, 296.0f, 160.0f)] autorelease];
    cardBg.image = [ELTheme roundedRectImageWithSize:cardBg.frame.size
                                              radius:12.0f
                                           fillColor:[ELTheme surfaceColor]
                                         borderColor:[ELTheme separatorColor]];
    cardBg.userInteractionEnabled = YES;
    [_emptyFooter addSubview:cardBg];

    UILabel *hdr = [[[UILabel alloc] initWithFrame:CGRectMake(16.0f, 14.0f, 264.0f, 22.0f)] autorelease];
    hdr.backgroundColor = [ELTheme surfaceColor];
    hdr.opaque = YES;
    hdr.font = [UIFont boldSystemFontOfSize:16.0f];
    hdr.textColor = [ELTheme textPrimaryColor];
    hdr.textAlignment = UITextAlignmentCenter;
    hdr.text = @"Your Music Library";
    [cardBg addSubview:hdr];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(16.0f, 40.0f, 264.0f, 56.0f)];
    _emptyLabel.backgroundColor = [ELTheme surfaceColor];
    _emptyLabel.opaque = YES;
    _emptyLabel.font = [UIFont systemFontOfSize:12.0f];
    _emptyLabel.textColor = [ELTheme textSecondaryColor];
    _emptyLabel.textAlignment = UITextAlignmentCenter;
    _emptyLabel.numberOfLines = 3;
    [cardBg addSubview:_emptyLabel];

    _emptyActionBtn = [[ELTheme pillButtonWithTitle:@"Sign In with Google"
                                              color:[ELTheme accentColor]
                                              frame:CGRectMake(48.0f, 106.0f, 200.0f, 38.0f)] retain];
    [_emptyActionBtn addTarget:self action:@selector(onEmptyAction) forControlEvents:UIControlEventTouchUpInside];
    [cardBg addSubview:_emptyActionBtn];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Sync"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(onSyncTapped)] autorelease];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 62.0f;
    _tableView.contentInset = UIEdgeInsetsMake(0.0f, 0.0f, 56.0f, 0.0f);
    _tableView.scrollIndicatorInsets = _tableView.contentInset;
    [ELTheme styleTableView:_tableView];
    [self.view addSubview:_tableView];

    [self buildQuickTilesHeader];
    [self buildEmptyFooter];
    _tableView.tableHeaderView = _quickTilesHeader;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshFromCache) name:ELLibraryUpdatedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshFromCache) name:ELAuthStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:ELPlayerStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];

    [self refreshFromCache];
}

- (void)reloadTable {
    [_tableView reloadData];
}

- (void)onPlaylistArtLoaded:(NSDictionary *)info {
    (void)info;
    [_tableView reloadData];
}

- (void)refreshVisibleCellsForVideoId:(NSString *)videoId {
    NSArray *cells = [_tableView visibleCells];
    for (UITableViewCell *cell in cells) {
        if ([cell isKindOfClass:[ELTrackCell class]]) {
            ELTrackCell *tc = (ELTrackCell *)cell;
            if (!videoId || [tc.videoId isEqualToString:videoId]) {
                [tc refreshDownloadState];
            }
        }
    }
}

- (void)onDownloadProgress:(NSNotification *)note {
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [self refreshVisibleCellsForVideoId:vid];
}

- (void)onDownloadsChanged {
    [self updateQuickTiles];
    [self refreshVisibleCellsForVideoId:nil];
}

- (void)updateQuickTiles {
    NSUInteger likedCount = [_likedSongs count];
    NSUInteger dlCount = [[[ELDownloadManager sharedManager] downloadedTracks] count];
    NSUInteger plCount = [_playlists count];
    BOOL signedIn = [[ELAuthManager sharedManager] isSignedIn];

    if (likedCount == 0) {
        _likedCountLabel.text = @"No songs";
    } else if (likedCount == 1) {
        _likedCountLabel.text = @"1 song";
    } else {
        _likedCountLabel.text = [NSString stringWithFormat:@"%lu songs", (unsigned long)likedCount];
    }

    if (dlCount == 0) {
        _downloadsCountLabel.text = @"None yet";
    } else {
        _downloadsCountLabel.text = [NSString stringWithFormat:@"%lu offline", (unsigned long)dlCount];
    }

    if (likedCount > 0) {
        _shuffleSubLabel.text = @"Liked Songs";
    } else if (dlCount > 0) {
        _shuffleSubLabel.text = @"Downloads";
    } else {
        _shuffleSubLabel.text = @"No tracks";
    }

    if (_syncing) {
        _syncTitleLabel.text = @"Syncing...";
        _syncSubLabel.text = @"Updating";
        _syncIconView.image = [ELTheme iconSyncSize:20.0f color:[ELTheme accentColor]];
    } else {
        _syncTitleLabel.text = @"Sync";
        _syncIconView.image = [ELTheme iconSyncSize:20.0f color:[ELTheme textSecondaryColor]];
        if (!signedIn) {
            _syncSubLabel.text = @"Sign in";
        } else if (plCount > 0) {
            _syncSubLabel.text = [NSString stringWithFormat:@"%lu %@",
                                  (unsigned long)plCount,
                                  (plCount == 1 ? @"playlist" : @"playlists")];
        } else if ([[ELYouTubeClient sharedClient] lastSyncTime] > 0) {
            _syncSubLabel.text = @"Up to date";
        } else {
            _syncSubLabel.text = @"Tap to sync";
        }
    }
}

- (void)onPlayLiked {
    if ([_likedSongs count] > 0) {
        [[ELAudioEngine sharedEngine] playTracks:_likedSongs startingAtIndex:0];
    } else {
        [[ELAudioEngine sharedEngine] postToast:@"No liked songs yet"];
    }
}

- (void)onOpenDownloads {
    self.tabBarController.selectedIndex = 3;
}

- (void)onShuffleQuick {
    if ([_likedSongs count] > 0) {
        [[ELAudioEngine sharedEngine] playTracksShuffled:_likedSongs];
    } else {
        NSArray *offline = [[ELDownloadManager sharedManager] downloadedTracks];
        if ([offline count] > 0) {
            [[ELAudioEngine sharedEngine] playTracksShuffled:offline];
        } else {
            [[ELAudioEngine sharedEngine] postToast:@"No tracks to shuffle"];
        }
    }
}

- (void)refreshFromCache {
    ELYouTubeClient *yt = [ELYouTubeClient sharedClient];
    [_playlists release];  _playlists = [[yt cachedPlaylists] retain];
    [_likedSongs release]; _likedSongs = [[yt cachedLikedSongs] retain];

    BOOL signedIn = [[ELAuthManager sharedManager] isSignedIn];
    BOOL hasContent = ([_playlists count] > 0 || [_likedSongs count] > 0);

    [self updateQuickTiles];
    _tableView.tableHeaderView = _quickTilesHeader;
    _tableView.tableFooterView = hasContent ? nil : _emptyFooter;

    if (!hasContent) {
        if (!signedIn) {
            _emptyLabel.text = @"Sign in with Google to sync your YouTube Music playlists and liked songs, or tap Search to play right away.";
            [_emptyActionBtn setTitle:@"Sign In with Google" forState:UIControlStateNormal];
        } else {
            _emptyLabel.text = @"Signed in! Tap Sync Now to pull your YouTube Music playlists and liked songs.";
            [_emptyActionBtn setTitle:@"Sync Library Now" forState:UIControlStateNormal];
        }
    }
    [_tableView reloadData];
}

- (void)onEmptyAction {
    if (![[ELAuthManager sharedManager] isSignedIn]) {
        self.tabBarController.selectedIndex = 4; /* Jump to Account tab */
    } else {
        [self onSyncTapped];
    }
}

- (void)onSyncTapped {
    if (![[ELAuthManager sharedManager] isSignedIn]) {
        self.tabBarController.selectedIndex = 4;
        return;
    }
    if (_syncing) return;
    _syncing = YES;
    [self updateQuickTiles];
    UIActivityIndicatorView *sp = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite] autorelease];
    [sp startAnimating];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithCustomView:sp] autorelease];
    [NSThread detachNewThreadSelector:@selector(syncWorker) toTarget:self withObject:nil];
}

- (void)syncWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSString *err = nil;
    BOOL ok = [[ELYouTubeClient sharedClient] syncLibraryWithError:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithBool:ok] forKey:@"ok"];
    if (err) [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onSyncFinished:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onSyncFinished:(NSDictionary *)res {
    _syncing = NO;
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Sync"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(onSyncTapped)] autorelease];
    [self refreshFromCache];
    if (![[res objectForKey:@"ok"] boolValue]) {
        NSString *err = [res objectForKey:@"error"];
        UIAlertView *av = [[[UIAlertView alloc] initWithTitle:@"Sync Failed"
                                                      message:(err ? err : @"Could not reach YouTube Music.")
                                                     delegate:nil
                                            cancelButtonTitle:@"OK"
                                            otherButtonTitles:nil] autorelease];
        [av show];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return (_filterMode == 2) ? 0 : [_playlists count];
    return (_filterMode == 1) ? 0 : [_likedSongs count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0 && (_filterMode == 2 || [_playlists count] == 0)) return 0.0f;
    if (section == 1 && (_filterMode == 1 || [_likedSongs count] == 0)) return 0.0f;
    return 28.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 28.0f)] autorelease];
    v.backgroundColor = [ELTheme surfaceColor];
    v.opaque = YES;
    UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectMake(14.0f, 0.0f, 292.0f, 28.0f)] autorelease];
    lbl.backgroundColor = [ELTheme surfaceColor];
    lbl.opaque = YES;
    lbl.font = [UIFont boldSystemFontOfSize:11.0f];
    lbl.textColor = [ELTheme textSecondaryColor];
    lbl.text = (section == 0) ? @"PLAYLISTS" : @"LIKED SONGS";
    [v addSubview:lbl];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *pid = @"ELPlaylistCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:pid];
        if (!cell) {
            cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:pid] autorelease];
            UIColor *bg = [ELTheme backgroundColor];
            cell.backgroundColor = bg;
            cell.opaque = YES;
            cell.contentView.backgroundColor = bg;
            cell.contentView.opaque = YES;
            UIView *sel = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
            sel.backgroundColor = [ELTheme surfaceHighlightColor];
            sel.opaque = YES;
            cell.selectedBackgroundView = sel;
            cell.textLabel.backgroundColor = bg;
            cell.textLabel.opaque = YES;
            cell.textLabel.textColor = [ELTheme textPrimaryColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:14.0f];
            cell.detailTextLabel.backgroundColor = bg;
            cell.detailTextLabel.opaque = YES;
            cell.detailTextLabel.textColor = [ELTheme textSecondaryColor];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0f];
            cell.imageView.backgroundColor = [UIColor clearColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        ELPlaylist *pl = [_playlists objectAtIndex:indexPath.row];
        cell.textLabel.text = pl.title;
        cell.detailTextLabel.text = ([pl.subtitle length] > 0) ? pl.subtitle : @"YouTube Music Playlist";
        UIImage *img = [[ELImageCache sharedCache] cachedImageForURL:pl.thumbURL];
        /* Pre-rendered rounded thumbnail: zero layer.cornerRadius/masksToBounds FBO stalls while scrolling */
        cell.imageView.image = img
            ? [ELTheme roundedThumbnailFromImage:img size:46.0f radius:6.0f cacheKey:pl.thumbURL]
            : [ELTheme roundedPlaceholderArtSize:46.0f radius:6.0f];
        if (!img && [pl.thumbURL length] > 0) {
            [[ELImageCache sharedCache] loadImageForURL:pl.thumbURL target:self action:@selector(onPlaylistArtLoaded:)];
        }
        return cell;
    }

    static NSString *cid = @"ELTrackCell";
    ELTrackCell *cell = (ELTrackCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[[ELTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid] autorelease];
    ELTrack *t = [_likedSongs objectAtIndex:indexPath.row];
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    [cell configureWithTrack:t isCurrent:(cur && [cur.videoId isEqualToString:t.videoId])];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        ELPlaylist *pl = [_playlists objectAtIndex:indexPath.row];
        ELPlaylistVC *vc = [[[ELPlaylistVC alloc] initWithPlaylist:pl] autorelease];
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        [[ELAudioEngine sharedEngine] playTracks:_likedSongs startingAtIndex:indexPath.row];
    }
}

@end
