#import "ELHomeVC.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELTheme.h"
#import "ELTrackListHelper.h"
#import "ELYouTubeClient.h"

@implementation ELHomeVC

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"Home";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Home"
                                                         image:[ELTheme tabIconHome]
                                                           tag:0] autorelease];
        _moods = [[NSArray alloc] initWithObjects:@"All", @"Chill", @"Workout", @"Focus", @"Party", @"Energy", nil];
        _moodButtons = [[NSMutableArray alloc] init];
        _tracks = [[NSArray alloc] init];
        _selectedMoodIndex = 0;
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_moodScroll release]; _moodScroll = nil;
    [_moodButtons removeAllObjects];
    [_tableView release]; _tableView = nil;
    [_sectionHeader release]; _sectionHeader = nil;
    [_spinner release]; _spinner = nil;
    [_emptyLabel release]; _emptyLabel = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_moodButtons release];
    [_moods release];
    [_tracks release];
    [super dealloc];
}

- (void)updateMoodChips {
    UIImage *selBg = [ELTheme stretchablePillImageWithHeight:30.0f color:[ELTheme accentColor]];
    UIImage *unselBg = [ELTheme stretchablePillImageWithHeight:30.0f color:[ELTheme surfaceColor]];
    for (NSUInteger i = 0; i < [_moodButtons count]; i++) {
        UIButton *btn = [_moodButtons objectAtIndex:i];
        BOOL active = ((NSInteger)i == _selectedMoodIndex);
        [btn setBackgroundImage:(active ? selBg : unselBg) forState:UIControlStateNormal];
        [btn setTitleColor:(active ? [UIColor whiteColor] : [ELTheme textSecondaryColor]) forState:UIControlStateNormal];
    }
}

- (void)buildMoodChipsBar {
    _moodScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 46.0f)];
    _moodScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _moodScroll.backgroundColor = [ELTheme backgroundColor];
    _moodScroll.opaque = YES;
    _moodScroll.showsHorizontalScrollIndicator = NO;
    _moodScroll.showsVerticalScrollIndicator = NO;

    [_moodButtons removeAllObjects];
    CGFloat x = 12.0f;
    UIFont *chipFont = [UIFont boldSystemFontOfSize:13.0f];
    for (NSUInteger i = 0; i < [_moods count]; i++) {
        NSString *title = [_moods objectAtIndex:i];
        CGSize textSize = [title sizeWithFont:chipFont];
        CGFloat w = textSize.width + 26.0f;
        if (w < 54.0f) w = 54.0f;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(x, 8.0f, w, 30.0f);
        btn.tag = (NSInteger)i;
        btn.titleLabel.font = chipFont;
        [btn setTitle:title forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(onMoodTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_moodScroll addSubview:btn];
        [_moodButtons addObject:btn];
        x += w + 8.0f;
    }
    _moodScroll.contentSize = CGSizeMake(x + 4.0f, 46.0f);
    [self updateMoodChips];
    [self.view addSubview:_moodScroll];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    UILabel *navTitle = [[[UILabel alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 180.0f, 28.0f)] autorelease];
    navTitle.backgroundColor = [UIColor clearColor];
    navTitle.font = [UIFont boldSystemFontOfSize:18.0f];
    navTitle.textColor = [ELTheme textPrimaryColor];
    navTitle.textAlignment = UITextAlignmentCenter;
    navTitle.text = @"Echo Music";
    self.navigationItem.titleView = navTitle;

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Refresh"
                                                                               style:UIBarButtonItemStyleBordered
                                                                              target:self
                                                                              action:@selector(onRefreshTapped)] autorelease];

    [self buildMoodChipsBar];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:CGRectMake(0.0f, 46.0f, 320.0f, self.view.bounds.size.height - 46.0f)
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    [self.view addSubview:_tableView];

    _spinner = [[ELTrackListHelper createSpinnerAtCenter:CGPointMake(160.0f, 200.0f)] retain];
    [self.view addSubview:_spinner];

    _emptyLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 165.0f, 264.0f, 70.0f)
                                                           text:nil
                                                       fontSize:14.0f
                                                          lines:3] retain];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadTable) name:ELPlayerStateChangedNotification object:nil];
