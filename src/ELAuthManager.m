#import "ELAuthManager.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"
#import <Security/Security.h>
#import <sys/stat.h>

NSString *const ELAuthStateChangedNotification = @"ELAuthStateChangedNotification";

/* Narrowed least-privilege OAuth scope (Flaw #3) */
static NSString *const kOAuthScope = @"https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/userinfo.profile";
static NSString *const kKeychainService = @"com.echolegacy.oauth";
static NSString *const kKeychainAccountAccessToken = @"accessToken";
static NSString *const kKeychainAccountRefreshToken = @"refreshToken";
static NSString *const kKeychainAccountClientSecret = @"clientSecret";

#define EL_MAX_TOKEN_EXPIRES_IN  86400.0
#define EL_MIN_TOKEN_EXPIRES_IN  60.0
#define EL_DEF_TOKEN_EXPIRES_IN  3500.0
#define EL_MAX_DEVICE_EXPIRES_IN 900
#define EL_MIN_DEVICE_EXPIRES_IN 60
#define EL_MIN_POLL_INTERVAL     5
#define EL_MAX_POLL_INTERVAL     60

@implementation ELDeviceCodeInfo
@synthesize deviceCode = _deviceCode;
@synthesize userCode = _userCode;
@synthesize verificationURL = _verificationURL;
@synthesize interval = _interval;
@synthesize expiresIn = _expiresIn;

- (void)dealloc {
    [_deviceCode release];
    [_userCode release];
    [_verificationURL release];
    [super dealloc];
}
@end

static NSString *el_url_encode(NSString *str) {
    if (!str) return @"";
    CFStringRef encoded = CFURLCreateStringByAddingPercentEscapes(
        kCFAllocatorDefault,
        (CFStringRef)str,
        NULL,
        (CFStringRef)@"!*'();:@&=+$,/?%#[] ",
        kCFStringEncodingUTF8
    );
    if (!encoded) return @"";
    return [(NSString *)encoded autorelease];
}

static void el_harden_path_permissions(NSString *path, mode_t mode, BOOL isDirectory) {
    if ([path length] == 0) return;
    const char *fsPath = [path fileSystemRepresentation];
    if (fsPath) {
        chmod(fsPath, mode);
    }
    NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:(unsigned long)mode]
                                                                    forKey:NSFilePosixPermissions];
    if (!isDirectory) {
        [attrs setObject:NSFileProtectionComplete forKey:NSFileProtectionKey];
    }
    [[NSFileManager defaultManager] setAttributes:attrs ofItemAtPath:path error:nil];
}

static NSString *el_auth_dir_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    NSDictionary *dirAttrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithUnsignedLong:0700UL]
                                                         forKey:NSFilePosixPermissions];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:dirAttrs
                                                    error:nil];
    el_harden_path_permissions(dir, 0700, YES);
    return dir;
}

static NSString *el_auth_file_path(void) {
    return [el_auth_dir_path() stringByAppendingPathComponent:@"auth.plist"];
}

static NSString *el_oauth_client_file_path(void) {
    return [el_auth_dir_path() stringByAppendingPathComponent:@"oauth_client.plist"];
}

static BOOL el_has_control_chars(NSString *s) {
    if (!s) return NO;
    NSUInteger len = [s length];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) return YES;
    }
    return NO;
}

static NSString *el_clean_credential_string(NSString *s, NSUInteger maxLen) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0 || [trimmed length] > maxLen) return nil;
    if (el_has_control_chars(trimmed)) return nil;
    return trimmed;
}

