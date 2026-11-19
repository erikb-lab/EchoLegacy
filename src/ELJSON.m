#import "ELJSON.h"
#import "cJSON.h"
#include <stdint.h>
#include <string.h>

#define EL_MAX_JSON_BYTES (8U * 1024U * 1024U)
#define EL_MAX_JSON_DEPTH 64

static BOOL el_should_skip_youtube_key(const char *k) {
    if (!k) return NO;
    switch (k[0]) {
        case 'a':
            return (strcmp(k, "accessibility") == 0 ||
                    strcmp(k, "accessibilityData") == 0 ||
                    strcmp(k, "adPlacements") == 0 ||
                    strcmp(k, "adSlots") == 0 ||
                    strcmp(k, "annotations") == 0 ||
                    strcmp(k, "attestation") == 0);
        case 'b':
            return (strcmp(k, "badges") == 0);
        case 'c':
            return (strcmp(k, "captions") == 0 ||
                    strcmp(k, "chipCloud") == 0 ||
                    strcmp(k, "clickTrackingParams") == 0 ||
                    strcmp(k, "colorPalette") == 0);
        case 'f':
            return (strcmp(k, "feedbackToken") == 0 ||
                    strcmp(k, "frameworkUpdates") == 0);
        case 'i':
            return (strcmp(k, "icon") == 0);
        case 'l':
            return (strcmp(k, "loggingDirectives") == 0);
        case 'm':
            return (strcmp(k, "mainAppWebResponseContext") == 0 ||
                    strcmp(k, "menu") == 0 ||
                    strcmp(k, "menuRenderer") == 0 ||
                    strcmp(k, "microformat") == 0);
        case 'o':
            return (strcmp(k, "onTap") == 0);
        case 'p':
            return (strcmp(k, "pauseIcon") == 0 ||
                    strcmp(k, "playIcon") == 0 ||
                    strcmp(k, "playbackTracking") == 0 ||
                    strcmp(k, "playerAds") == 0 ||
                    strcmp(k, "playerConfig") == 0);
        case 's':
            return (strcmp(k, "serviceTrackingParams") == 0 ||
                    strcmp(k, "storyboards") == 0);
        case 't':
            return (strcmp(k, "topbar") == 0 ||
                    strcmp(k, "trackingParams") == 0);
        case 'w':
            return (strcmp(k, "watchEndpointMusicSupportedConfigs") == 0 ||
                    strcmp(k, "webResponseContextExtensionData") == 0);
        default:
            return NO;
    }
}

static BOOL el_json_check_depth(const uint8_t *buf, size_t len, int maxDepth) {
    if (!buf || len == 0 || len > EL_MAX_JSON_BYTES) return NO;
    int depth = 0;
    BOOL inString = NO;
    BOOL escaped = NO;
    for (size_t i = 0; i < len; i++) {
        uint8_t c = buf[i];
        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (c == '\\') {
                escaped = YES;
            } else if (c == '"') {
                inString = NO;
            }
        } else {
            if (c == '"') {
                inString = YES;
            } else if (c == '{' || c == '[') {
                depth++;
                if (depth > maxDepth) return NO;
            } else if (c == '}' || c == ']') {
                if (depth > 0) depth--;
            }
        }
    }
    return YES;
}

static id el_objc_from_cjson(const cJSON *item, int depth, BOOL pruneYouTube) {
    if (depth > EL_MAX_JSON_DEPTH) {
        return nil;
    }
    if (!item || cJSON_IsNull(item)) {
        return [NSNull null];
    }
    if (cJSON_IsBool(item)) {
        return [NSNumber numberWithBool:cJSON_IsTrue(item) ? YES : NO];
    }
    if (cJSON_IsNumber(item)) {
        return [NSNumber numberWithDouble:item->valuedouble];
    }
    if (cJSON_IsString(item)) {
        if (!item->valuestring) return @"";
        NSString *s = [NSString stringWithUTF8String:item->valuestring];
        return s ? s : @"";
    }
    if (cJSON_IsArray(item)) {
        if (depth + 1 > EL_MAX_JSON_DEPTH) return nil;
        NSMutableArray *arr = [NSMutableArray array];
        const cJSON *child = NULL;
        cJSON_ArrayForEach(child, item) {
            id val = el_objc_from_cjson(child, depth + 1, pruneYouTube);
            if (val) [arr addObject:val];
        }
        return arr;
    }
    if (cJSON_IsObject(item)) {
        if (depth + 1 > EL_MAX_JSON_DEPTH) return nil;
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        const cJSON *child = NULL;
        cJSON_ArrayForEach(child, item) {
            if (!child->string) continue;
            if (pruneYouTube && el_should_skip_youtube_key(child->string)) continue;
            NSString *key = [NSString stringWithUTF8String:child->string];
            if (!key) continue;
            id val = el_objc_from_cjson(child, depth + 1, pruneYouTube);
            if (val) [dict setObject:val forKey:key];
        }
        return dict;
    }
    return [NSNull null];
}

