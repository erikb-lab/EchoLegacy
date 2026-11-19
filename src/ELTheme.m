#import "ELTheme.h"
#include <math.h>
#include <string.h>

#define EL_MAX_ROUNDED_THUMBS 128

static NSMutableDictionary *g_icon_cache = nil;
static NSMutableDictionary *g_thumb_cache = nil;
static NSMutableArray *g_thumb_lru = nil;
static BOOL g_thumb_observer_registered = NO;

static void el_color_rgba(UIColor *color, CGFloat *outR, CGFloat *outG, CGFloat *outB, CGFloat *outA) {
    CGFloat r = 0.0f, g = 0.0f, b = 0.0f, a = 1.0f;
    if (color) {
        CGColorRef cg = [color CGColor];
        if (cg) {
            const CGFloat *comps = CGColorGetComponents(cg);
            size_t n = CGColorGetNumberOfComponents(cg);
            if (n >= 4) {
                r = comps[0]; g = comps[1]; b = comps[2]; a = comps[3];
            } else if (n == 3) {
                r = comps[0]; g = comps[1]; b = comps[2]; a = 1.0f;
            } else if (n == 2) {
                r = comps[0]; g = comps[0]; b = comps[0]; a = comps[1];
            } else if (n == 1) {
                r = comps[0]; g = comps[0]; b = comps[0]; a = 1.0f;
            }
        }
    }
    if (outR) *outR = r;
    if (outG) *outG = g;
    if (outB) *outB = b;
    if (outA) *outA = a;
}

static NSString *el_color_hex(UIColor *color) {
    CGFloat rf, gf, bf, af;
    el_color_rgba(color, &rf, &gf, &bf, &af);
    int r = (int)(rf * 255.0f + 0.5f);
    int g = (int)(gf * 255.0f + 0.5f);
    int b = (int)(bf * 255.0f + 0.5f);
    int a = (int)(af * 255.0f + 0.5f);
    if (r < 0) r = 0; else if (r > 255) r = 255;
    if (g < 0) g = 0; else if (g > 255) g = 255;
    if (b < 0) b = 0; else if (b > 255) b = 255;
    if (a < 0) a = 0; else if (a > 255) a = 255;
    return [NSString stringWithFormat:@"%02x%02x%02x%02x", r, g, b, a];
}

static NSString *el_icon_key(NSString *name, CGFloat size, UIColor *color) {
    return [NSString stringWithFormat:@"%@_%d_%@", name, (int)(size + 0.5f), el_color_hex(color)];
}

static UIImage *el_cached_icon(NSString *key) {
    @synchronized([ELTheme class]) {
        if (!g_icon_cache) g_icon_cache = [[NSMutableDictionary alloc] init];
        UIImage *img = [g_icon_cache objectForKey:key];
        return img ? [[img retain] autorelease] : nil;
    }
}

static UIImage *el_store_icon(NSString *key, UIImage *img) {
    @synchronized([ELTheme class]) {
        if (!g_icon_cache) g_icon_cache = [[NSMutableDictionary alloc] init];
        if (img && key) [g_icon_cache setObject:img forKey:key];
        return img;
    }
}

static void el_add_rounded_rect_path(CGContextRef ctx, CGRect rect, CGFloat radius) {
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat midX = CGRectGetMidX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat maxR = (rect.size.width < rect.size.height ? rect.size.width : rect.size.height) * 0.5f;
    if (radius > maxR) radius = maxR;
    if (radius < 0.0f) radius = 0.0f;

    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, minX, midY);
    CGContextAddArcToPoint(ctx, minX, minY, midX, minY, radius);
    CGContextAddArcToPoint(ctx, maxX, minY, maxX, midY, radius);
    CGContextAddArcToPoint(ctx, maxX, maxY, midX, maxY, radius);
    CGContextAddArcToPoint(ctx, minX, maxY, minX, midY, radius);
    CGContextClosePath(ctx);
}