static BOOL el_is_valid_user_code(NSString *code) {
    if (![code isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = [code length];
    if (len < 4 || len > 32) return NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [code characterAtIndex:i];
        BOOL ok = ((c >= 'A' && c <= 'Z') ||
                   (c >= 'a' && c <= 'z') ||
                   (c >= '0' && c <= '9') ||
                   c == '-' || c == ' ');
        if (!ok) return NO;
    }
    return YES;
}

static BOOL el_is_valid_device_code(NSString *code) {
    if (![code isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = [code length];
    if (len < 8 || len > 512) return NO;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [code characterAtIndex:i];
        if (c <= 0x20 || c >= 0x7F) return NO;
    }
    return YES;
}

static NSString *el_validated_verification_url(NSString *rawURL) {
    NSString *defaultURL = @"https://www.google.com/device";
    if (![rawURL isKindOfClass:[NSString class]] || [rawURL length] == 0) {
        return defaultURL;
    }
    NSString *host = nil;
    NSString *path = nil;
    if (!ELValidateHTTPSURL(rawURL, ELHostCategoryGoogleAuth, &host, NULL, &path)) {
        return defaultURL;
    }
    BOOL hostAllowed = ([host isEqualToString:@"www.google.com"] ||
                        [host isEqualToString:@"google.com"] ||
                        [host isEqualToString:@"accounts.google.com"]);
    if (!hostAllowed) {
        return defaultURL;
    }
    if (!path || (![path hasPrefix:@"/device"] && ![path hasPrefix:@"/o/oauth2/device"])) {
        return defaultURL;
    }
    return [NSString stringWithFormat:@"https://%@%@", host, path];
}

static BOOL el_is_valid_avatar_url(NSString *rawURL) {
    if (![rawURL isKindOfClass:[NSString class]] || [rawURL length] == 0 || [rawURL length] > 512) {
        return NO;
    }
    NSString *host = nil;
    if (!ELValidateHTTPSURL(rawURL, ELHostCategoryThumbnail, &host, NULL, NULL)) {
        return NO;
    }
    return ([host isEqualToString:@"lh3.googleusercontent.com"] ||
            [host hasSuffix:@".googleusercontent.com"]);
}

/* Keychain Helpers (Security.framework) */
static void el_keychain_delete(NSString *account) {
    if ([account length] == 0) return;
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           (id)kSecClassGenericPassword, (id)kSecClass,
                           kKeychainService, (id)kSecAttrService,
                           account, (id)kSecAttrAccount,
                           nil];
    SecItemDelete((CFDictionaryRef)query);
}

static NSString *el_keychain_read(NSString *account) {
    if ([account length] == 0) return nil;
    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           (id)kSecClassGenericPassword, (id)kSecClass,
                           kKeychainService, (id)kSecAttrService,
                           account, (id)kSecAttrAccount,
                           (id)kCFBooleanTrue, (id)kSecReturnData,
                           (id)kSecMatchLimitOne, (id)kSecMatchLimit,
                           nil];
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) {
        if (result) CFRelease(result);
        return nil;
    }
    NSData *data = (NSData *)result;
    NSString *str = nil;
    if ([data isKindOfClass:[NSData class]] && [data length] > 0) {
        str = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    }
    CFRelease(result);
    return ([str length] > 0 && !el_has_control_chars(str)) ? str : nil;
}

static BOOL el_keychain_write(NSString *account, NSString *value) {
    if ([account length] == 0) return NO;
    if ([value length] == 0) {
        el_keychain_delete(account);
        return YES;
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;

    NSDictionary *query = [NSDictionary dictionaryWithObjectsAndKeys:
                           (id)kSecClassGenericPassword, (id)kSecClass,
                           kKeychainService, (id)kSecAttrService,
                           account, (id)kSecAttrAccount,
                           nil];
    NSDictionary *updateAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                                 data, (id)kSecValueData,
                                 nil];
    OSStatus status = SecItemUpdate((CFDictionaryRef)query, (CFDictionaryRef)updateAttrs);
    if (status == errSecSuccess) {
        return YES;
    }

    el_keychain_delete(account);
    NSMutableDictionary *addAttrs = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     (id)kSecClassGenericPassword, (id)kSecClass,
                                     kKeychainService, (id)kSecAttrService,
                                     account, (id)kSecAttrAccount,
                                     data, (id)kSecValueData,
                                     nil];
    if (kSecAttrAccessible != NULL && kSecAttrAccessibleWhenUnlockedThisDeviceOnly != NULL) {
        [addAttrs setObject:(id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly forKey:(id)kSecAttrAccessible];
    }
    status = SecItemAdd((CFDictionaryRef)addAttrs, NULL);
    if (status != errSecSuccess && [addAttrs objectForKey:(id)kSecAttrAccessible]) {
        [addAttrs removeObjectForKey:(id)kSecAttrAccessible];
        status = SecItemAdd((CFDictionaryRef)addAttrs, NULL);
    }
    return (status == errSecSuccess);
}

