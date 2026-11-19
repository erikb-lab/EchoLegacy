#import "ELLyricsClient.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"
#include <math.h>

#define EL_MAX_LYRICS_BYTES (64U * 1024U)
#define EL_MAX_LYRICS_LINES 2000U

static NSString *const kLyricsUserAgent = @"EchoLegacy/1.0 (iPhoneOS 4.1; lrclib)";
static NSString *const kOnlineLyricsDefaultsKey = @"ELOnlineLyricsEnabled";

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

static NSCharacterSet *el_cr_charset(void) {
    static NSCharacterSet *cs = nil;
    if (!cs) {
        @synchronized([ELLyricsClient class]) {
            if (!cs) cs = [[NSCharacterSet characterSetWithCharactersInString:@"\r"] retain];
        }
    }
    return cs;
}

static NSCharacterSet *el_plain_trim_charset(void) {
    static NSCharacterSet *cs = nil;
    if (!cs) {
        @synchronized([ELLyricsClient class]) {
            if (!cs) cs = [[NSCharacterSet characterSetWithCharactersInString:@"\r \t"] retain];
        }
    }
    return cs;
}

static NSArray *el_parse_lrc_string(NSString *lrc) {
    if ([lrc length] == 0 || [lrc length] > EL_MAX_LYRICS_BYTES) return [NSArray array];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *rawLines = [lrc componentsSeparatedByString:@"\n"];
    NSCharacterSet *crSet = el_cr_charset();
    NSCharacterSet *wsSet = [NSCharacterSet whitespaceCharacterSet];

    for (NSString *raw in rawLines) {
        if ([lines count] >= EL_MAX_LYRICS_LINES) break;
        NSString *line = [raw stringByTrimmingCharactersInSet:crSet];
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
                          stringByTrimmingCharactersInSet:wsSet];
        if ([text length] == 0) text = @" ";

        for (NSNumber *num in times) {
            if ([lines count] >= EL_MAX_LYRICS_LINES) break;
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
    if ([plain length] == 0 || [plain length] > EL_MAX_LYRICS_BYTES) return [NSArray array];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *rawLines = [plain componentsSeparatedByString:@"\n"];
    NSCharacterSet *trimSet = el_plain_trim_charset();
    for (NSString *raw in rawLines) {
        if ([lines count] >= EL_MAX_LYRICS_LINES) break;
        NSString *text = [raw stringByTrimmingCharactersInSet:trimSet];
        if ([text length] == 0) continue;
        ELLyricLine *item = [[[ELLyricLine alloc] init] autorelease];
        item.timeSeconds = -1.0;
        item.text = text;
        [lines addObject:item];
    }
    return lines;
}

static NSString *el_normalize_match_text(NSString *s) {
    if ([s length] == 0) return @"";
    NSString *lower = [s lowercaseString];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    NSMutableString *out = [NSMutableString stringWithCapacity:[lower length]];
    BOOL lastSpace = YES;
    for (NSUInteger i = 0; i < [lower length]; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([alnum characterIsMember:c]) {
            [out appendFormat:@"%C", c];
            lastSpace = NO;
        } else if (!lastSpace) {
            [out appendString:@" "];
            lastSpace = YES;
        }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static BOOL el_has_token_similarity(NSString *normA, NSString *normB) {
    if ([normA length] == 0 || [normB length] == 0) return NO;
    if ([normA rangeOfString:normB].location != NSNotFound ||
        [normB rangeOfString:normA].location != NSNotFound) {
        return YES;
    }
    NSArray *toksA = [normA componentsSeparatedByString:@" "];
    NSArray *toksB = [normB componentsSeparatedByString:@" "];
    NSUInteger significantA = 0;
    NSUInteger matchedA = 0;
    for (NSString *ta in toksA) {
        if ([ta length] < 2) continue;
        significantA++;
        if ([toksB containsObject:ta]) {
            matchedA++;
        }
    }
    if (significantA == 0) return NO;
    return (matchedA * 2 >= significantA && matchedA > 0);
}

static BOOL el_lrclib_item_matches_track(NSDictionary *item,
                                         NSString *cleanTitle,
                                         NSString *cleanArtist,
                                         NSInteger durationSeconds) {
    if (![item isKindOfClass:[NSDictionary class]]) return NO;

    NSString *candTitle = [ELJSON string:item forKey:@"trackName"];
    if ([candTitle length] == 0) candTitle = [ELJSON string:item forKey:@"name"];
    NSString *normTargetTitle = el_normalize_match_text(cleanTitle);
    NSString *normCandTitle = el_normalize_match_text(candTitle);
    if (!el_has_token_similarity(normTargetTitle, normCandTitle)) {
        return NO;
    }

    if ([cleanArtist length] > 0 &&
        [cleanArtist caseInsensitiveCompare:@"Unknown Artist"] != NSOrderedSame &&
        [cleanArtist caseInsensitiveCompare:@"YouTube Music"] != NSOrderedSame) {
        NSString *candArtist = [ELJSON string:item forKey:@"artistName"];
        NSString *normTargetArtist = el_normalize_match_text(cleanArtist);
        NSString *normCandArtist = el_normalize_match_text(candArtist);
        if ([normTargetArtist length] > 0 && !el_has_token_similarity(normTargetArtist, normCandArtist)) {
            return NO;
        }
    }

    NSNumber *candDurNum = [ELJSON number:item forKey:@"duration"];
    if (durationSeconds > 0 && candDurNum && [candDurNum doubleValue] > 0.0) {
        if (fabs([candDurNum doubleValue] - (double)durationSeconds) > 15.0) {
            return NO;
        }
    }
    return YES;
}

@implementation ELLyricsClient

+ (ELLyricsClient *)sharedClient {
    static ELLyricsClient *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELLyricsClient alloc] init];
    }
    return shared;
}

