#import <UIKit/UIKit.h>
#import "ELFeatures.h"

@interface ELDownloadsVC : UIViewController <UITableViewDataSource, UITableViewDelegate
#if EL_FEATURE_LOCAL_PLAYLISTS
, UITextFieldDelegate
#endif
> {
    UITableView *_tableView;
    UILabel *_emptyLabel;
    UIView *_downloadsHeader;
    UILabel *_downloadsInfoLabel;
    NSArray *_tracks;
    BOOL _needsRefresh;
#if EL_FEATURE_LOCAL_PLAYLISTS
    NSArray *_localPlaylists;
    UIView *_newPlaylistBar;
    UITextField *_newPlaylistField;
    BOOL _showingNewPlaylistBar;
#endif
}

@end
