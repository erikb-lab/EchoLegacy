#import <UIKit/UIKit.h>

@interface ELDownloadsVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UITableView *_tableView;
    UILabel *_emptyLabel;
    NSArray *_tracks;
}

@end
