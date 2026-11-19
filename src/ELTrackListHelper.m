#import "ELTrackListHelper.h"
#import "ELAudioEngine.h"
#import "ELFeatures.h"
#import "ELTheme.h"
#import "ELTrack.h"
#import "ELTrackCell.h"

@implementation ELTrackListHelper

+ (UITableView *)createTrackTableViewWithFrame:(CGRect)frame
                                      delegate:(id<UITableViewDataSource, UITableViewDelegate>)delegate
                                     rowHeight:(CGFloat)rowHeight {
    UITableView *tv = [[[UITableView alloc] initWithFrame:frame style:UITableViewStylePlain] autorelease];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.dataSource = delegate;
    tv.delegate = delegate;
    if (rowHeight > 0.0f) {
        tv.rowHeight = rowHeight;
    }
    tv.contentInset = UIEdgeInsetsMake(0.0f, 0.0f, 56.0f, 0.0f);
    tv.scrollIndicatorInsets = tv.contentInset;
    [ELTheme styleTableView:tv];
    return tv;
}

+ (UILabel *)createEmptyLabelWithFrame:(CGRect)frame
                                  text:(NSString *)text
                              fontSize:(CGFloat)fontSize
                                 lines:(NSInteger)lines {
    UILabel *lbl = [[[UILabel alloc] initWithFrame:frame] autorelease];
    lbl.backgroundColor = [UIColor clearColor];
    lbl.font = [UIFont systemFontOfSize:fontSize];
    lbl.textColor = [ELTheme textSecondaryColor];
    lbl.textAlignment = UITextAlignmentCenter;
    lbl.numberOfLines = lines;
    lbl.text = text;
    return lbl;
}

+ (UIActivityIndicatorView *)createSpinnerAtCenter:(CGPoint)center {
    UIActivityIndicatorView *sp = [[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge] autorelease];
    sp.center = center;
    sp.hidesWhenStopped = YES;
    return sp;
}

+ (UIView *)createSectionHeaderWithTitle:(NSString *)title height:(CGFloat)height {
    UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(0.0f, 0.0f, 320.0f, height)] autorelease];
    v.backgroundColor = [ELTheme surfaceColor];
    v.opaque = YES;

    UILabel *lbl = [[[UILabel alloc] initWithFrame:CGRectMake(14.0f, 0.0f, 292.0f, height)] autorelease];
    lbl.backgroundColor = [ELTheme surfaceColor];
    lbl.opaque = YES;
    lbl.font = [UIFont boldSystemFontOfSize:11.0f];
    lbl.textColor = [ELTheme textSecondaryColor];
    lbl.text = title;
    [v addSubview:lbl];
    return v;
}

+ (ELTrackCell *)dequeueTrackCellForTableView:(UITableView *)tableView track:(ELTrack *)track {
    static NSString *cid = @"ELTrackCell";
    ELTrackCell *cell = (ELTrackCell *)[tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[[ELTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid] autorelease];
    }
    ELTrack *cur = [[ELAudioEngine sharedEngine] currentTrack];
    BOOL isCurrent = (cur && [cur.videoId isEqualToString:track.videoId]);
    [cell configureWithTrack:track isCurrent:isCurrent];
    return cell;
}

+ (void)refreshVisibleTrackCellsInTableView:(UITableView *)tableView forVideoId:(NSString *)videoId {
#if EL_FEATURE_DOWNLOADS
    NSArray *cells = [tableView visibleCells];
    for (UITableViewCell *cell in cells) {
        if (![cell isKindOfClass:[ELTrackCell class]]) continue;
        ELTrackCell *tc = (ELTrackCell *)cell;
        if (!videoId || [tc.videoId isEqualToString:videoId]) {
            [tc refreshDownloadState];
        }
    }
#else
    (void)tableView;
    (void)videoId;
#endif
}

@end
