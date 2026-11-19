#import "ELUpdater.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"
#include "mbedtls/sha256.h"
#include <ctype.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kGitHubReleaseAPI = @"https://api.github.com/repos/erikb-lab/EchoLegacy/releases/latest";
static NSString *const kDefaultsReleaseKey = @"ELInstalledReleaseId";
static NSString *const kDefaultsReleaseTitleKey = @"ELInstalledReleaseTitle";
static NSString *const kExpectedBundleIdentifier = @"com.echolegacy.app";
static NSString *const kExpectedExecutableName = @"EchoLegacy";

#define EL_MAX_VERSION_JSON_BYTES (64ULL * 1024ULL)
#define EL_MAX_PLIST_BYTES        (64ULL * 1024ULL)
#define EL_MAX_CACERT_BYTES       (1024ULL * 1024ULL)
#define EL_MAX_BINARY_BYTES       (16ULL * 1024ULL * 1024ULL)
#define EL_MAX_IPA_BYTES          (32ULL * 1024ULL * 1024ULL)

static BOOL el_is_valid_sha256_hex(NSString *hex) {
    if (!hex || [hex length] != 64) return NO;
    const char *s = [hex UTF8String];
    if (!s) return NO;
    for (int i = 0; i < 64; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            return NO;
        }
    }
    return YES;
}

static BOOL el_consttime_hex_eq(const char *a, const char *b) {
    if (!a || !b) return NO;
    unsigned char diff = 0;
    for (int i = 0; i < 64; i++) {
        unsigned char ca = (unsigned char)tolower((unsigned char)a[i]);
        unsigned char cb = (unsigned char)tolower((unsigned char)b[i]);
        if (ca == 0 || cb == 0) return NO;
        diff |= (unsigned char)(ca ^ cb);
    }
    return (diff == 0 && a[64] == '\0' && b[64] == '\0');
}

static NSString *el_normalize_semver_string(NSString *ver) {
    if (!ver) return @"";
    NSString *s = [ver stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"]) {
        s = [s substringFromIndex:1];
    }
    NSRange dash = [s rangeOfString:@"-"];
    if (dash.location != NSNotFound) {
        s = [s substringToIndex:dash.location];
    }
    return s;
}

static BOOL el_parse_semver(NSString *ver, int outParts[3]) {
    outParts[0] = 0;
    outParts[1] = 0;
    outParts[2] = 0;
    NSString *clean = el_normalize_semver_string(ver);
    if ([clean length] == 0) return NO;
    NSArray *comps = [clean componentsSeparatedByString:@"."];
    if ([comps count] == 0 || [comps count] > 3) return NO;
    for (NSUInteger i = 0; i < [comps count]; i++) {
        NSString *part = [comps objectAtIndex:i];
        if ([part length] == 0 || [part length] > 8) return NO;
        const char *p = [part UTF8String];
        int val = 0;
        for (int j = 0; p[j] != '\0'; j++) {
            if (p[j] < '0' || p[j] > '9') return NO;
            val = val * 10 + (p[j] - '0');
        }
        outParts[i] = val;
    }
    return YES;
}

/* Returns >0 if a > b, 0 if a == b, <0 if a < b */
static int el_compare_semver(NSString *a, NSString *b) {
    int pa[3] = {0, 0, 0};
    int pb[3] = {0, 0, 0};
    BOOL oka = el_parse_semver(a, pa);
    BOOL okb = el_parse_semver(b, pb);
    if (!oka && !okb) return 0;
    if (oka && !okb) return 1;
    if (!oka && okb) return -1;
    for (int i = 0; i < 3; i++) {
        if (pa[i] != pb[i]) return (pa[i] > pb[i]) ? 1 : -1;
    }
    return 0;
}

