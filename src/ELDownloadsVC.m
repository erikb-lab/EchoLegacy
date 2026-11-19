#import "ELDownloadsVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#if EL_FEATURE_LOCAL_PLAYLISTS
#import "ELLocalPlaylistManager.h"
#import "ELLocalPlaylistVC.h"
#endif
#import "ELTheme.h"
#import "ELTrack.h"
#import "ELTrackListHelper.h"

@implementation ELDownloadsVC

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"Downloads";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Downloads"
                                                         image:[ELTheme tabIconDownloads]
                                                           tag:2] autorelease];
        _tracks = [[NSArray alloc] init];
#if EL_FEATURE_LOCAL_PLAYLISTS
        _localPlaylists = [[NSArray alloc] init];
        _showingNewPlaylistBar = NO;
#endif
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release]; _tableView = nil;
    [_emptyLabel release]; _emptyLabel = nil;
#if EL_FEATURE_LOCAL_PLAYLISTS
    [_newPlaylistBar release]; _newPlaylistBar = nil;
    [_newPlaylistField release]; _newPlaylistField = nil;
#endif
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_tracks release];
#if EL_FEATURE_LOCAL_PLAYLISTS
    [_localPlaylists release];
#endif
    [super dealloc];
}

#if EL_FEATURE_LOCAL_PLAYLISTS
- (void)buildNewPlaylistBar {
    _newPlaylistBar = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 48.0f)];
    _newPlaylistBar.backgroundColor = [ELTheme surfaceColor];
    _newPlaylistBar.opaque = YES;
    _newPlaylistBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _newPlaylistBar.hidden = YES;

    _newPlaylistField = [[UITextField alloc] initWithFrame:CGRectMake(10.0f, 9.0f, 168.0f, 30.0f)];
    _newPlaylistField.backgroundColor = [ELTheme backgroundColor];
    _newPlaylistField.opaque = YES;
    _newPlaylistField.textColor = [ELTheme textPrimaryColor];
    _newPlaylistField.font = [UIFont systemFontOfSize:14.0f];
    _newPlaylistField.placeholder = @"New playlist name...";
    _newPlaylistField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _newPlaylistField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _newPlaylistField.returnKeyType = UIReturnKeyDone;
    _newPlaylistField.delegate = self;
    [_newPlaylistBar addSubview:_newPlaylistField];

    UIButton *createBtn = [ELTheme pillButtonWithTitle:@"Create"
                                                 color:[ELTheme accentColor]
                                                 frame:CGRectMake(184.0f, 9.0f, 64.0f, 30.0f)];
    createBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [createBtn addTarget:self action:@selector(onCreatePlaylist) forControlEvents:UIControlEventTouchUpInside];
    [_newPlaylistBar addSubview:createBtn];

    UIButton *cancelBtn = [ELTheme pillButtonWithTitle:@"Cancel"
                                                 color:[ELTheme surfaceHighlightColor]
                                                 frame:CGRectMake(252.0f, 9.0f, 58.0f, 30.0f)];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [cancelBtn addTarget:self action:@selector(onCancelNewPlaylist) forControlEvents:UIControlEventTouchUpInside];
    [_newPlaylistBar addSubview:cancelBtn];

    [self.view addSubview:_newPlaylistBar];
}

- (void)layoutForNewPlaylistBar {
    CGFloat topY = _showingNewPlaylistBar ? 48.0f : 0.0f;
    _newPlaylistBar.hidden = !_showingNewPlaylistBar;
    _tableView.frame = CGRectMake(0.0f, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY);
}

- (void)onToggleNewPlaylistBar {
    if (_showingNewPlaylistBar) {
        [self onCancelNewPlaylist];
        return;
    }
    _showingNewPlaylistBar = YES;
    _newPlaylistField.text = @"";
    [self layoutForNewPlaylistBar];
    [_newPlaylistField becomeFirstResponder];
}

- (void)onCancelNewPlaylist {
    [_newPlaylistField resignFirstResponder];
    _showingNewPlaylistBar = NO;
    [self layoutForNewPlaylistBar];
}

- (void)onCreatePlaylist {
    NSString *trimmed = [_newPlaylistField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 0) {
        [[ELLocalPlaylistManager sharedManager] createPlaylistNamed:trimmed];
    }
    [self onCancelNewPlaylist];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self onCreatePlaylist];
    return YES;
}
#endif

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

#if EL_FEATURE_LOCAL_PLAYLISTS
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"+ Playlist"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(onToggleNewPlaylistBar)] autorelease];
#endif

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:self.view.bounds
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    [self.view addSubview:_tableView];

#if EL_FEATURE_LOCAL_PLAYLISTS
    [self buildNewPlaylistBar];
#endif

    _emptyLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 130.0f, 264.0f, 60.0f)
                                                           text:@"No downloaded songs yet.\nTap the download arrow on any track to play 100% offline."
                                                       fontSize:14.0f
                                                          lines:3] retain];
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshDownloads) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:ELPlayerStateChangedNotification object:nil];
#if EL_FEATURE_LOCAL_PLAYLISTS
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshDownloads) name:ELLocalPlaylistsChangedNotification object:nil];
#endif

    [self refreshDownloads];
}

