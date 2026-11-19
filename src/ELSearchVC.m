#import "ELSearchVC.h"
#import "ELAudioEngine.h"
#import "ELDownloadManager.h"
#import "ELTheme.h"
#import "ELTrackCell.h"
#import "ELYouTubeClient.h"

static NSString *el_history_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"search_history.plist"];
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
        NSArray *saved = [NSArray arrayWithContentsOfFile:el_history_path()];
        if ([saved isKindOfClass:[NSArray class]]) [_recentQueries addObjectsFromArray:saved];
        _showingHistory = YES;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_searchBar release];
    [_tableView release];
    [_spinner release];
    [_hintLabel release];
    [_results release];
    [_recentQueries release];
    [super dealloc];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [ELTheme backgroundColor];
    [ELTheme styleNavBar:self.navigationController.navigationBar];

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
    _searchBar.barStyle = UIBarStyleBlack;
    _searchBar.tintColor = [ELTheme surfaceColor];
    _searchBar.placeholder = @"Search YouTube Music...";
    _searchBar.delegate = self;
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 44, 320, self.view.bounds.size.height - 44)
                                              style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.contentInset = UIEdgeInsetsMake(0, 0, 56, 0);
    _tableView.scrollIndicatorInsets = _tableView.contentInset;
    [ELTheme styleTableView:_tableView];
    [self.view addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.center = CGPointMake(160, 185);
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    _hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(28, 150, 264, 60)];
    _hintLabel.backgroundColor = [UIColor clearColor];
    _hintLabel.font = [UIFont systemFontOfSize:14.0f];
    _hintLabel.textColor = [ELTheme textSecondaryColor];
    _hintLabel.textAlignment = UITextAlignmentCenter;
    _hintLabel.numberOfLines = 3;
    _hintLabel.text = @"Search any song or artist.\nTap a track to stream, or tap the arrow to save offline.";
    [self.view addSubview:_hintLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onPlayerStateChanged) name:ELPlayerStateChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadsChanged) name:ELDownloadsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onDownloadProgress:) name:ELDownloadProgressNotification object:nil];

    [self updateEmptyHint];
}

- (void)onPlayerStateChanged {
    if (!_showingHistory) {
        [_tableView reloadData];
    }
}

- (void)refreshVisibleCellsForVideoId:(NSString *)videoId {
    if (_showingHistory) return;
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

- (void)onClearHistory {
    [_recentQueries removeAllObjects];
    [_recentQueries writeToFile:el_history_path() atomically:YES];
    [self updateEmptyHint];
    [_tableView reloadData];
}

- (void)recordQuery:(NSString *)q {
    if ([q length] == 0) return;
    [_recentQueries removeObject:q];
    [_recentQueries insertObject:q atIndex:0];
    while ([_recentQueries count] > 10) [_recentQueries removeLastObject];
    [_recentQueries writeToFile:el_history_path() atomically:YES];
}

- (void)runSearchForQuery:(NSString *)q {
    if ([q length] == 0) return;
    [self recordQuery:q];
    _showingHistory = NO;
    _searchToken++;
    _hintLabel.hidden = YES;
    self.navigationItem.rightBarButtonItem = nil;
    [_spinner startAnimating];

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                          q, @"query",
                          [NSNumber numberWithInteger:_searchToken], @"token",
                          nil];
    [NSThread detachNewThreadSelector:@selector(searchWorker:) toTarget:self withObject:args];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    if ([searchText length] == 0) {
        _showingHistory = YES;
        [self updateEmptyHint];
        [_tableView reloadData];
    }
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *q = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self runSearchForQuery:q];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchWorker:(NSDictionary *)args {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *q = [args objectForKey:@"query"];
    NSNumber *tok = [args objectForKey:@"token"];
    NSString *err = nil;
    NSArray *tracks = [[ELYouTubeClient sharedClient] searchSongs:q error:&err];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:tok forKey:@"token"];
    if (tracks) [res setObject:tracks forKey:@"tracks"];
    if (err)    [res setObject:err forKey:@"error"];
    [self performSelectorOnMainThread:@selector(onSearchFinished:) withObject:res waitUntilDone:NO];
    [pool release];
}

- (void)onSearchFinished:(NSDictionary *)res {
    if ([[res objectForKey:@"token"] integerValue] != _searchToken) return;
    [_spinner stopAnimating];
    NSArray *tracks = [res objectForKey:@"tracks"];
    NSString *err = [res objectForKey:@"error"];
    if (tracks && [tracks count] > 0) {
        [_results release];
        _results = [tracks retain];
        _hintLabel.hidden = YES;
    } else {
        [_results release];
        _results = [[NSArray alloc] init];
        _hintLabel.text = err ? err : @"No results found.";
        _hintLabel.hidden = NO;
    }
    [_tableView reloadData];
}

#pragma mark - UITableViewDataSource

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return _showingHistory ? 44.0f : 62.0f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (_showingHistory && [_recentQueries count] > 0) ? 26.0f : 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (!_showingHistory || [_recentQueries count] == 0) return nil;
    UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 26)] autorelease];
    v.backgroundColor = [ELTheme surfaceColor];
    v.opaque = YES;
    UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectMake(14, 0, 292, 26)] autorelease];
    lbl.backgroundColor = [ELTheme surfaceColor];
    lbl.opaque = YES;
    lbl.font = [UIFont boldSystemFontOfSize:11.0f];
    lbl.textColor = [ELTheme textSecondaryColor];
    lbl.text = @"RECENT SEARCHES";
    [v addSubview:lbl];
    return v;
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

    static NSString *cid = @"ELTrackCell";
    ELTrackCell *cell = (ELTrackCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[[ELTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid] autorelease];
    ELTrack *t = [_results objectAtIndex:indexPath.row];
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    [cell configureWithTrack:t isCurrent:(cur && [cur.videoId isEqualToString:t.videoId])];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [_searchBar resignFirstResponder];
    if (_showingHistory) {
        NSString *q = [_recentQueries objectAtIndex:indexPath.row];
        _searchBar.text = q;
        [self runSearchForQuery:q];
    } else {
        [[ELAudioEngine sharedEngine] playTracks:_results startingAtIndex:indexPath.row];
    }
}

@end
