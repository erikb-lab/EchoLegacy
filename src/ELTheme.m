#import "ELTheme.h"
#include <math.h>
#include <pthread.h>
#include <string.h>

#define EL_MAX_ROUNDED_THUMBS 128

static pthread_mutex_t g_icon_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_thumb_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_backdrop_lock = PTHREAD_MUTEX_INITIALIZER;

static NSMutableDictionary *g_icon_cache = nil;
static NSMutableDictionary *g_thumb_cache = nil;
static NSMutableArray *g_thumb_lru = nil;
static NSMutableDictionary *g_backdrop_cache = nil;

static CGFloat el_clampf(CGFloat v, CGFloat lo, CGFloat hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static UIColor *el_static_color(UIColor **slot, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    if (!*slot) {
        *slot = [[UIColor colorWithRed:r green:g blue:b alpha:a] retain];
    }
    return *slot;
}

static void el_color_rgba(UIColor *color, CGFloat *outR, CGFloat *outG, CGFloat *outB, CGFloat *outA) {
    CGFloat r = 0.0f, g = 0.0f, b = 0.0f, a = 1.0f;
    CGColorRef cg = color ? [color CGColor] : NULL;
    if (cg) {
        const CGFloat *comps = CGColorGetComponents(cg);
        size_t n = CGColorGetNumberOfComponents(cg);
        if (n >= 4) {
            r = comps[0]; g = comps[1]; b = comps[2]; a = comps[3];
        } else if (n == 3) {
            r = comps[0]; g = comps[1]; b = comps[2];
        } else if (n == 2) {
            r = comps[0]; g = comps[0]; b = comps[0]; a = comps[1];
        } else if (n == 1) {
            r = comps[0]; g = comps[0]; b = comps[0];
        }
    }
    if (outR) *outR = r;
    if (outG) *outG = g;
    if (outB) *outB = b;
    if (outA) *outA = a;
}

static int el_unit_to_byte(CGFloat v) {
    int n = (int)(v * 255.0f + 0.5f);
    if (n < 0) return 0;
    if (n > 255) return 255;
    return n;
}

static NSString *el_color_hex(UIColor *color) {
    CGFloat rf, gf, bf, af;
    el_color_rgba(color, &rf, &gf, &bf, &af);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x",
            el_unit_to_byte(rf),
            el_unit_to_byte(gf),
            el_unit_to_byte(bf),
            el_unit_to_byte(af)];
}

static NSString *el_icon_key(NSString *name, CGFloat size, UIColor *color) {
    return [NSString stringWithFormat:@"%@_%d_%@", name, (int)(size + 0.5f), el_color_hex(color)];
}

static UIImage *el_cached_icon(NSString *key) {
    if (!key) return nil;
    pthread_mutex_lock(&g_icon_lock);
    UIImage *img = [g_icon_cache objectForKey:key];
    if (img) [[img retain] autorelease];
    pthread_mutex_unlock(&g_icon_lock);
    return img;
}

static UIImage *el_store_icon(NSString *key, UIImage *img) {
    if (!img || !key) return img;
    pthread_mutex_lock(&g_icon_lock);
    if (g_icon_cache) [g_icon_cache setObject:img forKey:key];
    pthread_mutex_unlock(&g_icon_lock);
    return img;
}

/* Returns a cached icon on hit, or opens an image context and returns nil on miss (pair with el_end_icon). */
static UIImage *el_begin_icon(NSString *key, CGSize size, CGContextRef *outCtx) {
    UIImage *cached = el_cached_icon(key);
    if (cached) return cached;
    UIGraphicsBeginImageContext(size);
    if (outCtx) *outCtx = UIGraphicsGetCurrentContext();
    return nil;
}

static UIImage *el_end_icon(NSString *key) {
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return el_store_icon(key, img);
}

