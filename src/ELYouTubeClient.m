#import "ELYouTubeClient.h"
#import "ELAuthManager.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"

NSString *const ELLibraryUpdatedNotification = @"ELLibraryUpdatedNotification";

static NSString *const kVisionOSUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
static NSString *const kWebUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0";

@implementation ELStreamInfo
@synthesize url = _url;
@synthesize userAgent = _userAgent;
@synthesize itag = _itag;
@synthesize contentLength = _contentLength;
@synthesize durationSeconds = _durationSeconds;

- (void)dealloc {
    [_url release];
    [_userAgent release];
    [super dealloc];
}
@end

static NSString *el_library_cache_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"library_cache.plist"];
}

/* Rewrites Google/YouTube thumbnail URLs to a clean iOS 4.1-compatible JPEG */
static NSString *el_resize_google_thumb(NSString *url, int size) {
    if ([url length] == 0) return @"";
    if ([url hasPrefix:@"//"]) {
        url = [@"https:" stringByAppendingString:url];
    }
    /* iOS 4.1 UIImage does not decode WebP; convert YouTube vi_webp URLs to JPEG */
    if ([url rangeOfString:@"/vi_webp/"].location != NSNotFound) {
        url = [url stringByReplacingOccurrencesOfString:@"/vi_webp/" withString:@"/vi/"];
        url = [url stringByReplacingOccurrencesOfString:@".webp" withString:@".jpg"];
    }
    NSRange eq = [url rangeOfString:@"=w" options:NSBackwardsSearch];
    if (eq.location != NSNotFound) {
        NSString *prefix = [url substringToIndex:eq.location];
        return [NSString stringWithFormat:@"%@=w%d-h%d-l90-rj", prefix, size, size];
    }
    NSRange sq = [url rangeOfString:@"=s" options:NSBackwardsSearch];
    if (sq.location != NSNotFound) {
        NSString *prefix = [url substringToIndex:sq.location];
        return [NSString stringWithFormat:@"%@=s%d-c-rj", prefix, size];
    }
    return url;
}

static NSString *el_text_from_yt_obj(id obj) {
    if (![obj isKindOfClass:[NSDictionary class]]) return @"";
    NSString *simple = [ELJSON string:obj forKey:@"simpleText"];
    if ([simple length] > 0) return simple;
    NSArray *runs = [ELJSON array:obj forKey:@"runs"];
    if ([runs count] > 0) {
        NSMutableString *out = [NSMutableString string];
        for (id r in runs) {
            NSString *t = [ELJSON string:r forKey:@"text"];
            if (t) [out appendString:t];
        }
        return out;
    }
    return @"";
}

static NSInteger el_parse_duration_text(NSString *text) {
    if ([text length] == 0) return 0;
    NSArray *parts = [text componentsSeparatedByString:@":"];
    if ([parts count] == 2) {
        return [[parts objectAtIndex:0] integerValue] * 60 + [[parts objectAtIndex:1] integerValue];
    }
    if ([parts count] == 3) {
        return [[parts objectAtIndex:0] integerValue] * 3600 +
               [[parts objectAtIndex:1] integerValue] * 60 +
               [[parts objectAtIndex:2] integerValue];
    }
    return 0;
}

static BOOL el_looks_like_duration(NSString *s) {
    if ([s length] < 3 || [s length] > 8) return NO;
    NSRange colon = [s rangeOfString:@":"];
    if (colon.location == NSNotFound) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:"];
    NSCharacterSet *inStr = [NSCharacterSet characterSetWithCharactersInString:s];
    return [allowed isSupersetOfSet:inStr];
}

static NSString *el_extract_best_thumb(NSDictionary *thumbRenderer) {
    NSDictionary *thumbObj = [ELJSON dict:thumbRenderer forKey:@"thumbnail"];
    NSArray *thumbs = [ELJSON array:thumbObj forKey:@"thumbnails"];
    if ([thumbs count] == 0) return @"";
    NSDictionary *last = [thumbs lastObject];
    return [ELJSON string:last forKey:@"url"] ? [ELJSON string:last forKey:@"url"] : @"";
}

