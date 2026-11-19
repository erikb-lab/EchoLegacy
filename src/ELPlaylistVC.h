#import <UIKit/UIKit.h>
#import "ELFeatures.h"
#import "ELTrack.h"

@interface ELPlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    ELPlaylist *_playlist;
    NSMutableArray *_tracks;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    UILabel *_headerInfoLabel;
#if EL_FEATURE_DOWNLOADS
    UIButton *_downloadPlaylistBtn;
    NSInteger _dlBtnState;
    NSInteger _dlBtnCompleted;
    NSInteger _dlBtnTotal;
#endif
    NSInteger _loadGen;
    BOOL _isLoadingMore;
    BOOL _needsRefresh;
}

- (id)initWithPlaylist:(ELPlaylist *)playlist;

@end
