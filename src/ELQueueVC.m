#import "ELQueueVC.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELTheme.h"
#import "ELTrackCell.h"

@implementation ELQueueVC

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release];
    [_headerLabel release];
    [_shuffleBtn release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];

    /* Sleek dark header bar */
    UIView *hdr = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 48.0f)] autorelease];
    hdr.backgroundColor = [ELTheme surfaceColor];
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

    _headerLabel = [[UILabel alloc] initWithFrame:CGRectMake(56.0f, 12.0f, 208.0f, 24.0f)];
    _headerLabel.backgroundColor = [ELTheme surfaceColor];
    _headerLabel.opaque = YES;
    _headerLabel.font = [UIFont boldSystemFontOfSize:16.0f];
    _headerLabel.textColor = [ELTheme textPrimaryColor];
    _headerLabel.textAlignment = UITextAlignmentCenter;
    [hdr addSubview:_headerLabel];

    _shuffleBtn = [[UIButton buttonWithType:UIButtonTypeCustom] retain];
    _shuffleBtn.frame = CGRectMake(270.0f, 6.0f, 42.0f, 36.0f);
    [_shuffleBtn addTarget:self action:@selector(onShuffleTapped) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:_shuffleBtn];

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0.0f, 48.0f, 320.0f, self.view.bounds.size.height - 48.0f)
                                              style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 62.0f;
    [ELTheme styleTableView:_tableView];
    [self.view addSubview:_tableView];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(refresh) name:ELPlayerStateChangedNotification object:nil];
#if EL_FEATURE_DOWNLOADS
    [nc addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [nc addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];
#endif

    [self refresh];
}

- (void)onClose {
    [self dismissModalViewControllerAnimated:YES];
}

- (void)onShuffleTapped {
    [[ELAudioEngine sharedEngine] toggleShuffle];
}

#if EL_FEATURE_DOWNLOADS
- (void)refreshVisibleCellsForVideoId:(NSString *)videoId {
    for (UITableViewCell *cell in [_tableView visibleCells]) {
        if (![cell isKindOfClass:[ELTrackCell class]]) continue;
        ELTrackCell *tc = (ELTrackCell *)cell;
        if (!videoId || [tc.videoId isEqualToString:videoId]) {
            [tc refreshDownloadState];
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
#endif

- (void)refresh {
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    NSArray *q = [eng queue];
    _headerLabel.text = [NSString stringWithFormat:@"Up Next (%lu)", (unsigned long)[q count]];
    UIColor *shufCol = eng.shuffleEnabled ? [ELTheme accentColor] : [ELTheme textSecondaryColor];
    [_shuffleBtn setImage:[ELTheme iconShuffleSize:22.0f color:shufCol] forState:UIControlStateNormal];
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [[[ELAudioEngine sharedEngine] queue] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"ELTrackCell";
    ELTrackCell *cell = (ELTrackCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[[ELTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid] autorelease];
    ELAudioEngine *eng = [ELAudioEngine sharedEngine];
    ELTrack *t = [eng.queue objectAtIndex:indexPath.row];
    [cell configureWithTrack:t isCurrent:((NSInteger)indexPath.row == eng.currentIndex)];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[ELAudioEngine sharedEngine] jumpToQueueIndex:indexPath.row];
}

@end