static ELTrack *el_parse_music_list_item(NSDictionary *renderer) {
    if (![renderer isKindOfClass:[NSDictionary class]]) return nil;

    NSString *videoId = nil;
    NSDictionary *plData = [ELJSON dict:renderer forKey:@"playlistItemData"];
    if (plData) videoId = [ELJSON string:plData forKey:@"videoId"];

    if ([videoId length] == 0) {
        NSDictionary *ov = [ELJSON dict:renderer forKey:@"overlay"];
        NSDictionary *mtor = [ELJSON dict:ov forKey:@"musicItemThumbnailOverlayRenderer"];
        NSDictionary *content = [ELJSON dict:mtor forKey:@"content"];
        NSDictionary *playBtn = [ELJSON dict:content forKey:@"musicPlayButtonRenderer"];
        NSDictionary *nav = [ELJSON dict:playBtn forKey:@"playNavigationEndpoint"];
        NSDictionary *watch = [ELJSON dict:nav forKey:@"watchEndpoint"];
        videoId = [ELJSON string:watch forKey:@"videoId"];
    }

    NSArray *flexCols = [ELJSON array:renderer forKey:@"flexColumns"];
    NSString *title = nil;
    NSString *artist = nil;
    NSString *album = nil;
    NSString *duration = nil;

    if ([flexCols count] > 0) {
        NSDictionary *c0 = [ELJSON dict:[flexCols objectAtIndex:0] forKey:@"musicResponsiveListItemFlexColumnRenderer"];
        NSArray *runs = [ELJSON array:[ELJSON dict:c0 forKey:@"text"] forKey:@"runs"];
        if ([runs count] > 0) {
            NSDictionary *r0 = [runs objectAtIndex:0];
            title = [ELJSON string:r0 forKey:@"text"];
            if ([videoId length] == 0) {
                NSDictionary *nav = [ELJSON dict:r0 forKey:@"navigationEndpoint"];
                NSDictionary *watch = [ELJSON dict:nav forKey:@"watchEndpoint"];
                videoId = [ELJSON string:watch forKey:@"videoId"];
            }
        }
    }

    if ([videoId length] == 0 || [title length] == 0) return nil;

    if ([flexCols count] > 1) {
        NSDictionary *c1 = [ELJSON dict:[flexCols objectAtIndex:1] forKey:@"musicResponsiveListItemFlexColumnRenderer"];
        NSArray *runs = [ELJSON array:[ELJSON dict:c1 forKey:@"text"] forKey:@"runs"];
        NSMutableArray *artists = [NSMutableArray array];
        for (id runObj in runs) {
            if (![runObj isKindOfClass:[NSDictionary class]]) continue;
            NSString *txt = [[ELJSON string:runObj forKey:@"text"]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([txt length] == 0 || [txt isEqualToString:@"\u2022"] || [txt isEqualToString:@"&"] || [txt isEqualToString:@","]) continue;
            if ([txt isEqualToString:@"Song"] || [txt isEqualToString:@"Video"]) continue;

            if (el_looks_like_duration(txt)) {
                duration = txt;
                continue;
            }
            NSDictionary *nav = [ELJSON dict:runObj forKey:@"navigationEndpoint"];
            NSDictionary *be = [ELJSON dict:nav forKey:@"browseEndpoint"];
            NSDictionary *cfg = [ELJSON dict:[ELJSON dict:be forKey:@"browseEndpointContextSupportedConfigs"]
                                      forKey:@"browseEndpointContextMusicConfig"];
            NSString *pageType = [ELJSON string:cfg forKey:@"pageType"];
            if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ALBUM"]) {
                album = txt;
            } else if ([pageType isEqualToString:@"MUSIC_PAGE_TYPE_ARTIST"]) {
                [artists addObject:txt];
            } else if ([artists count] == 0 && [txt rangeOfString:@"plays"].location == NSNotFound &&
                       [txt rangeOfString:@"views"].location == NSNotFound) {
                [artists addObject:txt];
            }
        }
        if ([artists count] > 0) artist = [artists componentsJoinedByString:@", "];
    }

    if ([duration length] == 0) {
        NSArray *fixedCols = [ELJSON array:renderer forKey:@"fixedColumns"];
        if ([fixedCols count] > 0) {
            NSDictionary *fc = [ELJSON dict:[fixedCols objectAtIndex:0] forKey:@"musicResponsiveListItemFixedColumnRenderer"];
            NSArray *runs = [ELJSON array:[ELJSON dict:fc forKey:@"text"] forKey:@"runs"];
            if ([runs count] > 0) {
                NSString *t = [ELJSON string:[runs objectAtIndex:0] forKey:@"text"];
                if (el_looks_like_duration(t)) duration = t;
            }
        }
    }

    NSDictionary *thumbWrap = [ELJSON dict:renderer forKey:@"thumbnail"];
    NSString *rawThumb = el_extract_best_thumb([ELJSON dict:thumbWrap forKey:@"musicThumbnailRenderer"]);

    ELTrack *track = [[[ELTrack alloc] init] autorelease];
    track.videoId = videoId;
    track.title = title;
    track.artist = ([artist length] > 0) ? artist : @"Unknown Artist";
    track.album = album ? album : @"";
    track.durationText = duration ? duration : @"";
    track.durationSeconds = el_parse_duration_text(duration);
    track.thumbURL = el_resize_google_thumb(rawThumb, 120);
    track.artURL = el_resize_google_thumb(rawThumb, 300);
    return track;
}

