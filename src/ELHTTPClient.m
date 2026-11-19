#import "ELHTTPClient.h"

#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

@implementation ELHTTPResponse
@synthesize statusCode = _statusCode;
@synthesize headers = _headers;
@synthesize body = _body;
@synthesize errorMessage = _errorMessage;

- (void)dealloc {
    [_headers release];
    [_body release];
    [_errorMessage release];
    [super dealloc];
}
@end

typedef struct {
    int is_https;
    int fd;
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
} el_conn_t;

/* Shared thread-safe TLS config + pre-seeded DRBG + Root CA chain */
static pthread_mutex_t          g_tls_init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t          g_tls_rng_lock  = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t          g_tls_sess_lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL                     g_tls_ready     = NO;
static mbedtls_x509_crt         g_ca_chain;
static mbedtls_entropy_context  g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static mbedtls_ssl_config       g_ssl_conf;

/* 8-slot LRU TLS 1.2 session ticket/ID cache for abbreviated 1-RTT handshakes */
#define EL_TLS_SESSION_CACHE_SLOTS 8
#define EL_TLS_SESSION_TTL_SEC     1800

typedef struct {
    BOOL                valid;
    char                key[128];
    time_t              saved_at;
    uint64_t            lru_seq;
    mbedtls_ssl_session session;
} el_tls_session_slot_t;

static el_tls_session_slot_t g_tls_sessions[EL_TLS_SESSION_CACHE_SLOTS];
static uint64_t              g_tls_lru_clock = 0;

static int el_tls_rng_cb(void *p_rng, unsigned char *output, size_t output_len) {
    (void)p_rng;
    pthread_mutex_lock(&g_tls_rng_lock);
    int ret = mbedtls_ctr_drbg_random(&g_drbg, output, output_len);
    pthread_mutex_unlock(&g_tls_rng_lock);
    return ret;
}

static BOOL el_init_tls_once(NSString **errOut) {
    pthread_mutex_lock(&g_tls_init_lock);
    if (g_tls_ready) {
        pthread_mutex_unlock(&g_tls_init_lock);
        return YES;
    }

    mbedtls_x509_crt_init(&g_ca_chain);
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_drbg);
    mbedtls_ssl_config_init(&g_ssl_conf);

    NSString *pemPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (pemPath) {
        mbedtls_x509_crt_parse_file(&g_ca_chain, [pemPath UTF8String]);
    }

    const char *pers = "echo_legacy_tls_v2";
    int ret = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                                    (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"RNG seed failed (%d)", ret];
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    ret = mbedtls_ssl_config_defaults(&g_ssl_conf,
                                      MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"TLS config failed (%d)", ret];
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    /* OPTIONAL verification so a drifted iPod RTC clock doesn't hard-brick playback,
       while still attaching our modern Root CA bundle. */
    mbedtls_ssl_conf_authmode(&g_ssl_conf, MBEDTLS_SSL_VERIFY_OPTIONAL);
    mbedtls_ssl_conf_ca_chain(&g_ssl_conf, &g_ca_chain, NULL);
    mbedtls_ssl_conf_rng(&g_ssl_conf, el_tls_rng_cb, NULL);

    g_tls_ready = YES;
    pthread_mutex_unlock(&g_tls_init_lock);
    return YES;
}

static BOOL el_tls_session_apply(mbedtls_ssl_context *ssl, const char *host, const char *port) {
    char key[128];
    snprintf(key, sizeof(key), "%s:%s", host ? host : "", port ? port : "443");
    time_t now = time(NULL);
    BOOL applied = NO;

    pthread_mutex_lock(&g_tls_sess_lock);
    for (int i = 0; i < EL_TLS_SESSION_CACHE_SLOTS; i++) {
        el_tls_session_slot_t *s = &g_tls_sessions[i];
        if (s->valid && strcmp(s->key, key) == 0) {
            if (now >= s->saved_at && (now - s->saved_at) <= EL_TLS_SESSION_TTL_SEC) {
                if (mbedtls_ssl_set_session(ssl, &s->session) == 0) {
                    s->lru_seq = ++g_tls_lru_clock;
                    applied = YES;
                }
            } else {
                mbedtls_ssl_session_free(&s->session);
                s->valid = NO;
            }
            break;
        }
    }
    pthread_mutex_unlock(&g_tls_sess_lock);
    return applied;
}

