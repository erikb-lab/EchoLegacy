#import "ELTrack.h"

static NSString *el_string_or_default(NSDictionary *dict, NSString *key, NSString *fallback) {
    id val = [dict objectForKey:key];
    return [val isKindOfClass:[NSString class]] ? (NSString *)val : fallback;
}

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
    [_subtitleText release];
    [super dealloc];
}

- (void)setArtist:(NSString *)artist {
    if (_artist != artist) {
        [_artist release];
        _artist = [artist copy];
        [_subtitleText release];
        _subtitleText = nil;
    }
}

- (void)setDurationText:(NSString *)durationText {
    if (_durationText != durationText) {
        [_durationText release];
        _durationText = [durationText copy];
        [_subtitleText release];
        _subtitleText = nil;
    }
}

- (NSString *)subtitleText {
    if (!_subtitleText) {
        if ([_durationText length] > 0) {
            _subtitleText = [[NSString alloc] initWithFormat:@"%@  •  %@",
                             _artist ? _artist : @"",
                             _durationText];
        } else {
            _subtitleText = [_artist copy];
        }
    }
    return _subtitleText;
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
    t.title = el_string_or_default(dict, @"title", @"Untitled");
    t.artist = el_string_or_default(dict, @"artist", @"Unknown Artist");
    t.album = el_string_or_default(dict, @"album", @"");
    t.durationText = el_string_or_default(dict, @"durationText", @"");
    t.durationSeconds = [[dict objectForKey:@"durationSeconds"] integerValue];
    t.thumbURL = el_string_or_default(dict, @"thumbURL", @"");
    t.artURL = el_string_or_default(dict, @"artURL", t.thumbURL);
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
    p.title = el_string_or_default(dict, @"title", @"Playlist");
    p.subtitle = el_string_or_default(dict, @"subtitle", @"");
    p.thumbURL = el_string_or_default(dict, @"thumbURL", @"");
    return p;
}

@end