static ELTrack *el_parse_tile_video(NSDictionary *tile) {
    if (![tile isKindOfClass:[NSDictionary class]]) return nil;
    NSString *ctype = [ELJSON string:tile forKey:@"contentType"];
    if (ctype && ![ctype isEqualToString:@"TILE_CONTENT_TYPE_VIDEO"]) return nil;

    NSString *videoId = [ELJSON string:tile forKey:@"contentId"];
    if ([videoId length] == 0) {
        NSDictionary *cmd = [ELJSON dict:tile forKey:@"onSelectCommand"];
        NSDictionary *we = [ELJSON dict:cmd forKey:@"watchEndpoint"];
        videoId = [ELJSON string:we forKey:@"videoId"];
    }
    if ([videoId length] == 0) return nil;

    NSDictionary *meta = [ELJSON dict:[ELJSON dict:tile forKey:@"metadata"] forKey:@"tileMetadataRenderer"];
    NSString *title = el_text_from_yt_obj([meta objectForKey:@"title"]);
    if ([title length] == 0) return nil;

    NSString *artist = @"Unknown Artist";
    NSArray *lines = [ELJSON array:meta forKey:@"lines"];
    if ([lines count] > 0) {
        NSDictionary *lr = [ELJSON dict:[lines objectAtIndex:0] forKey:@"lineRenderer"];
        NSArray *items = [ELJSON array:lr forKey:@"items"];
        if ([items count] > 0) {
            NSDictionary *lir = [ELJSON dict:[items objectAtIndex:0] forKey:@"lineItemRenderer"];
            NSString *a = el_text_from_yt_obj([lir objectForKey:@"text"]);
            if ([a length] > 0) artist = a;
        }
    }

    NSDictionary *hdr = [ELJSON dict:[ELJSON dict:tile forKey:@"header"] forKey:@"tileHeaderRenderer"];
    NSString *rawThumb = el_extract_best_thumb(hdr);
    NSString *duration = @"";
    NSArray *overlays = [ELJSON array:hdr forKey:@"thumbnailOverlays"];
    for (id ov in overlays) {
        NSDictionary *ts = [ELJSON dict:ov forKey:@"thumbnailOverlayTimeStatusRenderer"];
        if (ts) {
            NSString *dt = el_text_from_yt_obj([ts objectForKey:@"text"]);
            if (el_looks_like_duration(dt)) {
                duration = dt;
                break;
            }
        }
    }

    ELTrack *track = [[[ELTrack alloc] init] autorelease];
    track.videoId = videoId;
    track.title = title;
    track.artist = artist;
    track.album = @"";
    track.durationText = duration;
    track.durationSeconds = el_parse_duration_text(duration);
    track.thumbURL = el_resize_google_thumb(rawThumb, 120);
    track.artURL = el_resize_google_thumb(rawThumb, 300);
    return track;
}

static void el_collect_tracks_recursive(id node, NSMutableArray *outTracks, NSMutableSet *seenIds) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSDictionary *renderer = [ELJSON dict:dict forKey:@"musicResponsiveListItemRenderer"];
        if (renderer) {
            ELTrack *t = el_parse_music_list_item(renderer);
            if (t && ![seenIds containsObject:t.videoId]) {
                [seenIds addObject:t.videoId];
                [outTracks addObject:t];
            }
            return;
        }
        NSDictionary *tile = [ELJSON dict:dict forKey:@"tileRenderer"];
        if (tile) {
            ELTrack *t = el_parse_tile_video(tile);
            if (t && ![seenIds containsObject:t.videoId]) {
                [seenIds addObject:t.videoId];
                [outTracks addObject:t];
            }
            return;
        }
        for (id key in dict) {
            el_collect_tracks_recursive([dict objectForKey:key], outTracks, seenIds);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)node) {
            el_collect_tracks_recursive(child, outTracks, seenIds);
        }
    }
}

