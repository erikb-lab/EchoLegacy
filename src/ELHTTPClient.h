#import <Foundation/Foundation.h>

typedef enum {
    ELHostCategoryAnyAllowlisted = 0,
    ELHostCategoryYouTubeAPI,   /* music.youtube.com, www.youtube.com, youtubei.googleapis.com */
    ELHostCategoryGoogleAuth,   /* oauth2.googleapis.com, www.googleapis.com, accounts.google.com, www.google.com, google.com */
    ELHostCategoryMediaStream,  /* *.googlevideo.com */
    ELHostCategoryThumbnail,    /* i.ytimg.com, *.ytimg.com, lh3.googleusercontent.com, *.googleusercontent.com, *.ggpht.com */
    ELHostCategoryGitHubUpdate, /* api.github.com, github.com, objects.githubusercontent.com, release-assets.githubusercontent.com */
    ELHostCategoryLyrics        /* lrclib.net */
} ELHostCategory;

/* Validates that urlString is a clean https:// URL (no CR/LF/control chars, no userinfo,
   port 443, non-IP/non-private host) whose host matches the specified allowlist category. */
BOOL ELValidateHTTPSURL(NSString *urlString,
                        ELHostCategory category,
                        NSString **outHost,
                        NSString **outPort,
                        NSString **outPathAndQuery);

@interface ELHTTPResponse : NSObject {
    NSInteger _statusCode;
    NSDictionary *_headers;
    NSData *_body;
    NSString *_errorMessage;
}
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, retain) NSDictionary *headers;
@property (nonatomic, retain) NSData *body;
@property (nonatomic, copy) NSString *errorMessage;
@end

/* Return YES to keep receiving data, NO to abort transfer early. */
typedef BOOL (*ELHTTPStreamCallback)(const uint8_t *bytes, NSUInteger length,
                                     long long contentLength, void *userData);

@interface ELHTTPClient : NSObject

+ (ELHTTPClient *)sharedClient;

/* Validates that a PEM file on disk parses >= 1 valid X.509 certificate without errors. */
+ (BOOL)validateCACertFile:(NSString *)pemPath;

/* Reloads the bundle's cacert.pem trust store and clears cached TLS sessions. */
+ (BOOL)reloadTrustStore;

/* Closes and clears all idle keep-alive TLS connections (e.g. on memory warning or background). */
+ (void)clearKeepAlivePool;

/* Returns clock-drift-compensated UTC epoch seconds (synced from verified HTTPS Date headers). */
+ (NSTimeInterval)syncedCurrentTime;

/* Synchronous requests (always call from a background thread). */
- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body;

- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body
                         maxBytes:(NSUInteger)maxBytes;

- (ELHTTPResponse *)getURL:(NSString *)urlString headers:(NSDictionary *)headers;

- (ELHTTPResponse *)getURL:(NSString *)urlString
                   headers:(NSDictionary *)headers
                  maxBytes:(NSUInteger)maxBytes;

- (ELHTTPResponse *)postURL:(NSString *)urlString
                    headers:(NSDictionary *)headers
                       body:(NSData *)body;

/* Streams an HTTPS GET directly to destPath with strict byte cap & truncation verification. */
- (BOOL)downloadURL:(NSString *)urlString
            headers:(NSDictionary *)headers
             toFile:(NSString *)destPath
           maxBytes:(uint64_t)maxBytes
      expectedBytes:(long long)expectedBytes
              error:(NSString **)outError;

/* Streaming GET (follows redirects, handles chunked & Content-Length, supports Range header). */
- (BOOL)streamGETURL:(NSString *)urlString
             headers:(NSDictionary *)headers
            callback:(ELHTTPStreamCallback)callback
            userData:(void *)userData
          statusCode:(NSInteger *)outStatus
       contentLength:(long long *)outContentLength
               error:(NSString **)outError;

/* Bounded Range-chunked streaming GET (required for unthrottled YouTube googlevideo.com streams). */
- (BOOL)streamRangeChunksGETURL:(NSString *)urlString
                        headers:(NSDictionary *)headers
                    startOffset:(uint64_t)startOffset
                    totalLength:(long long)totalLength
                      chunkSize:(uint64_t)chunkSize
                       callback:(ELHTTPStreamCallback)callback
                       userData:(void *)userData
                     statusCode:(NSInteger *)outStatus
                          error:(NSString **)outError;

@end
