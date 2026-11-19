#import "ELLocalPlaylistVC.h"

#if EL_FEATURE_LOCAL_PLAYLISTS

#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#import "ELLocalPlaylistManager.h"
#import "ELTheme.h"
#import "ELTrack.h"
#import "ELTrackListHelper.h"

/* Modal picker for adding downloaded tracks to a local offline playlist (iOS 4.1 compatible) */
@interface ELOfflineTrackPickerVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    NSString *_playlistId;
    NSString *_playlistName;
    NSMutableArray *_availableTracks;
    UITableView *_tableView;
}
- (id)initWithPlaylistId:(NSString *)playlistId
            playlistName:(NSString *)playlistName
         availableTracks:(NSArray *)tracks;
@end

@implementation ELOfflineTrackPickerVC

- (id)initWithPlaylistId:(NSString *)playlistId
            playlistName:(NSString *)playlistName
         availableTracks:(NSArray *)tracks {
    self = [super init];
    if (self) {
        _playlistId = [playlistId copy];
        _playlistName = [playlistName copy];
        _availableTracks = [[NSMutableArray alloc] initWithArray:tracks];
        self.title = @"Add Tracks";
    }
    return self;
}

- (void)releaseViewOutlets {
    [_tableView release]; _tableView = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_playlistId release];
    [_playlistName release];
    [_availableTracks release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Done"
                                                                               style:UIBarButtonItemStyleDone
                                                                              target:self
                                                                              action:@selector(onDoneTapped)] autorelease];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:self.view.bounds
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    _tableView.contentInset = UIEdgeInsetsZero;
    _tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
    [self.view addSubview:_tableView];
}

- (void)onDoneTapped {
    [self.navigationController dismissModalViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [_availableTracks count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_availableTracks objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ELTrack *t = [_availableTracks objectAtIndex:indexPath.row];
    BOOL added = [[ELLocalPlaylistManager sharedManager] addTrack:t toPlaylistId:_playlistId];
    if (added) {
        NSString *msg = [NSString stringWithFormat:@"Added to %@", _playlistName ? _playlistName : @"Playlist"];
        [[ELAudioEngine sharedEngine] postToast:msg];
    }
    [_availableTracks removeObjectAtIndex:indexPath.row];
    if ([_availableTracks count] == 0) {
        [self onDoneTapped];
    } else {
        [_tableView reloadData];
    }
}

@end

@implementation ELLocalPlaylistVC

- (id)initWithPlaylistId:(NSString *)playlistId {
    self = [super init];
    if (self) {
        _playlistId = [playlistId copy];
        _tracks = [[NSArray alloc] init];
        _showingRenameBar = NO;
        ELLocalPlaylist *pl = [[ELLocalPlaylistManager sharedManager] playlistWithId:_playlistId];
        self.title = (pl && [pl.name length] > 0) ? pl.name : @"Playlist";
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release]; _tableView = nil;
    [_emptyLabel release]; _emptyLabel = nil;
    [_playlistHeader release]; _playlistHeader = nil;
    [_playlistInfoLabel release]; _playlistInfoLabel = nil;
    [_renameBar release]; _renameBar = nil;
    [_renameField release]; _renameField = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_playlistId release];
    [_tracks release];
    [super dealloc];
}

- (void)buildRenameBar {
    _renameBar = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 48.0f)];
    _renameBar.backgroundColor = [ELTheme surfaceColor];
    _renameBar.opaque = YES;
    _renameBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _renameBar.hidden = YES;

    _renameField = [[UITextField alloc] initWithFrame:CGRectMake(10.0f, 9.0f, 174.0f, 30.0f)];
    _renameField.backgroundColor = [ELTheme backgroundColor];
    _renameField.opaque = YES;
    _renameField.textColor = [ELTheme textPrimaryColor];
    _renameField.font = [UIFont systemFontOfSize:14.0f];
    _renameField.placeholder = @"Playlist name...";
    _renameField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _renameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _renameField.returnKeyType = UIReturnKeyDone;
    _renameField.delegate = self;
    [_renameBar addSubview:_renameField];

    UIButton *saveBtn = [ELTheme pillButtonWithTitle:@"Save"
                                               color:[ELTheme accentColor]
                                               frame:CGRectMake(190.0f, 9.0f, 58.0f, 30.0f)];
    saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [saveBtn addTarget:self action:@selector(onConfirmRename) forControlEvents:UIControlEventTouchUpInside];
    [_renameBar addSubview:saveBtn];

    UIButton *cancelBtn = [ELTheme pillButtonWithTitle:@"Cancel"
                                                 color:[ELTheme surfaceHighlightColor]
                                                 frame:CGRectMake(252.0f, 9.0f, 58.0f, 30.0f)];
    cancelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
    [cancelBtn addTarget:self action:@selector(onCancelRename) forControlEvents:UIControlEventTouchUpInside];
    [_renameBar addSubview:cancelBtn];

    [self.view addSubview:_renameBar];
}