- (void)reloadTable {
    [_tableView reloadData];
}

- (UIView *)buildDownloadsHeader {
    UIView *hdr = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 78.0f)] autorelease];
    hdr.backgroundColor = [ELTheme backgroundColor];
    hdr.opaque = YES;

    unsigned long long bytes = [[ELDownloadManager sharedManager] totalDownloadedBytes];
    double mb = (double)bytes / (1024.0 * 1024.0);
    UILabel *info = [[[UILabel alloc] initWithFrame:CGRectMake(14.0f, 6.0f, 292.0f, 18.0f)] autorelease];
    info.backgroundColor = [ELTheme backgroundColor];
    info.opaque = YES;
    info.font = [UIFont systemFontOfSize:12.0f];
    info.textColor = [ELTheme textSecondaryColor];
    info.text = [NSString stringWithFormat:@"%lu offline %@  •  %.1f MB stored locally",
                 (unsigned long)[_tracks count],
                 ([_tracks count] == 1 ? @"track" : @"tracks"),
                 mb];
    [hdr addSubview:info];

    UIButton *playBtn = [ELTheme pillButtonWithTitle:@"Play All"
                                               color:[ELTheme accentColor]
                                               frame:CGRectMake(14.0f, 30.0f, 140.0f, 36.0f)];
    [playBtn addTarget:self action:@selector(onPlayAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:playBtn];

    UIButton *shufBtn = [ELTheme pillButtonWithTitle:@"Shuffle"
                                               color:[ELTheme surfaceHighlightColor]
                                               frame:CGRectMake(166.0f, 30.0f, 140.0f, 36.0f)];
    [shufBtn addTarget:self action:@selector(onShuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:shufBtn];

    return hdr;
}

- (void)onPlayAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:0];
}

- (void)onShuffleAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracksShuffled:_tracks];
}

- (void)refreshDownloads {
    [_tracks release];
    _tracks = [[[ELDownloadManager sharedManager] downloadedTracks] retain];
#if EL_FEATURE_LOCAL_PLAYLISTS
    [_localPlaylists release];
    _localPlaylists = [[[ELLocalPlaylistManager sharedManager] playlists] retain];
    BOOL hasContent = ([_tracks count] > 0 || [_localPlaylists count] > 0);
#else
    BOOL hasContent = ([_tracks count] > 0);
#endif
    _emptyLabel.hidden = hasContent;
    _tableView.tableHeaderView = ([_tracks count] > 0) ? [self buildDownloadsHeader] : nil;
    self.navigationItem.title = ([_tracks count] > 0)
        ? [NSString stringWithFormat:@"Downloads (%lu)", (unsigned long)[_tracks count]]
        : @"Downloads";
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
#if EL_FEATURE_LOCAL_PLAYLISTS
    return 2;
#else
    return 1;
#endif
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
#if EL_FEATURE_LOCAL_PLAYLISTS
    if (section == 0) return [_localPlaylists count];
    return [_tracks count];
#else
    (void)section;
    return [_tracks count];
#endif
}

#if EL_FEATURE_LOCAL_PLAYLISTS
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return ([_localPlaylists count] > 0) ? 26.0f : 0.0f;
    return ([_localPlaylists count] > 0 && [_tracks count] > 0) ? 26.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0 && [_localPlaylists count] > 0) {
        return [ELTrackListHelper createSectionHeaderWithTitle:@"OFFLINE PLAYLISTS" height:26.0f];
    }
    if (section == 1 && [_localPlaylists count] > 0 && [_tracks count] > 0) {
        return [ELTrackListHelper createSectionHeaderWithTitle:@"DOWNLOADED SONGS" height:26.0f];
    }
    return nil;
}
#endif

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
#if EL_FEATURE_LOCAL_PLAYLISTS
    if (indexPath.section == 0) {
        static NSString *pid = @"ELLocalPlaylistCell";
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
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        ELLocalPlaylist *pl = [_localPlaylists objectAtIndex:indexPath.row];
        NSUInteger cnt = [pl.tracks count];
        cell.textLabel.text = pl.name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu %@",
                                     (unsigned long)cnt,
                                     (cnt == 1 ? @"song" : @"songs")];
        return cell;
    }
#endif
    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_tracks objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
#if EL_FEATURE_LOCAL_PLAYLISTS
    if (indexPath.section == 0) {
        ELLocalPlaylist *pl = [_localPlaylists objectAtIndex:indexPath.row];
        ELLocalPlaylistVC *vc = [[[ELLocalPlaylistVC alloc] initWithPlaylistId:pl.playlistId] autorelease];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
#endif
    [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
#if EL_FEATURE_LOCAL_PLAYLISTS
    if (indexPath.section == 0) {
        ELLocalPlaylist *pl = [_localPlaylists objectAtIndex:indexPath.row];
        [[ELLocalPlaylistManager sharedManager] deletePlaylistId:pl.playlistId];
        return;
    }
#endif
    ELTrack *t = [_tracks objectAtIndex:indexPath.row];
    [[ELDownloadManager sharedManager] deleteDownloadForVideoId:t.videoId];
}

@end
