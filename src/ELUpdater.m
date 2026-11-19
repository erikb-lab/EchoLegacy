#import "ELUpdater.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"
#include <stdio.h>
#include <sys/stat.h>

static NSString *const kGitHubReleaseAPI = @"https://api.github.com/repos/erikb-lab/EchoLegacy/releases/latest";
static NSString *const kDefaultsReleaseKey = @"ELInstalledReleaseId";
static NSString *const kDefaultsReleaseTitleKey = @"ELInstalledReleaseTitle";

@implementation ELUpdateInfo
@synthesize tagName = _tagName;
@synthesize releaseTitle = _releaseTitle;
@synthesize publishedAt = _publishedAt;
@synthesize binaryURL = _binaryURL;
@synthesize plistURL = _plistURL;
@synthesize cacertURL = _cacertURL;
@synthesize ipaURL = _ipaURL;
@synthesize binarySize = _binarySize;
@synthesize updateAvailable = _updateAvailable;

- (void)dealloc {
    [_tagName release];
    [_releaseTitle release];
    [_publishedAt release];
    [_binaryURL release];
    [_plistURL release];
    [_cacertURL release];
    [_ipaURL release];
    [super dealloc];
}
@end

@implementation ELUpdater

+ (ELUpdater *)sharedUpdater {
    static ELUpdater *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELUpdater alloc] init];
    }
    return shared;
}

- (NSString *)installedVersionLabel {
    NSString *savedTitle = [[NSUserDefaults standardUserDefaults] stringForKey:kDefaultsReleaseTitleKey];
    if ([savedTitle length] > 0) return savedTitle;
    NSString *ver = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return ([ver length] > 0) ? [NSString stringWithFormat:@"v%@", ver] : @"v0.1.0";
}

- (ELUpdateInfo *)checkForUpdateWithError:(NSString **)outError {
    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"EchoLegacy-iOS4/1.0", @"User-Agent",
                          @"application/vnd.github+json", @"Accept",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:kGitHubReleaseAPI headers:hdrs];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    if (resp.statusCode == 404) {
        if (outError) *outError = @"No GitHub release published yet";
        return nil;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 400) {
        if (outError) *outError = [NSString stringWithFormat:@"GitHub HTTP %ld", (long)resp.statusCode];
        return nil;
    }

    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Invalid GitHub response";
        return nil;
    }

    ELUpdateInfo *info = [[[ELUpdateInfo alloc] init] autorelease];
    info.tagName = [ELJSON string:json forKey:@"tag_name"];
    info.releaseTitle = [ELJSON string:json forKey:@"name"];
    info.publishedAt = [ELJSON string:json forKey:@"published_at"];
    if ([info.releaseTitle length] == 0) info.releaseTitle = info.tagName;

    NSArray *assets = [ELJSON array:json forKey:@"assets"];
    for (id a in assets) {
        if (![a isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = [ELJSON string:a forKey:@"name"];
        NSString *dl = [ELJSON string:a forKey:@"browser_download_url"];
        if ([name isEqualToString:@"EchoLegacy"]) {
            info.binaryURL = dl;
            info.binarySize = [[ELJSON number:a forKey:@"size"] longLongValue];
        } else if ([name isEqualToString:@"Info.plist"]) {
            info.plistURL = dl;
        } else if ([name isEqualToString:@"cacert.pem"]) {
            info.cacertURL = dl;
        } else if ([name isEqualToString:@"EchoLegacy.ipa"]) {
            info.ipaURL = dl;
        }
    }

    if ([info.binaryURL length] == 0 && [info.ipaURL length] == 0) {
        if (outError) *outError = @"Release has no EchoLegacy build asset";
        return nil;
    }

    NSString *releaseStamp = [NSString stringWithFormat:@"%@|%@",
                              info.tagName ? info.tagName : @"",
                              info.publishedAt ? info.publishedAt : @""];
    NSString *installedStamp = [[NSUserDefaults standardUserDefaults] stringForKey:kDefaultsReleaseKey];
    info.updateAvailable = ![releaseStamp isEqualToString:installedStamp];
    return info;
}

- (BOOL)downloadURL:(NSString *)urlString toFile:(NSString *)destPath error:(NSString **)outError {
    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"EchoLegacy-iOS4/1.0", @"User-Agent",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:urlString headers:hdrs];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return NO;
    }
    if (resp.statusCode < 200 || resp.statusCode >= 400 || [resp.body length] == 0) {
        if (outError) *outError = [NSString stringWithFormat:@"Download HTTP %ld", (long)resp.statusCode];
        return NO;
    }
    if (![resp.body writeToFile:destPath atomically:YES]) {
        if (outError) *outError = @"Failed writing update file";
        return NO;
    }
    return YES;
}

