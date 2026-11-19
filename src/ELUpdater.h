#import <Foundation/Foundation.h>

@interface ELUpdateInfo : NSObject {
    NSString *_tagName;
    NSString *_releaseTitle;
    NSString *_publishedAt;
    NSString *_binaryURL;
    NSString *_plistURL;
    NSString *_cacertURL;
    NSString *_ipaURL;
    long long _binarySize;
    BOOL _updateAvailable;
}

@property (nonatomic, copy) NSString *tagName;
@property (nonatomic, copy) NSString *releaseTitle;
@property (nonatomic, copy) NSString *publishedAt;
@property (nonatomic, copy) NSString *binaryURL;
@property (nonatomic, copy) NSString *plistURL;
@property (nonatomic, copy) NSString *cacertURL;
@property (nonatomic, copy) NSString *ipaURL;
@property (nonatomic, assign) long long binarySize;
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
