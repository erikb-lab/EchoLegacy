#import "ELLyricsClient.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"

static NSString *const kLyricsUserAgent = @"EchoLegacy/1.0 (iPhoneOS 4.1; lrclib)";

@implementation ELLyricLine
@synthesize timeSeconds = _timeSeconds;
@synthesize text = _text;

- (void)dealloc {
    [_text release];
    [super dealloc];
}
@end

static NSString *el_url_encode(NSString *s) {
    if (!s) return @"";
    CFStringRef encoded = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (CFStringRef)s,
        NULL,
        CFSTR("!*'();:@&=+$,/?%#[]"),
        kCFStringEncodingUTF8);
    if (!encoded) return @"";
    return [(NSString *)encoded autorelease];
}

static NSString *el_clean_track_query_part(NSString *s) {
    if ([s length] == 0) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    /* Strip common YouTube suffixes like " (Official Video)" or " [Official Audio]" */
    NSArray *markers = [NSArray arrayWithObjects:
                        @"(Official", @"[Official", @"(Audio", @"[Audio",
                        @"(Lyrics", @"[Lyrics", @"(Music Video", @"[Music Video", nil];
    for (NSString *m in markers) {
        NSRange r = [trimmed rangeOfString:m options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound && r.location > 0) {
            trimmed = [[trimmed substringToIndex:r.location]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return trimmed;
}

static BOOL el_parse_lrc_timestamp(NSString *tag, double *outSeconds) {
    /* tag is inside [...], e.g. "01:23.45" or "01:23.456" or "01:23" */
    if ([tag length] < 4) return NO;
    NSRange colon = [tag rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) return NO;

    NSString *minStr = [tag substringToIndex:colon.location];
    NSString *secPart = [tag substringFromIndex:colon.location + 1];

    /* Ensure minStr is all digits */
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 0; i < [minStr length]; i++) {
        if (![digits characterIsMember:[minStr characterAtIndex:i]]) return NO;
    }

    double mins = [minStr doubleValue];
    double secs = 0.0;
    NSRange dot = [secPart rangeOfString:@"."];
    if (dot.location != NSNotFound) {
        NSString *wholeStr = [secPart substringToIndex:dot.location];
        NSString *fracStr = [secPart substringFromIndex:dot.location + 1];
        if ([wholeStr length] == 0) return NO;
        for (NSUInteger i = 0; i < [wholeStr length]; i++) {
            if (![digits characterIsMember:[wholeStr characterAtIndex:i]]) return NO;
        }
        for (NSUInteger i = 0; i < [fracStr length]; i++) {
            if (![digits characterIsMember:[fracStr characterAtIndex:i]]) return NO;
        }
        secs = [wholeStr doubleValue];
        if ([fracStr length] > 0) {
            double denom = 1.0;
            for (NSUInteger i = 0; i < [fracStr length]; i++) denom *= 10.0;
            secs += [fracStr doubleValue] / denom;
        }
    } else {
        for (NSUInteger i = 0; i < [secPart length]; i++) {
            if (![digits characterIsMember:[secPart characterAtIndex:i]]) return NO;
        }
        secs = [secPart doubleValue];
    }

    if (outSeconds) *outSeconds = mins * 60.0 + secs;
    return YES;
}

static NSInteger el_compare_lyric_lines(id a, id b, void *ctx) {
    ELLyricLine *la = (ELLyricLine *)a;
    ELLyricLine *lb = (ELLyricLine *)b;
    if (la.timeSeconds < lb.timeSeconds) return NSOrderedAscending;
    if (la.timeSeconds > lb.timeSeconds) return NSOrderedDescending;
    return NSOrderedSame;
}

static NSArray *el_parse_lrc_string(NSString *lrc) {
    if ([lrc length] == 0) return [NSArray array];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *rawLines = [lrc componentsSeparatedByString:@"\n"];

    for (NSString *raw in rawLines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
        if ([line length] == 0) continue;

        /* Extract one or more leading [mm:ss.xx] tags */
        NSMutableArray *times = [NSMutableArray array];
        NSUInteger pos = 0;
        while (pos < [line length] && [line characterAtIndex:pos] == '[') {
            NSRange close = [line rangeOfString:@"]" options:0 range:NSMakeRange(pos + 1, [line length] - (pos + 1))];
            if (close.location == NSNotFound) break;
            NSString *tag = [line substringWithRange:NSMakeRange(pos + 1, close.location - (pos + 1))];
            double t = 0.0;
            if (el_parse_lrc_timestamp(tag, &t)) {
                [times addObject:[NSNumber numberWithDouble:t]];
                pos = close.location + 1;
            } else {
                /* Metadata tag like [ar:...] or [ti:...] */
                pos = close.location + 1;
                break;
            }
        }

        if ([times count] == 0) continue;

        NSString *text = [[line substringFromIndex:pos]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([text length] == 0) text = @" ";

        for (NSNumber *num in times) {
            ELLyricLine *item = [[[ELLyricLine alloc] init] autorelease];
            item.timeSeconds = [num doubleValue];
            item.text = text;
            [lines addObject:item];
        }
    }

    [lines sortUsingFunction:el_compare_lyric_lines context:NULL];
    return lines;
}

static NSArray *el_parse_plain_lyrics(NSString *plain) {
    if ([plain length] == 0) return [NSArray array];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *rawLines = [plain componentsSeparatedByString:@"\n"];
    for (NSString *raw in rawLines) {
        NSString *text = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r \t"]];
        if ([text length] == 0) continue;
        ELLyricLine *item = [[[ELLyricLine alloc] init] autorelease];
        item.timeSeconds = -1.0;
        item.text = text;
        [lines addObject:item];
    }
    return lines;
}

@implementation ELLyricsClient

+ (ELLyricsClient *)sharedClient {
    static ELLyricsClient *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELLyricsClient alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        _lyricsDir = [[docs stringByAppendingPathComponent:@"EchoLegacy/lyrics"] retain];
        NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
        [fm createDirectoryAtPath:_lyricsDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
    return self;
}

- (void)dealloc {
    [_lyricsDir release];
    [super dealloc];
}

- (NSString *)lyricsFilePathForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return nil;
    return [_lyricsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lrc", videoId]];
}

- (NSString *)plainLyricsFilePathForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return nil;
    return [_lyricsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", videoId]];
}

- (NSArray *)cachedLyricsForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return nil;
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *lrcPath = [self lyricsFilePathForVideoId:videoId];
    if (lrcPath && [fm fileExistsAtPath:lrcPath]) {
        NSString *raw = [NSString stringWithContentsOfFile:lrcPath encoding:NSUTF8StringEncoding error:nil];
        if ([raw length] > 0) {
            NSArray *parsed = el_parse_lrc_string(raw);
            if ([parsed count] > 0) return parsed;
        }
    }
    NSString *txtPath = [self plainLyricsFilePathForVideoId:videoId];
    if (txtPath && [fm fileExistsAtPath:txtPath]) {
        NSString *raw = [NSString stringWithContentsOfFile:txtPath encoding:NSUTF8StringEncoding error:nil];
        if ([raw length] > 0) {
            NSArray *parsed = el_parse_plain_lyrics(raw);
            if ([parsed count] > 0) return parsed;
        }
    }
    return nil;
}

- (void)deleteCachedLyricsForVideoId:(NSString *)videoId {
    if ([videoId length] == 0) return;
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *lrcPath = [self lyricsFilePathForVideoId:videoId];
    NSString *txtPath = [self plainLyricsFilePathForVideoId:videoId];
    if (lrcPath) [fm removeItemAtPath:lrcPath error:nil];
    if (txtPath) [fm removeItemAtPath:txtPath error:nil];
}

- (NSArray *)processLRCLibItem:(NSDictionary *)item videoId:(NSString *)videoId {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSString *synced = [ELJSON string:item forKey:@"syncedLyrics"];
    if ([synced length] > 0) {
        NSArray *parsed = el_parse_lrc_string(synced);
        if ([parsed count] > 0) {
            if ([videoId length] > 0) {
                NSString *path = [self lyricsFilePathForVideoId:videoId];
                [synced writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return parsed;
        }
    }
    NSString *plain = [ELJSON string:item forKey:@"plainLyrics"];
    if ([plain length] > 0) {
        NSArray *parsed = el_parse_plain_lyrics(plain);
        if ([parsed count] > 0) {
            if ([videoId length] > 0) {
                NSString *path = [self plainLyricsFilePathForVideoId:videoId];
                [plain writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return parsed;
        }
    }
    return nil;
}

- (NSArray *)fetchLyricsForTrack:(ELTrack *)track error:(NSString **)outError {
    if (!track || [track.title length] == 0) {
        if (outError) *outError = @"Invalid track";
        return nil;
    }

    NSArray *cached = [self cachedLyricsForVideoId:track.videoId];
    if ([cached count] > 0) return cached;

    NSString *artist = el_clean_track_query_part(track.artist);
    NSString *title = el_clean_track_query_part(track.title);
    if ([title length] == 0) title = track.title;

    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                             kLyricsUserAgent, @"User-Agent",
                             @"application/json", @"Accept",
                             nil];

    /* 1. Try exact /api/get */
    if ([artist length] > 0) {
        NSMutableString *url = [NSMutableString stringWithFormat:
                                @"https://lrclib.net/api/get?artist_name=%@&track_name=%@",
                                el_url_encode(artist), el_url_encode(title)];
        if (track.durationSeconds > 0) {
            [url appendFormat:@"&duration=%ld", (long)track.durationSeconds];
        }
        ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:url headers:headers];
        if (resp.statusCode == 200 && resp.body) {
            id json = [ELJSON objectWithData:resp.body];
            NSArray *lines = [self processLRCLibItem:json videoId:track.videoId];
            if ([lines count] > 0) return lines;
        }
    }

    /* 2. Fallback to /api/search?q=... */
    NSString *q = ([artist length] > 0)
        ? [NSString stringWithFormat:@"%@ %@", artist, title]
        : title;
    NSString *searchURL = [NSString stringWithFormat:@"https://lrclib.net/api/search?q=%@", el_url_encode(q)];
    ELHTTPResponse *searchResp = [[ELHTTPClient sharedClient] getURL:searchURL headers:headers];
    if (searchResp.errorMessage) {
        if (outError) *outError = searchResp.errorMessage;
        return nil;
    }
    if (searchResp.statusCode == 200 && searchResp.body) {
        id json = [ELJSON objectWithData:searchResp.body];
        if ([json isKindOfClass:[NSArray class]]) {
            NSArray *arr = (NSArray *)json;
            /* Prefer an entry with syncedLyrics */
            for (id item in arr) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *synced = [ELJSON string:item forKey:@"syncedLyrics"];
                if ([synced length] > 0) {
                    NSArray *lines = [self processLRCLibItem:item videoId:track.videoId];
                    if ([lines count] > 0) return lines;
                }
            }
            /* Fallback to first entry with plainLyrics */
            for (id item in arr) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSArray *lines = [self processLRCLibItem:item videoId:track.videoId];
                if ([lines count] > 0) return lines;
            }
        }
    }

    if (outError) *outError = @"No lyrics found";
    return nil;
}

@end