static void el_tls_session_evict(const char *host, const char *port) {
    char key[128];
    snprintf(key, sizeof(key), "%s:%s", host ? host : "", port ? port : "443");

    pthread_mutex_lock(&g_tls_sess_lock);
    for (int i = 0; i < EL_TLS_SESSION_CACHE_SLOTS; i++) {
        el_tls_session_slot_t *s = &g_tls_sessions[i];
        if (s->valid && strcmp(s->key, key) == 0) {
            mbedtls_ssl_session_free(&s->session);
            s->valid = NO;
            break;
        }
    }
    pthread_mutex_unlock(&g_tls_sess_lock);
}

static void el_tls_session_save(const mbedtls_ssl_context *ssl, const char *host, const char *port) {
    char key[128];
    snprintf(key, sizeof(key), "%s:%s", host ? host : "", port ? port : "443");

    mbedtls_ssl_session fresh;
    mbedtls_ssl_session_init(&fresh);
    if (mbedtls_ssl_get_session(ssl, &fresh) != 0) {
        mbedtls_ssl_session_free(&fresh);
        return;
    }

    time_t now = time(NULL);
    pthread_mutex_lock(&g_tls_sess_lock);
    int target = -1;
    uint64_t oldest_seq = UINT64_MAX;
    int oldest_idx = 0;

    for (int i = 0; i < EL_TLS_SESSION_CACHE_SLOTS; i++) {
        el_tls_session_slot_t *s = &g_tls_sessions[i];
        if (s->valid && strcmp(s->key, key) == 0) {
            target = i;
            break;
        }
        if (!s->valid && target < 0) {
            target = i;
        }
        if (s->valid && s->lru_seq < oldest_seq) {
            oldest_seq = s->lru_seq;
            oldest_idx = i;
        }
    }
    if (target < 0) target = oldest_idx;

    el_tls_session_slot_t *slot = &g_tls_sessions[target];
    if (slot->valid) {
        mbedtls_ssl_session_free(&slot->session);
    }
    slot->session = fresh;
    strncpy(slot->key, key, sizeof(slot->key) - 1);
    slot->key[sizeof(slot->key) - 1] = '\0';
    slot->saved_at = now;
    slot->lru_seq = ++g_tls_lru_clock;
    slot->valid = YES;
    pthread_mutex_unlock(&g_tls_sess_lock);
}

static void el_conn_close(el_conn_t *c) {
    if (!c) return;
    if (c->is_https) {
        mbedtls_ssl_close_notify(&c->ssl);
        mbedtls_ssl_free(&c->ssl);
        mbedtls_net_free(&c->net);
    } else if (c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
}

static int el_set_socket_opts(int fd, int timeout_sec) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval tv;
    tv.tv_sec = timeout_sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return 0;
}

static int el_conn_open(el_conn_t *c, const char *host, const char *port, int is_https, NSString **errOut) {
    memset(c, 0, sizeof(*c));
    c->is_https = is_https;
    c->fd = -1;

    if (!is_https) {
        struct addrinfo hints, *res = NULL, *p = NULL;
        memset(&hints, 0, sizeof(hints));
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        if (getaddrinfo(host, port, &hints, &res) != 0 || !res) {
            if (errOut) *errOut = [NSString stringWithFormat:@"DNS lookup failed for %s", host];
            return -1;
        }
        int fd = -1;
        for (p = res; p; p = p->ai_next) {
            fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
            if (fd < 0) continue;
            el_set_socket_opts(fd, 20);
            if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
            close(fd);
            fd = -1;
        }
        freeaddrinfo(res);
        if (fd < 0) {
            if (errOut) *errOut = [NSString stringWithFormat:@"Connect failed to %s:%s", host, port];
            return -1;
        }
        c->fd = fd;
        return 0;
    }

    if (!el_init_tls_once(errOut)) {
        return -1;
    }

    mbedtls_net_init(&c->net);
    mbedtls_ssl_init(&c->ssl);

    int ret = mbedtls_net_connect(&c->net, host, port, MBEDTLS_NET_PROTO_TCP);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"TCP connect failed to %s:%s (%d)", host, port, ret];
        el_conn_close(c);
        return -1;
    }
    el_set_socket_opts(c->net.fd, 20);

    ret = mbedtls_ssl_setup(&c->ssl, &g_ssl_conf);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"TLS setup failed (%d)", ret];
        el_conn_close(c);
        return -1;
    }

    ret = mbedtls_ssl_set_hostname(&c->ssl, host);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"SNI failed (%d)", ret];
        el_conn_close(c);
        return -1;
    }

    /* Attempt 1-RTT TLS 1.2 session ticket/ID resumption if cached for this host */
    BOOL usedCachedSession = el_tls_session_apply(&c->ssl, host, port);

    mbedtls_ssl_set_bio(&c->ssl, &c->net, mbedtls_net_send, mbedtls_net_recv, NULL);

    while ((ret = mbedtls_ssl_handshake(&c->ssl)) != 0) {
        if (ret != MBEDTLS_ERR_SSL_WANT_READ && ret != MBEDTLS_ERR_SSL_WANT_WRITE) {
            if (usedCachedSession) {
                el_tls_session_evict(host, port);
            }
            char ebuf[128];
            mbedtls_strerror(ret, ebuf, sizeof(ebuf));
            if (errOut) *errOut = [NSString stringWithFormat:@"TLS handshake failed: %s (-0x%x)", ebuf, -ret];
            el_conn_close(c);
            return -1;
        }
    }

    el_tls_session_save(&c->ssl, host, port);
    return 0;
}

