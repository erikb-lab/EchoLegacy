#import "ELHTTPClient.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
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

/* Default 8 MB in-memory response body cap; 16 MB max gunzip output; 50 MB max Range stream */
#define EL_HTTP_DEFAULT_MAX_BODY_BYTES  (8U * 1024U * 1024U)
#define EL_HTTP_HARD_MAX_BODY_BYTES     (32U * 1024U * 1024U)
#define EL_HTTP_MAX_GUNZIP_BYTES        (16U * 1024U * 1024U)
#define EL_HTTP_MAX_CHUNK_LINE_BYTES    256U
#define EL_HTTP_MAX_SINGLE_CHUNK_BYTES  (16UL * 1024UL * 1024UL)
#define EL_HTTP_MAX_RANGE_STREAM_BYTES  (50LL * 1024LL * 1024LL)
#define EL_HTTP_STEADY_RANGE_CHUNK_SIZE (1536ULL * 1024ULL) /* 1.5 MiB steady-state chunk after initial fast chunk */

/* Minimum plausible UTC epoch (2025-02-19 19:33:20 UTC) to detect drifted iPod touch 2G RTC clocks */
#define EL_MIN_VALID_EPOCH              1740000000LL
#define EL_CERT_CLOCK_SKEW_TOLERANCE    300LL

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
    int     used_clock_bootstrap;
    int     saw_cert;
    int64_t max_valid_from;
    int64_t min_valid_to;
} el_tls_vrfy_ctx_t;

typedef struct {
    int                 is_https;
    int                 fd;
    mbedtls_net_context net;
    mbedtls_ssl_context ssl;
    el_tls_vrfy_ctx_t   vrfy_ctx;
} el_conn_t;

/* Shared thread-safe TLS config + pre-seeded DRBG + Root CA chain + synced clock offset */
static pthread_mutex_t          g_tls_init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t          g_tls_rng_lock  = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t          g_tls_sess_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t          g_clock_lock    = PTHREAD_MUTEX_INITIALIZER;
static BOOL                     g_tls_ready     = NO;
static mbedtls_x509_crt         g_ca_chain;
static mbedtls_entropy_context  g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static mbedtls_ssl_config       g_ssl_conf;

static int64_t                  g_clock_offset_sec = 0;
static BOOL                     g_clock_synced     = NO;

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

/* Pure integer UTC civil date to 64-bit Unix epoch seconds (immune to 32-bit time_t & local TZ) */
static int64_t el_utc_to_epoch(int year, int mon, int day, int hour, int min, int sec) {
    if (year < 1970 || year > 9999 || mon < 1 || mon > 12 || day < 1 || day > 31 ||
        hour < 0 || hour > 23 || min < 0 || min > 59 || sec < 0 || sec > 60) {
        return -1;
    }
    int y = year - (mon <= 2 ? 1 : 0);
    int era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned m_adj = (unsigned)(mon + (mon > 2 ? -3 : 9));
    unsigned doy = (153U * m_adj + 2U) / 5U + (unsigned)day - 1U;
    unsigned doe = yoe * 365U + yoe / 4U - yoe / 100U + doy;
    int64_t days = (int64_t)era * 146097LL + (int64_t)doe - 719468LL;
    return days * 86400LL + (int64_t)hour * 3600LL + (int64_t)min * 60LL + (int64_t)sec;
}

static int64_t el_x509_time_to_epoch(const mbedtls_x509_time *t) {
    if (!t) return -1;
    return el_utc_to_epoch(t->year, t->mon, t->day, t->hour, t->min, t->sec);
}

/* Parses RFC 1123 HTTP Date header, e.g. "Thu, 19 Nov 2026 08:02:00 GMT" */
static BOOL el_parse_http_date(NSString *dateStr, int64_t *outEpoch) {
    if (!dateStr || [dateStr length] < 20 || [dateStr length] > 64) return NO;
    const char *s = [dateStr UTF8String];
    if (!s) return NO;

    const char *comma = strchr(s, ',');
    const char *p = comma ? (comma + 1) : s;
    while (*p == ' ') p++;

    int day = 0, year = 0, hour = 0, min = 0, sec = 0;
    char monStr[4] = {0, 0, 0, 0};
    char tzStr[8]  = {0};
    if (sscanf(p, "%d %3s %d %d:%d:%d %7s", &day, monStr, &year, &hour, &min, &sec, tzStr) != 7) {
        return NO;
    }
    if (strcmp(tzStr, "GMT") != 0 && strcmp(tzStr, "UTC") != 0) {
        return NO;
    }

    static const char *const kMonths[12] = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };
    int mon = 0;
    for (int i = 0; i < 12; i++) {
        if (strncasecmp(monStr, kMonths[i], 3) == 0) {
            mon = i + 1;
            break;
        }
    }
    if (mon == 0) return NO;

    int64_t epoch = el_utc_to_epoch(year, mon, day, hour, min, sec);
    if (epoch < EL_MIN_VALID_EPOCH) return NO;
    if (outEpoch) *outEpoch = epoch;
    return YES;
}

static int64_t el_synced_epoch_now(BOOL *outIsSynced) {
    pthread_mutex_lock(&g_clock_lock);
    int64_t offset = g_clock_offset_sec;
    BOOL synced = g_clock_synced;
    pthread_mutex_unlock(&g_clock_lock);

    int64_t sys_now = (int64_t)time(NULL);
    if (outIsSynced) *outIsSynced = (synced || sys_now >= EL_MIN_VALID_EPOCH);
    return sys_now + offset;
}

static void el_update_clock_from_server_epoch(int64_t serverEpoch) {
    if (serverEpoch < EL_MIN_VALID_EPOCH) return;
    int64_t sys_now = (int64_t)time(NULL);
    pthread_mutex_lock(&g_clock_lock);
    g_clock_offset_sec = serverEpoch - sys_now;
    g_clock_synced = YES;
    pthread_mutex_unlock(&g_clock_lock);
}

/*
 * mbedTLS X.509 certificate verification callback.
 * Enforces strict CA trust, signature, key strength, and CN/SAN hostname verification,
 * while evaluating certificate validity timestamps against the synced UTC clock so an
 * iPod touch 2G with a dead/drifted RTC battery verifies certificates accurately.
 */
static int el_tls_verify_cb(void *data, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    (void)depth;
    if (!crt || !flags) return MBEDTLS_ERR_X509_FATAL_ERROR;

    el_tls_vrfy_ctx_t *vctx = (el_tls_vrfy_ctx_t *)data;
    int64_t vfrom = el_x509_time_to_epoch(&crt->valid_from);
    int64_t vto   = el_x509_time_to_epoch(&crt->valid_to);

    /* Reject malformed validity dates or any certificate that expired before 2025-02-19 */
    if (vfrom <= 0 || vto <= 0 || vfrom >= vto || vto < EL_MIN_VALID_EPOCH) {
        *flags |= MBEDTLS_X509_BADCERT_EXPIRED;
        return 0;
    }

    if (vctx) {
        if (!vctx->saw_cert) {
            vctx->max_valid_from = vfrom;
            vctx->min_valid_to   = vto;
            vctx->saw_cert       = 1;
        } else {
            if (vfrom > vctx->max_valid_from) vctx->max_valid_from = vfrom;
            if (vto   < vctx->min_valid_to)   vctx->min_valid_to   = vto;
        }
        if (vctx->max_valid_from >= vctx->min_valid_to) {
            *flags |= MBEDTLS_X509_BADCERT_EXPIRED;
            return 0;
        }
    }

    uint32_t time_mask = (uint32_t)(MBEDTLS_X509_BADCERT_EXPIRED | MBEDTLS_X509_BADCERT_FUTURE);

    /* Never excuse non-time verification failures (CN_MISMATCH, NOT_TRUSTED, REVOKED, BAD_MD/PK/KEY) */
    if ((*flags & ~time_mask) != 0) {
        return 0;
    }

    BOOL clockReady = NO;
    int64_t eff_now = el_synced_epoch_now(&clockReady);
    if (clockReady) {
        if (eff_now >= (vfrom - EL_CERT_CLOCK_SKEW_TOLERANCE) &&
            eff_now <= (vto + EL_CERT_CLOCK_SKEW_TOLERANCE)) {
            *flags &= ~time_mask;
        } else if (eff_now < vfrom) {
            *flags |= MBEDTLS_X509_BADCERT_FUTURE;
        } else {
            *flags |= MBEDTLS_X509_BADCERT_EXPIRED;
        }
        return 0;
    }

    /* Unsynced drifted RTC (< 2025-02-19): allow handshake to complete ONLY so el_read_headers
       can immediately verify the server's Date header against [max_valid_from, min_valid_to]. */
    if (vctx) {
        vctx->used_clock_bootstrap = 1;
        *flags &= ~time_mask;
    }
    return 0;
}