static void el_collect_playlists_recursive(id node, NSMutableArray *outPlaylists, NSMutableSet *seenIds) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)node;
        NSDictionary *tile = [ELJSON dict:dict forKey:@"tileRenderer"];
        if (tile) {
            NSString *ctype = [ELJSON string:tile forKey:@"contentType"];
            if ([ctype isEqualToString:@"TILE_CONTENT_TYPE_PLAYLIST"]) {
                NSString *pid = [ELJSON string:tile forKey:@"contentId"];
                if ([pid length] == 0) {
                    NSDictionary *be = [ELJSON dict:[ELJSON dict:tile forKey:@"onSelectCommand"] forKey:@"browseEndpoint"];
                    NSString *bid = [ELJSON string:be forKey:@"browseId"];
                    if ([bid hasPrefix:@"VL"] && [bid length] > 2) pid = [bid substringFromIndex:2];
                }
                if ([pid length] > 0 && ![pid isEqualToString:@"LM"] && ![seenIds containsObject:pid]) {
                    NSDictionary *meta = [ELJSON dict:[ELJSON dict:tile forKey:@"metadata"] forKey:@"tileMetadataRenderer"];
                    NSString *title = el_text_from_yt_obj([meta objectForKey:@"title"]);
                    NSMutableArray *subParts = [NSMutableArray array];
                    NSArray *lines = [ELJSON array:meta forKey:@"lines"];
                    for (id lineObj in lines) {
                        NSDictionary *lr = [ELJSON dict:lineObj forKey:@"lineRenderer"];
                        for (id itemObj in [ELJSON array:lr forKey:@"items"]) {
                            NSDictionary *lir = [ELJSON dict:itemObj forKey:@"lineItemRenderer"];
                            NSString *s = el_text_from_yt_obj([lir objectForKey:@"text"]);
                            if ([s length] > 0) [subParts addObject:s];
                        }
                    }
                    NSDictionary *hdr = [ELJSON dict:[ELJSON dict:tile forKey:@"header"] forKey:@"tileHeaderRenderer"];
                    NSString *rawThumb = el_extract_best_thumb(hdr);

                    ELPlaylist *pl = [[[ELPlaylist alloc] init] autorelease];
                    pl.playlistId = pid;
                    pl.title = ([title length] > 0) ? title : @"Playlist";
                    pl.subtitle = [subParts componentsJoinedByString:@" • "];
                    pl.thumbURL = el_resize_google_thumb(rawThumb, 120);
                    [seenIds addObject:pid];
                    [outPlaylists addObject:pl];
                }
            }
            return;
        }
        NSDictionary *twoRow = [ELJSON dict:dict forKey:@"musicTwoRowItemRenderer"];
        if (twoRow) {
            NSDictionary *nav = [ELJSON dict:twoRow forKey:@"navigationEndpoint"];
            NSDictionary *be = [ELJSON dict:nav forKey:@"browseEndpoint"];
            NSString *browseId = [ELJSON string:be forKey:@"browseId"];
            if ([browseId hasPrefix:@"VL"] && [browseId length] > 2) {
                NSString *pid = [browseId substringFromIndex:2];
                if (![pid isEqualToString:@"LM"] && ![seenIds containsObject:pid]) {
                    NSArray *tRuns = [ELJSON array:[ELJSON dict:twoRow forKey:@"title"] forKey:@"runs"];
                    NSString *title = ([tRuns count] > 0) ? [ELJSON string:[tRuns objectAtIndex:0] forKey:@"text"] : @"Playlist";
                    NSArray *sRuns = [ELJSON array:[ELJSON dict:twoRow forKey:@"subtitle"] forKey:@"runs"];
                    NSMutableString *sub = [NSMutableString string];
                    for (id r in sRuns) {
                        NSString *txt = [ELJSON string:r forKey:@"text"];
                        if (txt) [sub appendString:txt];
                    }
                    NSDictionary *tr = [ELJSON dict:twoRow forKey:@"thumbnailRenderer"];
                    NSString *rawThumb = el_extract_best_thumb([ELJSON dict:tr forKey:@"musicThumbnailRenderer"]);

                    ELPlaylist *pl = [[[ELPlaylist alloc] init] autorelease];
                    pl.playlistId = pid;
                    pl.title = ([title length] > 0) ? title : @"Playlist";
                    pl.subtitle = sub;
                    pl.thumbURL = el_resize_google_thumb(rawThumb, 120);
                    [seenIds addObject:pid];
                    [outPlaylists addObject:pl];
                }
            }
            return;
        }
        for (id key in dict) {
            el_collect_playlists_recursive([dict objectForKey:key], outPlaylists, seenIds);
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)node) {
            el_collect_playlists_recursive(child, outPlaylists, seenIds);
        }
    }
}

@implementation ELYouTubeClient

+ (ELYouTubeClient *)sharedClient {
    static ELYouTubeClient *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELYouTubeClient alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _cachedLikedSongs = [[NSArray alloc] init];
        _cachedPlaylists = [[NSArray alloc] init];
        _streamInfoCache = [[NSMutableDictionary alloc] init];
        _streamInfoLRU = [[NSMutableArray alloc] init];
        [self loadLibraryCache];
    }
    return self;
}

