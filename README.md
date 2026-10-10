# Battle Arena — Flutter app

The mobile app for Battle Arena. The Go server it talks to lives in a separate
repo (`gobackend`).

---

## What the app is

A short-video app built around challenges. Someone posts a video with a prompt
— *"Who is better — Dancer?"* — someone else posts a response video, and
viewers vote between them. A challenge nobody has answered yet just plays in
the feed as an ordinary short.

The home screen is a vertical swipe feed with three tabs, and each one is a
genuinely different backend:

| Tab | Where it comes from | How it ranks |
|---|---|---|
| **For You** | `/feed/smart` | The full personalisation pipeline |
| **Following** | `/feed/following/v2` | Newest first from accounts you follow. No ranking at all. |
| **Explore** | `/feed/explore` | Discovery-first, deliberately not personalised |

---

## Running it

You need Flutter 3.47 or newer (`flutter upgrade`). On 3.44 a Flutter bug
breaks taps while a page is closing, so `pubspec.yaml` asks for 3.47.

```bash
flutter pub get
flutter run
```

That builds against the deployed backend. Note that it runs on a free hosting
tier which sleeps after about 15 minutes of inactivity, so the first request
after a quiet period takes 30–60 seconds while the server wakes up. The app
expects this — a login that times out says "could not reach the server", not
"wrong password".

### Recording a run, to send with a bug

```
tools\run_profile.bat
```

This runs the app and saves everything to `F:\logs.txt`: what `flutter run`
prints, and every line of the phone's own log, written straight into the file
as it happens. Nothing else is created, not even a temporary copy. Attach
that one file; if it is too big to attach, zip it first.

At the end it says how big the saved file really is, how many of the phone's
lines are in it, what the phone said went wrong (a crash, the app not
responding), and the video editor's last steps.

### Building it to share

```bash
flutter build appbundle             # for the Play Store
flutter build apk --split-per-abi   # to send the app file directly
```

Build it one of these two ways. A single app file holds the code for every
kind of phone, and a phone only ever uses one kind, so everyone would
download what their phone throws away. Measured on this app (release
builds, October 2026):

| app file | size | for |
|---|---|---|
| `app-arm64-v8a-release.apk` | 42.2 MB | almost every phone in use |
| `app-armeabi-v7a-release.apk` | 34.3 MB | older 32-bit phones |
| `app-x86_64-release.apk` | 47.9 MB | emulators, some Chromebooks |
| `app-release.apk`, not split, built for 64-bit phones only | 67.6 MB | 24 MB of it is for other phones |

A plain `flutter build apk` puts every kind of phone's whole app in one
file, so it is bigger still. The Play Store does the split by itself from
the app bundle.

Where a 64-bit phone's 42 MB goes: video calls (WebRTC) 12.3 MB, the app's
own code 12.2 MB, Flutter itself 11.7 MB, Android code 3.1 MB, crash
reporting 1.2 MB, pictures and the rest about 1.7 MB. The photo and video
editors and the Music button are 3.7 MB of that.

To see it again: `flutter build apk --release --analyze-size
--target-platform android-arm64`.

### Pointing at a local backend

```bash
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8081 \
  --dart-define=WS_BASE_URL=ws://10.0.2.2:8081
```

`10.0.2.2` is how the Android emulator reaches `localhost` on the machine
running it. On the iOS simulator use `http://localhost:8081`. On a real phone
use your computer's address on the network, and make sure the Go server is
listening on it rather than only on loopback.

Both URLs live in `lib/config/constants.dart` and nothing else carries a copy.

### Crash reporting

```bash
flutter run --dart-define=SENTRY_DSN=https://...
```

With no DSN the Sentry SDK does nothing and errors just print to the console,
which is what you want locally.

### Phone notifications

New messages and missed calls arrive as notifications on the phone — on the
lock screen, outside the app — and a tap opens the chat. They never go to
the app's notifications page. They come through Google's push service,
Firebase.

