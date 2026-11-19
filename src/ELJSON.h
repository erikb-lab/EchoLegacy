#import <Foundation/Foundation.h>

@interface ELJSON : NSObject

+ (id)objectWithData:(NSData *)data;
+ (id)objectWithString:(NSString *)jsonString;
+ (NSData *)dataWithObject:(id)obj;
+ (NSString *)stringWithObject:(id)obj;

/* Safe typed accessors for navigating nested InnerTube JSON */
+ (NSDictionary *)dict:(id)obj forKey:(NSString *)key;
+ (NSArray *)array:(id)obj forKey:(NSString *)key;
+ (NSString *)string:(id)obj forKey:(NSString *)key;
+ (NSNumber *)number:(id)obj forKey:(NSString *)key;

@end