- (void)dealloc {
    [_cachedLikedSongs release];
    [_cachedPlaylists release];
    [_visitorData release];
    [_streamInfoCache release];
    [_streamInfoLRU release];
    [super dealloc];
}

- (NSArray *)cachedLikedSongs {
    @synchronized(self) {
        return [[_cachedLikedSongs retain] autorelease];
    }
}

- (NSArray *)cachedPlaylists {
    @synchronized(self) {
        return [[_cachedPlaylists retain] autorelease];
    }
}

- (NSTimeInterval)lastSyncTime {
    @synchronized(self) {
        return _lastSyncTime;
    }
}

- (void)loadLibraryCache {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:el_library_cache_path()];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *songs = [NSMutableArray array];
    for (id item in [d objectForKey:@"likedSongs"]) {
        ELTrack *t = [ELTrack trackFromDictionary:item];
        if (t) [songs addObject:t];
    }
    NSMutableArray *pls = [NSMutableArray array];
    for (id item in [d objectForKey:@"playlists"]) {
        ELPlaylist *p = [ELPlaylist playlistFromDictionary:item];
        if (p) [pls addObject:p];
    }
    @synchronized(self) {
        [_cachedLikedSongs release];
        _cachedLikedSongs = [songs copy];
        [_cachedPlaylists release];
        _cachedPlaylists = [pls copy];
        _lastSyncTime = [[d objectForKey:@"lastSyncTime"] doubleValue];
    }
}

- (void)saveLibraryCache {
    NSMutableArray *songDicts = [NSMutableArray array];
    NSMutableArray *plDicts = [NSMutableArray array];
    NSTimeInterval ts = 0;
    @synchronized(self) {
        for (ELTrack *t in _cachedLikedSongs) [songDicts addObject:[t toDictionary]];
        for (ELPlaylist *p in _cachedPlaylists) [plDicts addObject:[p toDictionary]];
        ts = _lastSyncTime;
    }
    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
                             songDicts, @"likedSongs",
                             plDicts, @"playlists",
                             [NSNumber numberWithDouble:ts], @"lastSyncTime",
                             nil];
    [payload writeToFile:el_library_cache_path() atomically:YES];
}

- (void)clearLibraryCache {
    @synchronized(self) {
        [_cachedLikedSongs release]; _cachedLikedSongs = [[NSArray alloc] init];
        [_cachedPlaylists release];  _cachedPlaylists = [[NSArray alloc] init];
        _lastSyncTime = 0;
    }
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    [fm removeItemAtPath:el_library_cache_path() error:nil];
    [self performSelectorOnMainThread:@selector(postLibraryUpdatedOnMain) withObject:nil waitUntilDone:NO];
}

- (void)postLibraryUpdatedOnMain {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELLibraryUpdatedNotification object:self];
}

- (NSDictionary *)webRemixContext {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            @"WEB_REMIX", @"clientName",
                            @"1.20250915.03.00", @"clientVersion",
                            @"en", @"hl",
                            @"US", @"gl",
                            nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:client, @"client", nil];
}

- (NSDictionary *)postYTMusicEndpoint:(NSString *)endpoint
                                 body:(NSDictionary *)body
                         authenticated:(BOOL)useAuth
                                error:(NSString **)outError {
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                    @"application/json", @"Content-Type",
                                    kWebUserAgent, @"User-Agent",
                                    @"https://music.youtube.com", @"Origin",
                                    @"https://music.youtube.com/", @"Referer",
                                    @"gzip", @"Accept-Encoding",
                                    nil];
    if (useAuth) {
        NSString *authErr = nil;
        NSString *token = [[ELAuthManager sharedManager] validAccessTokenWithError:&authErr];
        if ([token length] == 0) {
            if (outError) *outError = authErr ? authErr : @"Sign in with Google first";
            return nil;
        }
        [headers setObject:[NSString stringWithFormat:@"Bearer %@", token] forKey:@"Authorization"];
        [headers setObject:[NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]]
                    forKey:@"X-Goog-Request-Time"];
    }

    NSString *url = [NSString stringWithFormat:@"https://music.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint];
    NSData *payload = [ELJSON dataWithObject:body];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:url headers:headers body:payload];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (resp.statusCode >= 400 || ![json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *errObj = [ELJSON dict:json forKey:@"error"];
        NSString *msg = [ELJSON string:errObj forKey:@"message"];
        if (outError) *outError = msg ? msg : [NSString stringWithFormat:@"YouTube Music HTTP %ld", (long)resp.statusCode];
        return nil;
    }
    return json;
}