+ (BOOL)isOnlineLyricsEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kOnlineLyricsDefaultsKey];
}

+ (void)setOnlineLyricsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kOnlineLyricsDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
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
    if (!el_is_valid_video_id(videoId)) return nil;
    return [_lyricsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lrc", videoId]];
}

- (NSString *)plainLyricsFilePathForVideoId:(NSString *)videoId {
    if (!el_is_valid_video_id(videoId)) return nil;
    return [_lyricsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", videoId]];
}

static NSString *el_read_capped_utf8_file(NSFileManager *fm, NSString *path, NSUInteger maxBytes) {
    if (!path || ![fm fileExistsAtPath:path]) return nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long fsz = [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
    if (fsz == 0 || fsz > (unsigned long long)maxBytes) return nil;
    NSString *raw = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return ([raw length] > 0 && [raw length] <= maxBytes) ? raw : nil;
}

- (NSArray *)cachedLyricsForVideoId:(NSString *)videoId {
    if (!el_is_valid_video_id(videoId)) return nil;
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *lrcRaw = el_read_capped_utf8_file(fm, [self lyricsFilePathForVideoId:videoId], EL_MAX_LYRICS_BYTES);
    if (lrcRaw) {
        NSArray *parsed = el_parse_lrc_string(lrcRaw);
        if ([parsed count] > 0) return parsed;
    }
    NSString *txtRaw = el_read_capped_utf8_file(fm, [self plainLyricsFilePathForVideoId:videoId], EL_MAX_LYRICS_BYTES);
    if (txtRaw) {
        NSArray *parsed = el_parse_plain_lyrics(txtRaw);
        if ([parsed count] > 0) return parsed;
    }
    return nil;
}

- (void)deleteCachedLyricsForVideoId:(NSString *)videoId {
    if (!el_is_valid_video_id(videoId)) return;
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *lrcPath = [self lyricsFilePathForVideoId:videoId];
    NSString *txtPath = [self plainLyricsFilePathForVideoId:videoId];
    if (lrcPath) [fm removeItemAtPath:lrcPath error:nil];
    if (txtPath) [fm removeItemAtPath:txtPath error:nil];
}

- (NSArray *)processLRCLibItem:(NSDictionary *)item videoId:(NSString *)videoId {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    NSString *synced = [ELJSON string:item forKey:@"syncedLyrics"];
    if ([synced length] > 0 && [synced length] <= EL_MAX_LYRICS_BYTES) {
        NSArray *parsed = el_parse_lrc_string(synced);
        if ([parsed count] > 0) {
            if (el_is_valid_video_id(videoId)) {
                NSString *path = [self lyricsFilePathForVideoId:videoId];
                if (path) [synced writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return parsed;
        }
    }
    NSString *plain = [ELJSON string:item forKey:@"plainLyrics"];
    if ([plain length] > 0 && [plain length] <= EL_MAX_LYRICS_BYTES) {
        NSArray *parsed = el_parse_plain_lyrics(plain);
        if ([parsed count] > 0) {
            if (el_is_valid_video_id(videoId)) {
                NSString *path = [self plainLyricsFilePathForVideoId:videoId];
                if (path) [plain writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
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

    if (![ELLyricsClient isOnlineLyricsEnabled]) {
        if (outError) *outError = @"Online lyrics disabled in Account settings";
        return nil;
    }

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
        if (ELValidateHTTPSURL(url, ELHostCategoryLyrics, NULL, NULL, NULL)) {
            ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:url
                                                               headers:headers
                                                              maxBytes:EL_MAX_LYRICS_BYTES];
            if (resp && resp.statusCode == 200 && resp.body && [resp.body length] <= EL_MAX_LYRICS_BYTES) {
                id json = [ELJSON objectWithData:resp.body];
                if ([json isKindOfClass:[NSDictionary class]] &&
                    el_lrclib_item_matches_track((NSDictionary *)json, title, artist, track.durationSeconds)) {
                    NSArray *lines = [self processLRCLibItem:(NSDictionary *)json videoId:track.videoId];
                    if ([lines count] > 0) return lines;
                }
            }
        }
    }

    /* 2. Fallback to /api/search?q=... */
    NSString *q = ([artist length] > 0)
        ? [NSString stringWithFormat:@"%@ %@", artist, title]
        : title;
    NSString *searchURL = [NSString stringWithFormat:@"https://lrclib.net/api/search?q=%@", el_url_encode(q)];
    if (!ELValidateHTTPSURL(searchURL, ELHostCategoryLyrics, NULL, NULL, NULL)) {
        if (outError) *outError = @"Invalid lyrics URL";
        return nil;
    }
    ELHTTPResponse *searchResp = [[ELHTTPClient sharedClient] getURL:searchURL
                                                             headers:headers
                                                            maxBytes:EL_MAX_LYRICS_BYTES];
    if (searchResp.errorMessage) {
        if (outError) *outError = searchResp.errorMessage;
        return nil;
    }
    if (searchResp.statusCode == 200 && searchResp.body && [searchResp.body length] <= EL_MAX_LYRICS_BYTES) {
        id json = [ELJSON objectWithData:searchResp.body];
        if ([json isKindOfClass:[NSArray class]]) {
            /* Prefer a validated entry with syncedLyrics; remember first plain fallback */
            NSDictionary *plainFallback = nil;
            for (id item in (NSArray *)json) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                if (!el_lrclib_item_matches_track((NSDictionary *)item, title, artist, track.durationSeconds)) continue;
                NSString *synced = [ELJSON string:item forKey:@"syncedLyrics"];
                if ([synced length] > 0 && [synced length] <= EL_MAX_LYRICS_BYTES) {
                    NSArray *lines = [self processLRCLibItem:item videoId:track.videoId];
                    if ([lines count] > 0) return lines;
                }
                if (!plainFallback) plainFallback = (NSDictionary *)item;
            }
            if (plainFallback) {
                NSArray *lines = [self processLRCLibItem:plainFallback videoId:track.videoId];
                if ([lines count] > 0) return lines;
            }
        }
    }

    if (outError) *outError = @"No lyrics found";
    return nil;
}

@end