static int el_tls_rng_cb(void *p_rng, unsigned char *output, size_t output_len) {
    (void)p_rng;
    pthread_mutex_lock(&g_tls_rng_lock);
    int ret = mbedtls_ctr_drbg_random(&g_drbg, output, output_len);
    pthread_mutex_unlock(&g_tls_rng_lock);
    return ret;
}

static void el_tls_sessions_clear_all(void) {
    pthread_mutex_lock(&g_tls_sess_lock);
    for (int i = 0; i < EL_TLS_SESSION_CACHE_SLOTS; i++) {
        if (g_tls_sessions[i].valid) {
            mbedtls_ssl_session_free(&g_tls_sessions[i].session);
            g_tls_sessions[i].valid = NO;
        }
    }
    pthread_mutex_unlock(&g_tls_sess_lock);
}

static BOOL el_init_tls_once(NSString **errOut) {
    pthread_mutex_lock(&g_tls_init_lock);
    if (g_tls_ready) {
        pthread_mutex_unlock(&g_tls_init_lock);
        return YES;
    }

    NSString *pemPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (!pemPath || [pemPath length] == 0) {
        if (errOut) *errOut = @"Missing cacert.pem trust store in app bundle";
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    mbedtls_x509_crt_init(&g_ca_chain);
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_drbg);
    mbedtls_ssl_config_init(&g_ssl_conf);

    int ret = mbedtls_x509_crt_parse_file(&g_ca_chain, [pemPath UTF8String]);
    if (ret < 0 || g_ca_chain.raw.len == 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"Failed loading cacert.pem (%d)", ret];
        mbedtls_x509_crt_free(&g_ca_chain);
        mbedtls_ctr_drbg_free(&g_drbg);
        mbedtls_entropy_free(&g_entropy);
        mbedtls_ssl_config_free(&g_ssl_conf);
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    const char *pers = "echo_legacy_tls_v3";
    ret = mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                                (const unsigned char *)pers, strlen(pers));
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"RNG seed failed (%d)", ret];
        mbedtls_x509_crt_free(&g_ca_chain);
        mbedtls_ctr_drbg_free(&g_drbg);
        mbedtls_entropy_free(&g_entropy);
        mbedtls_ssl_config_free(&g_ssl_conf);
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    ret = mbedtls_ssl_config_defaults(&g_ssl_conf,
                                      MBEDTLS_SSL_IS_CLIENT,
                                      MBEDTLS_SSL_TRANSPORT_STREAM,
                                      MBEDTLS_SSL_PRESET_DEFAULT);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"TLS config failed (%d)", ret];
        mbedtls_x509_crt_free(&g_ca_chain);
        mbedtls_ctr_drbg_free(&g_drbg);
        mbedtls_entropy_free(&g_entropy);
        mbedtls_ssl_config_free(&g_ssl_conf);
        pthread_mutex_unlock(&g_tls_init_lock);
        return NO;
    }

    mbedtls_ssl_conf_authmode(&g_ssl_conf, MBEDTLS_SSL_VERIFY_REQUIRED);
    mbedtls_ssl_conf_ca_chain(&g_ssl_conf, &g_ca_chain, NULL);
    mbedtls_ssl_conf_verify(&g_ssl_conf, el_tls_verify_cb, NULL);
    mbedtls_ssl_conf_rng(&g_ssl_conf, el_tls_rng_cb, NULL);

    g_tls_ready = YES;
    pthread_mutex_unlock(&g_tls_init_lock);
    return YES;
}

static BOOL el_tls_session_apply(mbedtls_ssl_context *ssl, const char *host, const char *port) {
    BOOL clockReady = NO;
    (void)el_synced_epoch_now(&clockReady);
    if (!clockReady) return NO;

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
    if (!ssl || mbedtls_ssl_get_verify_result(ssl) != 0) return;

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

/* Host & URL Validation (Flaws #5, #15, #16, #17) */
static BOOL el_has_forbidden_url_chars(NSString *s) {
    if (!s) return YES;
    NSUInteger len = [s length];
    if (len == 0 || len > 4096) return YES;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c <= 0x20 || c >= 0x7F) return YES;
    }
    return NO;
}

static BOOL el_has_forbidden_header_chars(NSString *s, BOOL isKey) {
    if (!s) return YES;
    NSUInteger len = [s length];
    if (len == 0 || len > (isKey ? 128U : 8192U)) return YES;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\r' || c == '\n' || c == '\0' || c >= 0x7F) return YES;
        if (isKey) {
            if (c <= 0x20 || c == ':') return YES;
        } else {
            if (c < 0x20 && c != '\t') return YES;
        }
    }
    return NO;
}

static BOOL el_is_valid_dns_hostname(NSString *host) {
    NSUInteger len = [host length];
    if (len < 4 || len > 253) return NO;
    if ([host hasPrefix:@"."] || [host hasSuffix:@"."] ||
        [host hasPrefix:@"-"] || [host hasSuffix:@"-"] ||
        [host rangeOfString:@".."].location != NSNotFound) {
        return NO;
    }
    if ([host isEqualToString:@"localhost"] ||
        [host hasSuffix:@".localhost"] ||
        [host hasSuffix:@".local"]) {
        return NO;
    }

    BOOL allDigitsAndDots = YES;
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [host characterAtIndex:i];
        BOOL isLower = (c >= 'a' && c <= 'z');
        BOOL isDigit = (c >= '0' && c <= '9');
        if (!isLower && !isDigit && c != '.' && c != '-') {
            return NO;
        }
        if (!isDigit && c != '.') {
            allDigitsAndDots = NO;
        }
    }
    /* Reject raw IPv4 literals */
    if (allDigitsAndDots) return NO;
    return YES;
}

static ELHostCategory el_category_for_host(NSString *host) {
    if (!el_is_valid_dns_hostname(host)) return (ELHostCategory)-1;

    /* 1. YouTube Music & Innertube API */
    if ([host isEqualToString:@"music.youtube.com"] ||
        [host isEqualToString:@"www.youtube.com"] ||
        [host isEqualToString:@"youtube.com"] ||
        [host isEqualToString:@"m.youtube.com"] ||
        [host isEqualToString:@"youtubei.googleapis.com"]) {
        return ELHostCategoryYouTubeAPI;
    }

    /* 2. Google OAuth 2.0 & Account Profile */
    if ([host isEqualToString:@"oauth2.googleapis.com"] ||
        [host isEqualToString:@"www.googleapis.com"] ||
        [host isEqualToString:@"accounts.google.com"] ||
        [host isEqualToString:@"www.google.com"] ||
        [host isEqualToString:@"google.com"]) {
        return ELHostCategoryGoogleAuth;
    }

    /* 3. YouTube Media Audio Streams (*.googlevideo.com) */
    if ([host hasSuffix:@".googlevideo.com"] && [host length] > 16) {
        return ELHostCategoryMediaStream;
    }

    /* 4. Album Art & Avatars */
    if ([host isEqualToString:@"i.ytimg.com"] ||
        ([host hasSuffix:@".ytimg.com"] && [host length] > 10) ||
        [host isEqualToString:@"lh3.googleusercontent.com"] ||
        ([host hasSuffix:@".googleusercontent.com"] && [host length] > 22) ||
        ([host hasSuffix:@".ggpht.com"] && [host length] > 10)) {
        return ELHostCategoryThumbnail;
    }

    /* 5. GitHub Self-Updater */
    if ([host isEqualToString:@"api.github.com"] ||
        [host isEqualToString:@"github.com"] ||
        [host isEqualToString:@"objects.githubusercontent.com"] ||
        [host isEqualToString:@"release-assets.githubusercontent.com"] ||
        [host isEqualToString:@"raw.githubusercontent.com"] ||
        [host isEqualToString:@"codeload.github.com"]) {
        return ELHostCategoryGitHubUpdate;
    }

    /* 6. LRCLIB Lyrics */
    if ([host isEqualToString:@"lrclib.net"]) {
        return ELHostCategoryLyrics;
    }

    return (ELHostCategory)-1;
}

