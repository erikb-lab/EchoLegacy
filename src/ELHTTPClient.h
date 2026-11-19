#import <Foundation/Foundation.h>

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

/* Synchronous requests (always call from a background thread). */
- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body;

- (ELHTTPResponse *)getURL:(NSString *)urlString headers:(NSDictionary *)headers;

- (ELHTTPResponse *)postURL:(NSString *)urlString
                    headers:(NSDictionary *)headers
                       body:(NSData *)body;

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
