#import "ELSearchVC.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#if EL_FEATURE_DOWNLOADS
#import "ELDownloadManager.h"
#endif
#import "ELTheme.h"
#import "ELTrackListHelper.h"
#import "ELYouTubeClient.h"
#import <sys/stat.h>

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
        _recentQueries = [[NSMutableArray alloc] init];
        _searchCache = [[NSMutableDictionary alloc] initWithCapacity:8];
        _searchCacheLRU = [[NSMutableArray alloc] initWithCapacity:8];
        _showingHistory = YES;
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_searchBarContainer release]; _searchBarContainer = nil;
    [_searchField release]; _searchField = nil;
    [_tableView release]; _tableView = nil;
    [_historyHeader release]; _historyHeader = nil;
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
    [_recentQueries release];
    [_searchCache release];
    [_searchCacheLRU release];
    [super dealloc];
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

    [self loadHistoryIfNeeded];

    _tableView = [[ELTrackListHelper createTrackTableViewWithFrame:CGRectMake(0.0f, 54.0f, 320.0f, self.view.bounds.size.height - 54.0f)
                                                          delegate:self
                                                         rowHeight:(_showingHistory ? 44.0f : 62.0f)] retain];
    [self.view addSubview:_tableView];

    _spinner = [[ELTrackListHelper createSpinnerAtCenter:CGPointMake(160.0f, 185.0f)] retain];
    [self.view addSubview:_spinner];

#if EL_FEATURE_DOWNLOADS
    NSString *hintText = @"Search any song or artist.\nTap a track to stream, or tap the arrow to save offline.";
#else
    NSString *hintText = @"Search any song or artist.\nTap a track to stream.";
#endif
    _hintLabel = [[ELTrackListHelper createEmptyLabelWithFrame:CGRectMake(28.0f, 150.0f, 264.0f, 60.0f)
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
        if (!_showingHistory) {
            [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
#if EL_FEATURE_DOWNLOADS
            [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
#endif
        }
    }
}

- (void)onPlayerStateChanged {
    if (_showingHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackHighlightInTableView:_tableView];
}

#if EL_FEATURE_DOWNLOADS
- (void)onDownloadsChanged {
    if (_showingHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:nil];
}

- (void)onDownloadProgress:(NSNotification *)note {
    if (_showingHistory) return;
    if (!self.view.window) {
        _needsRefresh = YES;
        return;
    }
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [ELTrackListHelper refreshVisibleTrackCellsInTableView:_tableView forVideoId:vid];
}
#endif

- (void)setShowingHistory:(BOOL)showing {
    _showingHistory = showing;
    _tableView.rowHeight = showing ? 44.0f : 62.0f;
}

- (void)updateEmptyHint {
    if (_showingHistory) {
        _hintLabel.hidden = ([_recentQueries count] > 0);
        self.navigationItem.rightBarButtonItem = ([_recentQueries count] > 0)
            ? [[[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStyleBordered target:self action:@selector(onClearHistory)] autorelease]
            : nil;
    } else {
        _hintLabel.hidden = ([_results count] > 0);
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
    [self recordQuery:q];
    NSArray *histSnap = [[_recentQueries copy] autorelease];
    [self setShowingHistory:NO];
    _searchToken++;
    _hintLabel.hidden = YES;
    self.navigationItem.rightBarButtonItem = nil;

    NSString *cacheKey = [q lowercaseString];
    NSArray *cached = [_searchCache objectForKey:cacheKey];
    if (cached && [cached count] > 0) {
        [_spinner stopAnimating];
        [_results release];
        _results = [cached retain];
        [_tableView reloadData];
        [NSThread detachNewThreadSelector:@selector(saveHistoryBg:) toTarget:self withObject:histSnap];
        return;
    }

    [_spinner startAnimating];

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          q, @"query",
                          cacheKey, @"cacheKey",
                          histSnap, @"historySnapshot",
                          [NSNumber numberWithInteger:_searchToken], @"token",
                          nil];
    [NSThread detachNewThreadSelector:@selector(searchWorker:) toTarget:self withObject:args];
}

#pragma mark - UITextFieldDelegate

- (void)onSearchTextChanged {
    if ([_searchField.text length] == 0) {
        [self setShowingHistory:YES];
        [self updateEmptyHint];
        [_tableView reloadData];
    }
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    (void)textField;
    [self setShowingHistory:YES];
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
    NSString *err = nil;
    NSArray *tracks = [[ELYouTubeClient sharedClient] searchSongs:q error:&err];
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
        _hintLabel.hidden = YES;
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
        _hintLabel.hidden = NO;
    }
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (_showingHistory && [_recentQueries count] > 0) ? 26.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (!_showingHistory || [_recentQueries count] == 0) return nil;
    if (!_historyHeader) {
        _historyHeader = [[ELTrackListHelper createSectionHeaderWithTitle:@"RECENT SEARCHES" height:26.0f] retain];
    }
    return _historyHeader;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return _showingHistory ? [_recentQueries count] : [_results count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_showingHistory) {
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
        cell.textLabel.text = [_recentQueries objectAtIndex:indexPath.row];
        return cell;
    }

    return [ELTrackListHelper dequeueTrackCellForTableView:tableView
                                                     track:[_results objectAtIndex:indexPath.row]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_searchField resignFirstResponder];
    if (_showingHistory) {
        NSString *q = [_recentQueries objectAtIndex:indexPath.row];
        _searchField.text = q;
        [self runSearchForQuery:q];
    } else {
        [[ELAudioEngine sharedEngine] playTracks:_results startingAtIndex:indexPath.row];
    }
}

@end
