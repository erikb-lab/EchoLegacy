#import "ELAuthManager.h"
#import "ELHTTPClient.h"
#import "ELJSON.h"

NSString *const ELAuthStateChangedNotification = @"ELAuthStateChangedNotification";

static NSString *const kDefaultClientId = @"861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
static NSString *const kDefaultClientSecret = @"SboVhoG9s0rNafixCSGGKXAT";
static NSString *const kOAuthScope = @"https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/userinfo.profile";

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
    return [(NSString *)encoded autorelease];
}

static NSString *el_auth_file_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = ([paths count] > 0) ? [paths objectAtIndex:0] : NSTemporaryDirectory();
    NSString *dir = [docs stringByAppendingPathComponent:@"EchoLegacy"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"auth.plist"];
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
        _clientId = [kDefaultClientId copy];
        _clientSecret = [kDefaultClientSecret copy];
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
        NSString *trimmed = [clientId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [_clientId release];
        _clientId = ([trimmed length] > 0) ? [trimmed copy] : [kDefaultClientId copy];
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
        NSString *trimmed = [clientSecret stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [_clientSecret release];
        _clientSecret = ([trimmed length] > 0) ? [trimmed copy] : [kDefaultClientSecret copy];
    }
    [self saveState];
}

- (void)loadState {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:el_auth_file_path()];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    @synchronized(self) {
        NSString *at = [d objectForKey:@"accessToken"];
        NSString *rt = [d objectForKey:@"refreshToken"];
        NSNumber *ea = [d objectForKey:@"expiresAt"];
        NSString *an = [d objectForKey:@"accountName"];
        NSString *av = [d objectForKey:@"accountAvatarURL"];
        NSString *cid = [d objectForKey:@"clientId"];
        NSString *csec = [d objectForKey:@"clientSecret"];
        if ([at isKindOfClass:[NSString class]]) { [_accessToken release]; _accessToken = [at copy]; }
        if ([rt isKindOfClass:[NSString class]]) { [_refreshToken release]; _refreshToken = [rt copy]; }
        if ([ea isKindOfClass:[NSNumber class]]) _expiresAt = [ea doubleValue];
        if ([an isKindOfClass:[NSString class]]) { [_accountName release]; _accountName = [an copy]; }
        if ([av isKindOfClass:[NSString class]]) { [_accountAvatarURL release]; _accountAvatarURL = [av copy]; }
        if ([cid isKindOfClass:[NSString class]] && [cid length] > 0) { [_clientId release]; _clientId = [cid copy]; }
        if ([csec isKindOfClass:[NSString class]] && [csec length] > 0) { [_clientSecret release]; _clientSecret = [csec copy]; }
    }
}

- (void)saveState {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    @synchronized(self) {
        if (_accessToken)      [d setObject:_accessToken forKey:@"accessToken"];
        if (_refreshToken)     [d setObject:_refreshToken forKey:@"refreshToken"];
        [d setObject:[NSNumber numberWithDouble:_expiresAt] forKey:@"expiresAt"];
        if (_accountName)      [d setObject:_accountName forKey:@"accountName"];
        if (_accountAvatarURL) [d setObject:_accountAvatarURL forKey:@"accountAvatarURL"];
        if (_clientId)         [d setObject:_clientId forKey:@"clientId"];
        if (_clientSecret)     [d setObject:_clientSecret forKey:@"clientSecret"];
    }
    [d writeToFile:el_auth_file_path() atomically:YES];
}

- (void)postAuthChangedOnMain {
    [[NSNotificationCenter defaultCenter] postNotificationName:ELAuthStateChangedNotification object:self];
}

- (ELDeviceCodeInfo *)requestDeviceCodeWithError:(NSString **)outError {
    NSString *cid = [self clientId];
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

    ELDeviceCodeInfo *info = [[[ELDeviceCodeInfo alloc] init] autorelease];
    info.deviceCode = [ELJSON string:json forKey:@"device_code"];
    info.userCode = [ELJSON string:json forKey:@"user_code"];
    info.verificationURL = [ELJSON string:json forKey:@"verification_url"];
    if (!info.verificationURL) info.verificationURL = @"https://www.google.com/device";
    info.interval = [[ELJSON number:json forKey:@"interval"] integerValue];
    if (info.interval < 3) info.interval = 5;
    info.expiresIn = [[ELJSON number:json forKey:@"expires_in"] integerValue];
    if (info.expiresIn <= 0) info.expiresIn = 1800;

    if ([info.deviceCode length] == 0 || [info.userCode length] == 0) {
        if (outError) *outError = @"Incomplete device code response from Google";
        return nil;
    }
    return info;
}