- (void)layoutForRenameBar {
    CGFloat topY = _showingRenameBar ? 48.0f : 0.0f;
    _renameBar.hidden = !_showingRenameBar;
    _tableView.frame = CGRectMake(0.0f, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Edit"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(onToggleEdit)] autorelease];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:self.view.bounds
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    [self.view addSubview:_tableView];

    [self buildRenameBar];

    _emptyLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 150.0f, 264.0f, 60.0f)
                                                           text:@"This playlist is empty.\nTap + Add to add downloaded songs."
                                                       fontSize:14.0f
                                                          lines:3] retain];
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPlaylistChanged) name:ELLocalPlaylistsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:ELPlayerStateChangedNotification object:nil];

    [self refreshPlaylist];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_needsRefresh) {
        _needsRefresh = NO;
        [self refreshPlaylist];
    }
}

- (void)onPlaylistChanged {
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [self refreshPlaylist];
}

- (void)reloadTable {
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
}

- (UIView *)buildPlaylistHeader {
    if (!_playlistHeader) {
        _playlistHeader = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 78.0f)];
        _playlistHeader.backgroundColor = [ELTheme backgroundColor];
        _playlistHeader.opaque = YES;

        _playlistInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(14.0f, 6.0f, 292.0f, 18.0f)];
        _playlistInfoLabel.backgroundColor = [ELTheme backgroundColor];
        _playlistInfoLabel.opaque = YES;
        _playlistInfoLabel.font = [UIFont systemFontOfSize:12.0f];
        _playlistInfoLabel.textColor = [ELTheme textSecondaryColor];
        [_playlistHeader addSubview:_playlistInfoLabel];

        UIButton *playBtn = [ELTheme pillButtonWithTitle:@"Play"
                                                   color:[ELTheme accentColor]
                                                   frame:CGRectMake(12.0f, 30.0f, 64.0f, 36.0f)];
        playBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
        [playBtn addTarget:self action:@selector(onPlayAll) forControlEvents:UIControlEventTouchUpInside];
        [_playlistHeader addSubview:playBtn];

        UIButton *shufBtn = [ELTheme pillButtonWithTitle:@"Shuffle"
                                                   color:[ELTheme surfaceHighlightColor]
                                                   frame:CGRectMake(82.0f, 30.0f, 70.0f, 36.0f)];
        shufBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
        [shufBtn addTarget:self action:@selector(onShuffleAll) forControlEvents:UIControlEventTouchUpInside];
        [_playlistHeader addSubview:shufBtn];

        UIButton *addBtn = [ELTheme pillButtonWithTitle:@"+ Add"
                                                  color:[ELTheme surfaceHighlightColor]
                                                  frame:CGRectMake(158.0f, 30.0f, 72.0f, 36.0f)];
        addBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
        [addBtn addTarget:self action:@selector(onAddTracks) forControlEvents:UIControlEventTouchUpInside];
        [_playlistHeader addSubview:addBtn];

        UIButton *renBtn = [ELTheme pillButtonWithTitle:@"Rename"
                                                  color:[ELTheme surfaceHighlightColor]
                                                  frame:CGRectMake(236.0f, 30.0f, 72.0f, 36.0f)];
        renBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12.0f];
        [renBtn addTarget:self action:@selector(onShowRename) forControlEvents:UIControlEventTouchUpInside];
        [_playlistHeader addSubview:renBtn];
    }

    NSUInteger count = [_tracks count];
    _playlistInfoLabel.text = [NSString stringWithFormat:@"%lu offline %@",
                               (unsigned long)count,
                               (count == 1 ? @"track" : @"tracks")];
    return _playlistHeader;
}