static void el_add_heart_path(CGContextRef ctx, CGFloat size) {
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, size * 0.50f, size * 0.30f);
    /* Top center notch -> left lobe -> left outer curve */
    CGContextAddCurveToPoint(ctx,
                             size * 0.44f, size * 0.15f,
                             size * 0.14f, size * 0.16f,
                             size * 0.14f, size * 0.39f);
    /* Left outer curve -> bottom tip */
    CGContextAddCurveToPoint(ctx,
                             size * 0.14f, size * 0.58f,
                             size * 0.35f, size * 0.70f,
                             size * 0.50f, size * 0.84f);
    /* Bottom tip -> right outer curve */
    CGContextAddCurveToPoint(ctx,
                             size * 0.65f, size * 0.70f,
                             size * 0.86f, size * 0.58f,
                             size * 0.86f, size * 0.39f);
    /* Right outer curve -> right lobe -> top center notch */
    CGContextAddCurveToPoint(ctx,
                             size * 0.86f, size * 0.16f,
                             size * 0.56f, size * 0.15f,
                             size * 0.50f, size * 0.30f);
    CGContextClosePath(ctx);
}

static CGFloat el_clampf(CGFloat v, CGFloat lo, CGFloat hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

@implementation ELTheme

+ (UIColor *)backgroundColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.051f green:0.051f blue:0.071f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)surfaceColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.106f green:0.106f blue:0.145f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)surfaceHighlightColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.165f green:0.165f blue:0.220f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)separatorColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.155f green:0.155f blue:0.205f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)accentColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.980f green:0.176f blue:0.282f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)textPrimaryColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.965f green:0.965f blue:0.985f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)textSecondaryColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.590f green:0.590f blue:0.670f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)successColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.204f green:0.827f blue:0.600f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)defaultBackdropColor {
    static UIColor *c = nil;
    if (!c) c = [[UIColor colorWithRed:0.145f green:0.115f blue:0.180f alpha:1.0f] retain];
    return c;
}

+ (UIColor *)dominantBackdropColorFromImage:(UIImage *)image cacheKey:(NSString *)cacheKey {
    static NSMutableDictionary *g_backdrop_cache = nil;
    if ([cacheKey length] > 0) {
        @synchronized(self) {
            if (!g_backdrop_cache) g_backdrop_cache = [[NSMutableDictionary alloc] init];
            UIColor *hit = [g_backdrop_cache objectForKey:cacheKey];
            if (hit) return [[hit retain] autorelease];
        }
    }
    UIColor *col = [self dominantBackdropColorFromImage:image];
    if (col && [cacheKey length] > 0 && image && image != [self placeholderArtImage]) {
        @synchronized(self) {
            if (!g_backdrop_cache) g_backdrop_cache = [[NSMutableDictionary alloc] init];
            if ([g_backdrop_cache count] > 32) [g_backdrop_cache removeAllObjects];
            [g_backdrop_cache setObject:col forKey:cacheKey];
        }
    }
    return col;
}

