#import <UIKit/UIKit.h>

@interface ELLibraryVC : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    UITableView *_tableView;
    UIView *_quickTilesHeader;
    UILabel *_likedCountLabel;
    UILabel *_downloadsCountLabel;
    UILabel *_shuffleSubLabel;
    UILabel *_syncTitleLabel;
    UILabel *_syncSubLabel;
    UIImageView *_syncIconView;
    UIView *_emptyFooter;
    UILabel *_emptyLabel;
    UIButton *_emptyActionBtn;
    NSArray *_playlists;
    NSArray *_likedSongs;
    BOOL _syncing;
}

@end
