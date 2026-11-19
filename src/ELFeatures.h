#ifndef EL_FEATURES_H
#define EL_FEATURES_H

/*
 * ELFeatures.h - Compile-time feature toggles for EchoLegacy
 *
 * Every flag defaults to 1 (enabled) via #ifndef so default builds keep full
 * functionality while allowing individual tabs or player features to be stripped
 * at compile time without changing runtime behavior.
 *
 * How to disable a feature:
 *   1. Change its default below from 1 to 0, OR
 *   2. Pass -DEL_FEATURE_<NAME>=0 in Makefile COMMON_FLAGS (e.g. -DEL_FEATURE_LYRICS=0).
 *
 * Note on Account tab:
 *   The Account tab (ELAccountVC) is always compiled and mounted so users can
 *   always sign in, view diagnostics, and inspect app status even if other tabs
 *   are toggled off.
 *
 * How to add a new tab or feature:
 *   1. Define a new EL_FEATURE_<MY_FEATURE> toggle here (defaulting to 1).
 *   2. Guard its UI/controller hooks with #if EL_FEATURE_<MY_FEATURE> ... #endif.
 *   3. For a new tab: create src/EL<MyTab>VC.{h,m}, add a tab icon helper in
 *      ELTheme.{h,m} if needed, and mount it in ELAppDelegate's
 *      appendTabWithController:toArray: helper inside #if EL_FEATURE_<MY_TAB>.
 *      Makefile automatically compiles all src/*.m files.
 */

/* --- Navigation Tabs --- */

/* Home tab: personalized YouTube Music shelves, mixes, and quick picks */
#ifndef EL_FEATURE_HOME_TAB
#define EL_FEATURE_HOME_TAB 1
#endif

/* Library tab: synced playlists, liked songs, and library refresh */
#ifndef EL_FEATURE_LIBRARY_TAB
#define EL_FEATURE_LIBRARY_TAB 1
#endif

/* Search tab: catalog search and recent search history */
#ifndef EL_FEATURE_SEARCH_TAB
#define EL_FEATURE_SEARCH_TAB 1
#endif

/* Offline downloads tab + download buttons/actions across player & browse lists */
#ifndef EL_FEATURE_DOWNLOADS
#define EL_FEATURE_DOWNLOADS 1
#endif

/* --- Player & Experience Features --- */

/* Lyrics sheet toggle in Now Playing */
#ifndef EL_FEATURE_LYRICS
#define EL_FEATURE_LYRICS 1
#endif

/* Start Radio / Mix actions from Now Playing and track action sheets */
#ifndef EL_FEATURE_RADIO_MIX
#define EL_FEATURE_RADIO_MIX 1
#endif

/* Sleep timer sheet/countdown in Now Playing */
#ifndef EL_FEATURE_SLEEP_TIMER
#define EL_FEATURE_SLEEP_TIMER 1
#endif

/* Heart/Like button in Now Playing */
#ifndef EL_FEATURE_LIKES
#define EL_FEATURE_LIKES 1
#endif

/* Scrolling marquee text for long track titles/artists */
#ifndef EL_FEATURE_MARQUEE
#define EL_FEATURE_MARQUEE 1
#endif

/* Shake device to shuffle playback (motionEnded in ELWindow) */
#ifndef EL_FEATURE_SHAKE_SHUFFLE
#define EL_FEATURE_SHAKE_SHUFFLE 1
#endif

/* Over-the-air update checker in Account view */
#ifndef EL_FEATURE_OTA_UPDATER
#define EL_FEATURE_OTA_UPDATER 1
#endif

/* Custom offline playlists stored locally on-device */
#ifndef EL_FEATURE_LOCAL_PLAYLISTS
#define EL_FEATURE_LOCAL_PLAYLISTS 1
#endif

/* Full-screen nightstand/desk Dock Mode player with live clock, dimmer, and wake lock */
#ifndef EL_FEATURE_DOCK_MODE
#define EL_FEATURE_DOCK_MODE 1
#endif

/* Headphone-unplug auto-pause, pause-on-mute, and optional reconnect resume */
#ifndef EL_FEATURE_SMART_PLAYBACK
#define EL_FEATURE_SMART_PLAYBACK 1
#endif

/* Smooth offline-only crossfade strictly when disconnected from Wi-Fi */
#ifndef EL_FEATURE_OFFLINE_CROSSFADE
#define EL_FEATURE_OFFLINE_CROSSFADE 1
#endif

/* Wikipedia track backstory sheet (Music DNA) */
#ifndef EL_FEATURE_MUSIC_DNA
#define EL_FEATURE_MUSIC_DNA 1
#endif

#endif /* EL_FEATURES_H */
