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
        _tracks = [[NSMutableArray alloc] init];
        _loadGen = 0;
        _isLoadingMore = NO;
        self.title = playlist.title ? playlist.title : @"Playlist";
    }
    return self;
}

- (void)releaseViewOutlets {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_tableView release]; _tableView = nil;
    [_spinner release]; _spinner = nil;
    [_statusLabel release]; _statusLabel = nil;
    [_headerInfoLabel release]; _headerInfoLabel = nil;
    [_downloadPlaylistBtn release]; _downloadPlaylistBtn = nil;
}

- (void)viewDidUnload {
    @synchronized(self) { _loadGen++; }
    [self releaseViewOutlets];
    [super viewDidUnload];
}

- (void)dealloc {
    @synchronized(self) { _loadGen++; }
    [self releaseViewOutlets];
    [_playlist release];
    [_tracks release];
    [super dealloc];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (![self.navigationController.viewControllers containsObject:self]) {
        @synchronized(self) { _loadGen++; }
    }
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
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onBatchProgress) name:ELDownloadBatchProgressNotification object:nil];

    /* 1. Instant 0.0s render if playlist is cached on disk */
    NSArray *cached = [[ELYouTubeClient sharedClient] cachedTracksForPlaylistId:_playlist.playlistId];
    if (cached && [cached count] > 0) {
        [_tracks removeAllObjects];
        [_tracks addObjectsFromArray:cached];
        _isLoadingMore = YES;
        _tableView.tableHeaderView = [self buildPlaylistHeader];
        [_tableView reloadData];
    } else {
        [_spinner startAnimating];
    }

    NSInteger gen = 0;
    @synchronized(self) {
        _loadGen++;
        gen = _loadGen;
    }
    [NSThread detachNewThreadSelector:@selector(loadPlaylistWorkerWithGen:)
                             toTarget:self
                           withObject:[NSNumber numberWithInteger:gen]];
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

- (BOOL)allTracksDownloaded {
    if ([_tracks count] == 0) return NO;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    for (ELTrack *t in _tracks) {
        if (![dm isDownloaded:t.videoId]) return NO;
    }
    return YES;
}

- (void)updateDownloadButtonState {
    if (!_downloadPlaylistBtn) return;
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if (dm.isBatchDownloading && dm.batchTotal > 0) {
        NSString *lbl = [NSString stringWithFormat:@"Cancel (%ld/%ld)", (long)dm.batchCompleted, (long)dm.batchTotal];
        [_downloadPlaylistBtn setTitle:lbl forState:UIControlStateNormal];
        UIImage *bg = [ELTheme roundedRectImageWithSize:_downloadPlaylistBtn.frame.size
                                                  radius:18.0f
                                               fillColor:[ELTheme accentColor]
                                             borderColor:nil];
        [_downloadPlaylistBtn setBackgroundImage:bg forState:UIControlStateNormal];
    } else if ([self allTracksDownloaded]) {
        [_downloadPlaylistBtn setTitle:@"Saved Offline" forState:UIControlStateNormal];
        UIImage *bg = [ELTheme roundedRectImageWithSize:_downloadPlaylistBtn.frame.size
                                                  radius:18.0f
                                               fillColor:[ELTheme successColor]
                                             borderColor:nil];
        [_downloadPlaylistBtn setBackgroundImage:bg forState:UIControlStateNormal];
    } else {
        [_downloadPlaylistBtn setTitle:@"Download Playlist" forState:UIControlStateNormal];
        UIImage *bg = [ELTheme roundedRectImageWithSize:_downloadPlaylistBtn.frame.size
                                                  radius:18.0f
                                               fillColor:[ELTheme surfaceHighlightColor]
                                             borderColor:nil];
        [_downloadPlaylistBtn setBackgroundImage:bg forState:UIControlStateNormal];
    }
}

- (void)onDownloadsChanged {
    [self refreshVisibleCellsForVideoId:nil];
    [self updateDownloadButtonState];
}

- (void)onDownloadProgress:(NSNotification *)note {
    NSString *vid = [[note userInfo] objectForKey:@"videoId"];
    [self refreshVisibleCellsForVideoId:vid];
}

- (void)onBatchProgress {
    [self updateDownloadButtonState];
}

