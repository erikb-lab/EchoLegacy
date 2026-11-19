#import "ELSearchVC.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELTheme.h"
#import "ELTrack.h"
#import "ELTrackListHelper.h"
#import "ELYouTubeClient.h"
#import <sys/stat.h>

enum {
    ELSearchModeHistory = 0,
    ELSearchModeSuggest = 1,
    ELSearchModeResults = 2
};

enum {
    ELSearchFilterAll = 0,
    ELSearchFilterSongs = 1,
    ELSearchFilterNoShorts = 2
};

static void el_harden_history_path(NSString *path, mode_t mode, BOOL isDirectory) {
    if ([path length] == 0) return;
    const char *fsPath = [path fileSystemRepresentation];
    if (fsPath) {
        chmod(fsPath, mode);
    }
    NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:(unsigned long)mode]
                                                                    forKey:NSFilePosixPermissions];
    if (!isDirectory) {
        [attrs setObject:NSFileProtectionComplete forKey:NSFileProtectionKey];
    }
    [[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:path error:nil];
}

static NSString *el_history_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    NSDictionary *dirAttrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700UL]
                                                         forKey:NSFilePosixPermissions];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:dirAttrs
                                                    error:nil];
    el_harden_history_path(dir, 0700, YES);
    return [dir stringByAppendingPathComponent:@"search_history.plist"];
}

static void el_save_history_array(NSArray *queries) {
    NSString *path = el_history_path();
    [queries writeToFile:path atomically:YES];
    el_harden_history_path(path, 0600, NO);
}

@implementation ELSearchVC

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"Search";
        self.tabBarItem = [[[UITabBarItem alloc] initWithTitle:@"Search"
                                                         image:[ELTheme tabIconSearch]
                                                           tag:1] autorelease];
        _results = [[NSArray alloc] init];
        _suggestions = [[NSArray alloc] init];
#if EL_FEATURE_DOWNLOADS
        _offlineMatches = [[NSArray alloc] init];
#endif
        _filterButtons = [[NSMutableArray alloc] init];
        _recentQueries = [[NSMutableArray alloc] init];
        _searchCache = [[NSMutableDictionary alloc] initWithCapacity:8];
        _searchCacheLRU = [[NSMutableArray alloc] initWithCapacity:8];
        _mode = ELSearchModeHistory;
        _filterMode = ELSearchFilterAll;
        _historyLoaded = NO;
    }
    return self;
}

- (void)loadHistoryIfNeeded {
    if (_historyLoaded) return;
    _historyLoaded = YES;
    NSString *histPath = el_history_path();
    if ([[NSFileManager defaultManager] fileExistsAtPath:histPath]) {
        el_harden_history_path(histPath, 0600, NO);
    }
    NSArray *saved = [NSArray arrayWithContentsOfFile:histPath];
    if ([saved isKindOfClass:[NSArray class]]) {
        for (id item in saved) {
            if ([item isKindOfClass:[NSString class]] && [item length] > 0 && [item length] <= 128) {
                [_recentQueries addObject:item];
                if ([_recentQueries count] >= 10) break;
            }
        }
    }
}

- (void)didReceiveMemoryWarning {
    [_searchCache removeAllObjects];
    [_searchCacheLRU removeAllObjects];
    [super didReceiveMemoryWarning];
}

- (void)releaseViewOutlets {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_searchBarContainer release]; _searchBarContainer = nil;
    [_searchField release]; _searchField = nil;
    [_filterBar release]; _filterBar = nil;
    [_filterButtons removeAllObjects];
    [_tableView release]; _tableView = nil;
    [_historyHeader release]; _historyHeader = nil;
    [_suggestionsHeader release]; _suggestionsHeader = nil;
#if EL_FEATURE_DOWNLOADS
    [_offlineHeader release]; _offlineHeader = nil;
    [_onlineHeader release]; _onlineHeader = nil;
#endif
    [_spinner release]; _spinner = nil;
    [_hintLabel release]; _hintLabel = nil;
}