- (NSArray *)searchSongs:(NSString *)query error:(NSString **)outError {
    if ([query length] == 0) return [NSArray array];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          [self webRemixContext], @"context",
                          query, @"query",
                          @"EgWKAQIIAWoMEAMQBBAJEAoQBRAV", @"params",
                          nil];
    NSDictionary *json = [self postYTMusicEndpoint:@"search" body:body authenticated:NO error:outError];
    if (!json) return nil;

    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    el_collect_tracks_recursive(json, tracks, seen);
    return tracks;
}

- (NSString *)ensureVisitorData {
    @synchronized(self) {
        if ([_visitorData length] > 0) return [[_visitorData copy] autorelease];
    }
    NSDictionary *c = [NSDictionary dictionaryWithObjectsAndKeys:
                       @"WEB", @"clientName",
                       @"2.20250915.01.00", @"clientVersion",
                       nil];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSDictionary dictionaryWithObjectsAndKeys:c, @"client", nil], @"context",
                          nil];
    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"application/json", @"Content-Type",
                          kVisionOSUserAgent, @"User-Agent",
                          @"gzip", @"Accept-Encoding",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false"
                                                        headers:hdrs
                                                           body:[ELJSON dataWithObject:body]];
    if (resp.statusCode == 200 && resp.body) {
        NSDictionary *json = [ELJSON objectWithData:resp.body];
        NSDictionary *rc = [ELJSON dict:json forKey:@"responseContext"];
        NSString *vd = [ELJSON string:rc forKey:@"visitorData"];
        if ([vd length] > 0) {
            @synchronized(self) {
                [_visitorData release];
                _visitorData = [vd copy];
            }
            return vd;
        }
    }
    return @"";
}

#define EL_STREAM_INFO_CACHE_MAX 8
#define EL_STREAM_INFO_TTL_SEC   1500.0

- (void)invalidateCachedStreamForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return;
    @synchronized(self) {
        [_streamInfoCache removeObjectForKey:videoId];
        [_streamInfoLRU removeObject:videoId];
    }
}

- (ELStreamInfo *)resolveAudioStreamForVideoId:(NSString *)videoId error:(NSString **)outError {
    if ([videoId length] == 0) {
        if (outError) *outError = @"Missing videoId";
        return nil;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized(self) {
        NSDictionary *entry = [_streamInfoCache objectForKey:videoId];
        if (entry) {
            NSTimeInterval ts = [[entry objectForKey:@"ts"] doubleValue];
            ELStreamInfo *cached = [entry objectForKey:@"info"];
            if (cached && (now - ts) >= 0.0 && (now - ts) < EL_STREAM_INFO_TTL_SEC) {
                return [[cached retain] autorelease];
            }
            [_streamInfoCache removeObjectForKey:videoId];
            [_streamInfoLRU removeObject:videoId];
        }
    }

    NSString *vd = [self ensureVisitorData];
    NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   @"VISIONOS", @"clientName",
                                   @"1.02", @"clientVersion",
                                   @"Apple", @"deviceMake",
                                   @"RealityDevice17,1", @"deviceModel",
                                   kVisionOSUserAgent, @"userAgent",
                                   @"visionOS", @"osName",
                                   @"26.5.23O471", @"osVersion",
                                   nil];
    if ([vd length] > 0) {
        [client setObject:vd forKey:@"visitorData"];
    }
    NSDictionary *context = [NSDictionary dictionaryWithObjectsAndKeys:client, @"client", nil];
    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          context, @"context",
                          videoId, @"videoId",
                          [NSNumber numberWithBool:YES], @"contentCheckOk",
                          [NSNumber numberWithBool:YES], @"racyCheckOk",
                          nil];
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                    @"application/json", @"Content-Type",
                                    kVisionOSUserAgent, @"User-Agent",
                                    @"https://www.youtube.com", @"Origin",
                                    @"101", @"X-YouTube-Client-Name",
                                    @"1.02", @"X-YouTube-Client-Version",
                                    @"gzip", @"Accept-Encoding",
                                    nil];
    if ([vd length] > 0) {
        [headers setObject:vd forKey:@"X-Goog-Visitor-Id"];
    }

    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
                                                        headers:headers
                                                           body:[ELJSON dataWithObject:body]];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Invalid player response";
        return nil;
    }

    NSDictionary *playStatus = [ELJSON dict:json forKey:@"playabilityStatus"];
    NSString *status = [ELJSON string:playStatus forKey:@"status"];
    if (![status isEqualToString:@"OK"]) {
        NSString *reason = [ELJSON string:playStatus forKey:@"reason"];
        if (outError) *outError = reason ? reason : @"Track unavailable";
        return nil;
    }

    NSDictionary *streamingData = [ELJSON dict:json forKey:@"streamingData"];
    NSArray *adaptive = [ELJSON array:streamingData forKey:@"adaptiveFormats"];

    NSDictionary *chosen = nil;
    /* Prefer itag 140 (128kbps AAC-LC), fallback to any audio/mp4 (e.g. itag 139) */
    for (id fmtObj in adaptive) {
        if (![fmtObj isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = [ELJSON string:fmtObj forKey:@"url"];
        NSString *mime = [ELJSON string:fmtObj forKey:@"mimeType"];
        NSInteger itag = [[ELJSON number:fmtObj forKey:@"itag"] integerValue];
        if ([url length] == 0) continue;
        if (itag == 140) {
            chosen = fmtObj;
            break;
        }
        if (!chosen && mime && [mime rangeOfString:@"audio/mp4"].location != NSNotFound) {
            chosen = fmtObj;
        }
    }

    if (!chosen) {
        if (outError) *outError = @"No compatible AAC stream found";
        return nil;
    }

    ELStreamInfo *info = [[[ELStreamInfo alloc] init] autorelease];
    info.url = [ELJSON string:chosen forKey:@"url"];
    info.userAgent = kVisionOSUserAgent;
    info.itag = [[ELJSON number:chosen forKey:@"itag"] integerValue];
    NSString *clStr = [ELJSON string:chosen forKey:@"contentLength"];
    info.contentLength = clStr ? [clStr longLongValue] : 0;
    NSString *durMsStr = [ELJSON string:chosen forKey:@"approxDurationMs"];
    if (durMsStr) {
        info.durationSeconds = [durMsStr doubleValue] / 1000.0;
    } else {
        NSDictionary *vdObj = [ELJSON dict:json forKey:@"videoDetails"];
        NSString *lenStr = [ELJSON string:vdObj forKey:@"lengthSeconds"];
        if (lenStr) info.durationSeconds = [lenStr doubleValue];
    }

    @synchronized(self) {
        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                               info, @"info",
                               [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]], @"ts",
                               nil];
        [_streamInfoCache setObject:entry forKey:videoId];
        [_streamInfoLRU removeObject:videoId];
        [_streamInfoLRU addObject:videoId];
        while ([_streamInfoLRU count] > EL_STREAM_INFO_CACHE_MAX) {
            NSString *evict = [_streamInfoLRU objectAtIndex:0];
            [_streamInfoCache removeObjectForKey:evict];
            [_streamInfoLRU removeObjectAtIndex:0];
        }
    }
    return info;
}

