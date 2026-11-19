#import "ELTrack.h"

@implementation ELTrack
@synthesize videoId = _videoId;
@synthesize title = _title;
@synthesize artist = _artist;
@synthesize album = _album;
@synthesize durationText = _durationText;
@synthesize durationSeconds = _durationSeconds;
@synthesize thumbURL = _thumbURL;
@synthesize artURL = _artURL;

- (void)dealloc {
    [_videoId release];
    [_title release];
    [_artist release];
    [_album release];
    [_durationText release];
    [_thumbURL release];
    [_artURL release];
    [super dealloc];
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (_videoId)      [d setObject:_videoId forKey:@"videoId"];
    if (_title)        [d setObject:_title forKey:@"title"];
    if (_artist)       [d setObject:_artist forKey:@"artist"];
    if (_album)        [d setObject:_album forKey:@"album"];
    if (_durationText) [d setObject:_durationText forKey:@"durationText"];
    [d setObject:[NSNumber numberWithInteger:_durationSeconds] forKey:@"durationSeconds"];
    if (_thumbURL)     [d setObject:_thumbURL forKey:@"thumbURL"];
    if (_artURL)       [d setObject:_artURL forKey:@"artURL"];
    return d;
}

+ (ELTrack *)trackFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *vid = [dict objectForKey:@"videoId"];
    if (!el_is_valid_video_id(vid)) return nil;
    ELTrack *t = [[[ELTrack alloc] init] autorelease];
    t.videoId = vid;
    t.title = [[dict objectForKey:@"title"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"title"] : @"Untitled";
    t.artist = [[dict objectForKey:@"artist"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"artist"] : @"Unknown Artist";
    t.album = [[dict objectForKey:@"album"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"album"] : @"";
    t.durationText = [[dict objectForKey:@"durationText"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"durationText"] : @"";
    t.durationSeconds = [[dict objectForKey:@"durationSeconds"] integerValue];
    t.thumbURL = [[dict objectForKey:@"thumbURL"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"thumbURL"] : @"";
    t.artURL = [[dict objectForKey:@"artURL"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"artURL"] : t.thumbURL;
    return t;
}

+ (NSString *)formatSeconds:(double)sec {
    if (sec < 0 || sec != sec) sec = 0;
    int total = (int)sec;
    int hrs = total / 3600;
    int mins = (total % 3600) / 60;
    int secs = total % 60;
    if (hrs > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hrs, mins, secs];
    }
    return [NSString stringWithFormat:@"%d:%02d", mins, secs];
}

@end

@implementation ELPlaylist
@synthesize playlistId = _playlistId;
@synthesize title = _title;
@synthesize subtitle = _subtitle;
@synthesize thumbURL = _thumbURL;

- (void)dealloc {
    [_playlistId release];
    [_title release];
    [_subtitle release];
    [_thumbURL release];
    [super dealloc];
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (_playlistId) [d setObject:_playlistId forKey:@"playlistId"];
    if (_title)      [d setObject:_title forKey:@"title"];
    if (_subtitle)   [d setObject:_subtitle forKey:@"subtitle"];
    if (_thumbURL)   [d setObject:_thumbURL forKey:@"thumbURL"];
    return d;
}

+ (ELPlaylist *)playlistFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *pid = [dict objectForKey:@"playlistId"];
    if (![pid isKindOfClass:[NSString class]] || [pid length] == 0) return nil;
    ELPlaylist *p = [[[ELPlaylist alloc] init] autorelease];
    p.playlistId = pid;
    p.title = [[dict objectForKey:@"title"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"title"] : @"Playlist";
    p.subtitle = [[dict objectForKey:@"subtitle"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"subtitle"] : @"";
    p.thumbURL = [[dict objectForKey:@"thumbURL"] isKindOfClass:[NSString class]] ? [dict objectForKey:@"thumbURL"] : @"";
    return p;
}

@end
