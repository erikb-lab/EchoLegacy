#import "ELPlaylistVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#import "ELTheme.h"
#import "ELTrackCell.h"
#import "ELYouTubeClient.h"

@implementation ELPlaylistVC

- (id)initWithPlaylist:(ELPlaylist *)playlist {
    self = [super init];
    if (self) {
        _playlist = [playlist retain];
        _tracks = [[NSArray alloc] init];
        self.title = playlist.title ? playlist.title : @"Playlist";
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_playlist release];
    [_tracks release];
    [_tableView release];
    [_spinner release];
    [_statusLabel release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 62.0f;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, 56, 0);
    _tableView.scrollIndicatorInsets = _tableView.contentInset;
    [ELTheme styleTableView:_tableView];
    [self.view addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = CGPointMake(160, 170);
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 200, 272, 44)];
    _statusLabel.backgroundColor = [UIColor clearColor];
    _statusLabel.textAlignment = UITextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont systemFontOfSize:13.0f];
    _statusLabel.textColor = [ELTheme textSecondaryColor];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadCells) name:ELPlayerStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];

    [_spinner startAnimating];
    [NSThread detachNewThreadSelector:@selector(loadPlaylistWorker) toTarget:self withObject:nil];
}

- (void)reloadCells {
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

- (void)onDownloadsChanged {
    [self refreshVisibleCellsForVideoId:nil];
}

- (void)onDownloadProgress:(NSNotification *)note {
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [self refreshVisibleCellsForVideoId:vid];
}

- (void)loadPlaylistWorker {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *err = nil;
    NSArray *list = [[ELYouTubeClient sharedClient] fetchTracksForPlaylistId:_playlist.playlistId error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    if (list) [res setObject:list forKey:@"tracks"];
    if (err)  [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onPlaylistLoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (UIView *)buildPlaylistHeader {
    UIView *hdr = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 78.0f)] autorelease];
    hdr.backgroundColor = [ELTheme backgroundColor];
    hdr.opaque = YES;

    UILabel *info = [[[UILabel alloc] initWithFrame:CGRectMake(14.0f, 6.0f, 292.0f, 18.0f)] autorelease];
    info.backgroundColor = [ELTheme backgroundColor];
    info.opaque = YES;
    info.font = [UIFont systemFontOfSize:12.0f];
    info.textColor = [ELTheme textSecondaryColor];
    info.text = [NSString stringWithFormat:@"%lu %@",
                 (unsigned long)[_tracks count],
                 ([_tracks count] == 1 ? @"track" : @"tracks")];
    [hdr addSubview:info];

    UIButton *playBtn = [ELTheme pillButtonWithTitle:@"Play"
                                               color:[ELTheme accentColor]
                                               frame:CGRectMake(12.0f, 30.0f, 92.0f, 36.0f)];
    [playBtn addTarget:self action:@selector(onPlayAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:playBtn];

    UIButton *shufBtn = [ELTheme pillButtonWithTitle:@"Shuffle"
                                               color:[ELTheme surfaceHighlightColor]
                                               frame:CGRectMake(112.0f, 30.0f, 92.0f, 36.0f)];
    [shufBtn addTarget:self action:@selector(onShuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:shufBtn];

    UIButton *dlBtn = [ELTheme pillButtonWithTitle:@"Save All"
                                             color:[ELTheme surfaceHighlightColor]
                                             frame:CGRectMake(212.0f, 30.0f, 96.0f, 36.0f)];
    [dlBtn addTarget:self action:@selector(onDownloadAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:dlBtn];

    return hdr;
}

- (void)onPlayAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:0];
}

- (void)onShuffleAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracksShuffled:_tracks];
}

- (void)onDownloadAll {
    if ([_tracks count] > 0) {
        [[ELDownloadManager sharedManager] downloadTracks:_tracks];
        [[ELAudioEngine sharedEngine] postToast:[NSString stringWithFormat:@"Queued %lu tracks", (unsigned long)[_tracks count]]];
    }
}

- (void)onPlaylistLoaded:(NSDictionary *)res {
    [_spinner stopAnimating];
    NSArray *list = [res objectForKey:@"tracks"];
    NSString *err = [res objectForKey:@"error"];
    if (list && [list count] > 0) {
        [_tracks release];
        _tracks = [list retain];
        _statusLabel.hidden = YES;
        _tableView.tableHeaderView = [self buildPlaylistHeader];
        [_tableView reloadData];
    } else {
        _statusLabel.text = err ? err : @"No playable tracks found in playlist.";
        _statusLabel.hidden = NO;
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [_tracks count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"ELTrackCell";
    ELTrackCell *cell = (ELTrackCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[[ELTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid] autorelease];
    ELTrack *t = [_tracks objectAtIndex:indexPath.row];
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    [cell configureWithTrack:t isCurrent:(cur && [cur.videoId isEqualToString:t.videoId])];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:indexPath.row];
}

@end