- (void)updateHeaderInfoLabel {
    if (!_headerInfoLabel) return;
    NSUInteger count = [_tracks count];
    if (_isLoadingMore) {
        _headerInfoLabel.text = [NSString stringWithFormat:@"%lu %@ (syncing...)",
                                 (unsigned long)count,
                                 (count == 1 ? @"track" : @"tracks")];
    } else {
        _headerInfoLabel.text = [NSString stringWithFormat:@"%lu %@",
                                 (unsigned long)count,
                                 (count == 1 ? @"track" : @"tracks")];
    }
}

- (BOOL)isLoadGenValid:(NSInteger)gen {
    @synchronized(self) {
        return (_loadGen == gen);
    }
}

- (void)loadPlaylistWorkerWithGen:(NSNumber *)genNum {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSInteger gen = [genNum integerValue];

    /* Page 1 runs at responsive priority so the first 15 tracks appear in ~0.4s */
    [NSThread setThreadPriority:0.55];

    ELYouTubeClient *yt = [ELYouTubeClient sharedClient];
    NSString *err = nil;
    NSString *nextTok = nil;
    NSArray *firstPage = [yt fetchPlaylistPageForId:_playlist.playlistId
                                  continuationToken:nil
                              nextContinuationToken:&nextTok
                                              error:&err];
    if (![self isLoadGenValid:gen]) {
        [pool release];
        return;
    }

    if (!firstPage || [firstPage count] == 0) {
        NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:genNum forKey:@"gen"];
        if (err) [res setObject:err forKey:@"error"];
        [self performSelectorOnMainThread:@selector(onPlaylistLoadError:) withObject:res waitUntilDone:NO];
        [pool release];
        return;
    }

    NSMutableArray *allTracks = [NSMutableArray array];
    NSMutableSet *seenIds = [NSMutableSet set];
    for (ELTrack *t in firstPage) {
        if (t && [t.videoId length] > 0 && ![seenIds containsObject:t.videoId]) {
            [seenIds addObject:t.videoId];
            [allTracks addObject:t];
        }
    }

    BOOL hasMore = ([nextTok length] > 0);
    NSDictionary *p1 = [NSDictionary dictionaryWithObjectsAndKeys:
                        genNum, @"gen",
                        [[allTracks copy] autorelease], @"tracks",
                        [NSNumber numberWithBool:hasMore], @"hasMore",
                        nil];
    [self performSelectorOnMainThread:@selector(onPlaylistFirstPageLoaded:) withObject:p1 waitUntilDone:NO];

    if (!hasMore) {
        [yt saveCachedTracks:allTracks forPlaylistId:_playlist.playlistId];
        [pool release];
        return;
    }

    /* Subsequent pages run at background priority so UI scrolling & audio never stutter */
    [NSThread setThreadPriority:0.30];

    NSMutableSet *seenTokens = [NSMutableSet setWithObject:nextTok];
    NSString *contToken = [nextTok retain];
    BOOL fetchAbortedOnError = NO;

    for (int page = 1; page < 50; page++) {
        if (![self isLoadGenValid:gen]) break;
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        NSString *pageErr = nil;
        NSString *tokOut = nil;
        NSArray *pageList = [yt fetchPlaylistPageForId:_playlist.playlistId
                                     continuationToken:contToken
                                 nextContinuationToken:&tokOut
                                                 error:&pageErr];
        [contToken release];
        contToken = nil;

        if (![self isLoadGenValid:gen]) {
            [inner release];
            break;
        }
        if (!pageList) {
            fetchAbortedOnError = YES;
            [inner release];
            break;
        }
        if ([pageList count] == 0) {
            [inner release];
            break;
        }

        NSMutableArray *batchNew = [NSMutableArray array];
        for (ELTrack *t in pageList) {
            if (t && [t.videoId length] > 0 && ![seenIds containsObject:t.videoId]) {
                [seenIds addObject:t.videoId];
                [allTracks addObject:t];
                [batchNew addObject:t];
            }
        }

        if ([batchNew count] == 0) {
            [inner release];
            break;
        }

        BOOL moreAfter = ([tokOut length] > 0 && ![seenTokens containsObject:tokOut]);
        NSDictionary *moreMsg = [NSDictionary dictionaryWithObjectsAndKeys:
                                 genNum, @"gen",
                                 [[batchNew copy] autorelease], @"newTracks",
                                 [[allTracks copy] autorelease], @"allTracks",
                                 [NSNumber numberWithBool:moreAfter], @"hasMore",
                                 nil];
        [self performSelectorOnMainThread:@selector(onPlaylistMoreTracksLoaded:) withObject:moreMsg waitUntilDone:NO];

        if (!moreAfter) {
            [inner release];
            break;
        }
        [seenTokens addObject:tokOut];
        contToken = [tokOut retain];
        [inner release];
    }

    [contToken release];

    if ([self isLoadGenValid:gen]) {
        if (!fetchAbortedOnError) {
            [yt saveCachedTracks:allTracks forPlaylistId:_playlist.playlistId];
        }
        NSDictionary *finMsg = [NSDictionary dictionaryWithObjectsAndKeys:
                                genNum, @"gen",
                                [[allTracks copy] autorelease], @"allTracks",
                                [NSNumber numberWithBool:!fetchAbortedOnError], @"completed",
                                nil];
        [self performSelectorOnMainThread:@selector(onPlaylistFinishLoading:) withObject:finMsg waitUntilDone:NO];
    }
    [pool release];
}

