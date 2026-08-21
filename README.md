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

You need the Flutter SDK (Dart SDK 3.11 or newer).

```bash
flutter pub get
flutter run
```

That builds against the deployed backend. Note that it runs on a free hosting
tier which sleeps after about 15 minutes of inactivity, so the first request
after a quiet period takes 30–60 seconds while the server wakes up. The app
expects this — a login that times out says "could not reach the server", not
"wrong password".

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

### Checks

```bash
flutter analyze --no-fatal-infos
flutter test
```

`--no-fatal-infos` matches CI. There are a number of pre-existing info-level
lints that predate the pipeline; warnings and errors still fail the build.

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