static int el_conn_write_all(el_conn_t *c, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        int ret;
        if (c->is_https) {
            ret = mbedtls_ssl_write(&c->ssl, buf + sent, len - sent);
            if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        } else {
            ret = (int)send(c->fd, buf + sent, len - sent, 0);
            if (ret < 0 && errno == EINTR) continue;
        }
        if (ret <= 0) return -1;
        sent += (size_t)ret;
    }
    return 0;
}

static int el_conn_read(el_conn_t *c, uint8_t *buf, size_t max_len) {
    for (;;) {
        int ret;
        if (c->is_https) {
            ret = mbedtls_ssl_read(&c->ssl, buf, max_len);
            if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (ret == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
            return ret;
        } else {
            ret = (int)recv(c->fd, buf, max_len, 0);
            if (ret < 0 && errno == EINTR) continue;
            return ret;
        }
    }
}

static NSData *el_gunzip_data(NSData *compressed) {
    if (!compressed || [compressed length] == 0) return compressed;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) return compressed;

    zs.next_in = (Bytef *)[compressed bytes];
    zs.avail_in = (uInt)[compressed length];

    NSMutableData *out = [NSMutableData dataWithCapacity:[compressed length] * 2];
    uint8_t chunk[16384];
    int status = Z_OK;
    while (status == Z_OK) {
        zs.next_out = chunk;
        zs.avail_out = sizeof(chunk);
        status = inflate(&zs, Z_NO_FLUSH);
        size_t have = sizeof(chunk) - zs.avail_out;
        if (have > 0) [out appendBytes:chunk length:have];
    }
    inflateEnd(&zs);
    return (status == Z_STREAM_END) ? out : compressed;
}

static BOOL el_parse_url(NSString *urlString, BOOL *isHTTPS, NSString **host, NSString **port, NSString **pathAndQuery) {
    if (!urlString) return NO;
    NSRange schemeRange = [urlString rangeOfString:@"://"];
    if (schemeRange.location == NSNotFound) return NO;

    NSString *scheme = [[urlString substringToIndex:schemeRange.location] lowercaseString];
    *isHTTPS = [scheme isEqualToString:@"https"];
    if (!*isHTTPS && ![scheme isEqualToString:@"http"]) return NO;

    NSString *rest = [urlString substringFromIndex:schemeRange.location + 3];
    NSRange slashRange = [rest rangeOfString:@"/"];
    NSString *authority = (slashRange.location == NSNotFound) ? rest : [rest substringToIndex:slashRange.location];
    NSString *pq = (slashRange.location == NSNotFound) ? @"/" : [rest substringFromIndex:slashRange.location];

    NSRange colonRange = [authority rangeOfString:@":"];
    if (colonRange.location != NSNotFound) {
        *host = [authority substringToIndex:colonRange.location];
        *port = [authority substringFromIndex:colonRange.location + 1];
    } else {
        *host = authority;
        *port = *isHTTPS ? @"443" : @"80";
    }
    *pathAndQuery = pq;
    return ([*host length] > 0);
}