@implementation ELAuthManager

+ (ELAuthManager *)sharedManager {
    static ELAuthManager *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELAuthManager alloc] init];
    }
    return shared;
}

- (id)init {
    self = [super init];
    if (self) {
        _clientId = nil;
        _clientSecret = nil;
        [self loadState];
    }
    return self;
}

- (void)dealloc {
    [_accessToken release];
    [_refreshToken release];
    [_accountName release];
    [_accountAvatarURL release];
    [_clientId release];
    [_clientSecret release];
    [super dealloc];
}

- (BOOL)isSignedIn {
    @synchronized(self) {
        return ([_refreshToken length] > 0 || [_accessToken length] > 0);
    }
}

- (BOOL)hasConfiguredClientId {
    @synchronized(self) {
        return ([_clientId length] > 0);
    }
}

- (NSString *)accountName {
    @synchronized(self) {
        return [[_accountName copy] autorelease];
    }
}

- (NSString *)accountAvatarURL {
    @synchronized(self) {
        return [[_accountAvatarURL copy] autorelease];
    }
}

- (NSString *)clientId {
    @synchronized(self) {
        return [[_clientId copy] autorelease];
    }
}

- (void)setClientId:(NSString *)clientId {
    @synchronized(self) {
        NSString *cleaned = el_clean_credential_string(clientId, 256);
        [_clientId release];
        _clientId = [cleaned copy];
    }
    [self saveState];
}

- (NSString *)clientSecret {
    @synchronized(self) {
        return [[_clientSecret copy] autorelease];
    }
}

- (void)setClientSecret:(NSString *)clientSecret {
    @synchronized(self) {
        NSString *cleaned = el_clean_credential_string(clientSecret, 256);
        [_clientSecret release];
        _clientSecret = [cleaned copy];
    }
    [self saveState];
}

