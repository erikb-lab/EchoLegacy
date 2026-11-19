#import <UIKit/UIKit.h>
#import "ELFeatures.h"

#if EL_FEATURE_LOCAL_PLAYLISTS

@interface ELLocalPlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate> {
    NSString *_playlistId;
    NSArray *_tracks;
    UITableView *_tableView;
    UILabel *_emptyLabel;
    UIView *_renameBar;
    UITextField *_renameField;
    BOOL _showingRenameBar;
}

- (id)initWithPlaylistId:(NSString *)playlistId;

@end

#endif