- (NSDictionary *)tvContext {
    NSDictionary *client = [NSDictionary dictionaryWithObjectsAndKeys:
                            @"TVHTML5", @"clientName",
                            @"7.20250915.10.00", @"clientVersion",
                            @"en", @"hl",
                            @"US", @"gl",
                            nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:client, @"client", nil];
}

- (NSDictionary *)postTVBrowseId:(NSString *)browseId error:(NSString **)outError {
    NSString *authErr = nil;
    NSString *token = [[ELAuthManager sharedManager] validAccessTokenWithError:&authErr];
    if ([token length] == 0) {
        if (outError) *outError = authErr ? authErr : @"Sign in with Google first";
        return nil;
    }

    NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                          [self tvContext], @"context",
                          browseId, @"browseId",
                          nil];
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                             @"application/json", @"Content-Type",
                             @"Mozilla/5.0 (Cobalt/Version)", @"User-Agent",
                             [NSString stringWithFormat:@"Bearer %@", token], @"Authorization",
                             @"gzip", @"Accept-Encoding",
                             nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://youtubei.googleapis.com/youtubei/v1/browse?prettyPrint=false"
                                                        headers:headers
                                                           body:[ELJSON dataWithObject:body]];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (resp.statusCode >= 400 || ![json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *errObj = [ELJSON dict:json forKey:@"error"];
        NSString *msg = [ELJSON string:errObj forKey:@"message"];
        if (outError) *outError = msg ? msg : [NSString stringWithFormat:@"YouTube TV HTTP %ld", (long)resp.statusCode];
        return nil;
    }
    return json;
}

- (NSArray *)fetchTracksForPlaylistId:(NSString *)playlistId error:(NSString **)outError {
    NSString *browseId = [playlistId hasPrefix:@"VL"] ? playlistId : [NSString stringWithFormat:@"VL%@", playlistId];
    NSDictionary *json = nil;
    if ([[ELAuthManager sharedManager] isSignedIn]) {
        json = [self postTVBrowseId:browseId error:outError];
    } else {
        NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                              [self webRemixContext], @"context",
                              browseId, @"browseId",
                              nil];
        json = [self postYTMusicEndpoint:@"browse" body:body authenticated:NO error:outError];
    }
    if (!json) return nil;

    NSMutableArray *tracks = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    el_collect_tracks_recursive(json, tracks, seen);
    return tracks;
}

