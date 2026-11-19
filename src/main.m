#import <UIKit/UIKit.h>
#include <signal.h>

int main(int argc, char *argv[]) {
    /* Never crash on closed TLS/HTTP sockets */
    signal(SIGPIPE, SIG_IGN);

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int retVal = UIApplicationMain(argc, argv, nil, @"ELAppDelegate");
    [pool release];
    return retVal;
}