static BOOL el_read_headers(el_conn_t *c, NSInteger *statusCode, NSMutableDictionary *headers, NSMutableData *leftover, NSString **errOut) {
    NSMutableData *buf = [NSMutableData dataWithCapacity:2048];
    uint8_t tmp[2048];
    NSUInteger headerEnd = NSNotFound;

    while (headerEnd == NSNotFound) {
        int n = el_conn_read(c, tmp, sizeof(tmp));
        if (n <= 0) {
            if (errOut) *errOut = @"Connection closed while reading HTTP headers";
            return NO;
        }
        [buf appendBytes:tmp length:(NSUInteger)n];
        const char *bytes = (const char *)[buf bytes];
        NSUInteger blen = [buf length];
        for (NSUInteger i = 0; i + 3 < blen; i++) {
            if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                headerEnd = i + 4;
                break;
            }
        }
        if (blen > 65536) {
            if (errOut) *errOut = @"HTTP header too large";
            return NO;
        }
    }

    NSString *hdrText = [[[NSString alloc] initWithBytes:[buf bytes]
                                                  length:headerEnd
                                                encoding:NSISOLatin1StringEncoding] autorelease];
    NSArray *lines = [hdrText componentsSeparatedByString:@"\r\n"];
    if ([lines count] == 0) return NO;

    NSString *statusLine = [lines objectAtIndex:0];
    NSArray *parts = [statusLine componentsSeparatedByString:@" "];
    *statusCode = ([parts count] >= 2) ? [[parts objectAtIndex:1] integerValue] : 0;

    for (NSUInteger i = 1; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange col = [line rangeOfString:@":"];
        if (col.location == NSNotFound) continue;
        NSString *k = [[[line substringToIndex:col.location]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        NSString *v = [[line substringFromIndex:col.location + 1]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k length] > 0) [headers setObject:v forKey:k];
    }

    if ([buf length] > headerEnd) {
        [leftover appendBytes:((const uint8_t *)[buf bytes]) + headerEnd
                       length:[buf length] - headerEnd];
    }
    return YES;
}

typedef struct {
    NSMutableData *buf;
} el_buf_ctx_t;

static BOOL el_collect_chunk_cb(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    (void)contentLength;
    el_buf_ctx_t *bctx = (el_buf_ctx_t *)userData;
    [bctx->buf appendBytes:bytes length:length];
    return YES;
}

@implementation ELHTTPClient

+ (ELHTTPClient *)sharedClient {
    static ELHTTPClient *shared = nil;
    @synchronized(self) {
        if (!shared) shared = [[ELHTTPClient alloc] init];
    }
    return shared;
}