static void el_set_stroke(CGContextRef ctx, UIColor *color, CGFloat lineWidth, BOOL roundJoin) {
    [color setStroke];
    CGContextSetLineWidth(ctx, lineWidth);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    if (roundJoin) {
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
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
    radius = el_clampf(radius, 0.0f, maxR);

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

static CGContextRef el_create_bitmap_context(size_t w, size_t h, BOOL opaque) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    CGBitmapInfo info = opaque
        ? (kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little)
        : (kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, info);
    CGColorSpaceRelease(cs);
    return ctx;
}

static UIImage *el_finish_bitmap_context(CGContextRef ctx) {
    CGImageRef cgOut = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!cgOut) return nil;
    UIImage *img = [UIImage imageWithCGImage:cgOut];
    CGImageRelease(cgOut);
    return img;
}

static size_t el_clamp_thumb_px(CGFloat size) {
    size_t px = (size_t)(size + 0.5f);
    if (px == 0) return 1;
    if (px > 512) return 512;
    return px;
}

static UIImage *el_render_rounded_cgimage(CGImageRef cgImg, size_t px, CGFloat radius, CGRect drawRect, UIColor *matteColor) {
    BOOL opaque = (matteColor != nil);
    CGContextRef ctx = el_create_bitmap_context(px, px, opaque);
    if (!ctx) return nil;
    CGFloat fSize = (CGFloat)px;
    CGRect bounds = CGRectMake(0.0f, 0.0f, fSize, fSize);
    if (opaque) {
        CGContextSetFillColorWithColor(ctx, [matteColor CGColor]);
        CGContextFillRect(ctx, bounds);
    } else {
        CGContextClearRect(ctx, bounds);
    }
    el_add_rounded_rect_path(ctx, bounds, radius);
    CGContextClip(ctx);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, drawRect, cgImg);
    return el_finish_bitmap_context(ctx);
}

static NSString *el_thumb_key(CGFloat size, CGFloat radius, UIColor *matteColor, NSString *cacheKey) {
    return [NSString stringWithFormat:@"%d_%d_%@_%@",
            (int)(size + 0.5f),
            (int)(radius + 0.5f),
            matteColor ? el_color_hex(matteColor) : @"clear",
            cacheKey];
}

static float el_max3f(float a, float b, float c) {
    return (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c);
}

static float el_min3f(float a, float b, float c) {
    return (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c);
}

static UIColor *el_backdrop_color_from_rgb(float r, float g, float b) {
    /* Convert RGB -> HSV in plain C (iOS 4.1 safe) */
    float maxC = el_max3f(r, g, b);
    float minC = el_min3f(r, g, b);
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
    s = (s > 0.08f) ? el_clampf(s * 1.05f, 0.28f, 0.62f) : el_clampf(s, 0.0f, 0.12f);
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

@implementation ELTheme

+ (void)initialize {
    if (self == [ELTheme class]) {
        g_icon_cache = [[NSMutableDictionary alloc] initWithCapacity:64];
        g_thumb_cache = [[NSMutableDictionary alloc] initWithCapacity:EL_MAX_ROUNDED_THUMBS];
        g_thumb_lru = [[NSMutableArray alloc] initWithCapacity:EL_MAX_ROUNDED_THUMBS];
        g_backdrop_cache = [[NSMutableDictionary alloc] initWithCapacity:32];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(flushMemoryCaches)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearThumbnailCache)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
}

+ (UIColor *)backgroundColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.051f, 0.051f, 0.071f, 1.0f);
}

+ (UIColor *)surfaceColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.106f, 0.106f, 0.145f, 1.0f);
}

+ (UIColor *)surfaceHighlightColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.165f, 0.165f, 0.220f, 1.0f);
}

+ (UIColor *)separatorColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.155f, 0.155f, 0.205f, 1.0f);
}

+ (UIColor *)accentColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.980f, 0.176f, 0.282f, 1.0f);
}

+ (UIColor *)textPrimaryColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.965f, 0.965f, 0.985f, 1.0f);
}

+ (UIColor *)textSecondaryColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.590f, 0.590f, 0.670f, 1.0f);
}

+ (UIColor *)successColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.204f, 0.827f, 0.600f, 1.0f);
}

