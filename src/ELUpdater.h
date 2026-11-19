#import <Foundation/Foundation.h>

@interface ELUpdateInfo : NSObject {
    NSString *_tagName;
    NSString *_releaseTitle;
    NSString *_publishedAt;
    NSString *_versionString;
    NSInteger _buildNumber;
    NSString *_versionJSONURL;
    long long _versionJSONSize;
    NSString *_binaryURL;
    NSString *_plistURL;
    NSString *_cacertURL;
    NSString *_ipaURL;
    long long _binarySize;
    long long _plistSize;
    long long _cacertSize;
    long long _ipaSize;
    NSString *_binarySHA256;
    NSString *_plistSHA256;
    NSString *_cacertSHA256;
    NSString *_ipaSHA256;
    BOOL _updateAvailable;
}

@property (nonatomic, copy) NSString *tagName;
@property (nonatomic, copy) NSString *releaseTitle;
@property (nonatomic, copy) NSString *publishedAt;
@property (nonatomic, copy) NSString *versionString;
@property (nonatomic, assign) NSInteger buildNumber;
@property (nonatomic, copy) NSString *versionJSONURL;
@property (nonatomic, assign) long long versionJSONSize;
@property (nonatomic, copy) NSString *binaryURL;
@property (nonatomic, copy) NSString *plistURL;
@property (nonatomic, copy) NSString *cacertURL;
@property (nonatomic, copy) NSString *ipaURL;
@property (nonatomic, assign) long long binarySize;
@property (nonatomic, assign) long long plistSize;
@property (nonatomic, assign) long long cacertSize;
@property (nonatomic, assign) long long ipaSize;
@property (nonatomic, copy) NSString *binarySHA256;
@property (nonatomic, copy) NSString *plistSHA256;
@property (nonatomic, copy) NSString *cacertSHA256;
@property (nonatomic, copy) NSString *ipaSHA256;
@property (nonatomic, assign) BOOL updateAvailable;

@end

@interface ELUpdater : NSObject

+ (ELUpdater *)sharedUpdater;

- (NSString *)installedVersionLabel;

/* Synchronous calls — invoke from a background NSThread */
- (ELUpdateInfo *)checkForUpdateWithError:(NSString **)outError;
- (BOOL)installUpdate:(ELUpdateInfo *)info
          savedIPAPath:(NSString **)outSavedIPAPath
                 error:(NSString **)outError;

@end