+ (UIColor *)dominantBackdropColorFromImage:(UIImage *)image {
    if (!image || image == [self placeholderArtImage]) {
        return [self defaultBackdropColor];
    }
    CGImageRef cgImg = [image CGImage];
    if (!cgImg) {
        return [self defaultBackdropColor];
    }

    const int dim = 12;
    unsigned char pixels[12 * 12 * 4];
    memset(pixels, 0, sizeof(pixels));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return [self defaultBackdropColor];
    }
    CGContextRef ctx = CGBitmapContextCreate(pixels,
                                             (size_t)dim,
                                             (size_t)dim,
                                             8,
                                             (size_t)(dim * 4),
                                             cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return [self defaultBackdropColor];
    }

    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0.0f, 0.0f, (CGFloat)dim, (CGFloat)dim), cgImg);
    CGContextRelease(ctx);

    /* Saturation-weighted dominant color with lower-half bias so the bottom fade melts seamlessly */
    float sumR = 0.0f, sumG = 0.0f, sumB = 0.0f, sumW = 0.0f;
    float allR = 0.0f, allG = 0.0f, allB = 0.0f, allW = 0.0f;

    for (int y = 0; y < dim; y++) {
        /* Bitmap buffer row 0 is the top of the image; rows y >= dim/2 are the bottom half near the fade */
        float rowBias = (y >= dim / 2) ? 1.45f : 0.85f;
        for (int x = 0; x < dim; x++) {
            int idx = (y * dim + x) * 4;
            unsigned char aByte = pixels[idx + 3];
            if (aByte < 32) continue;

            float invA = (aByte < 255) ? (1.0f / (float)aByte) : (1.0f / 255.0f);
            float r = (float)pixels[idx + 0] * invA;
            float g = (float)pixels[idx + 1] * invA;
            float b = (float)pixels[idx + 2] * invA;
            if (r > 1.0f) r = 1.0f;
            if (g > 1.0f) g = 1.0f;
            if (b > 1.0f) b = 1.0f;

            float maxC = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b);
            float minC = (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b);
            float chroma = maxC - minC;
            float luma = 0.299f * r + 0.587f * g + 0.114f * b;

            allR += r * rowBias;
            allG += g * rowBias;
            allB += b * rowBias;
            allW += rowBias;

            if (luma >= 0.07f && luma <= 0.92f) {
                float w = (0.12f + chroma * chroma * 3.5f) * rowBias;
                sumR += r * w;
                sumG += g * w;
                sumB += b * w;
                sumW += w;
            }
        }
    }

    float r, g, b;
    if (sumW > 0.001f) {
        r = sumR / sumW;
        g = sumG / sumW;
        b = sumB / sumW;
    } else if (allW > 0.001f) {
        r = allR / allW;
        g = allG / allW;
        b = allB / allW;
    } else {
        return [self defaultBackdropColor];
    }

    /* Convert RGB -> HSV in plain C (iOS 4.1 safe) */
    float maxC = (r > g) ? ((r > b) ? r : b) : ((g > b) ? g : b);
    float minC = (r < g) ? ((r < b) ? r : b) : ((g < b) ? g : b);
    float delta = maxC - minC;

    float h = 0.0f;
    float s = (maxC > 0.001f) ? (delta / maxC) : 0.0f;
    float v = maxC;

    if (delta > 0.0001f) {
        if (maxC == r) {
            h = (g - b) / delta + (g < b ? 6.0f : 0.0f);
        } else if (maxC == g) {
            h = (b - r) / delta + 2.0f;
        } else {
            h = (r - g) / delta + 4.0f;
        }
        h /= 6.0f;
    }

    /* Clamp saturation & brightness for rich dark backdrop with crisp white-text contrast */
    if (s > 0.08f) {
        s = el_clampf(s * 1.05f, 0.28f, 0.62f);
    } else {
        s = el_clampf(s, 0.0f, 0.12f);
    }
    v = el_clampf(v * 0.44f, 0.16f, 0.30f);

    /* Convert HSV -> RGB */
    float h6 = h * 6.0f;
    int sector = (int)floorf(h6);
    float frac = h6 - (float)sector;
    float p = v * (1.0f - s);
    float q = v * (1.0f - s * frac);
    float t = v * (1.0f - s * (1.0f - frac));
    float outR = v, outG = v, outB = v;
    switch (sector % 6) {
        case 0: outR = v; outG = t; outB = p; break;
        case 1: outR = q; outG = v; outB = p; break;
        case 2: outR = p; outG = v; outB = t; break;
        case 3: outR = p; outG = q; outB = v; break;
        case 4: outR = t; outG = p; outB = v; break;
        default: outR = v; outG = p; outB = q; break;
    }

    /* Final perceptual luma cap so white text always maintains >= 8:1 contrast */
    float outLuma = 0.299f * outR + 0.587f * outG + 0.114f * outB;
    if (outLuma > 0.25f) {
        float scale = 0.25f / outLuma;
        outR *= scale;
        outG *= scale;
        outB *= scale;
    } else if (outLuma < 0.11f) {
        float lift = 0.11f - outLuma;
        outR = el_clampf(outR + lift, 0.0f, 1.0f);
        outG = el_clampf(outG + lift, 0.0f, 1.0f);
        outB = el_clampf(outB + lift, 0.0f, 1.0f);
    }

    return [UIColor colorWithRed:outR green:outG blue:outB alpha:1.0f];
}

+ (UIColor *)darkerShadeOfColor:(UIColor *)color factor:(CGFloat)factor {
    CGFloat r, g, b, a;
    el_color_rgba(color, &r, &g, &b, &a);
    CGFloat f = el_clampf(factor, 0.0f, 1.0f);
    return [UIColor colorWithRed:r * f green:g * f blue:b * f alpha:a];
}

+ (UIColor *)colorWithColor:(UIColor *)color alpha:(CGFloat)alpha {
    CGFloat r, g, b, a;
    el_color_rgba(color, &r, &g, &b, &a);
    return [UIColor colorWithRed:r green:g blue:b alpha:el_clampf(alpha, 0.0f, 1.0f)];
}

+ (void)styleTableView:(UITableView *)tableView {
    tableView.backgroundColor = [self backgroundColor];
    tableView.separatorColor = [self separatorColor];
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
}

+ (void)styleNavBar:(UINavigationBar *)navBar {
    static UIColor *navTint = nil;
    if (!navTint) navTint = [[UIColor colorWithRed:0.095f green:0.095f blue:0.135f alpha:1.0f] retain];
    navBar.barStyle = UIBarStyleBlack;
    navBar.tintColor = navTint;
}

