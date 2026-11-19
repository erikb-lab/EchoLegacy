#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "ELTrack.h"

@class ELStreamInfo;

extern NSString *const ELPlayerStateChangedNotification;
extern NSString *const ELPlayerProgressNotification;
extern NSString *const ELPlayerToastNotification; /* userInfo: message */

typedef enum {
    ELPlayerStateStopped = 0,
    ELPlayerStateLoading,
    ELPlayerStatePlaying,
    ELPlayerStatePaused,
    ELPlayerStateError
} ELPlayerState;

typedef enum {
    ELRepeatModeOff = 0,
    ELRepeatModeAll,
    ELRepeatModeOne
} ELRepeatMode;

@interface ELAudioEngine : NSObject <AVAudioPlayerDelegate> {
    NSArray *_originalQueue;
    NSArray *_queue;
    NSInteger _currentIndex;
    ELPlayerState _state;
    BOOL _playingOffline;
    NSString *_lastError;

    BOOL _shuffleEnabled;
    ELRepeatMode _repeatMode;
    BOOL _shakeToShuffleEnabled;
    NSTimeInterval _lastShakeTime;

    /* Offline playback via AVAudioPlayer */
    AVAudioPlayer *_offlinePlayer;

    /* Live streaming playback via AudioFileStream + AudioQueue */
    NSInteger _sessionToken;
    double _streamDuration;
    double _streamSeekBaseSec;
    BOOL _streamSeekPending;
    double _streamSeekTargetSec;
    BOOL _streamPaused;

    NSTimer *_progressTimer;
    UIBackgroundTaskIdentifier _bgTask;
    BOOL _resumeAfterInterruption;

    /* Low-RAM disk-backed pre-next song buffering (Caches/EchoLegacy/prenext.fmp4) */
    NSString *_preNextDir;
    NSInteger _preNextGen;
    NSString *_preNextInFlightVideoId;
    NSString *_preNextReadyVideoId;
    ELStreamInfo *_preNextStreamInfo;
    unsigned long long _preNextByteLength;
    NSTimeInterval _preNextReadyTime;
    NSInteger _preNextAttemptedSessionToken;
    NSString *_preNextAttemptedVideoId;
}

+ (ELAudioEngine *)sharedEngine;

@property (nonatomic, readonly) ELTrack *currentTrack;
@property (nonatomic, readonly) NSArray *queue;
@property (nonatomic, readonly) NSInteger currentIndex;
@property (nonatomic, readonly) ELPlayerState state;
@property (nonatomic, readonly) BOOL isPlayingOffline;
@property (nonatomic, readonly) double currentTime;
@property (nonatomic, readonly) double duration;
@property (nonatomic, copy, readonly) NSString *lastError;

@property (nonatomic, readonly) BOOL shuffleEnabled;
@property (nonatomic, readonly) ELRepeatMode repeatMode;
@property (nonatomic, assign) BOOL shakeToShuffleEnabled;

- (void)playTracks:(NSArray *)tracks startingAtIndex:(NSInteger)index;
- (void)playTracksShuffled:(NSArray *)tracks;
- (void)playTrack:(ELTrack *)track;
- (void)jumpToQueueIndex:(NSInteger)index;

- (void)togglePlayPause;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)playNext;
- (void)playPrevious;
- (void)seekToSeconds:(double)seconds;

- (void)toggleShuffle;
- (void)cycleRepeatMode;
- (void)handleShakeToShuffle;
- (void)postToast:(NSString *)message;

- (void)handleRemoteControlEvent:(UIEvent *)event;

@end