- (BOOL)performRequestMethod:(NSString *)method
                         url:(NSString *)urlString
                     headers:(NSDictionary *)headers
                        body:(NSData *)body
                    callback:(ELHTTPStreamCallback)callback
                    userData:(void *)userData
                  statusCode:(NSInteger *)outStatus
             responseHeaders:(NSDictionary **)outHeaders
               contentLength:(long long *)outContentLength
                       error:(NSString **)outError {
    NSString *currentURL = urlString;
    NSString *currentMethod = method;
    NSData *currentBody = body;
    NSMutableDictionary *curHeaders = [NSMutableDictionary dictionary];
    if (headers) [curHeaders addEntriesFromDictionary:headers];

    for (int hop = 0; hop < 6; hop++) {
        BOOL isHTTPS = YES;
        NSString *host = nil, *port = nil, *pq = nil;
        if (!el_parse_url(currentURL, &isHTTPS, &host, &port, &pq)) {
            if (outError) *outError = @"Invalid URL";
            return NO;
        }

        el_conn_t conn;
        NSString *openErr = nil;
        if (el_conn_open(&conn, [host UTF8String], [port UTF8String], isHTTPS ? 1 : 0, &openErr) != 0) {
            if (outError) *outError = openErr;
            return NO;
        }

        NSMutableString *req = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", currentMethod, pq];
        [req appendFormat:@"Host: %@\r\n", host];
        [req appendString:@"Connection: close\r\n"];

        BOOL hasUA = NO;
        BOOL hasCL = NO;
        for (NSString *k in curHeaders) {
            NSString *lk = [k lowercaseString];
            if ([lk isEqualToString:@"host"] || [lk isEqualToString:@"connection"]) continue;
            if ([lk isEqualToString:@"user-agent"]) hasUA = YES;
            if ([lk isEqualToString:@"content-length"]) hasCL = YES;
            [req appendFormat:@"%@: %@\r\n", k, [curHeaders objectForKey:k]];
        }
        if (!hasUA) {
            [req appendString:@"User-Agent: Mozilla/5.0 (iPhone; U; CPU iPhone OS 4_1 like Mac OS X)\r\n"];
        }
        if (currentBody && [currentBody length] > 0 && !hasCL) {
            [req appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[currentBody length]];
        }
        [req appendString:@"\r\n"];

        NSData *reqHdrData = [req dataUsingEncoding:NSUTF8StringEncoding];
        if (el_conn_write_all(&conn, (const uint8_t *)[reqHdrData bytes], [reqHdrData length]) != 0 ||
            (currentBody && [currentBody length] > 0 &&
             el_conn_write_all(&conn, (const uint8_t *)[currentBody bytes], [currentBody length]) != 0)) {
            el_conn_close(&conn);
            if (outError) *outError = @"Failed sending HTTP request";
            return NO;
        }

        NSInteger status = 0;
        NSMutableDictionary *respHeaders = [NSMutableDictionary dictionary];
        NSMutableData *leftover = [NSMutableData data];
        NSString *hdrErr = nil;
        if (!el_read_headers(&conn, &status, respHeaders, leftover, &hdrErr)) {
            el_conn_close(&conn);
            if (outError) *outError = hdrErr;
            return NO;
        }

        /* Handle redirects */
        if ((status == 301 || status == 302 || status == 303 || status == 307 || status == 308) &&
            [respHeaders objectForKey:@"location"]) {
            NSString *loc = [respHeaders objectForKey:@"location"];
            el_conn_close(&conn);
            if ([loc hasPrefix:@"/"]) {
                loc = [NSString stringWithFormat:@"%@://%@%@", isHTTPS ? @"https" : @"http", host, loc];
            }
            BOOL nextHTTPS = YES;
            NSString *nextHost = nil, *nextPort = nil, *nextPQ = nil;
            if (el_parse_url(loc, &nextHTTPS, &nextHost, &nextPort, &nextPQ)) {
                if (![nextHost isEqualToString:host]) {
                    /* Strip Authorization across origins */
                    NSMutableArray *toRemove = [NSMutableArray array];
                    for (NSString *k in curHeaders) {
                        if ([[k lowercaseString] isEqualToString:@"authorization"]) [toRemove addObject:k];
                    }
                    for (NSString *k in toRemove) [curHeaders removeObjectForKey:k];
                }
            }
            currentURL = loc;
            if (status == 303) {
                currentMethod = @"GET";
                currentBody = nil;
            }
            continue;
        }

        if (outStatus) *outStatus = status;
        if (outHeaders) *outHeaders = [[respHeaders copy] autorelease];

        long long contentLen = -1;
        NSString *clStr = [respHeaders objectForKey:@"content-length"];
        if (clStr) contentLen = [clStr longLongValue];
        if (outContentLength) *outContentLength = contentLen;

        NSString *te = [[respHeaders objectForKey:@"transfer-encoding"] lowercaseString];
        BOOL isChunked = (te && [te rangeOfString:@"chunked"].location != NSNotFound);

        BOOL aborted = NO;
        uint8_t rbuf[16384];

        if (isChunked) {
            NSMutableData *cbuf = [NSMutableData dataWithData:leftover];
            BOOL done = NO;
            while (!done && !aborted) {
                /* Ensure we have a chunk size line (\r\n) */
                NSUInteger crlf = NSNotFound;
                while (crlf == NSNotFound) {
                    const char *p = (const char *)[cbuf bytes];
                    NSUInteger cl = [cbuf length];
                    for (NSUInteger i = 0; i + 1 < cl; i++) {
                        if (p[i] == '\r' && p[i+1] == '\n') { crlf = i; break; }
                    }
                    if (crlf == NSNotFound) {
                        int n = el_conn_read(&conn, rbuf, sizeof(rbuf));
                        if (n <= 0) { done = YES; break; }
                        [cbuf appendBytes:rbuf length:(NSUInteger)n];
                    }
                }
                if (done) break;

                NSString *szLine = [[[NSString alloc] initWithBytes:[cbuf bytes]
                                                             length:crlf
                                                           encoding:NSASCIIStringEncoding] autorelease];
                unsigned long chunkSize = strtoul([szLine UTF8String], NULL, 16);
                [cbuf replaceBytesInRange:NSMakeRange(0, crlf + 2) withBytes:NULL length:0];

                if (chunkSize == 0) {
                    done = YES;
                    break;
                }

                unsigned long rem = chunkSize;
                while (rem > 0 && !aborted) {
                    if ([cbuf length] > 0) {
                        NSUInteger take = ([cbuf length] < rem) ? [cbuf length] : (NSUInteger)rem;
                        if (callback && !callback((const uint8_t *)[cbuf bytes], take, contentLen, userData)) {
                            aborted = YES;
                            break;
                        }
                        [cbuf replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
                        rem -= take;
                    } else {
                        int n = el_conn_read(&conn, rbuf, (rem < sizeof(rbuf)) ? (size_t)rem : sizeof(rbuf));
                        if (n <= 0) { done = YES; break; }
                        if (callback && !callback(rbuf, (NSUInteger)n, contentLen, userData)) {
                            aborted = YES;
                            break;
                        }
                        rem -= (unsigned long)n;
                    }
                }
                if (done || aborted) break;

                /* Consume trailing \r\n after chunk data */
                while ([cbuf length] < 2) {
                    int n = el_conn_read(&conn, rbuf, sizeof(rbuf));
                    if (n <= 0) { done = YES; break; }
                    [cbuf appendBytes:rbuf length:(NSUInteger)n];
                }
                if ([cbuf length] >= 2) {
                    [cbuf replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
                }
            }
        } else {
            long long received = 0;
            if ([leftover length] > 0) {
                NSUInteger take = [leftover length];
                if (contentLen >= 0 && (long long)take > contentLen) take = (NSUInteger)contentLen;
                if (callback && !callback((const uint8_t *)[leftover bytes], take, contentLen, userData)) {
                    aborted = YES;
                }
                received += take;
            }
            while (!aborted && (contentLen < 0 || received < contentLen)) {
                size_t want = sizeof(rbuf);
                if (contentLen >= 0 && (contentLen - received) < (long long)want) {
                    want = (size_t)(contentLen - received);
                }
                int n = el_conn_read(&conn, rbuf, want);
                if (n <= 0) break;
                if (callback && !callback(rbuf, (NSUInteger)n, contentLen, userData)) {
                    aborted = YES;
                    break;
                }
                received += n;
            }
        }

        el_conn_close(&conn);
        return YES;
    }

    if (outError) *outError = @"Too many HTTP redirects";
    return NO;
}

- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body {
    ELHTTPResponse *resp = [[[ELHTTPResponse alloc] init] autorelease];
    el_buf_ctx_t bctx;
    bctx.buf = [NSMutableData data];

    NSInteger status = 0;
    NSDictionary *respHdrs = nil;
    long long cl = -1;
    NSString *err = nil;

    BOOL ok = [self performRequestMethod:method
                                     url:urlString
                                 headers:headers
                                    body:body
                                callback:el_collect_chunk_cb
                                userData:&bctx
                              statusCode:&status
                         responseHeaders:&respHdrs
                           contentLength:&cl
                                   error:&err];
    resp.statusCode = status;
    resp.headers = respHdrs;
    if (!ok) {
        resp.errorMessage = err ? err : @"Request failed";
        return resp;
    }

    NSString *ce = [[respHdrs objectForKey:@"content-encoding"] lowercaseString];
    if (ce && [ce rangeOfString:@"gzip"].location != NSNotFound) {
        resp.body = el_gunzip_data(bctx.buf);
    } else {
        resp.body = bctx.buf;
    }
    return resp;
}

- (ELHTTPResponse *)getURL:(NSString *)urlString headers:(NSDictionary *)headers {
    return [self requestMethod:@"GET" url:urlString headers:headers body:nil];
}

- (ELHTTPResponse *)postURL:(NSString *)urlString headers:(NSDictionary *)headers body:(NSData *)body {
    return [self requestMethod:@"POST" url:urlString headers:headers body:body];
}

typedef struct {
    ELHTTPStreamCallback innerCb;
    void *innerUserData;
    long long fullTotal;
    uint64_t chunkGot;
    BOOL aborted;
} el_range_wrap_t;

static BOOL el_range_chunk_cb(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_range_wrap_t *w = (el_range_wrap_t *)userData;
    w->chunkGot += length;
    long long reportTotal = (w->fullTotal > 0) ? w->fullTotal : contentLength;
    if (w->innerCb && !w->innerCb(bytes, length, reportTotal, w->innerUserData)) {
        w->aborted = YES;
        return NO;
    }
    return YES;
}

- (BOOL)streamGETURL:(NSString *)urlString
             headers:(NSDictionary *)headers
            callback:(ELHTTPStreamCallback)callback
            userData:(void *)userData
          statusCode:(NSInteger *)outStatus
       contentLength:(long long *)outContentLength
               error:(NSString **)outError {
    return [self performRequestMethod:@"GET"
                                  url:urlString
                              headers:headers
                                 body:nil
                             callback:callback
                             userData:userData
                           statusCode:outStatus
                      responseHeaders:NULL
                        contentLength:outContentLength
                                error:outError];
}

- (BOOL)streamRangeChunksGETURL:(NSString *)urlString
                        headers:(NSDictionary *)headers
                    startOffset:(uint64_t)startOffset
                    totalLength:(long long)totalLength
                      chunkSize:(uint64_t)chunkSize
                       callback:(ELHTTPStreamCallback)callback
                       userData:(void *)userData
                     statusCode:(NSInteger *)outStatus
                          error:(NSString **)outError {
    if (chunkSize < 65536) chunkSize = 524288;
    uint64_t pos = startOffset;
    long long knownTotal = totalLength;
    NSInteger lastStatus = 200;

    while (knownTotal <= 0 || (long long)pos < knownTotal) {
        NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
        uint64_t end = pos + chunkSize - 1;
        if (knownTotal > 0 && (long long)end >= knownTotal) {
            end = (uint64_t)(knownTotal - 1);
        }

        NSMutableDictionary *reqHdrs = [NSMutableDictionary dictionary];
        if (headers) [reqHdrs addEntriesFromDictionary:headers];
        [reqHdrs setObject:[NSString stringWithFormat:@"bytes=%llu-%llu",
                            (unsigned long long)pos, (unsigned long long)end]
                    forKey:@"Range"];

        el_range_wrap_t wrap;
        wrap.innerCb = callback;
        wrap.innerUserData = userData;
        wrap.fullTotal = knownTotal;
        wrap.chunkGot = 0;
        wrap.aborted = NO;

        NSInteger status = 0;
        NSDictionary *respHdrs = nil;
        long long cl = -1;
        NSString *err = nil;

        BOOL ok = [self performRequestMethod:@"GET"
                                         url:urlString
                                     headers:reqHdrs
                                        body:nil
                                    callback:el_range_chunk_cb
                                    userData:&wrap
                                  statusCode:&status
                             responseHeaders:&respHdrs
                               contentLength:&cl
                                       error:&err];
        lastStatus = status;
        if (outStatus) *outStatus = lastStatus;

        if (wrap.aborted) {
            [chunkPool release];
            return YES;
        }
        if (!ok) {
            NSString *retainedErr = [err retain];
            [chunkPool release];
            if (outError) *outError = [retainedErr autorelease];
            else [retainedErr release];
            return NO;
        }
        if (status == 416) {
            /* Reached EOF */
            [chunkPool release];
            if (outStatus) *outStatus = 206;
            return YES;
        }
        if (status != 200 && status != 206) {
            [chunkPool release];
            if (outError) *outError = [NSString stringWithFormat:@"HTTP %ld", (long)status];
            return NO;
        }

        /* Extract exact total length from Content-Range: bytes A-B/TOTAL if unknown */
        if (knownTotal <= 0 && respHdrs) {
            NSString *cr = [respHdrs objectForKey:@"content-range"];
            if (cr) {
                NSRange slash = [cr rangeOfString:@"/"];
                if (slash.location != NSNotFound) {
                    long long tot = [[cr substringFromIndex:slash.location + 1] longLongValue];
                    if (tot > 0) knownTotal = tot;
                }
            } else if (status == 200 && cl > 0) {
                knownTotal = (long long)pos + cl;
            }
        }

        [chunkPool release];
        if (wrap.chunkGot == 0) break;
        pos += wrap.chunkGot;
        if (status == 200) break; /* Server ignored Range and sent full body */
    }

    if (outStatus) *outStatus = lastStatus;
    return YES;
}

@end