- (void)loadState {
    NSString *authPath = el_auth_file_path();
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:authPath]) {
        el_harden_path_permissions(authPath, 0600, NO);
    }

    NSString *kcAccess = el_keychain_read(kKeychainAccountAccessToken);
    NSString *kcRefresh = el_keychain_read(kKeychainAccountRefreshToken);
    NSString *kcSecret = el_keychain_read(kKeychainAccountClientSecret);

    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:authPath];
    BOOL needsScrub = NO;

    @synchronized(self) {
        if ([kcAccess length] > 0) {
            [_accessToken release];
            _accessToken = [kcAccess copy];
        }
        if ([kcRefresh length] > 0) {
            [_refreshToken release];
            _refreshToken = [kcRefresh copy];
        }
        if ([kcSecret length] > 0) {
            [_clientSecret release];
            _clientSecret = [kcSecret copy];
        }

        if ([d isKindOfClass:[NSDictionary class]]) {
            NSString *legacyAT = el_clean_credential_string([d objectForKey:@"accessToken"], 2048);
            NSString *legacyRT = el_clean_credential_string([d objectForKey:@"refreshToken"], 2048);
            NSString *legacySec = el_clean_credential_string([d objectForKey:@"clientSecret"], 256);

            if ([d objectForKey:@"accessToken"] || [d objectForKey:@"refreshToken"] || [d objectForKey:@"clientSecret"]) {
                needsScrub = YES;
            }
            if ([_accessToken length] == 0 && [legacyAT length] > 0) {
                [_accessToken release];
                _accessToken = [legacyAT copy];
                el_keychain_write(kKeychainAccountAccessToken, _accessToken);
            }
            if ([_refreshToken length] == 0 && [legacyRT length] > 0) {
                [_refreshToken release];
                _refreshToken = [legacyRT copy];
                el_keychain_write(kKeychainAccountRefreshToken, _refreshToken);
            }
            if ([_clientSecret length] == 0 && [legacySec length] > 0) {
                [_clientSecret release];
                _clientSecret = [legacySec copy];
                el_keychain_write(kKeychainAccountClientSecret, _clientSecret);
            }

            NSNumber *ea = [d objectForKey:@"expiresAt"];
            NSString *an = el_clean_credential_string([d objectForKey:@"accountName"], 128);
            NSString *av = [d objectForKey:@"accountAvatarURL"];
            NSString *cid = el_clean_credential_string([d objectForKey:@"clientId"], 256);

            if ([ea isKindOfClass:[NSNumber class]]) {
                double val = [ea doubleValue];
                _expiresAt = (val > 0.0) ? val : 0.0;
            }
            if ([an length] > 0) {
                [_accountName release];
                _accountName = [an copy];
            }
            if (el_is_valid_avatar_url(av)) {
                [_accountAvatarURL release];
                _accountAvatarURL = [av copy];
            }
            if ([cid length] > 0) {
                [_clientId release];
                _clientId = [cid copy];
            }
        }

        /* Optional user-provisioned oauth_client.plist or Info.plist fallback */
        NSString *clientFile = el_oauth_client_file_path();
        if ([fm fileExistsAtPath:clientFile]) {
            el_harden_path_permissions(clientFile, 0600, NO);
            NSDictionary *cd = [NSDictionary dictionaryWithContentsOfFile:clientFile];
            if ([cd isKindOfClass:[NSDictionary class]]) {
                NSString *fcid = el_clean_credential_string([cd objectForKey:@"clientId"], 256);
                NSString *fsec = el_clean_credential_string([cd objectForKey:@"clientSecret"], 256);
                if ([_clientId length] == 0 && [fcid length] > 0) {
                    [_clientId release];
                    _clientId = [fcid copy];
                    needsScrub = YES;
                }
                if ([_clientSecret length] == 0 && [fsec length] > 0) {
                    [_clientSecret release];
                    _clientSecret = [fsec copy];
                    el_keychain_write(kKeychainAccountClientSecret, _clientSecret);
                    needsScrub = YES;
                }
                if ([cd objectForKey:@"clientSecret"]) {
                    NSMutableDictionary *cleanCD = [NSMutableDictionary dictionary];
                    if ([fcid length] > 0) [cleanCD setObject:fcid forKey:@"clientId"];
                    [cleanCD writeToFile:clientFile atomically:YES];
                    el_harden_path_permissions(clientFile, 0600, NO);
                }
            }
        }

        if ([_clientId length] == 0) {
            id bundleCID = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"ELOAuthClientId"];
            NSString *bcid = el_clean_credential_string(bundleCID, 256);
            if ([bcid length] > 0) {
                [_clientId release];
                _clientId = [bcid copy];
            }
        }
    }

    if (needsScrub) {
        [self saveState];
    }
}