- (ELAuthPollResult)pollTokenForDeviceCode:(NSString *)deviceCode error:(NSString **)outError {
    NSString *form = [NSString stringWithFormat:
                      @"client_id=%@&client_secret=%@&device_code=%@&grant_type=%@",
                      el_url_encode([self clientId]),
                      el_url_encode([self clientSecret]),
                      el_url_encode(deviceCode),
                      el_url_encode(@"urn:ietf:params:oauth:grant-type:device_code")];
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

    NSString *at = [ELJSON string:json forKey:@"access_token"];
    NSString *rt = [ELJSON string:json forKey:@"refresh_token"];
    double expiresIn = [[ELJSON number:json forKey:@"expires_in"] doubleValue];
    if (expiresIn <= 0) expiresIn = 3500;

    if ([at length] == 0) {
        if (outError) *outError = @"Missing access_token";
        return ELAuthPollError;
    }

    @synchronized(self) {
        [_accessToken release];
        _accessToken = [at copy];
        if ([rt length] > 0) {
            [_refreshToken release];
            _refreshToken = [rt copy];
        }
        _expiresAt = [[NSDate date] timeIntervalSince1970] + expiresIn - 60.0;
    }

    [self refreshAccountProfile];
    [self saveState];
    [self performSelectorOnMainThread:@selector(postAuthChangedOnMain) withObject:nil waitUntilDone:NO];
    return ELAuthPollSuccess;
}

- (void)refreshAccountProfile {
    NSString *token = nil;
    @synchronized(self) { token = [[_accessToken copy] autorelease]; }
    if ([token length] == 0) return;

    NSDictionary *hdrs = [NSDictionary dictionaryWithObjectsAndKeys:
                          [NSString stringWithFormat:@"Bearer %@", token], @"Authorization",
                          nil];
    ELHTTPResponse *resp = [[ELHTTPClient sharedClient] getURL:@"https://www.googleapis.com/oauth2/v2/userinfo"
                                                       headers:hdrs];
    if (resp.statusCode == 200 && resp.body) {
        NSDictionary *json = [ELJSON objectWithData:resp.body];
        NSString *name = [ELJSON string:json forKey:@"name"];
        NSString *pic = [ELJSON string:json forKey:@"picture"];
        @synchronized(self) {
            if ([name length] > 0) {
                [_accountName release];
                _accountName = [name copy];
            }
            if ([pic length] > 0) {
                [_accountAvatarURL release];
                _accountAvatarURL = [pic copy];
            }
        }
    }
}

- (NSString *)validAccessTokenWithError:(NSString **)outError {
    NSString *at = nil;
    NSString *rt = nil;
    NSTimeInterval exp = 0;
    @synchronized(self) {
        at = [[_accessToken copy] autorelease];
        rt = [[_refreshToken copy] autorelease];
        exp = _expiresAt;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if ([at length] > 0 && now < exp) {
        return at;
    }

    if ([rt length] == 0) {
        if (outError) *outError = @"Not signed in";
        return nil;
    }

    NSString *form = [NSString stringWithFormat:
                      @"client_id=%@&client_secret=%@&refresh_token=%@&grant_type=refresh_token",
                      el_url_encode([self clientId]),
                      el_url_encode([self clientSecret]),
                      el_url_encode(rt)];
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
    NSString *newAT = [ELJSON string:json forKey:@"access_token"];
    double expiresIn = [[ELJSON number:json forKey:@"expires_in"] doubleValue];
    if ([newAT length] == 0) {
        NSString *err = [ELJSON string:json forKey:@"error_description"];
        if (!err) err = [ELJSON string:json forKey:@"error"];
        if (outError) *outError = err ? err : @"Token refresh failed";
        return nil;
    }

    @synchronized(self) {
        [_accessToken release];
        _accessToken = [newAT copy];
        _expiresAt = now + (expiresIn > 0 ? expiresIn : 3500.0) - 60.0;
    }
    [self saveState];
    return newAT;
}

- (void)signOut {
    @synchronized(self) {
        [_accessToken release];      _accessToken = nil;
        [_refreshToken release];     _refreshToken = nil;
        [_accountName release];      _accountName = nil;
        [_accountAvatarURL release]; _accountAvatarURL = nil;
        _expiresAt = 0;
    }
    [self saveState];
    [self performSelectorOnMainThread:@selector(postAuthChangedOnMain) withObject:nil waitUntilDone:NO];
}

@end