static cJSON *el_cjson_from_objc(id obj, int depth) {
    if (depth > EL_MAX_JSON_DEPTH) {
        return cJSON_CreateNull();
    }
    if (!obj || obj == [NSNull null]) {
        return cJSON_CreateNull();
    }
    if ([obj isKindOfClass:[NSString class]]) {
        return cJSON_CreateString([(NSString *)obj UTF8String]);
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;
        const char *ot = [num objCType];
        if (ot && (ot[0] == 'c' || ot[0] == 'B')) {
            return cJSON_CreateBool([num boolValue] ? 1 : 0);
        }
        return cJSON_CreateNumber([num doubleValue]);
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        cJSON *arr = cJSON_CreateArray();
        for (id child in (NSArray *)obj) {
            cJSON_AddItemToArray(arr, el_cjson_from_objc(child, depth + 1));
        }
        return arr;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        cJSON *dict = cJSON_CreateObject();
        NSDictionary *d = (NSDictionary *)obj;
        for (id key in d) {
            NSString *kstr = [key description];
            cJSON_AddItemToObject(dict, [kstr UTF8String], el_cjson_from_objc([d objectForKey:key], depth + 1));
        }
        return dict;
    }
    return cJSON_CreateString([[obj description] UTF8String]);
}

@implementation ELJSON

+ (id)objectWithData:(NSData *)data pruneYouTube:(BOOL)pruneYouTube {
    if (!data || [data length] == 0 || [data length] > EL_MAX_JSON_BYTES) return nil;
    if (!el_json_check_depth((const uint8_t *)[data bytes], [data length], EL_MAX_JSON_DEPTH)) {
        return nil;
    }
    cJSON *root = cJSON_ParseWithLength((const char *)[data bytes], [data length]);
    if (!root) return nil;
    id result = el_objc_from_cjson(root, 0, pruneYouTube);
    cJSON_Delete(root);
    return result;
}

+ (id)objectWithData:(NSData *)data {
    return [self objectWithData:data pruneYouTube:NO];
}

+ (id)youtubeObjectWithData:(NSData *)data {
    return [self objectWithData:data pruneYouTube:YES];
}

+ (id)objectWithString:(NSString *)jsonString {
    if (!jsonString) return nil;
    return [self objectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding]];
}

+ (NSData *)dataWithObject:(id)obj {
    NSString *s = [self stringWithObject:obj];
    return s ? [s dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

+ (NSString *)stringWithObject:(id)obj {
    if (!obj) return nil;
    cJSON *root = el_cjson_from_objc(obj, 0);
    if (!root) return nil;
    char *printed = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!printed) return nil;
    NSString *s = [NSString stringWithUTF8String:printed];
    free(printed);
    return s;
}

+ (NSDictionary *)dict:(id)obj forKey:(NSString *)key {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    return [v isKindOfClass:[NSDictionary class]] ? (NSDictionary *)v : nil;
}

+ (NSArray *)array:(id)obj forKey:(NSString *)key {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    return [v isKindOfClass:[NSArray class]] ? (NSArray *)v : nil;
}

+ (NSString *)string:(id)obj forKey:(NSString *)key {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

+ (NSNumber *)number:(id)obj forKey:(NSString *)key {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    return [v isKindOfClass:[NSNumber class]] ? (NSNumber *)v : nil;
}

@end