- (void)saveState {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSString *at = nil;
    NSString *rt = nil;
    NSString *csec = nil;

    @synchronized(self) {
        at = [[_accessToken copy] autorelease];
        rt = [[_refreshToken copy] autorelease];
        csec = [[_clientSecret copy] autorelease];

        [d setObject:[NSNumber numberWithDouble:_expiresAt] forKey:@"expiresAt"];
        if ([_accountName length] > 0) {
            [d setObject:_accountName forKey:@"accountName"];
        }
        if (el_is_valid_avatar_url(_accountAvatarURL)) {
            [d setObject:_accountAvatarURL forKey:@"accountAvatarURL"];
        }
        if ([_clientId length] > 0) {
            [d setObject:_clientId forKey:@"clientId"];
        }
    }

    /* Persist sensitive tokens & client secret strictly in the iOS Keychain */
    el_keychain_write(kKeychainAccountAccessToken, at);
    el_keychain_write(kKeychainAccountRefreshToken, rt);
    el_keychain_write(kKeychainAccountClientSecret, csec);

    /* Persist non-secret metadata in auth.plist with 0600 permissions */
    NSString *authPath = el_auth_file_path();
    [d writeToFile:authPath atomically:YES];
    el_harden_path_permissions(authPath, 0600, NO);
}

- (void)postAuthChangedOnMain {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELAuthStateChangedNotification object:self];
}

- (ELDeviceCodeInfo *)requestDeviceCodeWithError:(NSString **)outError {
    NSString *cid = [self clientId];
    if ([cid length] == 0) {
        if (outError) *outError = @"Configure your Google OAuth Client ID in Account settings first.";
        return nil;
    }

    NSString *form = [NSString stringWithFormat:@"client_id=%@&scope=%@",
                      el_url_encode(cid), el_url_encode(kOAuthScope)];
    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"application/x-www-form-urlencoded", @"Content-Type",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://oauth2.googleapis.com/device/code"
                                                        headers:hdrs
                                                           body:[form dataUsingEncoding:NSUTF8StringEncoding]];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSDictionary class]] || resp.statusCode != 200) {
        NSString *desc = [ELJSON string:json forKey:@"error_description"];
        if (!desc) desc = [ELJSON string:json forKey:@"error"];
        if (outError) *outError = desc ? desc : [NSString stringWithFormat:@"HTTP %ld", (long)resp.statusCode];
        return nil;
    }

    NSString *devCode = [ELJSON string:json forKey:@"device_code"];
    NSString *usrCode = [ELJSON string:json forKey:@"user_code"];
    if (!el_is_valid_device_code(devCode) || !el_is_valid_user_code(usrCode)) {
        if (outError) *outError = @"Invalid device code response from Google";
        return nil;
    }

    NSString *rawVerURL = [ELJSON string:json forKey:@"verification_url"];
    if ([rawVerURL length] == 0) {
        rawVerURL = [ELJSON string:json forKey:@"verification_uri"];
    }

    ELDeviceCodeInfo *info = [[[ELDeviceCodeInfo alloc] init] autorelease];
    info.deviceCode = devCode;
    info.userCode = usrCode;
    info.verificationURL = el_validated_verification_url(rawVerURL);

    NSInteger interval = [[ELJSON number:json forKey:@"interval"] integerValue];
    if (interval < EL_MIN_POLL_INTERVAL) interval = EL_MIN_POLL_INTERVAL;
    if (interval > EL_MAX_POLL_INTERVAL) interval = EL_MAX_POLL_INTERVAL;
    info.interval = interval;

    NSInteger expiresIn = [[ELJSON number:json forKey:@"expires_in"] integerValue];
    if (expiresIn <= 0) expiresIn = EL_MAX_DEVICE_EXPIRES_IN;
    if (expiresIn < EL_MIN_DEVICE_EXPIRES_IN) expiresIn = EL_MIN_DEVICE_EXPIRES_IN;
    if (expiresIn > EL_MAX_DEVICE_EXPIRES_IN) expiresIn = EL_MAX_DEVICE_EXPIRES_IN;
    info.expiresIn = expiresIn;

    return info;
}