- (void)viewDidUnload {
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    [self releaseViewOutlets];
    [_results release];
    [_suggestions release];
#if EL_FEATURE_DOWNLOADS
    [_offlineMatches release];
#endif
    [_filterButtons release];
    [_recentQueries release];
    [_searchCache release];
    [_searchCacheLRU release];
    [super dealloc];
}

- (void)updateFilterPills {
    UIImage *selBg = [ELTheme stretchablePillImageWithHeight:24.0f color:[ELTheme accentColor]];
    UIImage *unselBg = [ELTheme stretchablePillImageWithHeight:24.0f color:[ELTheme surfaceColor]];
    for (NSUInteger i = 0; i < [_filterButtons count]; i++) {
        UIButton *btn = [_filterButtons objectAtIndex:i];
        BOOL active = ((NSInteger)i == _filterMode);
        [btn setBackgroundImage:(active ? selBg : unselBg) forState:UIControlStateNormal];
        [btn setTitleColor:(active ? [UIColor whiteColor] : [ELTheme textSecondaryColor]) forState:UIControlStateNormal];
    }
}

- (void)buildFilterBar {
    _filterBar = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 54.0f, 320.0f, 34.0f)];
    _filterBar.backgroundColor = [ELTheme backgroundColor];
    _filterBar.opaque = YES;
    _filterBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    [_filterButtons removeAllObjects];
    NSArray *titles = [NSArray arrayWithObjects:@"All", @"Songs", @"No Shorts", nil];
    CGFloat x = 12.0f;
    UIFont *f = [UIFont boldSystemFontOfSize:11.5f];
    for (NSUInteger i = 0; i < [titles count]; i++) {
        NSString *t = [titles objectAtIndex:i];
        CGFloat w = (i == 0) ? 50.0f : ((i == 1) ? 68.0f : 86.0f);
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(x, 4.0f, w, 24.0f);
        btn.tag = (NSInteger)i;
        btn.titleLabel.font = f;
        [btn setTitle:t forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(onFilterTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_filterBar addSubview:btn];
        [_filterButtons addObject:btn];
        x += w + 8.0f;
    }
    [self updateFilterPills];
    [self.view addSubview:_filterBar];
}

- (void)onFilterTapped:(UIButton *)sender {
    if (sender.tag == _filterMode) return;
    _filterMode = sender.tag;
    [self updateFilterPills];
    NSString *q = [_searchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (_mode == ELSearchModeResults && [q length] > 0) {
        [self runSearchForQuery:q];
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    _searchBarContainer = [[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 54.0f)];
    _searchBarContainer.backgroundColor = [ELTheme backgroundColor];
    _searchBarContainer.opaque = YES;
    _searchBarContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIImageView *pillBg = [[[UIImageView alloc] initWithFrame:CGRectMake(12.0f, 8.0f, 296.0f, 38.0f)] autorelease];
    pillBg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    pillBg.image = [ELTheme stretchablePillImageWithHeight:38.0f color:[ELTheme surfaceColor]];
    pillBg.userInteractionEnabled = NO;
    [_searchBarContainer addSubview:pillBg];

    UIImageView *glassView = [[[UIImageView alloc] initWithFrame:CGRectMake(24.0f, 19.0f, 16.0f, 16.0f)] autorelease];
    glassView.image = [ELTheme iconSearchSize:16.0f color:[ELTheme textSecondaryColor]];
    glassView.contentMode = UIViewContentModeCenter;
    glassView.userInteractionEnabled = NO;
    [_searchBarContainer addSubview:glassView];

    _searchField = [[UITextField alloc] initWithFrame:CGRectMake(48.0f, 12.0f, 248.0f, 30.0f)];
    _searchField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _searchField.backgroundColor = [ELTheme surfaceColor];
    _searchField.opaque = YES;
    _searchField.textColor = [ELTheme textPrimaryColor];
    _searchField.font = [UIFont systemFontOfSize:14.0f];
    _searchField.placeholder = @"Search YouTube Music...";
    _searchField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _searchField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchField.returnKeyType = UIReturnKeySearch;
    _searchField.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchField.delegate = self;
    [_searchField addTarget:self action:@selector(onSearchTextChanged) forControlEvents:UIControlEventEditingChanged];
    [_searchBarContainer addSubview:_searchField];
    [self.view addSubview:_searchBarContainer];

    [self buildFilterBar];
    [self loadHistoryIfNeeded];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:CGRectMake(0.0f, 88.0f, 320.0f, self.view.bounds.size.height - 88.0f)
                                                          delegate:self
                                                         rowHeight:62.0f] retain];
    [self.view addSubview:_tableView];

    _spinner = [[ELTrackListHelper createSpinnerAtCenter:CGPointMake(160.0f, 200.0f)] retain];
    [self.view addSubview:_spinner];

#if EL_FEATURE_DOWNLOADS
    NSString *hintText = @"Search any song or artist.\nTap a track to stream, or tap the arrow to save offline.";
#else
    NSString *hintText = @"Search any song or artist.\nTap a track to stream.";
#endif
    _hintLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 165.0f, 264.0f, 60.0f)
                                                          text:hintText
                                                      fontSize:14.0f
                                                         lines:3] retain];
    [self.view addSubview:_hintLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPlayerStateChanged) name:ELPlayerStateChangedNotification object:nil];
