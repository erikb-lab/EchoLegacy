#import <UIKit/UIKit.h>

@class ELTrack;
@class ELTrackCell;

@interface ELTrackListHelper : NSObject

+ (UITableView *)createTrackTableViewWithFrame:(CGRect)frame
                                      delegate:(id<UITableViewDataSource, UITableViewDelegate>)delegate
                                     rowHeight:(CGFloat)rowHeight;

+ (UILabel *)createEmptyLabelWithFrame:(CGRect)frame
                                  text:(NSString *)text
                              fontSize:(CGFloat)fontSize
                                 lines:(NSInteger)lines;

+ (UIActivityIndicatorView *)createSpinnerAtCenter:(CGPoint)center;

+ (UIView *)createSectionHeaderWithTitle:(NSString *)title height:(CGFloat)height;

+ (ELTrackCell *)dequeueTrackCellForTableView:(UITableView *)tableView track:(ELTrack *)track;

+ (void)refreshVisibleTrackHighlightInTableView:(UITableView *)tableView;

+ (void)refreshVisibleTrackCellsInTableView:(UITableView *)tableView forVideoId:(NSString *)videoId;

@end
