#import "ELDownloadsVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
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
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release]; _tableView = nil;
    [_emptyLabel release]; _emptyLabel = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_tracks release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:self.view.bounds
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    [self.view addSubview:_tableView];

    _emptyLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 130.0f, 264.0f, 60.0f)
                                                           text:@"No downloaded songs yet.\nTap the download arrow on any track to play 100% offline."
                                                       fontSize:14.0f
                                                          lines:3] retain];
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshDownloads) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:ELPlayerStateChangedNotification object:nil];

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
    _emptyLabel.hidden = ([_tracks count] > 0);
    _tableView.tableHeaderView = ([_tracks count] > 0) ? [self buildDownloadsHeader] : nil;
    self.navigationItem.title = ([_tracks count] > 0)
        ? [NSString stringWithFormat:@"Downloads (%lu)", (unsigned long)[_tracks count]]
        : @"Downloads";
    [_tableView reloadData];
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
        ELTrack *t = [_tracks objectAtIndex:indexPath.row];
        [[ELDownloadManager sharedManager] deleteDownloadForVideoId:t.videoId];
    }
}

@end