static void el_read_installed_version(NSString **outShortVersion, NSInteger *outBuildNumber) {
    NSDictionary *memInfo = [[NSBundle mainBundle] infoDictionary];
    NSString *ver = [memInfo objectForKey:@"CFBundleShortVersionString"];
    NSInteger build = [[memInfo objectForKey:@"CFBundleVersion"] integerValue];

    /* Also inspect on-disk Info.plist in case an in-place update already occurred */
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *plistPath = [bundleDir stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *diskInfo = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if ([diskInfo isKindOfClass:[NSDictionary class]]) {
        NSString *diskVer = [diskInfo objectForKey:@"CFBundleShortVersionString"];
        NSInteger diskBuild = [[diskInfo objectForKey:@"CFBundleVersion"] integerValue];
        int cmp = el_compare_semver(diskVer, ver);
        if (cmp > 0 || (cmp == 0 && diskBuild > build)) {
            ver = diskVer;
            build = diskBuild;
        }
    }

    if ([ver length] == 0) ver = @"0.2.0";
    if (build <= 0) build = 2;
    if (outShortVersion) *outShortVersion = ver;
    if (outBuildNumber) *outBuildNumber = build;
}

static BOOL el_is_strictly_newer_release(NSString *remoteVer,
                                         NSInteger remoteBuild,
                                         NSString *localVer,
                                         NSInteger localBuild) {
    int pRemote[3] = {0, 0, 0};
    BOOL hasRemoteSemver = el_parse_semver(remoteVer, pRemote);
    if (hasRemoteSemver) {
        int cmp = el_compare_semver(remoteVer, localVer);
        if (cmp > 0) return YES;
        if (cmp < 0) return NO;
        return (remoteBuild > localBuild);
    }
    return (remoteBuild > localBuild);
}

static BOOL el_verify_file_size_and_sha256(NSString *path,
                                           long long expectedSize,
                                           NSString *expectedSHA256,
                                           NSString **outError) {
    if ([path length] == 0 || expectedSize <= 0 || !el_is_valid_sha256_hex(expectedSHA256)) {
        if (outError) *outError = @"Missing expected size or SHA-256 metadata";
        return NO;
    }

    struct stat st;
    if (lstat([path UTF8String], &st) != 0 || !S_ISREG(st.st_mode)) {
        if (outError) *outError = @"Downloaded update file is missing or not a regular file";
        return NO;
    }
    if ((long long)st.st_size != expectedSize) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"Update file size mismatch (%lld vs %lld)",
                         (long long)st.st_size, expectedSize];
        }
        return NO;
    }

    int flags = O_RDONLY;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    int fd = open([path UTF8String], flags);
    if (fd < 0) {
        if (outError) *outError = @"Could not open downloaded file for verification";
        return NO;
    }

    mbedtls_sha256_context ctx;
    mbedtls_sha256_init(&ctx);
    if (mbedtls_sha256_starts_ret(&ctx, 0) != 0) {
        mbedtls_sha256_free(&ctx);
        close(fd);
        if (outError) *outError = @"SHA-256 initialization failed";
        return NO;
    }

    uint8_t buf[16384];
    long long totalRead = 0;
    ssize_t n;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        if (mbedtls_sha256_update_ret(&ctx, buf, (size_t)n) != 0) {
            mbedtls_sha256_free(&ctx);
            close(fd);
            if (outError) *outError = @"SHA-256 update failed";
            return NO;
        }
        totalRead += (long long)n;
    }
    close(fd);

    unsigned char digest[32];
    if (n < 0 || totalRead != expectedSize || mbedtls_sha256_finish_ret(&ctx, digest) != 0) {
        mbedtls_sha256_free(&ctx);
        if (outError) *outError = @"Failed reading update file for SHA-256 verification";
        return NO;
    }
    mbedtls_sha256_free(&ctx);

    static const char kHex[] = "0123456789abcdef";
    char computedHex[65];
    for (int i = 0; i < 32; i++) {
        computedHex[i * 2]     = kHex[(digest[i] >> 4) & 0x0F];
        computedHex[i * 2 + 1] = kHex[digest[i] & 0x0F];
    }
    computedHex[64] = '\0';

    if (!el_consttime_hex_eq(computedHex, [expectedSHA256 UTF8String])) {
        if (outError) *outError = @"SHA-256 checksum mismatch on downloaded update";
        return NO;
    }
    return YES;
}