BOOL ELValidateHTTPSURL(NSString *urlString,
                        ELHostCategory category,
                        NSString **outHost,
                        NSString **outPort,
                        NSString **outPathAndQuery) {
    if (el_has_forbidden_url_chars(urlString)) return NO;

    NSRange schemeRange = [urlString rangeOfString:@"://"];
    if (schemeRange.location == NSNotFound) return NO;

    NSString *scheme = [[urlString substringToIndex:schemeRange.location] lowercaseString];
    if (![scheme isEqualToString:@"https"]) return NO;

    NSString *rest = [urlString substringFromIndex:schemeRange.location + 3];
    if ([rest length] == 0) return NO;

    /* Reject fragments or backslashes or userinfo before authority split */
    if ([rest rangeOfString:@"#"].location != NSNotFound ||
        [rest rangeOfString:@"\\"].location != NSNotFound) {
        return NO;
    }

    NSRange slashRange = [rest rangeOfString:@"/"];
    NSRange queryRange = [rest rangeOfString:@"?"];
    NSString *authority = nil;
    NSString *pq = nil;

    if (slashRange.location == NSNotFound && queryRange.location == NSNotFound) {
        authority = rest;
        pq = @"/";
    } else if (slashRange.location != NSNotFound &&
               (queryRange.location == NSNotFound || slashRange.location < queryRange.location)) {
        authority = [rest substringToIndex:slashRange.location];
        pq = [rest substringFromIndex:slashRange.location];
    } else {
        authority = [rest substringToIndex:queryRange.location];
        pq = [@"/" stringByAppendingString:[rest substringFromIndex:queryRange.location]];
    }

    if ([authority length] == 0 ||
        [authority rangeOfString:@"@"].location != NSNotFound ||
        [authority rangeOfString:@"["].location != NSNotFound ||
        [authority rangeOfString:@"]"].location != NSNotFound) {
        return NO;
    }

    NSString *rawHost = nil;
    NSString *port = @"443";
    NSRange colonRange = [authority rangeOfString:@":"];
    if (colonRange.location != NSNotFound) {
        rawHost = [authority substringToIndex:colonRange.location];
        port = [authority substringFromIndex:colonRange.location + 1];
        if (![port isEqualToString:@"443"]) return NO;
    } else {
        rawHost = authority;
    }

    NSString *host = [rawHost lowercaseString];
    ELHostCategory hostCat = el_category_for_host(host);
    if ((int)hostCat <= 0) return NO;
    if (category != ELHostCategoryAnyAllowlisted && hostCat != category) return NO;

    if (outHost) *outHost = host;
    if (outPort) *outPort = port;
    if (outPathAndQuery) *outPathAndQuery = pq;
    return YES;
}

static BOOL el_is_public_ipv4(uint32_t ip_host_order) {
    if ((ip_host_order & 0xFF000000U) == 0x00000000U) return NO; /* 0.0.0.0/8 */
    if ((ip_host_order & 0xFF000000U) == 0x0A000000U) return NO; /* 10.0.0.0/8 */
    if ((ip_host_order & 0xFFC00000U) == 0x64400000U) return NO; /* 100.64.0.0/10 */
    if ((ip_host_order & 0xFF000000U) == 0x7F000000U) return NO; /* 127.0.0.0/8 */
    if ((ip_host_order & 0xFFFF0000U) == 0xA9FE0000U) return NO; /* 169.254.0.0/16 */
    if ((ip_host_order & 0xFFF00000U) == 0xAC100000U) return NO; /* 172.16.0.0/12 */
    if ((ip_host_order & 0xFFFFFF00U) == 0xC0000000U) return NO; /* 192.0.0.0/24 */
    if ((ip_host_order & 0xFFFFFF00U) == 0xC0000200U) return NO; /* 192.0.2.0/24 */
    if ((ip_host_order & 0xFFFF0000U) == 0xC0A80000U) return NO; /* 192.168.0.0/16 */
    if ((ip_host_order & 0xFFFE0000U) == 0xC6120000U) return NO; /* 198.18.0.0/15 */
    if ((ip_host_order & 0xE0000000U) == 0xE0000000U) return NO; /* 224.0.0.0/3 multicast/reserved */
    return YES;
}

static BOOL el_is_public_sockaddr(const struct sockaddr *sa) {
    if (!sa) return NO;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        uint32_t ip = ntohl(sin->sin_addr.s_addr);
        return el_is_public_ipv4(ip);
    } else if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        const uint8_t *b = sin6->sin6_addr.s6_addr;
        BOOL first10Zero = YES;
        for (int i = 0; i < 10; i++) {
            if (b[i] != 0) { first10Zero = NO; break; }
        }
        BOOL first15Zero = first10Zero && (b[10] == 0 && b[11] == 0 && b[12] == 0 && b[13] == 0 && b[14] == 0);
        if (first15Zero && (b[15] == 0 || b[15] == 1)) return NO; /* :: or ::1 */
        if (first10Zero && b[10] == 0xFF && b[11] == 0xFF) {
            uint32_t v4 = ((uint32_t)b[12] << 24) | ((uint32_t)b[13] << 16) |
                          ((uint32_t)b[14] << 8)  | (uint32_t)b[15];
            return el_is_public_ipv4(v4);
        }
        if ((b[0] & 0xFE) == 0xFC) return NO; /* fc00::/7 unique local */
        if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) return NO; /* fe80::/10 link-local */
        if (b[0] == 0xFF) return NO; /* ff00::/8 multicast */
        return YES;
    }
    return NO;
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

static int el_connect_validated_tcp(const char *host, const char *port, NSString **errOut) {
    struct addrinfo hints, *res = NULL, *p = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) {
        if (errOut) *errOut = [NSString stringWithFormat:@"DNS lookup failed for %s", host];
        return -1;
    }

    int fd = -1;
    BOOL blockedPrivate = NO;
    for (p = res; p; p = p->ai_next) {
        if (!el_is_public_sockaddr(p->ai_addr)) {
            blockedPrivate = YES;
            continue;
        }
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) continue;
        el_set_socket_opts(fd, 20);
        if (connect(fd, p->ai_addr, p->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) {
        if (errOut) {
            *errOut = blockedPrivate
                ? [NSString stringWithFormat:@"Blocked private/non-public IP address for %s", host]
                : [NSString stringWithFormat:@"TCP connect failed to %s:%s", host, port];
        }
        return -1;
    }
    return fd;
}

static int el_conn_open(el_conn_t *c, const char *host, const char *port, int is_https, NSString **errOut) {
    memset(c, 0, sizeof(*c));
    c->is_https = is_https;
    c->fd = -1;

    if (!is_https) {
        if (errOut) *errOut = @"Plaintext HTTP connections are disabled";
        return -1;
    }

    if (!el_init_tls_once(errOut)) {
        return -1;
    }

    mbedtls_net_init(&c->net);
    mbedtls_ssl_init(&c->ssl);

    int tcp_fd = el_connect_validated_tcp(host, port, errOut);
    if (tcp_fd < 0) {
        el_conn_close(c);
        return -1;
    }
    c->net.fd = tcp_fd;

    int ret = mbedtls_ssl_setup(&c->ssl, &g_ssl_conf);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"TLS setup failed (%d)", ret];
        el_conn_close(c);
        return -1;
    }

    mbedtls_ssl_set_verify(&c->ssl, el_tls_verify_cb, &c->vrfy_ctx);

    ret = mbedtls_ssl_set_hostname(&c->ssl, host);
    if (ret != 0) {
        if (errOut) *errOut = [NSString stringWithFormat:@"SNI failed (%d)", ret];
        el_conn_close(c);
        return -1;
    }

    /* Attempt 1-RTT TLS 1.2 session ticket/ID resumption if cached and clock is already synced */
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

    uint32_t verifyFlags = mbedtls_ssl_get_verify_result(&c->ssl);
    if (verifyFlags != 0) {
        el_tls_session_evict(host, port);
        if (errOut) *errOut = [NSString stringWithFormat:@"TLS certificate verification failed (0x%08x)", (unsigned int)verifyFlags];
        el_conn_close(c);
        return -1;
    }

    /* Never cache TLS sessions from a clock-bootstrap handshake (Flaw #12) */
    if (!c->vrfy_ctx.used_clock_bootstrap) {
        el_tls_session_save(&c->ssl, host, port);
    }
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