- (UIView *)buildPlaylistHeader {
    UIView *hdr = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, 78.0f)] autorelease];
    hdr.backgroundColor = [ELTheme backgroundColor];
    hdr.opaque = YES;

    [_headerInfoLabel release];
    _headerInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(14.0f, 6.0f, 292.0f, 18.0f)];
    _headerInfoLabel.backgroundColor = [ELTheme backgroundColor];
    _headerInfoLabel.opaque = YES;
    _headerInfoLabel.font = [UIFont systemFontOfSize:12.0f];
    _headerInfoLabel.textColor = [ELTheme textSecondaryColor];
    [self updateHeaderInfoLabel];
    [hdr addSubview:_headerInfoLabel];

    UIButton *playBtn = [ELTheme pillButtonWithTitle:@"Play"
                                               color:[ELTheme accentColor]
                                               frame:CGRectMake(12.0f, 30.0f, 76.0f, 36.0f)];
    [playBtn addTarget:self action:@selector(onPlayAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:playBtn];

    UIButton *shufBtn = [ELTheme pillButtonWithTitle:@"Shuffle"
                                               color:[ELTheme surfaceHighlightColor]
                                               frame:CGRectMake(94.0f, 30.0f, 76.0f, 36.0f)];
    [shufBtn addTarget:self action:@selector(onShuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:shufBtn];

    [_downloadPlaylistBtn release];
    _downloadPlaylistBtn = [[ELTheme pillButtonWithTitle:@"Download Playlist"
                                                  color:[ELTheme surfaceHighlightColor]
                                                  frame:CGRectMake(176.0f, 30.0f, 132.0f, 36.0f)] retain];
    _downloadPlaylistBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11.5f];
    [_downloadPlaylistBtn addTarget:self action:@selector(onDownloadAll) forControlEvents:UIControlEventTouchUpInside];
    [hdr addSubview:_downloadPlaylistBtn];
    [self updateDownloadButtonState];

    return hdr;
}

- (void)onPlayAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracks:_tracks startingAtIndex:0];
}

- (void)onShuffleAll {
    if ([_tracks count] > 0) [[ELAudioEngine sharedEngine] playTracksShuffled:_tracks];
}

- (void)onDownloadAll {
    ELDownloadManager *dm = [ELDownloadManager sharedManager];
    if (dm.isBatchDownloading) {
        [dm cancelBatchDownload];
        [[ELAudioEngine sharedEngine] postToast:@"Download cancelled"];
    } else if ([_tracks count] > 0 && ![self allTracksDownloaded]) {
        [dm downloadPlaylistTracks:_tracks title:_playlist.title];
    }
    [self updateDownloadButtonState];
}

- (BOOL)tracksMatchPrefix:(NSArray *)incoming {
    if ([_tracks count] < [incoming count]) return NO;
    for (NSUInteger i = 0; i < [incoming count]; i++) {
        ELTrack *a = [_tracks objectAtIndex:i];
        ELTrack *b = [incoming objectAtIndex:i];
        if (![a.videoId isEqualToString:b.videoId]) return NO;
    }
    return YES;
}

- (BOOL)currentTracksArePrefixOf:(NSArray *)incoming {
    NSUInteger curCount = [_tracks count];
    if (curCount == 0 || curCount > [incoming count]) return NO;
    for (NSUInteger i = 0; i < curCount; i++) {
        ELTrack *a = [_tracks objectAtIndex:i];
        ELTrack *b = [incoming objectAtIndex:i];
        if (![a.videoId isEqualToString:b.videoId]) return NO;
    }
    return YES;
}