+ (UIColor *)defaultBackdropColor {
    static UIColor *c = nil;
    return el_static_color(&c, 0.145f, 0.115f, 0.180f, 1.0f);
}

+ (UIColor *)dominantBackdropColorFromImage:(UIImage *)image cacheKey:(NSString *)cacheKey {
    BOOL hasKey = ([cacheKey length] > 0);
    if (hasKey) {
        pthread_mutex_lock(&g_backdrop_lock);
        UIColor *hit = [g_backdrop_cache objectForKey:cacheKey];
        if (hit) [[hit retain] autorelease];
        pthread_mutex_unlock(&g_backdrop_lock);
        if (hit) return hit;
    }
    UIColor *col = [self dominantBackdropColorFromImage:image];
    if (col && hasKey && image && image != [self placeholderArtImage]) {
        pthread_mutex_lock(&g_backdrop_lock);
        if ([g_backdrop_cache count] > 32) [g_backdrop_cache removeAllObjects];
        [g_backdrop_cache setObject:col forKey:cacheKey];
        pthread_mutex_unlock(&g_backdrop_lock);
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
            float r = el_clampf((float)pixels[idx + 0] * invA, 0.0f, 1.0f);
            float g = el_clampf((float)pixels[idx + 1] * invA, 0.0f, 1.0f);
            float b = el_clampf((float)pixels[idx + 2] * invA, 0.0f, 1.0f);

            float chroma = el_max3f(r, g, b) - el_min3f(r, g, b);
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

    if (sumW > 0.001f) {
        return el_backdrop_color_from_rgb(sumR / sumW, sumG / sumW, sumB / sumW);
    }
    if (allW > 0.001f) {
        return el_backdrop_color_from_rgb(allR / allW, allG / allW, allB / allW);
    }
    return [self defaultBackdropColor];
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
    navBar.barStyle = UIBarStyleBlack;
    navBar.tintColor = el_static_color(&navTint, 0.095f, 0.095f, 0.135f, 1.0f);
}

+ (UIButton *)pillButtonWithTitle:(NSString *)title color:(UIColor *)color frame:(CGRect)frame {
    static UIColor *hiTextColor = nil;
    el_static_color(&hiTextColor, 1.0f, 1.0f, 1.0f, 0.60f);

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = [UIColor clearColor];
    UIImage *bgNorm = [self stretchablePillImageWithHeight:frame.size.height color:color];
    UIImage *bgHi = [self stretchablePillImageWithHeight:frame.size.height color:[self darkerShadeOfColor:color factor:0.78f]];
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
    CGContextRef ctx = el_create_bitmap_context(px, px, YES);
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

    return el_store_icon(@"placeholder_art", el_finish_bitmap_context(ctx));
}

+ (UIImage *)tabIconHome {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"tab_home", CGSizeMake(24.0f, 24.0f), &ctx);
    if (c) return c;
    el_set_stroke(ctx, [UIColor whiteColor], 2.0f, YES);
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
    return el_end_icon(@"tab_home");
}

+ (UIImage *)tabIconLibrary {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"tab_lib", CGSizeMake(24.0f, 24.0f), &ctx);
    if (c) return c;
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
    return el_end_icon(@"tab_lib");
}

+ (UIImage *)tabIconSearch {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"tab_search", CGSizeMake(24.0f, 24.0f), &ctx);
    if (c) return c;
    el_set_stroke(ctx, [UIColor whiteColor], 2.3f, NO);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(4, 4, 12, 12));
    CGContextMoveToPoint(ctx, 14.5f, 14.5f);
    CGContextAddLineToPoint(ctx, 20.5f, 20.5f);
    CGContextStrokePath(ctx);
    return el_end_icon(@"tab_search");
}

+ (UIImage *)tabIconDownloads {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"tab_dl", CGSizeMake(24.0f, 24.0f), &ctx);
    if (c) return c;
    el_set_stroke(ctx, [UIColor whiteColor], 2.2f, YES);
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
    return el_end_icon(@"tab_dl");
}

