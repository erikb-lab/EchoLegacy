#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface ELTheme : NSObject

+ (UIColor *)backgroundColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)surfaceHighlightColor;
+ (UIColor *)separatorColor;
+ (UIColor *)accentColor;
+ (UIColor *)textPrimaryColor;
+ (UIColor *)textSecondaryColor;
+ (UIColor *)successColor;

/* Dynamic album-art dominant backdrop sampling & color shading (iOS 4.1 CG-only, <1ms) */
+ (UIColor *)dominantBackdropColorFromImage:(UIImage *)image;
+ (UIColor *)dominantBackdropColorFromImage:(UIImage *)image cacheKey:(NSString *)cacheKey;
+ (UIColor *)darkerShadeOfColor:(UIColor *)color factor:(CGFloat)factor;
+ (UIColor *)colorWithColor:(UIColor *)color alpha:(CGFloat)alpha;

+ (void)styleTableView:(UITableView *)tableView;
+ (void)styleNavBar:(UINavigationBar *)navBar;
+ (UIButton *)pillButtonWithTitle:(NSString *)title color:(UIColor *)color frame:(CGRect)frame;

/* Cached procedural CoreGraphics icons (zero re-allocation while scrolling!) */
+ (UIImage *)placeholderArtImage;
+ (UIImage *)tabIconHome;
+ (UIImage *)tabIconLibrary;
+ (UIImage *)tabIconSearch;
+ (UIImage *)tabIconDownloads;
+ (UIImage *)tabIconAccount;
+ (UIImage *)iconPlaySize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconPauseSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconPrevSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconNextSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconDownloadSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconCheckSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconCheckCircleSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconCloseSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconShuffleSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconRepeatSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconQueueSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconHeartOutlineSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconHeartFilledSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconSyncSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconSearchSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconMoreSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)iconLyricsSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)sliderTrackImageWithColor:(UIColor *)color;
+ (UIImage *)sliderThumbImage;

/* Pre-rendered MBX Lite-friendly surfaces & rounded thumbnails (zero offscreen FBO clipping!) */
+ (UIImage *)circlePillImageWithSize:(CGFloat)size color:(UIColor *)color;
+ (UIImage *)stretchablePillImageWithHeight:(CGFloat)height color:(UIColor *)color;
+ (UIImage *)stretchableCardImageWithColor:(UIColor *)color;
+ (UIImage *)roundedRectImageWithSize:(CGSize)size radius:(CGFloat)radius fillColor:(UIColor *)fillColor borderColor:(UIColor *)borderColor;
+ (UIImage *)verticalGradientImageWithHeight:(CGFloat)h
                                    topColor:(UIColor *)top
                                    midColor:(UIColor *)mid
                                 midLocation:(CGFloat)midLoc
                                 bottomColor:(UIColor *)bottom
                                      opaque:(BOOL)opaque;
+ (UIImage *)roundedPlaceholderArtSize:(CGFloat)size radius:(CGFloat)radius;
+ (UIImage *)roundedPlaceholderArtSize:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor;
+ (UIImage *)cachedRoundedThumbnailForSize:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey;
+ (UIImage *)cachedRoundedThumbnailForSize:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor cacheKey:(NSString *)cacheKey;
+ (UIImage *)roundedThumbnailFromImage:(UIImage *)image size:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey;
+ (UIImage *)roundedThumbnailFromImage:(UIImage *)image size:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor cacheKey:(NSString *)cacheKey;
+ (void)clearThumbnailCache;
+ (void)flushMemoryCaches;

@end
