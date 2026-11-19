#import <UIKit/UIKit.h>

@interface ELSearchVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate> {
    UIView *_searchBarContainer;
    UITextField *_searchField;
    UITableView *_tableView;
    UIView *_historyHeader;
    UIActivityIndicatorView *_spinner;
    UILabel *_hintLabel;
    NSArray *_results;
    NSMutableArray *_recentQueries;
    NSMutableDictionary *_searchCache;
    NSMutableArray *_searchCacheLRU;
    BOOL _showingHistory;
    BOOL _historyLoaded;
    BOOL _needsRefresh;
    NSInteger _searchToken;
}

@end