+ (UIImage *)tabIconAccount {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"tab_acct", CGSizeMake(24.0f, 24.0f), &ctx);
    if (c) return c;
    [[UIColor whiteColor] setStroke];
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(8, 3.5f, 8, 8));
    CGContextBeginPath(ctx);
    CGContextAddArc(ctx, 12, 23, 8.5f, (CGFloat)M_PI * 1.15f, (CGFloat)M_PI * 1.85f, 0);
    CGContextStrokePath(ctx);
    return el_end_icon(@"tab_acct");
}

+ (UIImage *)iconPlaySize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"play", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGFloat pad = size * 0.20f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, pad + size * 0.08f, pad);
    CGContextAddLineToPoint(ctx, size - pad + size * 0.05f, size * 0.5f);
    CGContextAddLineToPoint(ctx, pad + size * 0.08f, size - pad);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconPauseSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"pause", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGFloat padY = size * 0.21f;
    CGFloat barW = size * 0.18f;
    CGFloat h = size - padY * 2.0f;
    CGContextFillRect(ctx, CGRectMake(size * 0.25f, padY, barW, h));
    CGContextFillRect(ctx, CGRectMake(size * 0.57f, padY, barW, h));
    return el_end_icon(k);
}

+ (UIImage *)iconNextSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"next", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGFloat padY = size * 0.24f;
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, size * 0.18f, padY);
    CGContextAddLineToPoint(ctx, size * 0.68f, size * 0.5f);
    CGContextAddLineToPoint(ctx, size * 0.18f, size - padY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextFillRect(ctx, CGRectMake(size * 0.72f, padY, size * 0.12f, size - padY * 2.0f));
    return el_end_icon(k);
}

+ (UIImage *)iconPrevSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"prev", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGFloat padY = size * 0.24f;
    CGContextFillRect(ctx, CGRectMake(size * 0.16f, padY, size * 0.12f, size - padY * 2.0f));
    CGContextBeginPath(ctx);
    CGContextMoveToPoint(ctx, size * 0.82f, padY);
    CGContextAddLineToPoint(ctx, size * 0.32f, size * 0.5f);
    CGContextAddLineToPoint(ctx, size * 0.82f, size - padY);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconDownloadSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"dl", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 2.0f, YES);
    CGContextMoveToPoint(ctx, size * 0.5f, size * 0.18f);
    CGContextAddLineToPoint(ctx, size * 0.5f, size * 0.66f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.48f);
    CGContextAddLineToPoint(ctx, size * 0.5f, size * 0.68f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.48f);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.82f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.82f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconCheckSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"chk", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 2.3f, YES);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.52f);
    CGContextAddLineToPoint(ctx, size * 0.42f, size * 0.74f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.30f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconCheckCircleSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"chkcirc", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, (size >= 20.0f) ? 1.8f : 1.5f, YES);
    CGFloat pad = size * 0.12f;
    CGContextStrokeEllipseInRect(ctx, CGRectMake(pad, pad, size - pad * 2.0f, size - pad * 2.0f));
    CGContextMoveToPoint(ctx, size * 0.31f, size * 0.51f);
    CGContextAddLineToPoint(ctx, size * 0.44f, size * 0.65f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.37f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconCloseSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"close", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 2.2f, YES);
    CGContextMoveToPoint(ctx, size * 0.22f, size * 0.38f);
    CGContextAddLineToPoint(ctx, size * 0.50f, size * 0.66f);
    CGContextAddLineToPoint(ctx, size * 0.78f, size * 0.38f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconShuffleSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"shuf", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 1.9f, YES);
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
    return el_end_icon(k);
}

+ (UIImage *)iconRepeatSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"rep", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 1.9f, YES);
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
    return el_end_icon(k);
}