- (ELAuthPollResult)pollTokenForDeviceCode:(NSString *)deviceCode error:(NSString **)outError {
    NSString *cid = [self clientId];
    if ([cid length] == 0 || !el_is_valid_device_code(deviceCode)) {
        if (outError) *outError = @"Missing OAuth Client ID or device code";
        return ELAuthPollError;
    }

    NSString *csec = [self clientSecret];
    NSMutableString *form = [NSMutableString stringWithFormat:
                             @"client_id=%@&device_code=%@&grant_type=%@",
                             el_url_encode(cid),
                             el_url_encode(deviceCode),
                             el_url_encode(@"urn:ietf:params:oauth:grant-type:device_code")];
    if ([csec length] > 0) {
        [form appendFormat:@"&client_secret=%@", el_url_encode(csec)];
    }

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"application/x-www-form-urlencoded", @"Content-Type",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://oauth2.googleapis.com/token"
                                                        headers:hdrs
                                                           body:[form dataUsingEncoding:NSUTF8StringEncoding]];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return ELAuthPollError;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = @"Invalid response from Google token endpoint";
        return ELAuthPollError;
    }

    NSString *err = [ELJSON string:json forKey:@"error"];
    if (err) {
        if ([err isEqualToString:@"authorization_pending"]) return ELAuthPollPending;
        if ([err isEqualToString:@"slow_down"]) return ELAuthPollSlowDown;
        if (outError) {
            NSString *desc = [ELJSON string:json forKey:@"error_description"];
            *outError = desc ? desc : err;
        }
        return ELAuthPollDeniedOrExpired;
    }

    NSString *at = el_clean_credential_string([ELJSON string:json forKey:@"access_token"], 2048);
    NSString *rt = el_clean_credential_string([ELJSON string:json forKey:@"refresh_token"], 2048);
    double expiresIn = [[ELJSON number:json forKey:@"expires_in"] doubleValue];
    if (expiresIn <= 0.0) expiresIn = EL_DEF_TOKEN_EXPIRES_IN;
    if (expiresIn < EL_MIN_TOKEN_EXPIRES_IN) expiresIn = EL_MIN_TOKEN_EXPIRES_IN;
    if (expiresIn > EL_MAX_TOKEN_EXPIRES_IN) expiresIn = EL_MAX_TOKEN_EXPIRES_IN;

    if ([at length] == 0) {
        if (outError) *outError = @"Missing access_token";
        return ELAuthPollError;
    }

    NSTimeInterval now = [ELHTTPClient syncedCurrentTime];
    @synchronized(self) {
        [_accessToken release];
        _accessToken = [at copy];
        if ([rt length] > 0) {
            [_refreshToken release];
            _refreshToken = [rt copy];
        }
        _expiresAt = now + expiresIn - 30.0;
    }

    [self refreshAccountProfile];
    [self saveState];
    [self performSelectorOnMainThread:@selector(postAuthChangedOnMain) withObject:nil waitUntilDone:NO];
    return ELAuthPollSuccess;
}

- (void)refreshAccountProfile {
    NSString *token = nil;
    @synchronized(self) { token = [[_accessToken copy] autorelease]; }
    if ([token length] == 0 || el_has_control_chars(token)) return;

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSString stringWithFormat:@"Bearer %@", token], @"Authorization",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:@"https://www.googleapis.com/oauth2/v2/userinfo"
                                                       headers:hdrs
                                                      maxBytes:65536];
    if (resp.statusCode == 200 && resp.body) {
        NSDictionary *json = [ELJSON objectWithData:resp.body];
        NSString *name = el_clean_credential_string([ELJSON string:json forKey:@"name"], 128);
        NSString *pic = [ELJSON string:json forKey:@"picture"];
        @synchronized(self) {
            if ([name length] > 0) {
                [_accountName release];
                _accountName = [name copy];
            }
            [_accountAvatarURL release];
            _accountAvatarURL = el_is_valid_avatar_url(pic) ? [pic copy] : nil;
        }
    }
}