static NSData *el_gunzip_data(NSData *compressed, NSUInteger maxOutputBytes, BOOL *outFailed) {
    if (outFailed) *outFailed = NO;
    if (!compressed || [compressed length] == 0) return compressed;
    if (maxOutputBytes == 0 || maxOutputBytes > EL_HTTP_MAX_GUNZIP_BYTES) {
        maxOutputBytes = EL_HTTP_MAX_GUNZIP_BYTES;
    }

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, 16 + MAX_WBITS) != Z_OK) {
        if (outFailed) *outFailed = YES;
        return nil;
    }

    zs.next_in = (Bytef *)[compressed bytes];
    zs.avail_in = (uInt)[compressed length];

    NSUInteger initCap = [compressed length] * 2;
    if (initCap > maxOutputBytes) initCap = maxOutputBytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:initCap];
    uint8_t chunk[16384];
    int status = Z_OK;
    while (status == Z_OK) {
        zs.next_out = chunk;
        zs.avail_out = sizeof(chunk);
        status = inflate(&zs, Z_NO_FLUSH);
        size_t have = sizeof(chunk) - zs.avail_out;
        if (have > 0) {
            if ([out length] + have > maxOutputBytes) {
                inflateEnd(&zs);
                if (outFailed) *outFailed = YES;
                return nil;
            }
            [out appendBytes:chunk length:have];
        }
    }
    inflateEnd(&zs);
    if (status != Z_STREAM_END) {
        if (outFailed) *outFailed = YES;
        return nil;
    }
    return out;
}

static BOOL el_read_headers(el_conn_t *c,
                            const char *host,
                            const char *port,
                            NSInteger *statusCode,
                            NSMutableDictionary *headers,
                            NSMutableData *leftover,
                            NSString **errOut) {
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

    /* Validate & sync UTC clock from verified HTTPS Date header (Flaw #2) */
    if (c->is_https) {
        int64_t serverEpoch = 0;
        BOOL hasValidDate = el_parse_http_date([headers objectForKey:@"date"], &serverEpoch);
        if (c->vrfy_ctx.used_clock_bootstrap) {
            if (!hasValidDate || !c->vrfy_ctx.saw_cert ||
                serverEpoch < (c->vrfy_ctx.max_valid_from - EL_CERT_CLOCK_SKEW_TOLERANCE) ||
                serverEpoch > (c->vrfy_ctx.min_valid_to + EL_CERT_CLOCK_SKEW_TOLERANCE)) {
                el_tls_session_evict(host, port);
                if (errOut) *errOut = @"TLS certificate validity check failed against server Date header";
                return NO;
            }
            el_update_clock_from_server_epoch(serverEpoch);
            el_tls_session_save(&c->ssl, host, port);
        } else if (hasValidDate) {
            BOOL alreadySynced = NO;
            (void)el_synced_epoch_now(&alreadySynced);
            if (!alreadySynced) {
                el_update_clock_from_server_epoch(serverEpoch);
            }
        }
    }

    if ([buf length] > headerEnd) {
        [leftover appendBytes:((const uint8_t *)[buf bytes]) + headerEnd
                       length:[buf length] - headerEnd];
    }
    return YES;
}

typedef struct {
    NSMutableData *buf;
    NSUInteger     maxBytes;
    BOOL           exceeded;
} el_buf_ctx_t;

static BOOL el_collect_chunk_cb(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_buf_ctx_t *bctx = (el_buf_ctx_t *)userData;
    if (!bctx) return NO;
    if (contentLength > 0 && (uint64_t)contentLength > (uint64_t)bctx->maxBytes) {
        bctx->exceeded = YES;
        return NO;
    }
    if ([bctx->buf length] + length > bctx->maxBytes) {
        bctx->exceeded = YES;
        return NO;
    }
    [bctx->buf appendBytes:bytes length:length];
    return YES;
}

typedef struct {
    FILE      *fp;
    uint64_t   maxBytes;
    uint64_t   writtenBytes;
    BOOL       writeError;
    BOOL       exceeded;
} el_file_dl_ctx_t;