static BOOL el_validate_armv6_macho_file(NSString *path, NSString **outError) {
    int fd = open([path UTF8String], O_RDONLY);
    if (fd < 0) {
        if (outError) *outError = @"Could not open downloaded binary";
        return NO;
    }
    uint8_t hdr[28];
    ssize_t n = read(fd, hdr, sizeof(hdr));
    close(fd);
    if (n < (ssize_t)sizeof(hdr)) {
        if (outError) *outError = @"Downloaded binary is too small";
        return NO;
    }

    /* 32-bit little-endian Mach-O header: magic = 0xfeedface, cputype = 12 (ARM),
       cpusubtype = 6 (ARMv6), filetype = 2 (MH_EXECUTE) */
    uint32_t magic      = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) | ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
    uint32_t cputype    = (uint32_t)hdr[4] | ((uint32_t)hdr[5] << 8) | ((uint32_t)hdr[6] << 16) | ((uint32_t)hdr[7] << 24);
    uint32_t cpusubtype = (uint32_t)hdr[8] | ((uint32_t)hdr[9] << 8) | ((uint32_t)hdr[10] << 16) | ((uint32_t)hdr[11] << 24);
    uint32_t filetype   = (uint32_t)hdr[12] | ((uint32_t)hdr[13] << 8) | ((uint32_t)hdr[14] << 16) | ((uint32_t)hdr[15] << 24);

    if (magic != 0xfeedfaceU || cputype != 12U || (cpusubtype & 0xFFU) != 6U || filetype != 2U) {
        if (outError) *outError = @"Downloaded file is not a valid armv6 Mach-O executable";
        return NO;
    }
    return YES;
}

static BOOL el_validate_info_plist_file(NSString *path,
                                        NSString *expectedVersion,
                                        NSInteger expectedBuild,
                                        NSString **outError) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if ([data length] == 0 || [data length] > EL_MAX_PLIST_BYTES) {
        if (outError) *outError = @"Downloaded Info.plist has invalid size";
        return NO;
    }

    NSPropertyListFormat fmt = 0;
    NSString *errDesc = nil;
    id plist = [NSPropertyListSerialization propertyListFromData:data
                                                mutabilityOption:NSPropertyListImmutable
                                                          format:&fmt
                                                errorDescription:&errDesc];
    if (errDesc) [errDesc release];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Downloaded Info.plist is not a valid property list dictionary";
        return NO;
    }

    NSDictionary *dict = (NSDictionary *)plist;
    NSString *bundleId = [dict objectForKey:@"CFBundleIdentifier"];
    NSString *execName = [dict objectForKey:@"CFBundleExecutable"];
    NSString *shortVer = [dict objectForKey:@"CFBundleShortVersionString"];
    NSString *buildStr = [dict objectForKey:@"CFBundleVersion"];

    if (![bundleId isKindOfClass:[NSString class]] || ![bundleId isEqualToString:kExpectedBundleIdentifier]) {
        if (outError) *outError = @"Downloaded Info.plist has mismatched CFBundleIdentifier";
        return NO;
    }
    if (![execName isKindOfClass:[NSString class]] || ![execName isEqualToString:kExpectedExecutableName]) {
        if (outError) *outError = @"Downloaded Info.plist has mismatched CFBundleExecutable";
        return NO;
    }
    if (![shortVer isKindOfClass:[NSString class]] || [shortVer length] == 0) {
        if (outError) *outError = @"Downloaded Info.plist is missing CFBundleShortVersionString";
        return NO;
    }
    if (![buildStr isKindOfClass:[NSString class]] || [buildStr integerValue] <= 0) {
        if (outError) *outError = @"Downloaded Info.plist has invalid CFBundleVersion";
        return NO;
    }
    if ([expectedVersion length] > 0 && el_compare_semver(shortVer, expectedVersion) != 0) {
        if (outError) *outError = @"Downloaded Info.plist version does not match version.json";
        return NO;
    }
    if (expectedBuild > 0 && [buildStr integerValue] != expectedBuild) {
        if (outError) *outError = @"Downloaded Info.plist build number does not match version.json";
        return NO;
    }
    return YES;
}