- (NSString *)validAccessTokenWithError:(NSString **)outError {
    NSString *at = nil;
    NSString *rt = nil;
    NSString *cid = nil;
    NSString *csec = nil;
    NSTimeInterval exp = 0;
    @synchronized(self) {
        at = [[_accessToken copy] autorelease];
        rt = [[_refreshToken copy] autorelease];
        cid = [[_clientId copy] autorelease];
        csec = [[_clientSecret copy] autorelease];
        exp = _expiresAt;
    }

    NSTimeInterval now = [ELHTTPClient syncedCurrentTime];
    if ([at length] > 0 && now < exp) {
        return at;
    }

    if ([rt length] == 0) {
        if (outError) *outError = @"Not signed in";
        return nil;
    }
    if ([cid length] == 0) {
        if (outError) *outError = @"OAuth Client ID not configured";
        return nil;
    }

    NSMutableString *form = [NSMutableString stringWithFormat:
                             @"client_id=%@&refresh_token=%@&grant_type=refresh_token",
                             el_url_encode(cid),
                             el_url_encode(rt)];
    if ([csec length] > 0) {
        [form appendFormat:@"&client_secret=%@", el_url_encode(csec)];
    }

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          @"application/x-www-form-urlencoded", @"Content-Type",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] postURL:@"https://oauth2.googleapis.com/token"
                                                        headers:hdrs
                                                           body:[form dataUsingEncoding:NSUTF8StringEncoding]];
    if (resp.errorMessage) {
        if (outError) *outError = resp.errorMessage;
        return nil;
    }
    NSDictionary *json = [ELJSON objectWithData:resp.body];
    NSString *newAT = el_clean_credential_string([ELJSON string:json forKey:@"access_token"], 2048);
    double expiresIn = [[ELJSON number:json forKey:@"expires_in"] doubleValue];
    if (expiresIn <= 0.0) expiresIn = EL_DEF_TOKEN_EXPIRES_IN;
    if (expiresIn < EL_MIN_TOKEN_EXPIRES_IN) expiresIn = EL_MIN_TOKEN_EXPIRES_IN;
    if (expiresIn > EL_MAX_TOKEN_EXPIRES_IN) expiresIn = EL_MAX_TOKEN_EXPIRES_IN;

    if ([newAT length] == 0) {
        NSString *err = [ELJSON string:json forKey:@"error_description"];
        if (!err) err = [ELJSON string:json forKey:@"error"];
        if (outError) *outError = err ? err : @"Token refresh failed";
        return nil;
    }

    @synchronized(self) {
        [_accessToken release];
        _accessToken = [newAT copy];
        _expiresAt = [ELHTTPClient syncedCurrentTime] + expiresIn - 30.0;
    }
    [self saveState];
    return newAT;
}

- (void)revokeTokenWorker:(NSString *)token {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([token length] > 0) {
        NSString *form = [NSString stringWithFormat:@"token=%@", el_url_encode(token)];
        NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                              @"application/x-www-form-urlencoded", @"Content-Type",
                              nil];
        [[ELHTTPClient sharedClient] postURL:@"https://oauth2.googleapis.com/revoke"
                                     headers:hdrs
                                        body:[form dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [pool release];
}

- (void)signOut {
    NSString *tokenToRevoke = nil;
    @synchronized(self) {
        if ([_refreshToken length] > 0) {
            tokenToRevoke = [[_refreshToken copy] autorelease];
        } else if ([_accessToken length] > 0) {
            tokenToRevoke = [[_accessToken copy] autorelease];
        }
        [_accessToken release];      _accessToken = nil;
        [_refreshToken release];     _refreshToken = nil;
        [_accountName release];      _accountName = nil;
        [_accountAvatarURL release]; _accountAvatarURL = nil;
        _expiresAt = 0;
    }

    el_keychain_delete(kKeychainAccountAccessToken);
    el_keychain_delete(kKeychainAccountRefreshToken);
    [self saveState];
    [self performSelectorOnMainThread:@selector(postAuthChangedOnMain) withObject:nil waitUntilDone:NO];

    if ([tokenToRevoke length] > 0) {
        [NSThread detachNewThreadSelector:@selector(revokeTokenWorker:) toTarget:self withObject:tokenToRevoke];
    }
}

@end
