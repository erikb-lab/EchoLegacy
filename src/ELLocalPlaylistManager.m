#import "ELLocalPlaylistManager.h"
#include <stdlib.h>
#include <sys/stat.h>

#if EL_FEATURE_LOCAL_PLAYLISTS

NSString *const ELLocalPlaylistsChangedNotification = @"ELLocalPlaylistsChangedNotification";

static NSString *el_sanitize_playlist_name(NSString *name) {
    if (![name isKindOfClass:[NSString class]]) return @"";
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 80) {
        trimmed = [trimmed substringToIndex:80];
    }
    return trimmed;
}

static NSString *el_local_playlists_dir(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700UL]
                                                      forKey:NSFilePosixPermissions];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:attrs
                                                    error:nil];
    const char *fsDir = [dir fileSystemRepresentation];
    if (fsDir) chmod(fsDir, 0700);
    return dir;
}

@implementation ELLocalPlaylist

@synthesize playlistId = _playlistId;
@synthesize name = _name;
@synthesize tracks = _tracks;

- (id)init {
    self = [super init];
    if (self) {
        _tracks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_playlistId release];
    [_name release];
    [_tracks release];
    [super dealloc];
}

- (ELLocalPlaylist *)snapshotCopy {
    ELLocalPlaylist *copy = [[[ELLocalPlaylist alloc] init] autorelease];
    copy.playlistId = self.playlistId;
    copy.name = self.name;
    if (_tracks) {
        [copy.tracks addObjectsFromArray:_tracks];
    }
    return copy;
}

- (NSDictionary *)toDictionary {
    NSMutableArray *trackDicts = [NSMutableArray arrayWithCapacity:[_tracks count]];
    for (ELTrack *t in _tracks) {
        NSDictionary *d = [t toDictionary];
        if (d) [trackDicts addObject:d];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            (_playlistId ? _playlistId : @""), @"playlistId",
            (_name ? _name : @"Untitled"), @"name",
            trackDicts, @"tracks",
            nil];
}

+ (ELLocalPlaylist *)playlistFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *pid = [dict objectForKey:@"playlistId"];
    NSString *name = el_sanitize_playlist_name([dict objectForKey:@"name"]);
    if (![pid isKindOfClass:[NSString class]] || [pid length] == 0) return nil;
    if ([name length] == 0) name = @"Untitled";

    ELLocalPlaylist *pl = [[[ELLocalPlaylist alloc] init] autorelease];
    pl.playlistId = pid;
    pl.name = name;

    NSArray *rawTracks = [dict objectForKey:@"tracks"];
    if ([rawTracks isKindOfClass:[NSArray class]]) {
        NSMutableSet *seen = [NSMutableSet set];
        for (id item in rawTracks) {
            ELTrack *t = [ELTrack trackFromDictionary:item];
            if (t && el_is_valid_video_id(t.videoId) && ![seen containsObject:t.videoId]) {
                [seen addObject:t.videoId];
                [pl.tracks addObject:t];
            }
        }
    }
    return pl;
}

@end

@implementation ELLocalPlaylistManager

+ (ELLocalPlaylistManager *)sharedManager {
    static ELLocalPlaylistManager *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELLocalPlaylistManager alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _playlists = [[NSMutableArray alloc] init];
        _storePath = [[el_local_playlists_dir() stringByAppendingPathComponent:@"local_playlists.plist"] retain];
        _saveCond = [[NSCondition alloc] init];
        [self loadFromDisk];
    }
    return self;
}

- (void)dealloc {
    [_playlists release];
    [_storePath release];
    [_saveCond release];
    [_pendingSaveSnapshot release];
    [super dealloc];
}

- (ELLocalPlaylist *)findPlaylistLocked:(NSString *)playlistId {
    if (![playlistId isKindOfClass:[NSString class]] || [playlistId length] == 0) return nil;
    for (ELLocalPlaylist *pl in _playlists) {
        if ([pl.playlistId isEqualToString:playlistId]) {
            return pl;
        }
    }
    return nil;
}

