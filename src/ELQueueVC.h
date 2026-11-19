#import <UIKit/UIKit.h>

@interface ELQueueVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UITableView *_tableView;
    UILabel *_headerLabel;
    UIButton *_shuffleBtn;
}

@end
