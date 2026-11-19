#import <UIKit/UIKit.h>
#import "ELFeatures.h"

@interface ELSearchVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate> {
    UIView *_searchBarContainer;
    UITextField *_searchField;
    UIView *_filterBar;
    NSMutableArray *_filterButtons;
    UITableView *_tableView;
    UIView *_historyHeader;
    UIView *_suggestionsHeader;
#if EL_FEATURE_DOWNLOADS
    UIView *_offlineHeader;
    UIView *_onlineHeader;
    NSArray *_offlineMatches;
#endif
    UIActivityIndicatorView *_spinner;
    UILabel *_hintLabel;
    NSArray *_results;
    NSArray *_suggestions;
    NSMutableArray *_recentQueries;
    NSMutableDictionary *_searchCache;
    NSMutableArray *_searchCacheLRU;
    NSInteger _mode;       /* 0 = history, 1 = suggest, 2 = results */
    NSInteger _filterMode; /* 0 = All, 1 = Songs, 2 = No Shorts */
    BOOL _historyLoaded;
    BOOL _needsRefresh;
    NSInteger _searchToken;
    NSInteger _suggestToken;
}

@end