+ (UIImage *)iconQueueSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"queue", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 2.1f, NO);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.28f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.28f);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.50f);
    CGContextAddLineToPoint(ctx, size * 0.80f, size * 0.50f);
    CGContextMoveToPoint(ctx, size * 0.20f, size * 0.72f);
    CGContextAddLineToPoint(ctx, size * 0.64f, size * 0.72f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconHeartOutlineSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"heart_out", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    CGFloat lw = size * 0.09f;
    if (lw < 1.7f) lw = 1.7f;
    el_set_stroke(ctx, color, lw, YES);
    el_add_heart_path(ctx, size);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconHeartFilledSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"heart_fill", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    [color setStroke];
    CGContextSetLineWidth(ctx, 0.9f);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    el_add_heart_path(ctx, size);
    CGContextDrawPath(ctx, kCGPathFillStroke);
    return el_end_icon(k);
}

+ (UIImage *)iconSyncSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"sync", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, 1.9f, YES);

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

    return el_end_icon(k);
}

+ (UIImage *)sliderTrackImageWithColor:(UIColor *)color {
    NSString *k = el_icon_key(@"strack_r", 10.0f, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(10.0f, 5.0f), &ctx);
    if (c) return c;
    [color setFill];
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, 10.0f, 5.0f), 2.5f);
    CGContextFillPath(ctx);
    UIImage *img = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:4 topCapHeight:0];
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)sliderThumbImage {
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(@"sthumb", CGSizeMake(14.0f, 14.0f), &ctx);
    if (c) return c;
    [[UIColor whiteColor] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(1.0f, 1.0f, 12.0f, 12.0f));
    return el_end_icon(@"sthumb");
}

+ (UIImage *)circlePillImageWithSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"cpill", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(0.0f, 0.0f, size, size));
    return el_end_icon(k);
}

+ (UIImage *)stretchablePillImageWithHeight:(CGFloat)height color:(UIColor *)color {
    NSString *k = el_icon_key(@"spill", height, color);
    CGFloat w = height + 4.0f;
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(w, height), &ctx);
    if (c) return c;
    [color setFill];
    el_add_rounded_rect_path(ctx, CGRectMake(0.0f, 0.0f, w, height), height * 0.5f);
    CGContextFillPath(ctx);
    NSInteger cap = (NSInteger)(height * 0.5f);
    UIImage *img = [UIGraphicsGetImageFromCurrentImageContext() stretchableImageWithLeftCapWidth:cap topCapHeight:0];
    UIGraphicsEndImageContext();
    return el_store_icon(k, img);
}

+ (UIImage *)stretchableCardImageWithColor:(UIColor *)color {
    NSString *k = el_icon_key(@"scard_bg", 10.0f, color);
    UIImage *cached = el_cached_icon(k);
    if (cached) return cached;

    const size_t dim = 24;
    CGContextRef ctx = el_create_bitmap_context(dim, dim, YES);
    if (!ctx) return nil;
    CGRect bounds = CGRectMake(0.0f, 0.0f, (CGFloat)dim, (CGFloat)dim);
    CGContextSetFillColorWithColor(ctx, [[self backgroundColor] CGColor]);
    CGContextFillRect(ctx, bounds);
    CGContextSetFillColorWithColor(ctx, [color CGColor]);
    el_add_rounded_rect_path(ctx, bounds, 10.0f);
    CGContextFillPath(ctx);

    UIImage *raw = el_finish_bitmap_context(ctx);
    UIImage *img = raw ? [raw stretchableImageWithLeftCapWidth:11 topCapHeight:11] : nil;
    return el_store_icon(k, img);
}

+ (UIImage *)iconSearchSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"search", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, size * 0.11f, NO);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(size * 0.16f, size * 0.16f, size * 0.48f, size * 0.48f));
    CGContextMoveToPoint(ctx, size * 0.59f, size * 0.59f);
    CGContextAddLineToPoint(ctx, size * 0.84f, size * 0.84f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)iconMoreSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"more", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    [color setFill];
    CGFloat d = size * 0.16f;
    CGFloat cy = (size - d) * 0.5f;
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.18f - d * 0.5f, cy, d, d));
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.50f - d * 0.5f, cy, d, d));
    CGContextFillEllipseInRect(ctx, CGRectMake(size * 0.82f - d * 0.5f, cy, d, d));
    return el_end_icon(k);
}