+ (UIButton *)pillButtonWithTitle:(NSString *)title color:(UIColor *)color frame:(CGRect)frame {
    static UIColor *hiTextColor = nil;
    if (!hiTextColor) hiTextColor = [[UIColor colorWithWhite:1.0f alpha:0.60f] retain];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [UIColor clearColor];
    CGFloat r = frame.size.height * 0.5f;
    UIImage *bgNorm = [self roundedRectImageWithSize:frame.size radius:r fillColor:color borderColor:nil];
    UIImage *bgHi = [self roundedRectImageWithSize:frame.size radius:r fillColor:[self darkerShadeOfColor:color factor:0.78f] borderColor:nil];
    [btn setBackgroundImage:bgNorm forState:UIControlStateNormal];
    [btn setBackgroundImage:bgHi forState:UIControlStateHighlighted];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13.0f];
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn setTitleColor:hiTextColor forState:UIControlStateHighlighted];
    return btn;
}

+ (UIImage *)placeholderArtImage {
    UIImage *c = el_cached_icon(@"placeholder_art");
    if (c) return c;
    const size_t px = 96;
    const CGFloat fSize = 96.0f;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return nil;
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             px,
                                             px,
                                             8,
                                             px * 4,
                                             cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;

    /* Flip to top-left UIKit coordinates so note geometry renders identically on any thread */
    CGContextTranslateCTM(ctx, 0.0f, fSize);
    CGContextScaleCTM(ctx, 1.0f, -1.0f);

    CGContextSetRGBFillColor(ctx, 0.106f, 0.106f, 0.145f, 1.0f);
    CGContextFillRect(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize));

    CGContextSetRGBFillColor(ctx, 0.32f, 0.32f, 0.42f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(26.0f, 58.0f, 16.0f, 12.0f));
    CGContextFillEllipseInRect(ctx, CGRectMake(54.0f, 52.0f, 16.0f, 12.0f));
    CGContextFillRect(ctx, CGRectMake(39.0f, 28.0f, 4.0f, 34.0f));
    CGContextFillRect(ctx, CGRectMake(67.0f, 22.0f, 4.0f, 34.0f));
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, 39.0f, 28.0f);
    CGContextAddLineToPoint(ctx, 71.0f, 22.0f);
    CGContextAddLineToPoint(ctx, 71.0f, 30.0f);
    CGContextAddLineToPoint(ctx, 39.0f, 36.0f);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);

    CGImageRef cgOut = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    UIImage *img = nil;
    if (cgOut) {
        img = [UIImage imageWithCGImage:cgOut];
        CGImageRelease(cgOut);
    }
    return el_store_icon(@"placeholder_art", img);
}

+ (UIImage *)tabIconHome {
    UIImage *c = el_cached_icon(@"tab_home");
    if (c) return c;
    CGSize sz = CGSizeMake(24.0f, 24.0f);
    UIGraphicsBeginImageContext(sz);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    /* Roof + house body */
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, 3.5f, 11.0f);
    CGContextAddLineToPoint(ctx, 12.0f, 4.0f);
    CGContextAddLineToPoint(ctx, 20.5f, 11.0f);
    CGContextMoveToPoint(ctx, 5.5f, 10.0f);
    CGContextAddLineToPoint(ctx, 5.5f, 20.0f);
    CGContextAddLineToPoint(ctx, 10.0f, 20.0f);
    CGContextAddLineToPoint(ctx, 10.0f, 14.5f);
    CGContextAddLineToPoint(ctx, 14.0f, 14.5f);
    CGContextAddLineToPoint(ctx, 14.0f, 20.0f);
    CGContextAddLineToPoint(ctx, 18.5f, 20.0f);
    CGContextAddLineToPoint(ctx, 18.5f, 10.0f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"tab_home", img);
}

+ (UIImage *)tabIconLibrary {
    UIImage *c = el_cached_icon(@"tab_lib");
    if (c) return c;
    CGSize sz = CGSizeMake(24.0f, 24.0f);
    UIGraphicsBeginImageContext(sz);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(4, 15, 6, 5));
    CGContextFillEllipseInRect(ctx, CGRectMake(14, 13, 6, 5));
    CGContextFillRect(ctx, CGRectMake(8.5f, 5, 2, 12));
    CGContextFillRect(ctx, CGRectMake(18.5f, 3, 2, 12));
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, 8.5f, 5);
    CGContextAddLineToPoint(ctx, 20.5f, 3);
    CGContextAddLineToPoint(ctx, 20.5f, 6.5f);
    CGContextAddLineToPoint(ctx, 8.5f, 8.5f);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"tab_lib", img);
}

