#import <UIKit/UIKit.h>
#import "ELTrack.h"

@interface ELPlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    ELPlaylist *_playlist;
    NSMutableArray *_tracks;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    UILabel *_headerInfoLabel;
    UIButton *_downloadPlaylistBtn;
    NSInteger _loadGen;
    BOOL _isLoadingMore;
}

- (id)initWithPlaylist:(ELPlaylist *)playlist;

@end