static BOOL el_validate_zip_file(NSString *path, NSString **outError) {
    int fd = open([path UTF8String], O_RDONLY);
    if (fd < 0) {
        if (outError) *outError = @"Could not open downloaded IPA";
        return NO;
    }
    uint8_t sig[4];
    ssize_t n = read(fd, sig, sizeof(sig));
    close(fd);
    if (n != 4 || sig[0] != 'P' || sig[1] != 'K' || sig[2] != 0x03 || sig[3] != 0x04) {
        if (outError) *outError = @"Downloaded IPA is not a valid ZIP archive";
        return NO;
    }
    return YES;
}

@implementation ELUpdateInfo
@synthesize tagName = _tagName;
@synthesize releaseTitle = _releaseTitle;
@synthesize publishedAt = _publishedAt;
@synthesize versionString = _versionString;
@synthesize buildNumber = _buildNumber;
@synthesize versionJSONURL = _versionJSONURL;
@synthesize versionJSONSize = _versionJSONSize;
@synthesize binaryURL = _binaryURL;
@synthesize plistURL = _plistURL;
@synthesize cacertURL = _cacertURL;
@synthesize ipaURL = _ipaURL;
@synthesize binarySize = _binarySize;
@synthesize plistSize = _plistSize;
@synthesize cacertSize = _cacertSize;
@synthesize ipaSize = _ipaSize;
@synthesize binarySHA256 = _binarySHA256;
@synthesize plistSHA256 = _plistSHA256;
@synthesize cacertSHA256 = _cacertSHA256;
@synthesize ipaSHA256 = _ipaSHA256;
@synthesize updateAvailable = _updateAvailable;

- (void)dealloc {
    [_tagName release];
    [_releaseTitle release];
    [_publishedAt release];
    [_versionString release];
    [_versionJSONURL release];
    [_binaryURL release];
    [_plistURL release];
    [_cacertURL release];
    [_ipaURL release];
    [_binarySHA256 release];
    [_plistSHA256 release];
    [_cacertSHA256 release];
    [_ipaSHA256 release];
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
    NSString *ver = nil;
    NSInteger build = 0;
    el_read_installed_version(&ver, &build);
    return [NSString stringWithFormat:@"v%@ (Build %ld)", ver, (long)build];
}

static void el_extract_asset_meta(NSDictionary *verJson,
                                  NSString *assetName,
                                  long long *ioSize,
                                  NSString **outSHA256) {
    NSString *sha = nil;
    long long metaSize = 0;

    NSDictionary *assetsDict = [ELJSON dict:verJson forKey:@"assets"];
    if (assetsDict) {
        NSDictionary *entry = [ELJSON dict:assetsDict forKey:assetName];
        if (entry) {
            sha = [ELJSON string:entry forKey:@"sha256"];
            NSNumber *szNum = [ELJSON number:entry forKey:@"size"];
            if (szNum) metaSize = [szNum longLongValue];
        }
    }

    if (!el_is_valid_sha256_hex(sha)) {
        *outSHA256 = nil;
        return;
    }
    if (metaSize > 0) {
        if (*ioSize > 0 && *ioSize != metaSize) {
            /* Reject inconsistent size between GitHub release API and version.json */
            *outSHA256 = nil;
            return;
        }
        *ioSize = metaSize;
    }
    *outSHA256 = [sha lowercaseString];
}

