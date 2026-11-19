# EchoLegacy (iOS 4.1 / armv6)

A **100% standalone, device-side** YouTube Music client base for **iPod touch 2G (iOS 4.1, `armv6`)**, built on Linux with zero companion PC server required.

## What's Included in the Base
- **Embedded TLS 1.2 (`mbedTLS 2.28.10`)**: Connects directly to YouTube Music (`music.youtube.com`), InnerTube (`youtubei.googleapis.com`), Google OAuth (`oauth2.googleapis.com`), album art CDNs, and `googlevideo.com` from iOS 4.1.
- **Live Streaming + Seeking (`el_fmp4_adts` + CoreAudio `AudioQueue`)**: Resolves direct `itag 140` (128 kbps AAC-LC) streams, demuxes DASH fMP4 to ADTS AAC on-the-fly in pure C, plays via hardware AAC decoding with background playback + lock-screen controls, and seeks via the `sidx` segment index.
- **Offline Downloads (`ELDownloadManager`)**: Saves hardware-playable `.aac` tracks + square JPEG album art + index metadata to `Documents/EchoLegacy/downloads/` for 100% offline playback.
- **On-Device Google Sign-In & Library Sync (`ELAuthManager` + `ELYouTubeClient`)**: Uses Google OAuth 2.0 Device Flow (`google.com/device` + live user code on the iPod) to sign in and sync your YouTube Music playlists and liked songs directly on-device.
- **Modern Dark Programmatic UIKit UI (`ELTheme`)**: No XIBs or Storyboards (builds natively on Linux), with cached vector icons, rounded album art, persistent mini-player bar, full-screen Now Playing view (Shuffle, Repeat Off/All/One, Up Next queue), Shake-to-Shuffle, Recent Searches, and 4 clean tabs (`Library`, `Search`, `Downloads`, `Account`).
- **128 MB RAM Friendly**: 2-at-a-time download queue, automatic in-memory art cache flush on background/memory warnings, cached UI icons, and lean CoreAudio buffering.

## Building & Deploying
- Build `.app` and `.ipa`: `make ipa`
- Deploy over USB SSH (`iproxy` + OpenSSH on iPod): `./deploy.sh` (override password with `IPOD_PASS=...`, default `alpine`)

## Module Layout (for Easy Extension)
- `src/el_fmp4_adts.{h,c}` — Pure-C streaming fMP4 → ADTS demuxer + `sidx` seek table
- `src/ELHTTPClient.{h,m}` — Standalone TLS 1.2 + HTTP/1.1 + chunked + gzip + redirect client
- `src/ELJSON.{h,m}` — `cJSON` bridge for iOS 4.1 (replaces iOS 5+ `NSJSONSerialization`)
- `src/ELAuthManager.{h,m}` — Google OAuth 2.0 Device Flow & token refresh
- `src/ELYouTubeClient.{h,m}` — InnerTube search, stream resolution, playlist & library sync
- `src/ELAudioEngine.{h,m}` — Unified streaming (`AudioQueue`) + offline (`AVAudioPlayer`) playback
- `src/ELDownloadManager.{h,m}` — Offline download queue & storage
- `src/ELTheme.{h,m}` & `src/*VC.{h,m}` — Dark programmatic UIKit views

## ⚠️ Experimental: OAuth scope
This build requests the full `https://www.googleapis.com/auth/youtube` scope (previously narrowed to `youtube.readonly` in commit `83a5272`) to fix `Request had insufficient authentication scopes` errors on InnerTube `browse` and `like` calls. It is **experimental** and grants write access to your YouTube account. To undo: revert this commit, then revoke the app at https://myaccount.google.com/permissions and sign in again.