- (void)onPlaylistFirstPageLoaded:(NSDictionary *)res {
    NSInteger gen = [[res objectForKey:@"gen"] integerValue];
    if (![self isLoadGenValid:gen]) return;

    [_spinner stopAnimating];
    NSArray *list = [res objectForKey:@"tracks"];
    BOOL hasMore = [[res objectForKey:@"hasMore"] boolValue];
    _isLoadingMore = hasMore;
    _statusLabel.hidden = YES;

    /* If we already loaded a disk cache whose first page matches, keep the full cached list visible while syncing */
    if ([_tracks count] >= [list count] && [self tracksMatchPrefix:list]) {
        if (!hasMore && [_tracks count] != [list count]) {
            [_tracks removeAllObjects];
            [_tracks addObjectsFromArray:list];
            [_tableView reloadData];
        }
        [self updateHeaderInfoLabel];
        [self updateDownloadButtonState];
        return;
    }

    [_tracks removeAllObjects];
    [_tracks addObjectsFromArray:list];
    if (!_tableView.tableHeaderView) {
        _tableView.tableHeaderView = [self buildPlaylistHeader];
    } else {
        [self updateHeaderInfoLabel];
        [self updateDownloadButtonState];
    }
    [_tableView reloadData];
}

- (void)onPlaylistMoreTracksLoaded:(NSDictionary *)res {
    NSInteger gen = [[res objectForKey:@"gen"] integerValue];
    if (![self isLoadGenValid:gen]) return;

    NSArray *allTracks = [res objectForKey:@"allTracks"];
    NSArray *newTracks = [res objectForKey:@"newTracks"];
    BOOL hasMore = [[res objectForKey:@"hasMore"] boolValue];
    _isLoadingMore = hasMore;

    /* If disk cache already matches the accumulated prefix, avoid jarring reloads mid-scroll */
    if ([_tracks count] >= [allTracks count] && [self tracksMatchPrefix:allTracks]) {
        if (!hasMore && [_tracks count] != [allTracks count]) {
            [_tracks removeAllObjects];
            [_tracks addObjectsFromArray:allTracks];
            [_tableView reloadData];
        }
        [self updateHeaderInfoLabel];
        [self updateDownloadButtonState];
        return;
    }

    /* Progressive append: preserve existing ELTrack objects in _tracks and append only new suffix */
    if ([self currentTracksArePrefixOf:allTracks]) {
        NSUInteger oldCount = [_tracks count];
        NSUInteger totalCount = [allTracks count];
        if (oldCount + [newTracks count] == totalCount) {
            [_tracks addObjectsFromArray:newTracks];
        } else if (totalCount > oldCount) {
            [_tracks addObjectsFromArray:[allTracks subarrayWithRange:NSMakeRange(oldCount, totalCount - oldCount)]];
        }
    } else {
        [_tracks removeAllObjects];
        [_tracks addObjectsFromArray:allTracks];
    }
    [self updateHeaderInfoLabel];
    [self updateDownloadButtonState];
    [_tableView reloadData];
}

- (void)onPlaylistFinishLoading:(NSDictionary *)res {
    NSInteger gen = [res isKindOfClass:[NSDictionary class]]
        ? [[res objectForKey:@"gen"] integerValue]
        : [(NSNumber *)res integerValue];
    if (![self isLoadGenValid:gen]) return;
    _isLoadingMore = NO;
    if ([res isKindOfClass:[NSDictionary class]]) {
        BOOL completed = [[res objectForKey:@"completed"] boolValue];
        NSArray *allTracks = [res objectForKey:@"allTracks"];
        if (completed && [allTracks count] > 0 && [_tracks count] != [allTracks count]) {
            [_tracks removeAllObjects];
            [_tracks addObjectsFromArray:allTracks];
            [_tableView reloadData];
        }
    }
    [self updateHeaderInfoLabel];
    [self updateDownloadButtonState];
}

- (void)onPlaylistLoadError:(NSDictionary *)res {
    NSInteger gen = [[res objectForKey:@"gen"] integerValue];
    if (![self isLoadGenValid:gen]) return;
    [_spinner stopAnimating];
    _isLoadingMore = NO;
    if ([_tracks count] > 0) {
        [self updateHeaderInfoLabel];
        return;
    }
    NSString *err = [res objectForKey:@"error"];
    _statusLabel.text = err ? err : @"No playable tracks found in playlist.";
    _statusLabel.hidden = NO;
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
