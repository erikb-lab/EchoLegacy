#import <UIKit/UIKit.h>

@interface ELSearchVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate> {
    UISearchBar *_searchBar;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    UILabel *_hintLabel;
    NSArray *_results;
    NSMutableArray *_recentQueries;
    BOOL _showingHistory;
    NSInteger _searchToken;
}

@end
