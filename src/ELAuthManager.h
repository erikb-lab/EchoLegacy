#import <Foundation/Foundation.h>

extern NSString *const ELAuthStateChangedNotification;

@interface ELDeviceCodeInfo : NSObject {
    NSString *_deviceCode;
    NSString *_userCode;
    NSString *_verificationURL;
    NSInteger _interval;
    NSInteger _expiresIn;
}
@property (nonatomic, copy) NSString *deviceCode;
@property (nonatomic, copy) NSString *userCode;
@property (nonatomic, copy) NSString *verificationURL;
@property (nonatomic, assign) NSInteger interval;
@property (nonatomic, assign) NSInteger expiresIn;
@end

typedef enum {
    ELAuthPollPending = 0,
    ELAuthPollSuccess,
    ELAuthPollSlowDown,
    ELAuthPollDeniedOrExpired,
    ELAuthPollError
} ELAuthPollResult;

@interface ELAuthManager : NSObject {
    NSString *_accessToken;
    NSString *_refreshToken;
    NSTimeInterval _expiresAt;
    NSString *_accountName;
    NSString *_accountAvatarURL;
    NSString *_clientId;
    NSString *_clientSecret;
}

+ (ELAuthManager *)sharedManager;

@property (nonatomic, readonly) BOOL isSignedIn;
@property (nonatomic, readonly) BOOL hasConfiguredClientId;
@property (nonatomic, copy, readonly) NSString *accountName;
@property (nonatomic, copy, readonly) NSString *accountAvatarURL;
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, copy) NSString *clientSecret;

/* Synchronous calls — invoke from background threads */
- (ELDeviceCodeInfo *)requestDeviceCodeWithError:(NSString **)outError;
- (ELAuthPollResult)pollTokenForDeviceCode:(NSString *)deviceCode error:(NSString **)outError;
- (NSString *)validAccessTokenWithError:(NSString **)outError;
- (void)refreshAccountProfile;

- (void)signOut;
- (void)saveState;

@end
