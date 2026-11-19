#import "ELJSON.h"
#import "cJSON.h"

static id el_objc_from_cjson(const cJSON *item) {
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
        NSMutableArray *arr = [NSMutableArray array];
        const cJSON *child = NULL;
        cJSON_ArrayForEach(child, item) {
            id val = el_objc_from_cjson(child);
            if (val) [arr addObject:val];
        }
        return arr;
    }
    if (cJSON_IsObject(item)) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        const cJSON *child = NULL;
        cJSON_ArrayForEach(child, item) {
            if (!child->string) continue;
            NSString *key = [NSString stringWithUTF8String:child->string];
            if (!key) continue;
            id val = el_objc_from_cjson(child);
            if (val) [dict setObject:val forKey:key];
        }
        return dict;
    }
    return [NSNull null];
}

static cJSON *el_cjson_from_objc(id obj) {
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
            cJSON_AddItemToArray(arr, el_cjson_from_objc(child));
        }
        return arr;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        cJSON *dict = cJSON_CreateObject();
        NSDictionary *d = (NSDictionary *)obj;
        for (id key in d) {
            NSString *kstr = [key description];
            cJSON_AddItemToObject(dict, [kstr UTF8String], el_cjson_from_objc([d objectForKey:key]));
        }
        return dict;
    }
    return cJSON_CreateString([[obj description] UTF8String]);
}

@implementation ELJSON

+ (id)objectWithData:(NSData *)data {
    if (!data || [data length] == 0) return nil;
    cJSON *root = cJSON_ParseWithLength((const char *)[data bytes], [data length]);
    if (!root) return nil;
    id result = el_objc_from_cjson(root);
    cJSON_Delete(root);
    return result;
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
    cJSON *root = el_cjson_from_objc(obj);
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