- (void)loadFromDisk {
    NSData *data = [NSData dataWithContentsOfFile:_storePath];
    if ([data length] == 0) return;

    NSString *errDesc = nil;
    id plist = [NSPropertyListSerialization propertyListFromData:data
                                                mutabilityOption:NSPropertyListImmutable
                                                          format:NULL
                                                errorDescription:&errDesc];
    if (errDesc) [errDesc release];
    if (![plist isKindOfClass:[NSArray class]]) return;

    @synchronized(self) {
        [_playlists removeAllObjects];
        NSMutableSet *seenIds = [NSMutableSet set];
        for (id item in (NSArray *)plist) {
            ELLocalPlaylist *pl = [ELLocalPlaylist playlistFromDictionary:item];
            if (pl && ![seenIds containsObject:pl.playlistId]) {
                [seenIds addObject:pl.playlistId];
                [_playlists addObject:pl];
            }
        }
    }
}

- (void)writeSnapshotToDisk:(NSArray *)serialized {
    NSString *errDesc = nil;
    NSData *binData = [NSPropertyListSerialization dataFromPropertyList:serialized
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                       errorDescription:&errDesc];
    if (errDesc) [errDesc release];
    if (!binData) return;

    if ([binData writeToFile:_storePath atomically:YES]) {
        const char *fsPath = [_storePath fileSystemRepresentation];
        if (fsPath) chmod(fsPath, 0600);
    }
}

- (void)saveThreadMain:(id)unused {
    (void)unused;
    [NSThread setThreadPriority:0.25];
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSArray *snapshot = nil;
        [_saveCond lock];
        while (!_pendingSaveSnapshot) {
            [_saveCond wait];
        }
        snapshot = _pendingSaveSnapshot;
        _pendingSaveSnapshot = nil;
        [_saveCond unlock];

        if (snapshot) {
            [self writeSnapshotToDisk:snapshot];
            [snapshot release];
        }
        [pool drain];
    }
}

- (void)saveSnapshotsToDisk:(NSArray *)serialized {
    if (!serialized) return;
    [_saveCond lock];
    [_pendingSaveSnapshot release];
    _pendingSaveSnapshot = [serialized retain];
    if (!_saveThreadStarted) {
        _saveThreadStarted = YES;
        [NSThread detachNewThreadSelector:@selector(saveThreadMain:) toTarget:self withObject:nil];
    }
    [_saveCond signal];
    [_saveCond unlock];
}

- (NSArray *)serializedSnapshotLocked {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[_playlists count]];
    for (ELLocalPlaylist *pl in _playlists) {
        [arr addObject:[pl toDictionary]];
    }
    return arr;
}

- (void)postChangedOnMain {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELLocalPlaylistsChangedNotification
                                                        object:self];
}

- (void)notifyChanged {
    if ([NSThread isMainThread]) {
        [self postChangedOnMain];
    } else {
        [self performSelectorOnMainThread:@selector(postChangedOnMain)
                               withObject:nil
                            waitUntilDone:NO];
    }
}

- (NSArray *)playlists {
    @synchronized(self) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[_playlists count]];
        for (ELLocalPlaylist *pl in _playlists) {
            [out addObject:[pl snapshotCopy]];
        }
        return [NSArray arrayWithArray:out];
    }
}

- (ELLocalPlaylist *)playlistWithId:(NSString *)playlistId {
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        return pl ? [pl snapshotCopy] : nil;
    }
}

