#import <UIKit/UIKit.h>
#import "ELTrack.h"

@interface ELPlaylistVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    ELPlaylist *_playlist;
    NSArray *_tracks;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
}

- (id)initWithPlaylist:(ELPlaylist *)playlist;

@end