- (void)refreshPlaylist {
    ELLocalPlaylist *pl = [[ELLocalPlaylistManager sharedManager] playlistWithId:_playlistId];
    if (!pl) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.title = pl.name;
    [_tracks release];
    _tracks = [[NSArray alloc] initWithArray:pl.tracks];
    _emptyLabel.hidden = ([_tracks count] > 0);
    _tableView.tableHeaderView = [self buildPlaylistHeader];
    [_tableView reloadData];
}

- (void)onToggleEdit {
    BOOL editing = !_tableView.editing;
    [_tableView setEditing:editing animated:YES];
    self.navigationItem.rightBarButtonItem.title = editing ? @"Done" : @"Edit";
    self.navigationItem.rightBarButtonItem.style = editing ? UIBarButtonItemStyleDone : UIBarButtonItemStyleBordered;
}

- (void)onPlayAll {
    if ([_tracks count] > 0) {
        [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:0];
    } else {
        [[ELAudioEngine sharedEngine] postToast:@"Playlist is empty"];
    }
}

- (void)onShuffleAll {
    if ([_tracks count] > 0) {
        [[ELAudioEngine sharedEngine] playTracksShuffled:_tracks];
    } else {
        [[ELAudioEngine sharedEngine] postToast:@"Playlist is empty"];
    }
}

- (void)onAddTracks {
    NSArray *downloaded = [[ELDownloadManager sharedManager] downloadedTracks];
    if ([downloaded count] == 0) {
        [[ELAudioEngine sharedEngine] postToast:@"Download songs first to add to playlists"];
        return;
    }
    ELLocalPlaylistManager *pm = [ELLocalPlaylistManager sharedManager];
    NSMutableArray *available = [NSMutableArray array];
    for (ELTrack *t in downloaded) {
        if (![pm playlistId:_playlistId containsVideoId:t.videoId]) {
            [available addObject:t];
        }
    }
    if ([available count] == 0) {
        [[ELAudioEngine sharedEngine] postToast:@"All downloaded songs are already in this playlist"];
        return;
    }
    ELOfflineTrackPickerVC *picker = [[[ELOfflineTrackPickerVC alloc] initWithPlaylistId:_playlistId
                                                                            playlistName:self.title
                                                                         availableTracks:available] autorelease];
    UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:picker] autorelease];
    [ELTheme styleNavBar:nav.navigationBar];
    [self presentModalViewController:nav animated:YES];
}

- (void)onShowRename {
    _showingRenameBar = YES;
    _renameField.text = self.title;
    [self layoutForRenameBar];
    [_renameField becomeFirstResponder];
}

- (void)onCancelRename {
    [_renameField resignFirstResponder];
    _showingRenameBar = NO;
    [self layoutForRenameBar];
}

- (void)onConfirmRename {
    NSString *trimmed = [_renameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 0) {
        [[ELLocalPlaylistManager sharedManager] renamePlaylistId:_playlistId toName:trimmed];
    }
    [self onCancelRename];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self onConfirmRename];
    return YES;
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [_tracks count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_tracks objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        [[ELLocalPlaylistManager sharedManager] removeTrackAtIndex:(NSUInteger)indexPath.row
                                                    fromPlaylistId:_playlistId];
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    (void)tableView;
    [[ELLocalPlaylistManager sharedManager] moveTrackAtIndex:(NSUInteger)sourceIndexPath.row
                                                     toIndex:(NSUInteger)destinationIndexPath.row
                                                inPlaylistId:_playlistId];
}

@end

#endif