+ (UIImage *)tabIconSearch {
    UIImage *c = el_cached_icon(@"tab_search");
    if (c) return c;
    CGSize sz = CGSizeMake(24.0f, 24.0f);
    UIGraphicsBeginImageContext(sz);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.3f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, 12, 12));
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, 14.5f, 14.5f);
    CGContextAddLineToPoint(ctx, 20.5f, 20.5f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"tab_search", img);
}

+ (UIImage *)tabIconDownloads {
    UIImage *c = el_cached_icon(@"tab_dl");
    if (c) return c;
    CGSize sz = CGSizeMake(24.0f, 24.0f);
    UIGraphicsBeginImageContext(sz);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.2f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, 12, 3.5f);
    CGContextAddLineToPoint(ctx, 12, 15.0f);
    CGContextMoveToPoint(ctx, 7.5f, 10.5f);
    CGContextAddLineToPoint(ctx, 12, 15.5f);
    CGContextAddLineToPoint(ctx, 16.5f, 10.5f);
    CGContextMoveToPoint(ctx, 4.5f, 16.5f);
    CGContextAddLineToPoint(ctx, 4.5f, 20.0f);
    CGContextAddLineToPoint(ctx, 19.5f, 20.0f);
    CGContextAddLineToPoint(ctx, 19.5f, 16.5f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"tab_dl", img);
}

+ (UIImage *)tabIconAccount {
    UIImage *c = el_cached_icon(@"tab_acct");
    if (c) return c;
    CGSize sz = CGSizeMake(24.0f, 24.0f);
    UIGraphicsBeginImageContext(sz);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(8, 3.5f, 8, 8));
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, 12, 23, 8.5f, (CGFloat)M_PI * 1.15f, (CGFloat)M_PI * 1.85f, 0);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"tab_acct", img);
}