#if EL_FEATURE_DOWNLOADS
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];
#endif

    [self updateEmptyHint];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_needsRefresh) {
        _needsRefresh = NO;
        if (_mode != ELSearchModeHistory) {
            [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
#if EL_FEATURE_DOWNLOADS
            [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
#endif
        }
    }
}

- (void)onPlayerStateChanged {
    if (_mode == ELSearchModeHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
}

#if EL_FEATURE_DOWNLOADS
- (void)onDownloadsChanged {
    if (_mode == ELSearchModeHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
}

- (void)onDownloadProgress:(NSNotification *)note {
    if (_mode == ELSearchModeHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:vid];
}

- (void)updateOfflineMatchesForQuery:(NSString *)query {
    [_offlineMatches release];
    if ([query length] == 0) {
        _offlineMatches = [[NSArray alloc] init];
        return;
    }
    NSArray *all = [[ELDownloadManager sharedManager] downloadedTracks];
    NSMutableArray *hits = [NSMutableArray array];
    for (ELTrack *t in all) {
        BOOL matchTitle = ([t.title length] > 0 && [t.title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound);
        BOOL matchArtist = ([t.artist length] > 0 && [t.artist rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (matchTitle || matchArtist) {
            [hits addObject:t];
            if ([hits count] >= 12) break;
        }
    }
    _offlineMatches = [[NSArray alloc] initWithArray:hits];
}
#endif

- (void)updateEmptyHint {
    if (_mode == ELSearchModeHistory) {
        _hintLabel.hidden = ([_recentQueries count] > 0);
        self.navigationItem.rightBarButtonItem = ([_recentQueries count] > 0)
            ? [[[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(onClearHistory)] autorelease]
            : nil;
    } else if (_mode == ELSearchModeSuggest) {
#if EL_FEATURE_DOWNLOADS
        BOOL hasAny = ([_offlineMatches count] > 0 || [_suggestions count] > 0);
#else
        BOOL hasAny = ([_suggestions count] > 0);
#endif
        _hintLabel.hidden = hasAny;
        self.navigationItem.rightBarButtonItem = nil;
    } else {
#if EL_FEATURE_DOWNLOADS
        BOOL hasAny = ([_offlineMatches count] > 0 || [_results count] > 0);
#else
        BOOL hasAny = ([_results count] > 0);
#endif
        _hintLabel.hidden = hasAny;
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)saveHistoryBg:(NSArray *)snapshot {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.15];
    el_save_history_array(snapshot);
    [pool release];
}

- (void)onClearHistory {
    [_recentQueries removeAllObjects];
    [NSThread detachNewThreadSelector:@selector(saveHistoryBg:) toTarget:self withObject:[NSArray array]];
    [self updateEmptyHint];
    [_tableView reloadData];
}

- (void)recordQuery:(NSString *)q {
    if ([q length] == 0) return;
    if ([q length] > 128) q = [q substringToIndex:128];
    [_recentQueries removeObject:q];
    [_recentQueries insertObject:q atIndex:0];
    while ([_recentQueries count] > 10) [_recentQueries removeLastObject];
}

- (void)runSearchForQuery:(NSString *)q {
    if ([q length] == 0) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(triggerDebouncedSuggestions:) object:nil];
    _suggestToken++;

    [self recordQuery:q];
    NSArray *histSnap = [[_recentQueries copy] autorelease];
    _mode = ELSearchModeResults;
    _searchToken++;
    _hintLabel.hidden = YES;
    self.navigationItem.rightBarButtonItem = nil;

#if EL_FEATURE_DOWNLOADS
    [self updateOfflineMatchesForQuery:q];
#endif

    NSString *cacheKey = [NSString stringWithFormat:@"%ld|%@", (long)_filterMode, [q lowercaseString]];
    NSArray *cached = [_searchCache objectForKey:cacheKey];
    if (cached && [cached count] > 0) {
        [_spinner stopAnimating];
        [_results release];
        _results = [cached retain];
        [_tableView reloadData];
        [NSThread detachNewThreadSelector:@selector(saveHistoryBg:) toTarget:self withObject:histSnap];
        return;
    }

    [_tableView reloadData];
    [_spinner startAnimating];

    BOOL songsOnly = (_filterMode == ELSearchFilterSongs);
    BOOL hideShorts = (_filterMode == ELSearchFilterNoShorts);
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          q, @"query",
                          cacheKey, @"cacheKey",
                          histSnap, @"historySnapshot",
                          [NSNumber numberWithInteger:_searchToken], @"token",
                          [NSNumber numberWithBool:songsOnly], @"songsOnly",
                          [NSNumber numberWithBool:hideShorts], @"hideShorts",
                          nil];
    [NSThread detachNewThreadSelector:@selector(searchWorker:) toTarget:self withObject:args];
}

#pragma mark - Live Suggestions

- (void)triggerDebouncedSuggestions:(NSString *)query {
    if (_mode != ELSearchModeSuggest || [query length] == 0) return;
    _suggestToken++;
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          query, @"query",
                          [NSNumber numberWithInteger:_suggestToken], @"token",
                          nil];
    [NSThread detachNewThreadSelector:@selector(suggestionsWorker:) toTarget:self withObject:args];
}

- (void)suggestionsWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSThread setThreadPriority:0.25];
    NSString *q = [args objectForKey:@"query"];
    NSNumber *tok = [args objectForKey:@"token"];
    NSArray *list = [[ELYouTubeClient sharedClient] fetchSearchSuggestionsForQuery:q];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:tok forKey:@"token"];
    if (list) [res setObject:list forKey:@"suggestions"];
    [self performSelectorOnMainThread:@selector(onSuggestionsLoaded:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onSuggestionsLoaded:(NSDictionary *)res {
    if ([[res objectForKey:@"token"] integerValue] != _suggestToken) return;
    if (_mode != ELSearchModeSuggest) return;
    NSArray *list = [res objectForKey:@"suggestions"];
    [_suggestions release];
    _suggestions = list ? [list retain] : [[NSArray alloc] init];
    [self updateEmptyHint];
    [_tableView reloadData];
}

#pragma mark - UITextFieldDelegate

- (void)onSearchTextChanged {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    NSString *trimmed = [_searchField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) {
        _suggestToken++;
        _mode = ELSearchModeHistory;
        [_suggestions release];
        _suggestions = [[NSArray alloc] init];
#if EL_FEATURE_DOWNLOADS
        [self updateOfflineMatchesForQuery:@""];
#endif
        [self updateEmptyHint];
        [_tableView reloadData];
        return;
    }

    _mode = ELSearchModeSuggest;
#if EL_FEATURE_DOWNLOADS
    [self updateOfflineMatchesForQuery:trimmed];
#endif
    [self updateEmptyHint];
    [_tableView reloadData];
    [self performSelector:@selector(triggerDebouncedSuggestions:) withObject:trimmed afterDelay:0.35];
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    (void)textField;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _suggestToken++;
    _mode = ELSearchModeHistory;
    [_suggestions release];
    _suggestions = [[NSArray alloc] init];
#if EL_FEATURE_DOWNLOADS
    [self updateOfflineMatchesForQuery:@""];
#endif
    [self updateEmptyHint];
    [_tableView reloadData];
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    NSString *q = [textField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self runSearchForQuery:q];
    return YES;
}

- (void)searchWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    /* Interactive high priority so search beats background thumbnails & offline downloads */
    [NSThread setThreadPriority:0.75];
    NSString *q = [args objectForKey:@"query"];
    NSString *cacheKey = [args objectForKey:@"cacheKey"];
    NSArray *histSnap = [args objectForKey:@"historySnapshot"];
    NSNumber *tok = [args objectForKey:@"token"];
    BOOL songsOnly = [[args objectForKey:@"songsOnly"] boolValue];
    BOOL hideShorts = [[args objectForKey:@"hideShorts"] boolValue];
    NSString *err = nil;
    NSArray *tracks = [[ELYouTubeClient sharedClient] searchTracksForQuery:q
                                                                 songsOnly:songsOnly
                                                                hideShorts:hideShorts
                                                                     error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:tok forKey:@"token"];
    if (cacheKey) [res setObject:cacheKey forKey:@"cacheKey"];
    if (tracks)   [res setObject:tracks forKey:@"tracks"];
    if (err)      [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onSearchFinished:) withObject:res waitUntilDone:NO];

    /* Persist history AFTER dispatching results to UI so search latency is never penalized by flash I/O */
    if (histSnap) {
        [NSThread setThreadPriority:0.15];
        el_save_history_array(histSnap);
    }
    [pool release];
}

- (void)onSearchFinished:(NSDictionary *)res {
    if ([[res objectForKey:@"token"] integerValue] != _searchToken) return;
    [_spinner stopAnimating];
    NSArray *tracks = [res objectForKey:@"tracks"];
    NSString *err = [res objectForKey:@"error"];
    NSString *cacheKey = [res objectForKey:@"cacheKey"];
    if (tracks && [tracks count] > 0) {
        [_results release];
        _results = [tracks retain];
        if ([cacheKey length] > 0) {
            [_searchCache setObject:tracks forKey:cacheKey];
            [_searchCacheLRU removeObject:cacheKey];
            [_searchCacheLRU addObject:cacheKey];
            while ([_searchCacheLRU count] > 8) {
                NSString *evict = [_searchCacheLRU objectAtIndex:0];
                [_searchCache removeObjectForKey:evict];
                [_searchCacheLRU removeObjectAtIndex:0];
            }
        }
    } else {
        [_results release];
        _results = [[NSArray alloc] init];
        _hintLabel.text = err ? err : @"No results found.";
    }
    [self updateEmptyHint];
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (_mode == ELSearchModeHistory) return 1;
    return 2; /* Section 0: Downloaded Matches, Section 1: Suggestions or Online Results */
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (_mode == ELSearchModeHistory) return 44.0f;
    if (_mode == ELSearchModeSuggest && indexPath.section == 1) return 44.0f;
    return 62.0f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (_mode == ELSearchModeHistory) {
        return ([_recentQueries count] > 0) ? 26.0f : 0.0f;
    }
    if (section == 0) {
#if EL_FEATURE_DOWNLOADS
        return ([_offlineMatches count] > 0) ? 26.0f : 0.0f;
#else
        return 0.0f;
#endif
    }
    if (_mode == ELSearchModeSuggest) {
        return ([_suggestions count] > 0) ? 26.0f : 0.0f;
    }
#if EL_FEATURE_DOWNLOADS
    return ([_offlineMatches count] > 0 && [_results count] > 0) ? 26.0f : 0.0f;
#else
    return 0.0f;
#endif
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (_mode == ELSearchModeHistory) {
        if ([_recentQueries count] == 0) return nil;
        if (!_historyHeader) {
            _historyHeader = [[ELTrackListHelper createSectionHeaderWithTitle:@"RECENT SEARCHES" height:26.0f] retain];
        }
        return _historyHeader;
    }
    if (section == 0) {
#if EL_FEATURE_DOWNLOADS
        if ([_offlineMatches count] == 0) return nil;
        if (!_offlineHeader) {
            _offlineHeader = [[ELTrackListHelper createSectionHeaderWithTitle:@"DOWNLOADED MATCHES" height:26.0f] retain];
        }
        return _offlineHeader;
#else
        return nil;
#endif
    }
    if (_mode == ELSearchModeSuggest) {
        if ([_suggestions count] == 0) return nil;
        if (!_suggestionsHeader) {
            _suggestionsHeader = [[ELTrackListHelper createSectionHeaderWithTitle:@"SUGGESTIONS" height:26.0f] retain];
        }
        return _suggestionsHeader;
    }
#if EL_FEATURE_DOWNLOADS
    if ([_offlineMatches count] > 0 && [_results count] > 0) {
        if (!_onlineHeader) {
            _onlineHeader = [[ELTrackListHelper createSectionHeaderWithTitle:@"YOUTUBE MUSIC" height:26.0f] retain];
        }
        return _onlineHeader;
    }
#endif
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (_mode == ELSearchModeHistory) {
        return [_recentQueries count];
    }
    if (section == 0) {
#if EL_FEATURE_DOWNLOADS
        return [_offlineMatches count];
#else
        return 0;
#endif
    }
    return (_mode == ELSearchModeSuggest) ? [_suggestions count] : [_results count];
}

- (UITableViewCell *)dequeuePlainTextCellForTableView:(UITableView *)tableView text:(NSString *)text {
    static NSString *hid = @"ELHistoryCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:hid];
    if (!cell) {
        cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:hid] autorelease];
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
        cell.textLabel.font = [UIFont systemFontOfSize:14.0f];
        cell.textLabel.textColor = [ELTheme textPrimaryColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = text;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_mode == ELSearchModeHistory) {
        return [self dequeuePlainTextCellForTableView:tableView text:[_recentQueries objectAtIndex:indexPath.row]];
    }
    if (indexPath.section == 0) {
#if EL_FEATURE_DOWNLOADS
        return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                         track:[_offlineMatches objectAtIndex:indexPath.row]];
#endif
    }
    if (_mode == ELSearchModeSuggest) {
        return [self dequeuePlainTextCellForTableView:tableView text:[_suggestions objectAtIndex:indexPath.row]];
    }
    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_results objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_searchField resignFirstResponder];
    if (_mode == ELSearchModeHistory) {
        NSString *q = [_recentQueries objectAtIndex:indexPath.row];
        _searchField.text = q;
        [self runSearchForQuery:q];
        return;
    }
    if (indexPath.section == 0) {
#if EL_FEATURE_DOWNLOADS
        [[ELAudioEngine sharedEngine] playTracks:_offlineMatches startingAtIndex:indexPath.row];
#endif
        return;
    }
    if (_mode == ELSearchModeSuggest) {
        NSString *q = [_suggestions objectAtIndex:indexPath.row];
        _searchField.text = q;
        [self runSearchForQuery:q];
        return;
    }
    [[ELAudioEngine sharedEngine] playTracks:_results startingAtIndex:indexPath.row];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return (_mode == ELSearchModeHistory);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (_mode != ELSearchModeHistory || editingStyle != UITableViewCellEditingStyleDelete) return;
    if ((NSUInteger)indexPath.row < [_recentQueries count]) {
        [_recentQueries removeObjectAtIndex:(NSUInteger)indexPath.row];
        NSArray *snap = [[_recentQueries copy] autorelease];
        [NSThread detachNewThreadSelector:@selector(saveHistoryBg:) toTarget:self withObject:snap];
        [self updateEmptyHint];
        [_tableView reloadData];
    }
}

@end
