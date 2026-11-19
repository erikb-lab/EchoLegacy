#import "ELMusicDNAClient.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"

#if EL_FEATURE_MUSIC_DNA

#define EL_MAX_DNA_BYTES (128U * 1024U)

static NSString *const kDNAUserAgent = @"EchoLegacy/1.0 (iPhoneOS 4.1; https://github.com/erikb-lab/EchoLegacy)";

static NSString *el_dna_url_encode(NSString *s) {
    if ([s length] == 0) return @"";
    CFStringRef encoded = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (CFStringRef)s,
        NULL,
        CFSTR("!*'();:@&=+$,/?%#[]"),
        kCFStringEncodingUTF8);
    if (!encoded) return @"";
    return [(NSString *)encoded autorelease];
}

static NSString *el_dna_clean_part(NSString *s) {
    if ([s length] == 0) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *markers = [NSArray arrayWithObjects:
                        @"(Official", @"[Official", @"(Audio", @"[Audio",
                        @"(Lyrics", @"[Lyrics", @"(Music Video", @"[Music Video",
                        @"(feat.", @"(ft.", nil];
    for (NSString *m in markers) {
        NSRange r = [trimmed rangeOfString:m options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound && r.location > 0) {
            trimmed = [[trimmed substringToIndex:r.location]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }
    return trimmed;
}

@implementation ELMusicDNAClient

+ (ELMusicDNAClient *)sharedClient {
    static ELMusicDNAClient *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELMusicDNAClient alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        _cacheDir = [[docs stringByAppendingPathComponent:@"EchoLegacy/music_dna"] retain];
        NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
        [fm createDirectoryAtPath:_cacheDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
    return self;
}

- (void)dealloc {
    [_cacheDir release];
    [super dealloc];
}

- (NSString *)cachePathForVideoId:(NSString *)videoId {
    if (!el_is_valid_video_id(videoId)) return nil;
    return [_cacheDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", videoId]];
}

- (NSDictionary *)loadCachedDNAForVideoId:(NSString *)videoId {
    NSString *path = [self cachePathForVideoId:videoId];
    if (!path) return nil;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    NSString *summary = [d objectForKey:@"summary"];
    if (![summary isKindOfClass:[NSString class]] || [summary length] == 0) return nil;
    return d;
}

- (void)saveCachedDNA:(NSDictionary *)dna forVideoId:(NSString *)videoId {
    NSString *path = [self cachePathForVideoId:videoId];
    if (!path || !dna) return;
    NSString *errDesc = nil;
    NSData *binData = [NSPropertyListSerialization dataFromPropertyList:dna
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                       errorDescription:&errDesc];
    if (errDesc) [errDesc release];
    if (binData) {
        [binData writeToFile:path atomically:YES];
    }
}

- (NSArray *)openSearchTitlesForQuery:(NSString *)query headers:(NSDictionary *)headers {
    if ([query length] == 0) return nil;
    NSString *url = [NSString stringWithFormat:
                     @"https://en.wikipedia.org/w/api.php?action=opensearch&limit=3&format=json&search=%@",
                     el_dna_url_encode(query)];
    if (!ELValidateHTTPSURL(url, ELHostCategoryInfo, NULL, NULL, NULL)) return nil;
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:url headers:headers maxBytes:EL_MAX_DNA_BYTES];
    if (!resp || resp.statusCode != 200 || [resp.body length] == 0) return nil;
    id json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSArray class]] || [(NSArray *)json count] < 2) return nil;
    id titles = [(NSArray *)json objectAtIndex:1];
    return [titles isKindOfClass:[NSArray class]] ? (NSArray *)titles : nil;
}

- (NSDictionary *)fetchSummaryForPageTitle:(NSString *)pageTitle headers:(NSDictionary *)headers {
    if ([pageTitle length] == 0) return nil;
    NSString *underscored = [pageTitle stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *url = [NSString stringWithFormat:
                     @"https://en.wikipedia.org/api/rest_v1/page/summary/%@",
                     el_dna_url_encode(underscored)];
    if (!ELValidateHTTPSURL(url, ELHostCategoryInfo, NULL, NULL, NULL)) return nil;
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:url headers:headers maxBytes:EL_MAX_DNA_BYTES];
    if (!resp || resp.statusCode != 200 || [resp.body length] == 0) return nil;
    id json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSString *type = [ELJSON string:json forKey:@"type"];
    if ([type isEqualToString:@"disambiguation"]) return nil;
    NSString *extract = [ELJSON string:json forKey:@"extract"];
    if ([extract length] == 0) return nil;
    NSString *title = [ELJSON string:json forKey:@"title"];
    if ([title length] == 0) title = pageTitle;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            title, @"title",
            extract, @"summary",
            @"Wikipedia", @"source",
            nil];
}

- (NSDictionary *)fetchDNAForTrack:(ELTrack *)track error:(NSString **)outError {
    if (!track || [track.title length] == 0) {
        if (outError) *outError = @"Invalid track";
        return nil;
    }

    NSDictionary *cached = [self loadCachedDNAForVideoId:track.videoId];
    if (cached) return cached;

    NSString *title = el_dna_clean_part(track.title);
    NSString *artist = el_dna_clean_part(track.artist);
    if ([artist caseInsensitiveCompare:@"Unknown Artist"] == NSOrderedSame ||
        [artist caseInsensitiveCompare:@"YouTube Music"] == NSOrderedSame) {
        artist = @"";
    }

    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:
                             kDNAUserAgent, @"User-Agent",
                             @"application/json", @"Accept",
                             nil];

    NSMutableArray *queries = [NSMutableArray arrayWithCapacity:2];
    if ([title length] > 0 && [artist length] > 0) {
        [queries addObject:[NSString stringWithFormat:@"%@ %@ song", title, artist]];
    } else if ([title length] > 0) {
        [queries addObject:[NSString stringWithFormat:@"%@ song", title]];
    }
    if ([artist length] > 0) {
        [queries addObject:artist];
    }

    for (NSString *q in queries) {
        NSArray *candidates = [self openSearchTitlesForQuery:q headers:headers];
        for (id cand in candidates) {
            if (![cand isKindOfClass:[NSString class]]) continue;
            NSDictionary *dna = [self fetchSummaryForPageTitle:(NSString *)cand headers:headers];
            if (dna) {
                [self saveCachedDNA:dna forVideoId:track.videoId];
                return dna;
            }
        }
    }

    if (outError) *outError = @"No Music DNA found on Wikipedia";
    return nil;
}

@end

#endif /* EL_FEATURE_MUSIC_DNA */