+ (UIImage *)iconPlaySize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"play", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGFloat pad = size * 0.20f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, pad + size * 0.08f, pad);
    CGContextAddLineToPoint(ctx, size - pad + size * 0.05f, size * 0.5f);
    CGContextAddLineToPoint(ctx, pad + size * 0.08f, size - pad);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconPauseSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"pause", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGFloat padY = size * 0.21f;
    CGFloat barW = size * 0.18f;
    CGFloat h = size - padY * 2.0f;
    CGContextFillRect(ctx, CGRectMake(size * 0.25f, padY, barW, h));
    CGContextFillRect(ctx, CGRectMake(size * 0.57f, padY, barW, h));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconNextSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"next", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGFloat padY = size * 0.24f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, size * 0.18f, padY);
    CGContextAddLineToPoint(ctx, size * 0.68f, size * 0.5f);
    CGContextAddLineToPoint(ctx, size * 0.18f, size - padY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextFillRect(ctx, CGRectMake(size * 0.72f, padY, size * 0.12f, size - padY * 2.0f));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconPrevSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"prev", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGFloat padY = size * 0.24f;
    CGContextFillRect(ctx, CGRectMake(size * 0.16f, padY, size * 0.12f, size - padY * 2.0f));
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, size * 0.82f, padY);
    CGContextAddLineToPoint(ctx, size * 0.32f, size * 0.5f);
    CGContextAddLineToPoint(ctx, size * 0.82f, size - padY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconDownloadSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"dl", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, size * 0.5f, size * 0.18f);
    CGContextAddLineToPoint(ctx, size * 0.5f, size * 0.66f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.48f);
    CGContextAddLineToPoint(ctx, size * 0.5f, size * 0.68f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.48f);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.82f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.82f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconCheckSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"chk", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 2.3f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.52f);
    CGContextAddLineToPoint(ctx, size * 0.42f, size * 0.74f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.30f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconCheckCircleSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"chkcirc", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGFloat lw = (size >= 20.0f) ? 1.8f : 1.5f;
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGFloat pad = size * 0.12f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake(pad, pad, size - pad * 2.0f, size - pad * 2.0f));
    CGContextMoveToPoint(ctx, size * 0.31f, size * 0.51f);
    CGContextAddLineToPoint(ctx, size * 0.44f, size * 0.65f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.37f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconCloseSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"close", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 2.2f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.38f);
    CGContextAddLineToPoint(ctx, size * 0.50f, size * 0.66f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.38f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconShuffleSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"shuf", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 1.9f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    /* Top-left to bottom-right path */
    CGContextMoveToPoint(ctx, size * 0.16f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.36f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.64f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.82f, size * 0.70f);
    /* Bottom-left to top-right path */
    CGContextMoveToPoint(ctx, size * 0.16f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.36f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.64f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.82f, size * 0.30f);
    /* Arrowheads */
    CGContextMoveToPoint(ctx, size * 0.72f, size * 0.20f);
    CGContextAddLineToPoint(ctx, size * 0.84f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.72f, size * 0.40f);
    CGContextMoveToPoint(ctx, size * 0.72f, size * 0.60f);
    CGContextAddLineToPoint(ctx, size * 0.84f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.72f, size * 0.80f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconRepeatSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"rep", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 1.9f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    /* Top rail right */
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.44f);
    CGContextAddLineToPoint(ctx, size * 0.20f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.30f);
    CGContextMoveToPoint(ctx, size * 0.68f, size * 0.20f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.30f);
    CGContextAddLineToPoint(ctx, size * 0.68f, size * 0.40f);
    /* Bottom rail left */
    CGContextMoveToPoint(ctx, size * 0.80f, size * 0.56f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.22f, size * 0.70f);
    CGContextMoveToPoint(ctx, size * 0.32f, size * 0.60f);
    CGContextAddLineToPoint(ctx, size * 0.20f, size * 0.70f);
    CGContextAddLineToPoint(ctx, size * 0.32f, size * 0.80f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconQueueSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"queue", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 2.1f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.28f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.28f);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.50f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.50f);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.72f);
    CGContextAddLineToPoint(ctx, size * 0.64f, size * 0.72f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconHeartOutlineSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"heart_out", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGFloat lw = size * 0.09f;
    if (lw < 1.7f) lw = 1.7f;
    CGContextSetLineWidth(ctx, lw);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    el_add_heart_path(ctx, size);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconHeartFilledSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"heart_fill", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    [color setStroke];
    CGContextSetLineWidth(ctx, 0.9f);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    el_add_heart_path(ctx, size);
    CGContextDrawPath(ctx, kCGPathFillStroke);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconSyncSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"sync", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, 1.9f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    CGFloat cx = size * 0.50f;
    CGFloat cy = size * 0.50f;
    CGFloat r = size * 0.33f;

    /* Upper clockwise arc + right arrowhead */
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, cx, cy, r, (CGFloat)M_PI * 1.12f, (CGFloat)M_PI * 1.88f, 0);
    CGContextStrokePath(ctx);
    CGFloat ax1 = cx + r * cosf((float)M_PI * 1.88f);
    CGFloat ay1 = cy + r * sinf((float)M_PI * 1.88f);
    CGContextMoveToPoint(ctx, ax1 - size * 0.14f, ay1 - size * 0.02f);
    CGContextAddLineToPoint(ctx, ax1 + size * 0.02f, ay1 + size * 0.03f);
    CGContextAddLineToPoint(ctx, ax1 + size * 0.03f, ay1 - size * 0.14f);
    CGContextStrokePath(ctx);

    /* Lower clockwise arc + left arrowhead */
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, cx, cy, r, (CGFloat)M_PI * 0.12f, (CGFloat)M_PI * 0.88f, 0);
    CGContextStrokePath(ctx);
    CGFloat ax2 = cx + r * cosf((float)M_PI * 0.88f);
    CGFloat ay2 = cy + r * sinf((float)M_PI * 0.88f);
    CGContextMoveToPoint(ctx, ax2 + size * 0.14f, ay2 + size * 0.02f);
    CGContextAddLineToPoint(ctx, ax2 - size * 0.02f, ay2 - size * 0.03f);
    CGContextAddLineToPoint(ctx, ax2 - size * 0.03f, ay2 + size * 0.14f);
    CGContextStrokePath(ctx);

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)sliderTrackImageWithColor:(UIColor *)color {
    NSString *k = el_icon_key(@"strack_r", 10.0f, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(10.0f, 5.0f));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, 10.0f, 5.0f), 2.5f);
    CGContextFillPath(ctx);
    UIImage *img = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:4 topCapHeight:0];
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)sliderThumbImage {
    UIImage *c = el_cached_icon(@"sthumb");
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(14.0f, 14.0f));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(1.0f, 1.0f, 12.0f, 12.0f));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(@"sthumb", img);
}