- (BOOL)installUpdate:(ELUpdateInfo *)info
          savedIPAPath:(NSString **)outSavedIPAPath
                 error:(NSString **)outError {
    if (!info) {
        if (outError) *outError = @"Missing update info";
        return NO;
    }

    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *execPath = [[NSBundle mainBundle] executablePath];
    BOOL canWriteBundle = [fm isWritableFileAtPath:bundleDir];

    if (canWriteBundle && [info.binaryURL length] > 0 && [execPath length] > 0) {
        NSString *tmpBin = [execPath stringByAppendingString:@".new"];
        if (![self downloadURL:info.binaryURL toFile:tmpBin error:outError]) {
            [fm removeItemAtPath:tmpBin error:nil];
            return NO;
        }

        /* Sanity-check Mach-O magic (0xfeedface for 32-bit armv6) before replacing executable */
        NSData *head = [NSData dataWithContentsOfFile:tmpBin options:0 error:nil];
        if ([head length] < 16384) {
            [fm removeItemAtPath:tmpBin error:nil];
            if (outError) *outError = @"Downloaded binary is invalid";
            return NO;
        }
        const uint8_t *b = (const uint8_t *)[head bytes];
        uint32_t magic = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        if (magic != 0xcefaedfe && magic != 0xfeedface) {
            [fm removeItemAtPath:tmpBin error:nil];
            if (outError) *outError = @"Downloaded file is not a valid Mach-O binary";
            return NO;
        }

        chmod([tmpBin UTF8String], 0755);
        if (rename([tmpBin UTF8String], [execPath UTF8String]) != 0) {
            [fm removeItemAtPath:tmpBin error:nil];
            if (outError) *outError = @"Could not replace app binary";
            return NO;
        }

        /* Optionally refresh Info.plist and cacert.pem */
        if ([info.cacertURL length] > 0) {
            NSString *caPath = [bundleDir stringByAppendingPathComponent:@"cacert.pem"];
            NSString *tmpCA = [caPath stringByAppendingString:@".new"];
            if ([self downloadURL:info.cacertURL toFile:tmpCA error:NULL]) {
                rename([tmpCA UTF8String], [caPath UTF8String]);
            } else {
                [fm removeItemAtPath:tmpCA error:nil];
            }
        }
        if ([info.plistURL length] > 0) {
            NSString *plPath = [bundleDir stringByAppendingPathComponent:@"Info.plist"];
            NSString *tmpPL = [plPath stringByAppendingString:@".new"];
            if ([self downloadURL:info.plistURL toFile:tmpPL error:NULL]) {
                rename([tmpPL UTF8String], [plPath UTF8String]);
            } else {
                [fm removeItemAtPath:tmpPL error:nil];
            }
        }

        NSString *releaseStamp = [NSString stringWithFormat:@"%@|%@",
                                  info.tagName ? info.tagName : @"",
                                  info.publishedAt ? info.publishedAt : @""];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:releaseStamp forKey:kDefaultsReleaseKey];
        if (info.releaseTitle) [ud setObject:info.releaseTitle forKey:kDefaultsReleaseTitleKey];
        [ud synchronize];
        return YES;
    }

    /* Fallback if app bundle is read-only: download EchoLegacy.ipa to Documents/EchoLegacy/updates/ */
    if ([info.ipaURL length] > 0) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        NSString *upDir = [docs stringByAppendingPathComponent:@"EchoLegacy/updates"];
        [fm createDirectoryAtPath:upDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *ipaPath = [upDir stringByAppendingPathComponent:@"EchoLegacy.ipa"];
        if ([self downloadURL:info.ipaURL toFile:ipaPath error:outError]) {
            if (outSavedIPAPath) *outSavedIPAPath = ipaPath;
            return YES;
        }
        return NO;
    }

    if (outError) *outError = @"Bundle not writable and no IPA asset found";
    return NO;
}

@end