- (ELUpdateInfo *)checkForUpdateWithError:(NSString **)outError {
    if (!ELValidateHTTPSURL(kGitHubReleaseAPI, ELHostCategoryGitHubUpdate, NULL, NULL, NULL)) {
        if (outError) *outError = @"Invalid GitHub release endpoint";
        return nil;
    }

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"EchoLegacy-iOS4/1.0", @"User-Agent",
                          @"application/vnd.github+json", @"Accept",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:kGitHubReleaseAPI
                                                       headers:hdrs
                                                      maxBytes:256 * 1024];
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
        long long sz = [[ELJSON number:a forKey:@"size"] longLongValue];
        if (!ELValidateHTTPSURL(dl, ELHostCategoryGitHubUpdate, NULL, NULL, NULL) || sz <= 0) {
            continue;
        }
        if ([name isEqualToString:@"EchoLegacy"]) {
            info.binaryURL = dl;
            info.binarySize = sz;
        } else if ([name isEqualToString:@"Info.plist"]) {
            info.plistURL = dl;
            info.plistSize = sz;
        } else if ([name isEqualToString:@"cacert.pem"]) {
            info.cacertURL = dl;
            info.cacertSize = sz;
        } else if ([name isEqualToString:@"EchoLegacy.ipa"]) {
            info.ipaURL = dl;
            info.ipaSize = sz;
        } else if ([name isEqualToString:@"version.json"]) {
            info.versionJSONURL = dl;
            info.versionJSONSize = sz;
        }
    }

    if ([info.versionJSONURL length] == 0 || info.versionJSONSize <= 0 ||
        (uint64_t)info.versionJSONSize > EL_MAX_VERSION_JSON_BYTES) {
        if (outError) *outError = @"Release is missing signed version.json metadata";
        return nil;
    }

    /* Fetch and parse version.json for SHA-256 hashes, exact sizes, and build/version numbers */
    ELHTTPResponse *vResp = [[ELHTTPClient sharedClient] getURL:info.versionJSONURL
                                                        headers:[NSDictionary dictionaryWithObject:@"EchoLegacy-iOS4/1.0" forKey:@"User-Agent"]
                                                       maxBytes:(NSUInteger)EL_MAX_VERSION_JSON_BYTES];
    if (vResp.errorMessage || vResp.statusCode < 200 || vResp.statusCode >= 400 ||
        (long long)[vResp.body length] != info.versionJSONSize) {
        if (outError) *outError = @"Could not verify release version.json metadata";
        return nil;
    }

    NSDictionary *verJson = [ELJSON objectWithData:vResp.body];
    if (![verJson isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Malformed release version.json";
        return nil;
    }

    NSString *verStr = [ELJSON string:verJson forKey:@"version"];
    if ([verStr length] == 0) {
        NSString *tagStr = [ELJSON string:verJson forKey:@"tag"];
        int dummy[3];
        if (el_parse_semver(tagStr, dummy)) {
            verStr = el_normalize_semver_string(tagStr);
        } else if (el_parse_semver(info.tagName, dummy)) {
            verStr = el_normalize_semver_string(info.tagName);
        }
    }
    info.versionString = verStr;
    info.buildNumber = [[ELJSON number:verJson forKey:@"build"] integerValue];

    long long binSize = info.binarySize;
    long long plSize  = info.plistSize;
    long long caSize  = info.cacertSize;
    long long ipaSize = info.ipaSize;
    NSString *binSHA = nil, *plSHA = nil, *caSHA = nil, *ipaSHA = nil;

    el_extract_asset_meta(verJson, @"EchoLegacy",     &binSize, &binSHA);
    el_extract_asset_meta(verJson, @"Info.plist",     &plSize,  &plSHA);
    el_extract_asset_meta(verJson, @"cacert.pem",     &caSize,  &caSHA);
    el_extract_asset_meta(verJson, @"EchoLegacy.ipa", &ipaSize, &ipaSHA);

    info.binarySize   = binSize;
    info.plistSize    = plSize;
    info.cacertSize   = caSize;
    info.ipaSize      = ipaSize;
    info.binarySHA256 = binSHA;
    info.plistSHA256  = plSHA;
    info.cacertSHA256 = caSHA;
    info.ipaSHA256    = ipaSHA;

    BOOL hasVerifiedBundleAssets = ([info.binaryURL length] > 0 && info.binarySize > 0 && [info.binarySHA256 length] == 64 &&
                                    [info.plistURL length] > 0  && info.plistSize > 0  && [info.plistSHA256 length] == 64 &&
                                    [info.cacertURL length] > 0 && info.cacertSize > 0 && [info.cacertSHA256 length] == 64);
    BOOL hasVerifiedIPAAsset = ([info.ipaURL length] > 0 && info.ipaSize > 0 && [info.ipaSHA256 length] == 64);

    if (!hasVerifiedBundleAssets && !hasVerifiedIPAAsset) {
        if (outError) *outError = @"Release version.json is missing required SHA-256 asset hashes";
        return nil;
    }

    /* Flaw #14: Strict semantic version + integer build number downgrade protection */
    NSString *localVer = nil;
    NSInteger localBuild = 0;
    el_read_installed_version(&localVer, &localBuild);
    info.updateAvailable = el_is_strictly_newer_release(info.versionString,
                                                        info.buildNumber,
                                                        localVer,
                                                        localBuild);
    return info;
}