+ (UIImage *)circlePillImageWithSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"cpill", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(0.0f, 0.0f, size, size));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)stretchablePillImageWithHeight:(CGFloat)height color:(UIColor *)color {
    NSString *k = el_icon_key(@"spill", height, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    CGFloat w = height + 4.0f;
    UIGraphicsBeginImageContext(CGSizeMake(w, height));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, w, height), height * 0.5f);
    CGContextFillPath(ctx);
    NSInteger cap = (NSInteger)(height * 0.5f);
    UIImage *img = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:cap topCapHeight:0];
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)stretchableCardImageWithColor:(UIColor *)color {
    NSString *k = el_icon_key(@"scard", 10.0f, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    CGFloat dim = 24.0f;
    CGFloat radius = 10.0f;
    UIGraphicsBeginImageContext(CGSizeMake(dim, dim));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, dim, dim), radius);
    CGContextFillPath(ctx);
    UIImage *img = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:11 topCapHeight:11];
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconSearchSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"search", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, size * 0.11f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(size * 0.16f, size * 0.16f, size * 0.48f, size * 0.48f));
    CGContextMoveToPoint(ctx, size * 0.59f, size * 0.59f);
    CGContextAddLineToPoint(ctx, size * 0.84f, size * 0.84f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconMoreSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"more", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    CGFloat d = size * 0.16f;
    CGFloat cy = (size - d) * 0.5f;
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.18f - d * 0.5f, cy, d, d));
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.50f - d * 0.5f, cy, d, d));
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.82f - d * 0.5f, cy, d, d));
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)iconLyricsSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"lyrics", size, color);
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(CGSizeMake(size, size));
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setStroke];
    CGContextSetLineWidth(ctx, size * 0.10f);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    el_add_rounded_rect_path(ctx, CGRectMake(size * 0.14f, size * 0.18f, size * 0.72f, size * 0.64f), size * 0.14f);
    CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.38f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.38f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.52f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.52f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.66f);
    CGContextAddLineToPoint(ctx, size * 0.54f, size * 0.66f);
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)roundedRectImageWithSize:(CGSize)size radius:(CGFloat)radius fillColor:(UIColor *)fillColor borderColor:(UIColor *)borderColor {
    NSString *k = [NSString stringWithFormat:@"rrect_%dx%d_%d_%@_%@",
                   (int)(size.width + 0.5f), (int)(size.height + 0.5f), (int)(radius + 0.5f),
                   el_color_hex(fillColor), borderColor ? el_color_hex(borderColor) : @"none"];
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIGraphicsBeginImageContext(size);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect rect = CGRectMake(0.0f, 0.0f, size.width, size.height);
    if (borderColor) {
        CGRect inset = CGRectInset(rect, 0.5f, 0.5f);
        el_add_rounded_rect_path(ctx, inset, radius);
        [fillColor setFill];
        [borderColor setStroke];
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextDrawPath(ctx, kCGPathFillStroke);
    } else {
        el_add_rounded_rect_path(ctx, rect, radius);
        [fillColor setFill];
        CGContextFillPath(ctx);
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (void)clearThumbnailCache {
    @synchronized(self) {
        [g_thumb_cache removeAllObjects];
        [g_thumb_lru removeAllObjects];
    }
}

+ (void)ensureThumbCacheReady {
    @synchronized(self) {
        if (!g_thumb_cache) g_thumb_cache = [[NSMutableDictionary alloc] initWithCapacity:EL_MAX_ROUNDED_THUMBS];
        if (!g_thumb_lru) g_thumb_lru = [[NSMutableArray alloc] initWithCapacity:EL_MAX_ROUNDED_THUMBS];
        if (!g_thumb_observer_registered) {
            g_thumb_observer_registered = YES;
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(clearThumbnailCache)
                                                         name:UIApplicationDidReceiveMemoryWarningNotification
                                                       object:nil];
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(clearThumbnailCache)
                                                         name:UIApplicationDidEnterBackgroundNotification
                                                       object:nil];
        }
    }
}

