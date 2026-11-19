#import <UIKit/UIKit.h>

@interface ELHomeVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UIScrollView *_moodScroll;
    NSMutableArray *_moodButtons;
    UITableView *_tableView;
    UIView *_sectionHeader;
    UIActivityIndicatorView *_spinner;
    UILabel *_emptyLabel;
    NSArray *_moods;
    NSInteger _selectedMoodIndex;
    NSArray *_tracks;
    NSInteger _loadToken;
    BOOL _needsRefresh;
}

@end