- (BOOL)downloadVerifiedURL:(NSString *)urlString
                     toFile:(NSString *)destPath
                   maxBytes:(uint64_t)maxBytes
               expectedSize:(long long)expectedSize
             expectedSHA256:(NSString *)expectedSHA256
                      error:(NSString **)outError {
    if (!ELValidateHTTPSURL(urlString, ELHostCategoryGitHubUpdate, NULL, NULL, NULL)) {
        if (outError) *outError = @"Update asset URL is not an allowlisted GitHub HTTPS host";
        return NO;
    }
    if (expectedSize <= 0 || (uint64_t)expectedSize > maxBytes || !el_is_valid_sha256_hex(expectedSHA256)) {
        if (outError) *outError = @"Update asset has invalid size or missing SHA-256 hash";
        return NO;
    }

    unlink([destPath UTF8String]);
    NSDictionary *hdrs = [NSDictionary dictionaryWithObject:@"EchoLegacy-iOS4/1.0" forKey:@"User-Agent"];
    if (![[ELHTTPClient sharedClient] downloadURL:urlString
                                          headers:hdrs
                                           toFile:destPath
                                         maxBytes:maxBytes
                                    expectedBytes:expectedSize
                                            error:outError]) {
        unlink([destPath UTF8String]);
        return NO;
    }

    if (!el_verify_file_size_and_sha256(destPath, expectedSize, expectedSHA256, outError)) {
        unlink([destPath UTF8String]);
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

    /* Enforce downgrade & replay protection before downloading anything (Flaw #14) */
    NSString *localVer = nil;
    NSInteger localBuild = 0;
    el_read_installed_version(&localVer, &localBuild);
    if (!el_is_strictly_newer_release(info.versionString, info.buildNumber, localVer, localBuild)) {
        if (outError) {
            *outError = [NSString stringWithFormat:@"Refusing downgrade or same-version install (installed v%@ build %ld)",
                         localVer, (long)localBuild];
        }
        return NO;
    }

    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *execPath = [[NSBundle mainBundle] executablePath];
    BOOL canWriteBundle = [fm isWritableFileAtPath:bundleDir];

    if (canWriteBundle && [info.binaryURL length] > 0 && [execPath length] > 0) {
        if ([info.plistURL length] == 0 || [info.cacertURL length] == 0 ||
            !el_is_valid_sha256_hex(info.binarySHA256) ||
            !el_is_valid_sha256_hex(info.plistSHA256) ||
            !el_is_valid_sha256_hex(info.cacertSHA256)) {
            if (outError) *outError = @"Incomplete SHA-256 verification metadata for bundle update";
            return NO;
        }

        NSString *caPath = [bundleDir stringByAppendingPathComponent:@"cacert.pem"];
        NSString *plPath = [bundleDir stringByAppendingPathComponent:@"Info.plist"];
        NSString *tmpBin = [execPath stringByAppendingString:@".new"];
        NSString *tmpCA  = [caPath stringByAppendingString:@".new"];
        NSString *tmpPL  = [plPath stringByAppendingString:@".new"];

        /* 1. Download & SHA-256 verify binary, then validate armv6 Mach-O header */
        if (![self downloadVerifiedURL:info.binaryURL
                                toFile:tmpBin
                              maxBytes:EL_MAX_BINARY_BYTES
                          expectedSize:info.binarySize
                        expectedSHA256:info.binarySHA256
                                 error:outError] ||
            !el_validate_armv6_macho_file(tmpBin, outError)) {
            unlink([tmpBin UTF8String]);
            return NO;
        }

        /* 2. Download & SHA-256 verify cacert.pem, then validate X.509 certificates (Flaw #12) */
        if (![self downloadVerifiedURL:info.cacertURL
                                toFile:tmpCA
                              maxBytes:EL_MAX_CACERT_BYTES
                          expectedSize:info.cacertSize
                        expectedSHA256:info.cacertSHA256
                                 error:outError]) {
            unlink([tmpBin UTF8String]);
            unlink([tmpCA UTF8String]);
            return NO;
        }
        if (![ELHTTPClient validateCACertFile:tmpCA]) {
            unlink([tmpBin UTF8String]);
            unlink([tmpCA UTF8String]);
            if (outError) *outError = @"Downloaded cacert.pem failed X.509 certificate validation";
            return NO;
        }

        /* 3. Download & SHA-256 verify Info.plist, then validate property list structure (Flaw #12) */
        if (![self downloadVerifiedURL:info.plistURL
                                toFile:tmpPL
                              maxBytes:EL_MAX_PLIST_BYTES
                          expectedSize:info.plistSize
                        expectedSHA256:info.plistSHA256
                                 error:outError] ||
            !el_validate_info_plist_file(tmpPL, info.versionString, info.buildNumber, outError)) {
            unlink([tmpBin UTF8String]);
            unlink([tmpCA UTF8String]);
            unlink([tmpPL UTF8String]);
            return NO;
        }

        /* 4. All assets verified — set strict permissions and atomically rename into place */
        chmod([tmpCA UTF8String], 0644);
        chmod([tmpPL UTF8String], 0644);
        chmod([tmpBin UTF8String], 0755);

        if (rename([tmpCA UTF8String], [caPath UTF8String]) != 0 ||
            rename([tmpPL UTF8String], [plPath UTF8String]) != 0 ||
            rename([tmpBin UTF8String], [execPath UTF8String]) != 0) {
            unlink([tmpBin UTF8String]);
            unlink([tmpCA UTF8String]);
            unlink([tmpPL UTF8String]);
            if (outError) *outError = @"Could not atomically replace verified app bundle files";
            return NO;
        }

        [ELHTTPClient reloadTrustStore];

        NSString *releaseStamp = [NSString stringWithFormat:@"%@|%ld",
                                  info.versionString ? info.versionString : (info.tagName ? info.tagName : @""),
                                  (long)info.buildNumber];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:releaseStamp forKey:kDefaultsReleaseKey];
        if (info.releaseTitle) [ud setObject:info.releaseTitle forKey:kDefaultsReleaseTitleKey];
        [ud synchronize];
        return YES;
    }

    /* Fallback when /Applications/EchoLegacy.app is root:wheel read-only:
       download and verify EchoLegacy.ipa into Documents/EchoLegacy/updates/ */
    if ([info.ipaURL length] > 0) {
        if (info.ipaSize <= 0 || !el_is_valid_sha256_hex(info.ipaSHA256)) {
            if (outError) *outError = @"Release IPA is missing required size or SHA-256 metadata";
            return NO;
        }
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
        NSString *appDocs = [docs stringByAppendingPathComponent:@"EchoLegacy"];
        NSString *upDir = [appDocs stringByAppendingPathComponent:@"updates"];
        [fm createDirectoryAtPath:upDir withIntermediateDirectories:YES attributes:nil error:nil];
        chmod([appDocs UTF8String], 0700);
        chmod([upDir UTF8String], 0700);

        NSString *ipaPath = [upDir stringByAppendingPathComponent:@"EchoLegacy.ipa"];
        NSString *tmpIPA = [ipaPath stringByAppendingString:@".new"];
        if (![self downloadVerifiedURL:info.ipaURL
                                toFile:tmpIPA
                              maxBytes:EL_MAX_IPA_BYTES
                          expectedSize:info.ipaSize
                        expectedSHA256:info.ipaSHA256
                                 error:outError] ||
            !el_validate_zip_file(tmpIPA, outError)) {
            unlink([tmpIPA UTF8String]);
            return NO;
        }

        chmod([tmpIPA UTF8String], 0600);
        if (rename([tmpIPA UTF8String], [ipaPath UTF8String]) != 0) {
            unlink([tmpIPA UTF8String]);
            if (outError) *outError = @"Could not finalize verified IPA file";
            return NO;
        }
        if (outSavedIPAPath) *outSavedIPAPath = ipaPath;
        return YES;
    }

    if (outError) *outError = @"Bundle not writable and no verified IPA asset found";
    return NO;
}

@end