static BOOL el_file_dl_chunk_cb(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_file_dl_ctx_t *fctx = (el_file_dl_ctx_t *)userData;
    if (!fctx || !fctx->fp) return NO;
    if (contentLength > 0 && (uint64_t)contentLength > fctx->maxBytes) {
        fctx->exceeded = YES;
        return NO;
    }
    if (fctx->writtenBytes + (uint64_t)length > fctx->maxBytes) {
        fctx->exceeded = YES;
        return NO;
    }
    if (length > 0 && fwrite(bytes, 1, length, fctx->fp) != length) {
        fctx->writeError = YES;
        return NO;
    }
    fctx->writtenBytes += (uint64_t)length;
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

+ (BOOL)validateCACertFile:(NSString *)pemPath {
    if (!pemPath || [pemPath length] == 0) return NO;
    mbedtls_x509_crt tmpChain;
    mbedtls_x509_crt_init(&tmpChain);
    int ret = mbedtls_x509_crt_parse_file(&tmpChain, [pemPath UTF8String]);
    /* ret == 0 means every certificate in the file parsed without error */
    BOOL valid = (ret == 0 && tmpChain.raw.len > 0);
    mbedtls_x509_crt_free(&tmpChain);
    return valid;
}

+ (BOOL)reloadTrustStore {
    NSString *pemPath = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
    if (![self validateCACertFile:pemPath]) return NO;

    pthread_mutex_lock(&g_tls_init_lock);
    if (g_tls_ready) {
        mbedtls_x509_crt newChain;
        mbedtls_x509_crt_init(&newChain);
        int ret = mbedtls_x509_crt_parse_file(&newChain, [pemPath UTF8String]);
        if (ret != 0 || newChain.raw.len == 0) {
            mbedtls_x509_crt_free(&newChain);
            pthread_mutex_unlock(&g_tls_init_lock);
            return NO;
        }
        mbedtls_x509_crt_free(&g_ca_chain);
        g_ca_chain = newChain;
        mbedtls_ssl_conf_ca_chain(&g_ssl_conf, &g_ca_chain, NULL);
    }
    pthread_mutex_unlock(&g_tls_init_lock);
    el_tls_sessions_clear_all();
    return YES;
}

+ (NSTimeInterval)syncedCurrentTime {
    return (NSTimeInterval)el_synced_epoch_now(NULL);
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
    if (!method || (![method isEqualToString:@"GET"] &&
                    ![method isEqualToString:@"POST"] &&
                    ![method isEqualToString:@"HEAD"])) {
        if (outError) *outError = @"Invalid HTTP method";
        return NO;
    }

    NSString *currentURL = urlString;
    NSString *currentMethod = method;
    NSData *currentBody = body;
    NSMutableDictionary *curHeaders = [NSMutableDictionary dictionary];
    if (headers) {
        for (id keyObj in headers) {
            if (![keyObj isKindOfClass:[NSString class]]) {
                if (outError) *outError = @"Invalid HTTP header key";
                return NO;
            }
            id valObj = [headers objectForKey:keyObj];
            if (![valObj isKindOfClass:[NSString class]]) {
                if (outError) *outError = @"Invalid HTTP header value";
                return NO;
            }
            NSString *kStr = (NSString *)keyObj;
            NSString *vStr = (NSString *)valObj;
            if (el_has_forbidden_header_chars(kStr, YES) ||
                el_has_forbidden_header_chars(vStr, NO)) {
                if (outError) *outError = @"Forbidden control characters in HTTP header";
                return NO;
            }
            [curHeaders setObject:vStr forKey:kStr];
        }
    }

    ELHostCategory initialCategory = ELHostCategoryAnyAllowlisted;

    for (int hop = 0; hop < 6; hop++) {
        NSString *host = nil, *port = nil, *pq = nil;
        if (!ELValidateHTTPSURL(currentURL, initialCategory, &host, &port, &pq)) {
            if (outError) {
                *outError = (hop > 0)
                    ? @"Blocked untrusted or non-HTTPS redirect target"
                    : @"Blocked untrusted or invalid HTTPS URL";
            }
            return NO;
        }
        if (hop == 0) {
            initialCategory = el_category_for_host(host);
        }

        el_conn_t conn;
        NSString *openErr = nil;
        if (el_conn_open(&conn, [host UTF8String], [port UTF8String], 1, &openErr) != 0) {
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
        if (!el_read_headers(&conn, [host UTF8String], [port UTF8String], &status, respHeaders, leftover, &hdrErr)) {
            el_conn_close(&conn);
            if (outError) *outError = hdrErr;
            return NO;
        }

        /* Handle redirects (Flaws #5 & #16) */
        if ((status == 301 || status == 302 || status == 303 || status == 307 || status == 308) &&
            [respHeaders objectForKey:@"location"]) {
            NSString *loc = [respHeaders objectForKey:@"location"];
            el_conn_close(&conn);

            /* Disallow redirects on OAuth token/code/revoke POST requests */
            if (initialCategory == ELHostCategoryGoogleAuth && [currentMethod isEqualToString:@"POST"]) {
                if (outError) *outError = @"Blocked unexpected redirect on OAuth POST endpoint";
                return NO;
            }

            if ([loc hasPrefix:@"/"]) {
                loc = [NSString stringWithFormat:@"https://%@%@", host, loc];
            }

            NSString *nextHost = nil, *nextPort = nil, *nextPQ = nil;
            if (!ELValidateHTTPSURL(loc, initialCategory, &nextHost, &nextPort, &nextPQ)) {
                if (outError) *outError = @"Blocked insecure or cross-category HTTP redirect";
                return NO;
            }

            BOOL crossOrigin = (![nextHost isEqualToString:host] || ![nextPort isEqualToString:port]);
            if (crossOrigin) {
                /* Strip sensitive headers across hosts */
                NSMutableArray *toRemove = [NSMutableArray array];
                for (NSString *k in curHeaders) {
                    NSString *lk = [k lowercaseString];
                    if ([lk isEqualToString:@"authorization"] ||
                        [lk isEqualToString:@"cookie"] ||
                        [lk isEqualToString:@"x-goog-visitor-id"] ||
                        [lk isEqualToString:@"x-goog-request-time"] ||
                        [lk isEqualToString:@"origin"] ||
                        [lk isEqualToString:@"referer"]) {
                        [toRemove addObject:k];
                    }
                }
                for (NSString *k in toRemove) [curHeaders removeObjectForKey:k];
            }

            if (status == 301 || status == 302 || status == 303 || crossOrigin) {
                if ([currentMethod isEqualToString:@"POST"]) {
                    currentMethod = @"GET";
                }
                currentBody = nil;
                NSMutableArray *bodyHdrs = [NSMutableArray array];
                for (NSString *k in curHeaders) {
                    NSString *lk = [k lowercaseString];
                    if ([lk isEqualToString:@"content-type"] || [lk isEqualToString:@"content-length"]) {
                        [bodyHdrs addObject:k];
                    }
                }
                for (NSString *k in bodyHdrs) [curHeaders removeObjectForKey:k];
            }

            currentURL = loc;
            continue;
        }

        if (outStatus) *outStatus = status;
        if (outHeaders) *outHeaders = [[respHeaders copy] autorelease];

        long long contentLen = -1;
        NSString *clStr = [respHeaders objectForKey:@"content-length"];
        if (clStr) {
            contentLen = [clStr longLongValue];
            if (contentLen < 0) {
                el_conn_close(&conn);
                if (outError) *outError = @"Invalid negative Content-Length";
                return NO;
            }
        }
        if (outContentLength) *outContentLength = contentLen;

        NSString *te = [[respHeaders objectForKey:@"transfer-encoding"] lowercaseString];
        BOOL isChunked = (te && [te rangeOfString:@"chunked"].location != NSNotFound);

        BOOL aborted = NO;
        BOOL transferError = NO;
        NSString *transferErrMsg = nil;
        uint8_t rbuf[16384];

        if (isChunked) {
            NSMutableData *cbuf = [NSMutableData dataWithData:leftover];
            BOOL done = NO;
            while (!done && !aborted && !transferError) {
                /* Ensure we have a chunk size line (\r\n) within 256 bytes (Flaw #10) */
                NSUInteger crlf = NSNotFound;
                while (crlf == NSNotFound) {
                    const char *p = (const char *)[cbuf bytes];
                    NSUInteger cl = [cbuf length];
                    for (NSUInteger i = 0; i + 1 < cl; i++) {
                        if (p[i] == '\r' && p[i+1] == '\n') { crlf = i; break; }
                    }
                    if (crlf == NSNotFound) {
                        if (cl > EL_HTTP_MAX_CHUNK_LINE_BYTES) {
                            transferError = YES;
                            transferErrMsg = @"HTTP chunk header line too long";
                            break;
                        }
                        int n = el_conn_read(&conn, rbuf, sizeof(rbuf));
                        if (n <= 0) {
                            transferError = YES;
                            transferErrMsg = @"Truncated chunked HTTP response";
                            break;
                        }
                        [cbuf appendBytes:rbuf length:(NSUInteger)n];
                    }
                }
                if (transferError) break;

                if (crlf == 0 || crlf > EL_HTTP_MAX_CHUNK_LINE_BYTES) {
                    transferError = YES;
                    transferErrMsg = @"Malformed HTTP chunk size line";
                    break;
                }

                NSString *szLine = [[[NSString alloc] initWithBytes:[cbuf bytes]
                                                             length:crlf
                                                           encoding:NSASCIIStringEncoding] autorelease];
                const char *szCStr = [szLine UTF8String];
                if (!szCStr || !isxdigit((unsigned char)szCStr[0])) {
                    transferError = YES;
                    transferErrMsg = @"Invalid HTTP chunk size";
                    break;
                }
                char *endPtr = NULL;
                unsigned long chunkSize = strtoul(szCStr, &endPtr, 16);
                if (endPtr == szCStr || chunkSize > EL_HTTP_MAX_SINGLE_CHUNK_BYTES) {
                    transferError = YES;
                    transferErrMsg = @"HTTP chunk size exceeds maximum";
                    break;
                }
                [cbuf replaceBytesInRange:NSMakeRange(0, crlf + 2) withBytes:NULL length:0];

                if (chunkSize == 0) {
                    done = YES;
                    break;
                }

                unsigned long rem = chunkSize;
                while (rem > 0 && !aborted && !transferError) {
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
                        if (n <= 0) {
                            transferError = YES;
                            transferErrMsg = @"Truncated HTTP chunk payload";
                            break;
                        }
                        if (callback && !callback(rbuf, (NSUInteger)n, contentLen, userData)) {
                            aborted = YES;
                            break;
                        }
                        rem -= (unsigned long)n;
                    }
                }
                if (aborted || transferError) break;

                /* Consume trailing \r\n after chunk data */
                while ([cbuf length] < 2) {
                    int n = el_conn_read(&conn, rbuf, sizeof(rbuf));
                    if (n <= 0) {
                        transferError = YES;
                        transferErrMsg = @"Truncated HTTP chunk delimiter";
                        break;
                    }
                    [cbuf appendBytes:rbuf length:(NSUInteger)n];
                }
                if (transferError) break;
                const uint8_t *delim = (const uint8_t *)[cbuf bytes];
                if (delim[0] != '\r' || delim[1] != '\n') {
                    transferError = YES;
                    transferErrMsg = @"Malformed HTTP chunk delimiter";
                    break;
                }
                [cbuf replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
            }
            if (!aborted && !transferError && !done) {
                transferError = YES;
                transferErrMsg = @"Truncated chunked HTTP response";
            }
        } else {
            long long received = 0;
            if ([leftover length] > 0) {
                NSUInteger take = [leftover length];
                if (contentLen >= 0 && (long long)take > contentLen) take = (NSUInteger)contentLen;
                if (callback && !callback((const uint8_t *)[leftover bytes], take, contentLen, userData)) {
                    aborted = YES;
                }
                received += (long long)take;
            }
            while (!aborted && (contentLen < 0 || received < contentLen)) {
                size_t want = sizeof(rbuf);
                if (contentLen >= 0 && (contentLen - received) < (long long)want) {
                    want = (size_t)(contentLen - received);
                }
                int n = el_conn_read(&conn, rbuf, want);
                if (n < 0) {
                    transferError = YES;
                    transferErrMsg = @"Socket read error during HTTP response";
                    break;
                }
                if (n == 0) break;
                if (callback && !callback(rbuf, (NSUInteger)n, contentLen, userData)) {
                    aborted = YES;
                    break;
                }
                received += (long long)n;
            }
            /* Flaw #11: Verify exact Content-Length match on connection close */
            if (!aborted && !transferError && contentLen >= 0 && received != contentLen) {
                transferError = YES;
                transferErrMsg = [NSString stringWithFormat:@"Truncated HTTP response (%lld of %lld bytes)",
                                  received, contentLen];
            }
        }

        el_conn_close(&conn);
        if (transferError) {
            if (outError) *outError = transferErrMsg ? transferErrMsg : @"HTTP transfer failed";
            return NO;
        }
        return YES;
    }

    if (outError) *outError = @"Too many HTTP redirects";
    return NO;
}

- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body
                         maxBytes:(NSUInteger)maxBytes {
    if (maxBytes == 0) maxBytes = EL_HTTP_DEFAULT_MAX_BODY_BYTES;
    if (maxBytes > EL_HTTP_HARD_MAX_BODY_BYTES) maxBytes = EL_HTTP_HARD_MAX_BODY_BYTES;

    ELHTTPResponse *resp = [[[ELHTTPResponse alloc] init] autorelease];
    el_buf_ctx_t bctx;
    bctx.buf = [NSMutableData data];
    bctx.maxBytes = maxBytes;
    bctx.exceeded = NO;

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
    if (bctx.exceeded) {
        resp.errorMessage = @"HTTP response body exceeds maximum allowed size";
        return resp;
    }
    if (!ok) {
        resp.errorMessage = err ? err : @"Request failed";
        return resp;
    }

    NSString *ce = [[respHdrs objectForKey:@"content-encoding"] lowercaseString];
    if (ce && [ce rangeOfString:@"gzip"].location != NSNotFound) {
        BOOL gunzipFailed = NO;
        NSUInteger gunzipCap = (maxBytes > EL_HTTP_MAX_GUNZIP_BYTES) ? maxBytes : EL_HTTP_MAX_GUNZIP_BYTES;
        NSData *decompressed = el_gunzip_data(bctx.buf, gunzipCap, &gunzipFailed);
        if (gunzipFailed || !decompressed) {
            resp.errorMessage = @"Invalid or oversized gzip response body";
            resp.body = nil;
            return resp;
        }
        resp.body = decompressed;
    } else {
        resp.body = bctx.buf;
    }
    return resp;
}

- (ELHTTPResponse *)requestMethod:(NSString *)method
                              url:(NSString *)urlString
                          headers:(NSDictionary *)headers
                             body:(NSData *)body {
    return [self requestMethod:method
                           url:urlString
                       headers:headers
                          body:body
                      maxBytes:EL_HTTP_DEFAULT_MAX_BODY_BYTES];
}

- (ELHTTPResponse *)getURL:(NSString *)urlString headers:(NSDictionary *)headers {
    return [self requestMethod:@"GET"
                           url:urlString
                       headers:headers
                          body:nil
                      maxBytes:EL_HTTP_DEFAULT_MAX_BODY_BYTES];
}

- (ELHTTPResponse *)getURL:(NSString *)urlString
                   headers:(NSDictionary *)headers
                  maxBytes:(NSUInteger)maxBytes {
    return [self requestMethod:@"GET"
                           url:urlString
                       headers:headers
                          body:nil
                      maxBytes:maxBytes];
}

- (ELHTTPResponse *)postURL:(NSString *)urlString headers:(NSDictionary *)headers body:(NSData *)body {
    return [self requestMethod:@"POST"
                           url:urlString
                       headers:headers
                          body:body
                      maxBytes:EL_HTTP_DEFAULT_MAX_BODY_BYTES];
}

- (BOOL)downloadURL:(NSString *)urlString
            headers:(NSDictionary *)headers
             toFile:(NSString *)destPath
           maxBytes:(uint64_t)maxBytes
      expectedBytes:(long long)expectedBytes
              error:(NSString **)outError {
    if (!destPath || [destPath length] == 0) {
        if (outError) *outError = @"Missing destination path";
        return NO;
    }
    if (maxBytes == 0) maxBytes = EL_HTTP_HARD_MAX_BODY_BYTES;
    if (expectedBytes > 0 && (uint64_t)expectedBytes > maxBytes) {
        if (outError) *outError = @"Expected download size exceeds maximum allowed size";
        return NO;
    }

    NSString *partPath = [destPath stringByAppendingString:@".part"];
    unlink([partPath UTF8String]);
    FILE *fp = fopen([partPath UTF8String], "wb");
    if (!fp) {
        if (outError) *outError = @"Could not open temporary file for download";
        return NO;
    }
    chmod([partPath UTF8String], 0600);

    el_file_dl_ctx_t fctx;
    memset(&fctx, 0, sizeof(fctx));
    fctx.fp = fp;
    fctx.maxBytes = maxBytes;

    NSInteger status = 0;
    long long contentLen = -1;
    NSString *err = nil;
    BOOL ok = [self performRequestMethod:@"GET"
                                     url:urlString
                                 headers:headers
                                    body:nil
                                callback:el_file_dl_chunk_cb
                                userData:&fctx
                              statusCode:&status
                         responseHeaders:NULL
                           contentLength:&contentLen
                                   error:&err];
    if (fflush(fp) != 0) fctx.writeError = YES;
    fclose(fp);

    if (fctx.exceeded) {
        unlink([partPath UTF8String]);
        if (outError) *outError = @"Download exceeds maximum allowed file size";
        return NO;
    }
    if (fctx.writeError) {
        unlink([partPath UTF8String]);
        if (outError) *outError = @"Disk write error while downloading file";
        return NO;
    }
    if (!ok) {
        unlink([partPath UTF8String]);
        if (outError) *outError = err ? err : @"Download failed";
        return NO;
    }
    if (status < 200 || status >= 300) {
        unlink([partPath UTF8String]);
        if (outError) *outError = [NSString stringWithFormat:@"Download HTTP %ld", (long)status];
        return NO;
    }
    if (fctx.writtenBytes == 0 ||
        (contentLen >= 0 && fctx.writtenBytes != (uint64_t)contentLen) ||
        (expectedBytes > 0 && fctx.writtenBytes != (uint64_t)expectedBytes)) {
        unlink([partPath UTF8String]);
        if (outError) *outError = @"Downloaded file size mismatch (truncated download)";
        return NO;
    }

    if (rename([partPath UTF8String], [destPath UTF8String]) != 0) {
        unlink([partPath UTF8String]);
        if (outError) *outError = @"Failed moving downloaded file into place";
        return NO;
    }
    return YES;
}

typedef struct {
    ELHTTPStreamCallback innerCb;
    void *innerUserData;
    long long fullTotal;
    uint64_t chunkGot;
    uint64_t totalBeforeChunk;
    BOOL aborted;
    BOOL exceededCap;
} el_range_wrap_t;

static BOOL el_range_chunk_cb(const uint8_t *bytes, NSUInteger length, long long contentLength, void *userData) {
    el_range_wrap_t *w = (el_range_wrap_t *)userData;
    if (w->totalBeforeChunk + w->chunkGot + (uint64_t)length > (uint64_t)EL_HTTP_MAX_RANGE_STREAM_BYTES) {
        w->exceededCap = YES;
        w->aborted = YES;
        return NO;
    }
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

/*
 * Executes a single Range GET request while reusing an open HTTPS keep-alive connection
 * across consecutive chunks to the same host:port, and updating *ioURL if redirected
 * to an edge CDN host so subsequent chunks avoid redundant redirects and TLS handshakes.
 */
- (BOOL)performRangeKeepAliveGET:(NSString **)ioURL
                            conn:(el_conn_t *)ioConn
                        connOpen:(BOOL *)ioConnOpen
                        connHost:(NSString **)ioConnHost
                        connPort:(NSString **)ioConnPort
                         headers:(NSDictionary *)headers
                        callback:(ELHTTPStreamCallback)callback
                        userData:(void *)userData
                      statusCode:(NSInteger *)outStatus
                 responseHeaders:(NSDictionary **)outHeaders
                   contentLength:(long long *)outContentLength
                           error:(NSString **)outError {
    if (!ioURL || ![*ioURL length] || !ioConn || !ioConnOpen || !ioConnHost || !ioConnPort) {
        if (outError) *outError = @"Invalid range connection state";
        return NO;
    }

    NSMutableDictionary *curHeaders = [NSMutableDictionary dictionary];
    if (headers) {
        for (id keyObj in headers) {
            if (![keyObj isKindOfClass:[NSString class]]) {
                if (outError) *outError = @"Invalid HTTP header key";
                return NO;
            }
            id valObj = [headers objectForKey:keyObj];
            if (![valObj isKindOfClass:[NSString class]]) {
                if (outError) *outError = @"Invalid HTTP header value";
                return NO;
            }
            NSString *kStr = (NSString *)keyObj;
            NSString *vStr = (NSString *)valObj;
            if (el_has_forbidden_header_chars(kStr, YES) ||
                el_has_forbidden_header_chars(vStr, NO)) {
                if (outError) *outError = @"Forbidden control characters in HTTP header";
                return NO;
            }
            [curHeaders setObject:vStr forKey:kStr];
        }
    }

    ELHostCategory initialCategory = ELHostCategoryAnyAllowlisted;
    NSString *currentURL = *ioURL;

    for (int hop = 0; hop < 6; hop++) {
        NSString *host = nil, *port = nil, *pq = nil;
        if (!ELValidateHTTPSURL(currentURL, initialCategory, &host, &port, &pq)) {
            if (*ioConnOpen) {
                el_conn_close(ioConn);
                *ioConnOpen = NO;
            }
            if (outError) {
                *outError = (hop > 0)
                    ? @"Blocked untrusted or non-HTTPS redirect target"
                    : @"Blocked untrusted or invalid HTTPS URL";
            }
            return NO;
        }
        if (hop == 0) {
            initialCategory = el_category_for_host(host);
        }

        if (*ioConnOpen && (!*ioConnHost || !*ioConnPort ||
                            ![*ioConnHost isEqualToString:host] ||
                            ![*ioConnPort isEqualToString:port])) {
            el_conn_close(ioConn);
            *ioConnOpen = NO;
        }

        NSMutableString *req = [NSMutableString stringWithFormat:@"GET %@ HTTP/1.1\r\n", pq];
        [req appendFormat:@"Host: %@\r\n", host];
        [req appendString:@"Connection: keep-alive\r\n"];

        BOOL hasUA = NO;
        for (NSString *k in curHeaders) {
            NSString *lk = [k lowercaseString];
            if ([lk isEqualToString:@"host"] || [lk isEqualToString:@"connection"]) continue;
            if ([lk isEqualToString:@"user-agent"]) hasUA = YES;
            [req appendFormat:@"%@: %@\r\n", k, [curHeaders objectForKey:k]];
        }
        if (!hasUA) {
            [req appendString:@"User-Agent: Mozilla/5.0 (iPhone; U; CPU iPhone OS 4_1 like Mac OS X)\r\n"];
        }
        [req appendString:@"\r\n"];
        NSData *reqHdrData = [req dataUsingEncoding:NSUTF8StringEncoding];

        NSInteger status = 0;
        NSMutableDictionary *respHeaders = nil;
        NSMutableData *leftover = nil;
        NSString *hdrErr = nil;
        BOOL gotHeaders = NO;

        for (int attempt = 0; attempt < 2; attempt++) {
            BOOL reused = *ioConnOpen;
            if (!*ioConnOpen) {
                NSString *openErr = nil;
                if (el_conn_open(ioConn, [host UTF8String], [port UTF8String], 1, &openErr) != 0) {
                    if (outError) *outError = openErr;
                    return NO;
                }
                *ioConnOpen = YES;
                [*ioConnHost release]; *ioConnHost = [host copy];
                [*ioConnPort release]; *ioConnPort = [port copy];
            }

            if (el_conn_write_all(ioConn, (const uint8_t *)[reqHdrData bytes], [reqHdrData length]) != 0) {
                el_conn_close(ioConn);
                *ioConnOpen = NO;
                if (reused && attempt == 0) continue;
                if (outError) *outError = @"Failed sending HTTP range request";
                return NO;
            }

            respHeaders = [NSMutableDictionary dictionary];
            leftover = [NSMutableData data];
            hdrErr = nil;
            if (!el_read_headers(ioConn, [host UTF8String], [port UTF8String], &status, respHeaders, leftover, &hdrErr)) {
                el_conn_close(ioConn);
                *ioConnOpen = NO;
                if (reused && attempt == 0) continue;
                if (outError) *outError = hdrErr;
                return NO;
            }
            gotHeaders = YES;
            break;
        }
        if (!gotHeaders) {
            if (outError) *outError = hdrErr ? hdrErr : @"Failed reading HTTP range headers";
            return NO;
        }

        if ((status == 301 || status == 302 || status == 303 || status == 307 || status == 308) &&
            [respHeaders objectForKey:@"location"]) {
            NSString *loc = [respHeaders objectForKey:@"location"];
            el_conn_close(ioConn);
            *ioConnOpen = NO;

            if ([loc hasPrefix:@"/"]) {
                loc = [NSString stringWithFormat:@"https://%@%@", host, loc];
            }
            NSString *nextHost = nil, *nextPort = nil, *nextPQ = nil;
            if (!ELValidateHTTPSURL(loc, initialCategory, &nextHost, &nextPort, &nextPQ)) {
                if (outError) *outError = @"Blocked insecure or cross-category HTTP redirect";
                return NO;
            }
            if (![nextHost isEqualToString:host] || ![nextPort isEqualToString:port]) {
                NSMutableArray *toRemove = [NSMutableArray array];
                for (NSString *k in curHeaders) {
                    NSString *lk = [k lowercaseString];
                    if ([lk isEqualToString:@"authorization"] ||
                        [lk isEqualToString:@"cookie"] ||
                        [lk isEqualToString:@"x-goog-visitor-id"] ||
                        [lk isEqualToString:@"x-goog-request-time"] ||
                        [lk isEqualToString:@"origin"] ||
                        [lk isEqualToString:@"referer"]) {
                        [toRemove addObject:k];
                    }
                }
                for (NSString *k in toRemove) [curHeaders removeObjectForKey:k];
            }
            currentURL = loc;
            [*ioURL release];
            *ioURL = [loc copy];
            continue;
        }

        if (outStatus) *outStatus = status;
        if (outHeaders) *outHeaders = [[respHeaders copy] autorelease];

        long long contentLen = -1;
        NSString *clStr = [respHeaders objectForKey:@"content-length"];
        if (clStr) {
            contentLen = [clStr longLongValue];
            if (contentLen < 0) {
                el_conn_close(ioConn);
                *ioConnOpen = NO;
                if (outError) *outError = @"Invalid negative Content-Length";
                return NO;
            }
        }
        if (outContentLength) *outContentLength = contentLen;

        NSString *te = [[respHeaders objectForKey:@"transfer-encoding"] lowercaseString];
        BOOL isChunked = (te && [te rangeOfString:@"chunked"].location != NSNotFound);
        NSString *connHdr = [[respHeaders objectForKey:@"connection"] lowercaseString];
        BOOL peerWantsClose = (connHdr && [connHdr rangeOfString:@"close"].location != NSNotFound);

        if (isChunked || contentLen < 0) {
            /* Fall back to non-keep-alive drain and close socket after transfer */
            peerWantsClose = YES;
        }

        BOOL aborted = NO;
        BOOL transferError = NO;
        NSString *transferErrMsg = nil;
        uint8_t rbuf[16384];

        if (!isChunked) {
            long long received = 0;
            if ([leftover length] > 0) {
                NSUInteger take = [leftover length];
                if (contentLen >= 0 && (long long)take > contentLen) take = (NSUInteger)contentLen;
                if (callback && !callback((const uint8_t *)[leftover bytes], take, contentLen, userData)) {
                    aborted = YES;
                }
                received += (long long)take;
            }
            while (!aborted && (contentLen < 0 || received < contentLen)) {
                size_t want = sizeof(rbuf);
                if (contentLen >= 0 && (contentLen - received) < (long long)want) {
                    want = (size_t)(contentLen - received);
                }
                int n = el_conn_read(ioConn, rbuf, want);
                if (n < 0) {
                    transferError = YES;
                    transferErrMsg = @"Socket read error during HTTP range response";
                    break;
                }
                if (n == 0) break;
                if (callback && !callback(rbuf, (NSUInteger)n, contentLen, userData)) {
                    aborted = YES;
                    break;
                }
                received += (long long)n;
            }
            if (!aborted && !transferError && contentLen >= 0 && received != contentLen) {
                transferError = YES;
                transferErrMsg = [NSString stringWithFormat:@"Truncated HTTP range response (%lld of %lld bytes)",
                                  received, contentLen];
            }
        } else {
            /* Rare chunked range fallback: close connection and delegate or fail if truncated */
            el_conn_close(ioConn);
            *ioConnOpen = NO;
            return [self performRequestMethod:@"GET"
                                          url:currentURL
                                      headers:curHeaders
                                         body:nil
                                     callback:callback
                                     userData:userData
                                   statusCode:outStatus
                              responseHeaders:outHeaders
                                contentLength:outContentLength
                                        error:outError];
        }

        if (aborted || transferError || peerWantsClose || status == 416 || (status != 200 && status != 206)) {
            el_conn_close(ioConn);
            *ioConnOpen = NO;
        }

        if (transferError) {
            if (outError) *outError = transferErrMsg ? transferErrMsg : @"HTTP range transfer failed";
            return NO;
        }
        return YES;
    }

    if (*ioConnOpen) {
        el_conn_close(ioConn);
        *ioConnOpen = NO;
    }
    if (outError) *outError = @"Too many HTTP redirects";
    return NO;
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
    if (totalLength > EL_HTTP_MAX_RANGE_STREAM_BYTES ||
        startOffset >= (uint64_t)EL_HTTP_MAX_RANGE_STREAM_BYTES) {
        if (outError) *outError = @"Stream size exceeds 50 MB limit";
        return NO;
    }
    if (chunkSize < 65536) chunkSize = 524288;
    uint64_t initialChunkSize = chunkSize;
    uint64_t steadyChunkSize = (chunkSize > EL_HTTP_STEADY_RANGE_CHUNK_SIZE)
        ? chunkSize
        : EL_HTTP_STEADY_RANGE_CHUNK_SIZE;

    uint64_t pos = startOffset;
    long long knownTotal = totalLength;
    NSInteger lastStatus = 200;

    el_conn_t kaConn;
    memset(&kaConn, 0, sizeof(kaConn));
    kaConn.fd = -1;
    BOOL kaOpen = NO;
    NSString *kaHost = nil;
    NSString *kaPort = nil;
    NSString *activeURL = [urlString copy];

    while (knownTotal <= 0 || (long long)pos < knownTotal) {
        if ((long long)pos >= EL_HTTP_MAX_RANGE_STREAM_BYTES) {
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
            if (outError) *outError = @"Stream exceeded 50 MB limit";
            return NO;
        }
        NSAutoreleasePool *chunkPool = [[NSAutoreleasePool alloc] init];
        /* Use fast initialChunkSize (e.g. 512 KiB) at byte 0 for instant time-to-first-audio,
           then step up to 1.5 MiB chunks over the reused keep-alive TLS socket. */
        uint64_t curSpan = (pos == 0) ? initialChunkSize : steadyChunkSize;
        uint64_t end = pos + curSpan - 1;
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
        wrap.totalBeforeChunk = pos - startOffset;
        wrap.aborted = NO;
        wrap.exceededCap = NO;

        NSInteger status = 0;
        NSDictionary *respHdrs = nil;
        long long cl = -1;
        NSString *err = nil;

        BOOL ok = [self performRangeKeepAliveGET:&activeURL
                                            conn:&kaConn
                                        connOpen:&kaOpen
                                        connHost:&kaHost
                                        connPort:&kaPort
                                         headers:reqHdrs
                                        callback:el_range_chunk_cb
                                        userData:&wrap
                                      statusCode:&status
                                 responseHeaders:&respHdrs
                                   contentLength:&cl
                                           error:&err];
        lastStatus = status;
        if (outStatus) *outStatus = lastStatus;

        if (wrap.exceededCap) {
            [chunkPool release];
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
            if (outError) *outError = @"Stream exceeded 50 MB limit";
            return NO;
        }
        if (wrap.aborted) {
            [chunkPool release];
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
            return YES;
        }
        if (!ok) {
            NSString *retainedErr = [err retain];
            [chunkPool release];
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
            if (outError) *outError = [retainedErr autorelease];
            else [retainedErr release];
            return NO;
        }
        if (status == 416) {
            /* Reached EOF: valid only if we already received the expected total */
            [chunkPool release];
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
            if (knownTotal > 0 && (long long)pos < knownTotal) {
                if (outError) *outError = @"Truncated range stream (HTTP 416 before expected end)";
                return NO;
            }
            if (outStatus) *outStatus = 206;
            return YES;
        }
        if (status != 200 && status != 206) {
            [chunkPool release];
            if (kaOpen) el_conn_close(&kaConn);
            [kaHost release];
            [kaPort release];
            [activeURL release];
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
                    if (tot > EL_HTTP_MAX_RANGE_STREAM_BYTES) {
                        [chunkPool release];
                        if (kaOpen) el_conn_close(&kaConn);
                        [kaHost release];
                        [kaPort release];
                        [activeURL release];
                        if (outError) *outError = @"Stream Content-Range total exceeds 50 MB limit";
                        return NO;
                    }
                    if (tot > 0) knownTotal = tot;
                }
            } else if (status == 200 && cl > 0) {
                if ((long long)pos + cl > EL_HTTP_MAX_RANGE_STREAM_BYTES) {
                    [chunkPool release];
                    if (kaOpen) el_conn_close(&kaConn);
                    [kaHost release];
                    [kaPort release];
                    [activeURL release];
                    if (outError) *outError = @"Stream Content-Length exceeds 50 MB limit";
                    return NO;
                }
                knownTotal = (long long)pos + cl;
            }
        }

        [chunkPool release];
        if (wrap.chunkGot == 0) break;
        pos += wrap.chunkGot;
        if (status == 200) break; /* Server ignored Range and sent full body */
    }

    if (kaOpen) el_conn_close(&kaConn);
    [kaHost release];
    [kaPort release];
    [activeURL release];

    if (knownTotal > 0 && (long long)pos < knownTotal) {
        if (outError) *outError = [NSString stringWithFormat:@"Truncated range stream (%llu of %lld bytes)",
                                   (unsigned long long)pos, knownTotal];
        return NO;
    }

    if (outStatus) *outStatus = lastStatus;
    return YES;
}

@end