+ (UIImage *)roundedPlaceholderArtSize:(CGFloat)size radius:(CGFloat)radius {
    if (size <= 0.0f) size = 44.0f;
    if (size > 512.0f) size = 512.0f;
    NSString *k = [NSString stringWithFormat:@"rph_%d_%d", (int)(size + 0.5f), (int)(radius + 0.5f)];
    UIImage *c = el_cached_icon(k);
    if (c) return c;
    UIImage *base = [self placeholderArtImage];
    CGImageRef cgImg = [base CGImage];
    size_t px = (size_t)(size + 0.5f);
    if (px == 0) px = 1;
    if (px > 512) px = 512;
    CGFloat fSize = (CGFloat)px;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs || !cgImg) {
        if (cs) CGColorSpaceRelease(cs);
        return base;
    }
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             px,
                                             px,
                                             8,
                                             px * 4,
                                             cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) return base;
    CGContextClearRect(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize));
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize), radius);
    CGContextClip(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize), cgImg);
    CGImageRef cgOut = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    UIImage *img = nil;
    if (cgOut) {
        img = [UIImage imageWithCGImage:cgOut];
        CGImageRelease(cgOut);
    }
    return el_store_icon(k, img ? img : base);
}

+ (UIImage *)cachedRoundedThumbnailForSize:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey {
    if ([cacheKey length] == 0 || size <= 0.0f) {
        return nil;
    }
    [self ensureThumbCacheReady];
    NSString *fullKey = [NSString stringWithFormat:@"%d_%d_%@", (int)(size + 0.5f), (int)(radius + 0.5f), cacheKey];
    @synchronized(self) {
        UIImage *hit = [g_thumb_cache objectForKey:fullKey];
        if (hit) {
            [[hit retain] autorelease];
            [g_thumb_lru removeObject:fullKey];
            [g_thumb_lru addObject:fullKey];
            return hit;
        }
    }
    return nil;
}

+ (UIImage *)roundedThumbnailFromImage:(UIImage *)image size:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey {
    if (!image || size <= 0.0f) {
        return [self roundedPlaceholderArtSize:size radius:radius];
    }
    CGImageRef cgImg = [image CGImage];
    if (!cgImg) {
        return [self roundedPlaceholderArtSize:size radius:radius];
    }
    CGFloat srcW = (CGFloat)CGImageGetWidth(cgImg);
    CGFloat srcH = (CGFloat)CGImageGetHeight(cgImg);
    if (srcW <= 0.0f || srcH <= 0.0f) {
        return [self roundedPlaceholderArtSize:size radius:radius];
    }

    UIImage *cachedHit = [self cachedRoundedThumbnailForSize:size radius:radius cacheKey:cacheKey];
    if (cachedHit) {
        return cachedHit;
    }

    size_t px = (size_t)(size + 0.5f);
    if (px == 0) px = 1;
    if (px > 512) px = 512;
    CGFloat fSize = (CGFloat)px;

    /* Aspect-fill center crop + rounded clip in one pure CoreGraphics pass (100% thread-safe on any worker thread) */
    CGFloat scaleX = fSize / srcW;
    CGFloat scaleY = fSize / srcH;
    CGFloat scale = (scaleX > scaleY) ? scaleX : scaleY;
    CGFloat drawW = srcW * scale;
    CGFloat drawH = srcH * scale;
    CGFloat drawX = (fSize - drawW) * 0.5f;
    CGFloat drawY = (fSize - drawH) * 0.5f;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        return [self roundedPlaceholderArtSize:size radius:radius];
    }
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             px,
                                             px,
                                             8,
                                             px * 4,
                                             cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        return [self roundedPlaceholderArtSize:size radius:radius];
    }

    CGContextClearRect(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize));
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, fSize, fSize), radius);
    CGContextClip(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(drawX, drawY, drawW, drawH), cgImg);

    CGImageRef cgOut = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    UIImage *out = nil;
    if (cgOut) {
        out = [UIImage imageWithCGImage:cgOut];
        CGImageRelease(cgOut);
    }

    if (out && [cacheKey length] > 0) {
        NSString *fullKey = [NSString stringWithFormat:@"%d_%d_%@", (int)(size + 0.5f), (int)(radius + 0.5f), cacheKey];
        @synchronized(self) {
            [g_thumb_cache setObject:out forKey:fullKey];
            [g_thumb_lru removeObject:fullKey];
            [g_thumb_lru addObject:fullKey];
            while ([g_thumb_lru count] > EL_MAX_ROUNDED_THUMBS) {
                NSString *evict = [g_thumb_lru objectAtIndex:0];
                [g_thumb_cache removeObjectForKey:evict];
                [g_thumb_lru removeObjectAtIndex:0];
            }
        }
    }
    return out ? out : [self roundedPlaceholderArtSize:size radius:radius];
}

@end