#if EL_FEATURE_DOWNLOADS
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];
#endif

    [self loadCurrentMood];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_needsRefresh) {
        _needsRefresh = NO;
        [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
#if EL_FEATURE_DOWNLOADS
        [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
#endif
    }
}

- (void)reloadTable {
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
}

#if EL_FEATURE_DOWNLOADS
- (void)onDownloadsChanged {
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
}

- (void)onDownloadProgress:(NSNotification *)note {
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:vid];
}
#endif

- (void)onMoodTapped:(UIButton *)sender {
    if (sender.tag == _selectedMoodIndex && [_tracks count] > 0) return;
    _selectedMoodIndex = sender.tag;
    [self updateMoodChips];
    [self loadCurrentMood];
}

- (void)onRefreshTapped {
    [self loadCurrentMood];
}

- (void)onPlayAllTapped {
    if ([_tracks count] > 0) {
        [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:0];
    }
}

- (void)loadCurrentMood {
    _loadToken++;
    _emptyLabel.hidden = YES;
    [_spinner startAnimating];

    NSString *mood = [_moods objectAtIndex:(NSUInteger)_selectedMoodIndex];
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          mood, @"mood",
                          [NSNumber numberWithInteger:_loadToken], @"token",
                          nil];
    [NSThread detachNewThreadSelector:@selector(loadMoodWorker:) toTarget:self withObject:args];
}

- (void)loadMoodWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.55];
    NSString *mood = [args objectForKey:@"mood"];
    NSNumber *tok = [args objectForKey:@"token"];
    NSString *err = nil;
    NSArray *tracks = [[ELYouTubeClient sharedClient] fetchHomeTracksForMood:mood error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:tok forKey:@"token"];
    if (tracks) [res setObject:tracks forKey:@"tracks"];
    if (err)    [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onMoodLoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onMoodLoaded:(NSDictionary *)res {
    if ([[res objectForKey:@"token"] integerValue] != _loadToken) return;
    [_spinner stopAnimating];
    NSArray *tracks = [res objectForKey:@"tracks"];
    NSString *err = [res objectForKey:@"error"];
    [_tracks release];
    if (tracks && [tracks count] > 0) {
        _tracks = [tracks retain];
        _emptyLabel.hidden = YES;
    } else {
        _tracks = [[NSArray alloc] init];
        _emptyLabel.text = err ? err : @"No quick picks available.\nTap Refresh to try again.";
        _emptyLabel.hidden = NO;
    }
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [_tracks count];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return ([_tracks count] > 0) ? 36.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if ([_tracks count] == 0) return nil;
    if (!_sectionHeader) {
        _sectionHeader = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 36.0f)];
        _sectionHeader.backgroundColor = [ELTheme backgroundColor];
        _sectionHeader.opaque = YES;

        UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectMake(14.0f, 4.0f, 200.0f, 28.0f)] autorelease];
        lbl.backgroundColor = [ELTheme backgroundColor];
        lbl.opaque = YES;
        lbl.font = [UIFont boldSystemFontOfSize:12.0f];
        lbl.textColor = [ELTheme textSecondaryColor];
        lbl.text = @"QUICK PICKS";
        [_sectionHeader addSubview:lbl];

        UIButton *playAllBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        playAllBtn.frame = CGRectMake(240.0f, 5.0f, 68.0f, 26.0f);
        [playAllBtn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:[ELTheme surfaceColor]] forState:UIControlStateNormal];
        [playAllBtn setBackgroundImage:[ELTheme stretchablePillImageWithHeight:26.0f color:[ELTheme surfaceHighlightColor]] forState:UIControlStateHighlighted];
        playAllBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.0f];
        [playAllBtn setTitle:@"Play all" forState:UIControlStateNormal];
        [playAllBtn setTitleColor:[ELTheme textPrimaryColor] forState:UIControlStateNormal];
        [playAllBtn addTarget:self action:@selector(onPlayAllTapped) forControlEvents:UIControlEventTouchUpInside];
        [_sectionHeader addSubview:playAllBtn];
    }
    return _sectionHeader;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_tracks objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:indexPath.row];
}

@end