+ (UIImage *)iconLyricsSize:(CGFloat)size color:(UIColor *)color {
    NSString *k = el_icon_key(@"lyrics", size, color);
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(size, size), &ctx);
    if (c) return c;
    el_set_stroke(ctx, color, size * 0.10f, YES);
    el_add_rounded_rect_path(ctx, CGRectMake(size * 0.14f, size * 0.18f, size * 0.72f, size * 0.64f), size * 0.14f);
    CGContextStrokePath(ctx);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.38f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.38f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.52f);
    CGContextAddLineToPoint(ctx, size * 0.70f, size * 0.52f);
    CGContextMoveToPoint(ctx, size * 0.30f, size * 0.66f);
    CGContextAddLineToPoint(ctx, size * 0.54f, size * 0.66f);
    CGContextStrokePath(ctx);
    return el_end_icon(k);
}

+ (UIImage *)roundedRectImageWithSize:(CGSize)size radius:(CGFloat)radius fillColor:(UIColor *)fillColor borderColor:(UIColor *)borderColor {
    NSString *k = [NSString stringWithFormat:@"rrect_%dx%d_%d_%@_%@",
                   (int)(size.width + 0.5f), (int)(size.height + 0.5f), (int)(radius + 0.5f),
                   el_color_hex(fillColor), borderColor ? el_color_hex(borderColor) : @"none"];
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, size, &ctx);
    if (c) return c;
    CGRect rect = CGRectMake(0.0f, 0.0f, size.width, size.height);
    if (borderColor) {
        el_add_rounded_rect_path(ctx, CGRectInset(rect, 0.5f, 0.5f), radius);
        [fillColor setFill];
        [borderColor setStroke];
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextDrawPath(ctx, kCGPathFillStroke);
    } else {
        el_add_rounded_rect_path(ctx, rect, radius);
        [fillColor setFill];
        CGContextFillPath(ctx);
    }
    return el_end_icon(k);
}

+ (UIImage *)artShadowFrameImageWithSize:(CGFloat)size radius:(CGFloat)radius {
    if (size < 16.0f) size = 16.0f;
    if (size > 320.0f) size = 320.0f;
    const CGFloat pad = 12.0f;
    CGFloat total = size + pad * 2.0f;
    NSString *k = [NSString stringWithFormat:@"artframe_%d_%d", (int)(size + 0.5f), (int)(radius + 0.5f)];
    CGContextRef ctx = NULL;
    UIImage *c = el_begin_icon(k, CGSizeMake(total, total), &ctx);
    if (c) return c;

    CGRect artRect = CGRectMake(pad, pad, size, size);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0.0f, 5.0f), 9.0f, [[UIColor colorWithWhite:0.0f alpha:0.55f] CGColor]);
    [[UIColor colorWithWhite:0.06f alpha:1.0f] setFill];
    el_add_rounded_rect_path(ctx, artRect, radius);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);

    /* Subtle 1px inner highlight border for crisp framing on dark backdrops */
    [[UIColor colorWithWhite:1.0f alpha:0.14f] setStroke];
    CGContextSetLineWidth(ctx, 1.0f);
    el_add_rounded_rect_path(ctx, CGRectInset(artRect, 0.5f, 0.5f), radius);
    CGContextStrokePath(ctx);

    return el_end_icon(k);
}