- (ELLocalPlaylist *)createPlaylistNamed:(NSString *)name {
    NSString *clean = el_sanitize_playlist_name(name);
    if ([clean length] == 0) clean = @"New Playlist";

    ELLocalPlaylist *created = nil;
    NSArray *snapshot = nil;
    @synchronized(self) {
        _nextIdCounter++;
        NSString *pid = [NSString stringWithFormat:@"lp_%llu_%lu_%u",
                         (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000.0),
                         (unsigned long)_nextIdCounter,
                         (unsigned int)(arc4random() & 0xFFFF)];
        ELLocalPlaylist *pl = [[[ELLocalPlaylist alloc] init] autorelease];
        pl.playlistId = pid;
        pl.name = clean;
        [_playlists insertObject:pl atIndex:0];
        created = [pl snapshotCopy];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
    return created;
}

- (ELLocalPlaylist *)upsertPlaylistWithId:(NSString *)playlistId name:(NSString *)name tracks:(NSArray *)tracks {
    if (![playlistId isKindOfClass:[NSString class]]) return nil;
    NSString *cleanId = [playlistId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanId length] == 0) return nil;
    if ([cleanId length] > 128) cleanId = [cleanId substringToIndex:128];

    NSString *cleanName = el_sanitize_playlist_name(name);
    if ([cleanName length] == 0) cleanName = @"Downloaded Playlist";

    NSMutableArray *deduped = [NSMutableArray arrayWithCapacity:[tracks count]];
    NSMutableSet *seen = [NSMutableSet setWithCapacity:[tracks count]];
    for (ELTrack *t in tracks) {
        if ([t isKindOfClass:[ELTrack class]] && el_is_valid_video_id(t.videoId) && ![seen containsObject:t.videoId]) {
            [seen addObject:t.videoId];
            [deduped addObject:t];
        }
    }

    ELLocalPlaylist *result = nil;
    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:cleanId];
        if (!pl) {
            pl = [[[ELLocalPlaylist alloc] init] autorelease];
            pl.playlistId = cleanId;
            [_playlists insertObject:pl atIndex:0];
        }
        pl.name = cleanName;
        [pl.tracks removeAllObjects];
        [pl.tracks addObjectsFromArray:deduped];
        result = [pl snapshotCopy];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
    return result;
}

- (void)renamePlaylistId:(NSString *)playlistId toName:(NSString *)newName {
    NSString *clean = el_sanitize_playlist_name(newName);
    if ([clean length] == 0) return;

    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl || [pl.name isEqualToString:clean]) return;
        pl.name = clean;
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
}

- (void)deletePlaylistId:(NSString *)playlistId {
    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl) return;
        [_playlists removeObject:pl];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
}

- (BOOL)addTrack:(ELTrack *)track toPlaylistId:(NSString *)playlistId {
    if (!track || !el_is_valid_video_id(track.videoId)) return NO;

    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl) return NO;
        for (ELTrack *existing in pl.tracks) {
            if ([existing.videoId isEqualToString:track.videoId]) {
                return NO;
            }
        }
        [pl.tracks addObject:track];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
    return YES;
}

- (void)removeTrackAtIndex:(NSUInteger)index fromPlaylistId:(NSString *)playlistId {
    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl || index >= [pl.tracks count]) return;
        [pl.tracks removeObjectAtIndex:index];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
}

- (void)moveTrackAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex inPlaylistId:(NSString *)playlistId {
    if (fromIndex == toIndex) return;
    NSArray *snapshot = nil;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl) return;
        NSUInteger count = [pl.tracks count];
        if (fromIndex >= count || toIndex >= count) return;
        ELTrack *moved = [[pl.tracks objectAtIndex:fromIndex] retain];
        [pl.tracks removeObjectAtIndex:fromIndex];
        [pl.tracks insertObject:moved atIndex:toIndex];
        [moved release];
        snapshot = [self serializedSnapshotLocked];
    }
    [self saveSnapshotsToDisk:snapshot];
    [self notifyChanged];
}

- (BOOL)playlistId:(NSString *)playlistId containsVideoId:(NSString *)videoId {
    if (!el_is_valid_video_id(videoId)) return NO;
    @synchronized(self) {
        ELLocalPlaylist *pl = [self findPlaylistLocked:playlistId];
        if (!pl) return NO;
        for (ELTrack *t in pl.tracks) {
            if ([t.videoId isEqualToString:videoId]) return YES;
        }
        return NO;
    }
}

@end

#endif /* EL_FEATURE_LOCAL_PLAYLISTS */