- (BOOL)syncLibraryWithError:(NSString **)outError {
    if (![[ELAuthManager sharedManager] isSignedIn]) {
        if (outError) *outError = @"Sign in with Google first";
        return NO;
    }

    /* 1. Fetch Liked Music (VLLM) via TVHTML5 OAuth client */
    NSString *likedErr = nil;
    NSArray *liked = [self fetchTracksForPlaylistId:@"VLLM" error:&likedErr];

    /* 2. Fetch Library Playlists (FEplaylist_aggregation) via TVHTML5 OAuth client */
    NSString *plErr = nil;
    NSDictionary *plJson = [self postTVBrowseId:@"FEplaylist_aggregation" error:&plErr];
    NSMutableArray *playlists = [NSMutableArray array];
    if (plJson) {
        NSMutableSet *seenPl = [NSMutableSet set];
        el_collect_playlists_recursive(plJson, playlists, seenPl);
    }

    if (!liked && !plJson) {
        if (outError) *outError = likedErr ? likedErr : (plErr ? plErr : @"Library sync failed");
        return NO;
    }

    @synchronized(self) {
        [_cachedLikedSongs release];
        _cachedLikedSongs = liked ? [liked copy] : [[NSArray alloc] init];
        [_cachedPlaylists release];
        _cachedPlaylists = [playlists copy];
        _lastSyncTime = [[NSDate date] timeIntervalSince1970];
    }

    [self saveLibraryCache];
    [self performSelectorOnMainThread:@selector(postLibraryUpdatedOnMain) withObject:nil waitUntilDone:NO];
    return YES;
}

- (BOOL)isTrackLiked:(NSString *)videoId {
    if ([videoId length] == 0) return NO;
    @synchronized(self) {
        for (ELTrack *t in _cachedLikedSongs) {
            if ([t.videoId isEqualToString:videoId]) return YES;
        }
    }
    return NO;
}

- (BOOL)setLiked:(BOOL)liked forTrack:(ELTrack *)track error:(NSString **)outError {
    if (!track || [track.videoId length] == 0) {
        if (outError) *outError = @"Invalid track";
        return NO;
    }

    if ([[ELAuthManager sharedManager] isSignedIn]) {
        NSString *authErr = nil;
        NSString *token = [[ELAuthManager sharedManager] validAccessTokenWithError:&authErr];
        if ([token length] == 0) {
            if (outError) *outError = authErr ? authErr : @"Sign in with Google first";
            return NO;
        }

        NSString *endpoint = liked
            ? @"https://youtubei.googleapis.com/youtubei/v1/like/like?prettyPrint=false"
            : @"https://youtubei.googleapis.com/youtubei/v1/like/removelike?prettyPrint=false";
        NSDictionary *target = [NSDictionary dictionaryWithObject:track.videoId forKey:@"videoId"];
        NSDictionary *body = [NSDictionary dictionaryWithObjectsAndKeys:
                              [self tvContext], @"context",
                              target, @"target",
                              nil];
        NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                                 @"application/json", @"Content-Type",
                                 @"Mozilla/5.0 (Cobalt/Version)", @"User-Agent",
                                 [NSString stringWithFormat:@"Bearer %@", token], @"Authorization",
                                 @"gzip", @"Accept-Encoding",
                                 nil];
        ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:endpoint
                                                            headers:headers
                                                               body:[ELJSON dataWithObject:body]];
        if (resp.errorMessage) {
            if (outError) *outError = resp.errorMessage;
            return NO;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 400) {
            NSDictionary *json = [ELJSON objectWithData:resp.body];
            NSDictionary *errObj = [ELJSON dict:json forKey:@"error"];
            NSString *msg = [ELJSON string:errObj forKey:@"message"];
            if (outError) *outError = msg ? msg : [NSString stringWithFormat:@"YouTube Like HTTP %ld", (long)resp.statusCode];
            return NO;
        }
    }

    @synchronized(self) {
        NSMutableArray *updated = [NSMutableArray arrayWithCapacity:[_cachedLikedSongs count] + 1];
        if (liked) {
            [updated addObject:track];
        }
        for (ELTrack *existing in _cachedLikedSongs) {
            if (![existing.videoId isEqualToString:track.videoId]) {
                [updated addObject:existing];
            }
        }
        [_cachedLikedSongs release];
        _cachedLikedSongs = [updated copy];
    }

    [self saveLibraryCache];
    [self performSelectorOnMainThread:@selector(postLibraryUpdatedOnMain) withObject:nil waitUntilDone:NO];
    return YES;
}

@end