+ (UIImage *)verticalGradientImageWithHeight:(CGFloat)h
                                    topColor:(UIColor *)top
                                    midColor:(UIColor *)mid
                                 midLocation:(CGFloat)midLoc
                                 bottomColor:(UIColor *)bottom
                                      opaque:(BOOL)opaque {
    size_t pxH = (size_t)(h + 0.5f);
    if (pxH == 0) pxH = 1;
    if (pxH > 1024) pxH = 1024;

    int midPct = (int)(el_clampf(midLoc, 0.0f, 1.0f) * 100.0f + 0.5f);
    NSString *k = [NSString stringWithFormat:@"vgrad_%u_%d_%@_%@_%d_%@",
                   (unsigned)pxH,
                   opaque ? 1 : 0,
                   el_color_hex(top),
                   mid ? el_color_hex(mid) : @"none",
                   midPct,
                   el_color_hex(bottom)];
    UIImage *cached = el_cached_icon(k);
    if (cached) return cached;

    CGContextRef ctx = el_create_bitmap_context(1, pxH, opaque);
    if (!ctx) return nil;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) {
        CGContextRelease(ctx);
        return nil;
    }

    CGFloat r0, g0, b0, a0;
    CGFloat r2, g2, b2, a2;
    el_color_rgba(top, &r0, &g0, &b0, &a0);
    el_color_rgba(bottom, &r2, &g2, &b2, &a2);

    CGGradientRef grad = NULL;
    if (mid) {
        CGFloat r1, g1, b1, a1;
        el_color_rgba(mid, &r1, &g1, &b1, &a1);
        CGFloat comps[12] = { r0, g0, b0, a0, r1, g1, b1, a1, r2, g2, b2, a2 };
        CGFloat locs[3] = { 0.0f, el_clampf(midLoc, 0.0f, 1.0f), 1.0f };
        grad = CGGradientCreateWithColorComponents(cs, comps, locs, 3);
    } else {
        CGFloat comps[8] = { r0, g0, b0, a0, r2, g2, b2, a2 };
        CGFloat locs[2] = { 0.0f, 1.0f };
        grad = CGGradientCreateWithColorComponents(cs, comps, locs, 2);
    }
    CGColorSpaceRelease(cs);

    if (grad) {
        /* CGBitmapContext origin is bottom-left: y = pxH is top, y = 0 is bottom */
        CGContextDrawLinearGradient(ctx,
                                    grad,
                                    CGPointMake(0.0f, (CGFloat)pxH),
                                    CGPointMake(0.0f, 0.0f),
                                    0);
        CGGradientRelease(grad);
    }
    UIImage *img = el_finish_bitmap_context(ctx);
    return el_store_icon(k, img);
}

+ (void)clearThumbnailCache {
    pthread_mutex_lock(&g_thumb_lock);
    [g_thumb_cache removeAllObjects];
    [g_thumb_lru removeAllObjects];
    pthread_mutex_unlock(&g_thumb_lock);
}

+ (void)flushMemoryCaches {
    [self clearThumbnailCache];

    pthread_mutex_lock(&g_backdrop_lock);
    [g_backdrop_cache removeAllObjects];
    pthread_mutex_unlock(&g_backdrop_lock);

    pthread_mutex_lock(&g_icon_lock);
    if ([g_icon_cache count] > 0) {
        NSMutableArray *evictKeys = [NSMutableArray array];
        for (NSString *k in g_icon_cache) {
            if ([k hasPrefix:@"vgrad_"] || [k hasPrefix:@"rrect_"] || [k hasPrefix:@"artframe_"]) {
                [evictKeys addObject:k];
            }
        }
        if ([evictKeys count] > 0) {
            [g_icon_cache removeObjectsForKeys:evictKeys];
        }
    }
    pthread_mutex_unlock(&g_icon_lock);
}

+ (UIImage *)roundedPlaceholderArtSize:(CGFloat)size radius:(CGFloat)radius {
    return [self roundedPlaceholderArtSize:size radius:radius matteColor:[self surfaceColor]];
}

+ (UIImage *)roundedPlaceholderArtSize:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor {
    if (size <= 0.0f) size = 44.0f;
    if (size > 512.0f) size = 512.0f;
    NSString *k = [NSString stringWithFormat:@"rph_%d_%d_%@",
                   (int)(size + 0.5f),
                   (int)(radius + 0.5f),
                   matteColor ? el_color_hex(matteColor) : @"clear"];
    UIImage *c = el_cached_icon(k);
    if (c) return c;

    UIImage *base = [self placeholderArtImage];
    CGImageRef cgImg = [base CGImage];
    if (!cgImg) return base;

    size_t px = el_clamp_thumb_px(size);
    CGFloat fSize = (CGFloat)px;
    UIImage *img = el_render_rounded_cgimage(cgImg, px, radius, CGRectMake(0.0f, 0.0f, fSize, fSize), matteColor);
    return el_store_icon(k, img ? img : base);
}