It is set up: the app has the Firebase project `battle-38226` built in
(`lib/services/push_service.dart`), so every build gets notifications with
no extra steps, and the server has `NOTIFICATION_SENDER=fcm` and the
project's private key in `FCM_SERVICE_ACCOUNT_JSON` on Render. The values
built into the app are not secret; the private key must only ever be on the
server.

To try a different Firebase project for one build, put its four values in
`firebase_push.json` next to `pubspec.yaml` (see
`firebase_push.example.json`); `tools\run_profile.bat` passes it in on its
own, or use `flutter run --dart-define-from-file=firebase_push.json`.

iPhones need more: an iOS app in the same project (`FIREBASE_IOS_APP_ID`),
an APNs key uploaded to Firebase, and the Push Notifications capability in
Xcode.

### Checks

```bash
flutter analyze --no-fatal-infos
flutter test
```

`--no-fatal-infos` matches CI. There are a number of pre-existing info-level
lints that predate the pipeline; warnings and errors still fail the build.

`test/phone_log_tools_test.dart` runs the scripts in `tools/` with PowerShell 7
(`pwsh`), which CI has. Without it those tests skip on your computer (set
`PWSH` to point at one); on CI they fail instead, so they cannot quietly stop
running.

---

## How it is laid out

```
lib/
  config/      theme, and the backend URLs
  models/      the shapes that come back from the API
  pages/       one file per screen
  providers/   app-wide state (auth, user data, theme)
  screens/     login, and the bottom-nav shell
  services/    everything that is not UI — network, video, uploads, analytics
  widgets/     reusable pieces, including the reels feed itself
```

### The parts that matter most

**`widgets/smart_reels_feed.dart`** is the feed. Paging, playback, gestures,
the battle flip animation, and the event tracking that feeds the ranking
system. It is the biggest file in the repo by a distance.

**`services/video_player_service.dart`** and **`services/video_cache_service.dart`**
are the two halves of making a swipe feel instant, and the split between them
is the single most important idea in this app — see below.

**`services/event_tracker.dart`** batches around 30 kinds of interaction and
sends them every 5 seconds. The backend's ranking is only as good as this data.

**`services/upload_job_manager.dart`** runs uploads in the background. You can
tap Post, leave the page, and keep scrolling; the job survives navigation and
is restored after an app kill.

---

## The video pipeline, and why it looks like this

This is the part that will be confusing without context, because the obvious
design is the wrong one and the code deliberately does not use it.

**The problem.** A phone can only decode a small, fixed number of videos at
once. That limit belongs to the chip, not to memory — so a phone with plenty of
free RAM will still take a decoder away from the app mid-playback, which the
user sees as a video frozen on its last frame.

**The obvious design that fails.** To make the next reel instant, start playing
it early. But "playing" means holding a decoder, so five ready reels means five
decoders, and the phone takes them back.

**What this app does instead.** "Ready" is split into two separate things:

* **Getting the bytes onto the phone** is cheap and uses no decoder. That is
  `VideoCacheService`. It downloads only the opening slice of upcoming reels
  and serves it to the player through a small local web server, streaming the
  rest from the network behind it. Costs roughly a tenth of the data of
  downloading whole files.

* **Running a decoder** is expensive, so `VideoPlayerService` keeps a hard cap
  of four players — exactly what is on screen or one gesture away: the current
  reel, one up, one down, and the opponent's video during a battle flip.

There is one more piece. `third_party/video_player_android/` is a copy of the
official Flutter video plugin with a single change: it can open a video with
its audio switched off. Muting is not enough — the player keeps decoding sound
nobody hears, which burns a second decoder slot per warm video for nothing.
`third_party/video_player_android/LOCAL_CHANGES.md` explains it in full,
including the device logs that forced it. That folder is held as close to the
original as possible so the change stays easy to re-apply on a newer release,
which is why it is excluded from this project's linting.

---

## A note on `devb/`

It is an empty folder — a leftover pointer to the backend from when it was a
submodule. The backend is its own repository now, with its own CI. Nothing here
reads it.