+ (UIImage *)cachedRoundedThumbnailForSize:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey {
    return [self cachedRoundedThumbnailForSize:size radius:radius matteColor:[self surfaceColor] cacheKey:cacheKey];
}

+ (UIImage *)cachedRoundedThumbnailForSize:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor cacheKey:(NSString *)cacheKey {
    if ([cacheKey length] == 0 || size <= 0.0f) {
        return nil;
    }
    NSString *fullKey = el_thumb_key(size, radius, matteColor, cacheKey);
    UIImage *hit = nil;
    pthread_mutex_lock(&g_thumb_lock);
    hit = [g_thumb_cache objectForKey:fullKey];
    if (hit) {
        [[hit retain] autorelease];
        [g_thumb_lru removeObject:fullKey];
        [g_thumb_lru addObject:fullKey];
    }
    pthread_mutex_unlock(&g_thumb_lock);
    return hit;
}

+ (UIImage *)roundedThumbnailFromImage:(UIImage *)image size:(CGFloat)size radius:(CGFloat)radius cacheKey:(NSString *)cacheKey {
    return [self roundedThumbnailFromImage:image size:size radius:radius matteColor:[self surfaceColor] cacheKey:cacheKey];
}

+ (UIImage *)roundedThumbnailFromImage:(UIImage *)image size:(CGFloat)size radius:(CGFloat)radius matteColor:(UIColor *)matteColor cacheKey:(NSString *)cacheKey {
    if (!image || size <= 0.0f) {
        return [self roundedPlaceholderArtSize:size radius:radius matteColor:matteColor];
    }
    CGImageRef cgImg = [image CGImage];
    if (!cgImg) {
        return [self roundedPlaceholderArtSize:size radius:radius matteColor:matteColor];
    }
    CGFloat srcW = (CGFloat)CGImageGetWidth(cgImg);
    CGFloat srcH = (CGFloat)CGImageGetHeight(cgImg);
    if (srcW <= 0.0f || srcH <= 0.0f) {
        return [self roundedPlaceholderArtSize:size radius:radius matteColor:matteColor];
    }

    UIImage *cachedHit = [self cachedRoundedThumbnailForSize:size radius:radius matteColor:matteColor cacheKey:cacheKey];
    if (cachedHit) {
        return cachedHit;
    }

    size_t px = el_clamp_thumb_px(size);
    CGFloat fSize = (CGFloat)px;

    /* Aspect-fill center crop + rounded clip in one pure CoreGraphics pass (100% thread-safe on any worker thread) */
    CGFloat scaleX = fSize / srcW;
    CGFloat scaleY = fSize / srcH;
    CGFloat scale = (scaleX > scaleY) ? scaleX : scaleY;
    CGFloat drawW = srcW * scale;
    CGFloat drawH = srcH * scale;
    CGRect drawRect = CGRectMake((fSize - drawW) * 0.5f, (fSize - drawH) * 0.5f, drawW, drawH);

    UIImage *out = el_render_rounded_cgimage(cgImg, px, radius, drawRect, matteColor);
    if (out && [cacheKey length] > 0) {
        NSString *fullKey = el_thumb_key(size, radius, matteColor, cacheKey);
        pthread_mutex_lock(&g_thumb_lock);
        [g_thumb_cache setObject:out forKey:fullKey];
        [g_thumb_lru removeObject:fullKey];
        [g_thumb_lru addObject:fullKey];
        while ([g_thumb_lru count] > EL_MAX_ROUNDED_THUMBS) {
            NSString *evict = [g_thumb_lru objectAtIndex:0];
            [g_thumb_cache removeObjectForKey:evict];
            [g_thumb_lru removeObjectAtIndex:0];
        }
        pthread_mutex_unlock(&g_thumb_lock);
    }
    return out ? out : [self roundedPlaceholderArtSize:size radius:radius matteColor:matteColor];
}

@end
