# Local copy of `video_player_android`

Forked from **pub.dev `video_player_android` 2.9.5**, unmodified except for
the one change below.

The app uses it through `dependency_overrides` in the root `pubspec.yaml`.

## Why this copy exists

The reels feed keeps several videos loaded at once so a swipe lands on one
that is already playing. Only one of them is on screen. The others are muted.

Muting does not stop the work. `setVolume(0)` silences the output while
ExoPlayer keeps selecting the audio track, keeps a hardware AAC decoder open,
keeps an `AudioTrack` and its thread alive, and decodes every chunk of sound
before dropping it. A profile run on device caught one of these plainly:

```
[mId: 5] Qinput: 126, Render: 0, Drop: 122
```

126 chunks of audio decoded, none of it played.

That matters because a phone can only run a small, fixed number of hardware
decoders at once — a property of the chip, not of memory. Each warm video was
spending two decoder slots to use one. When the budget ran out, Android took
decoders back from us mid-playback:

```
D/MediaCodec: MediaCodec::reclaim(0x...) c2.mtk.avc.decoder
E/MediaCodec: Released by resource manager
```

which the user sees as a video frozen on its last frame.

The upstream package has no way to express "open this video without its
sound". `selectAudioTrack` picks *between* audio tracks; there is no
deselect, and volume is not track selection. Hence the fork.

## The change

One method, `setAudioEnabled`, added to the per-player API.

| File | What changed |
| --- | --- |
| `pigeons/messages.dart` | `setAudioEnabled(bool)` added to `VideoPlayerInstanceApi` |
| `lib/src/messages.g.dart` | regenerated |
| `android/src/main/kotlin/.../Messages.kt` | regenerated |
| `android/src/main/java/.../VideoPlayer.java` | implementation, on `DefaultTrackSelector` |
| `lib/src/android_video_player.dart` | `AndroidVideoPlayer.setAudioEnabled` + `_PlayerInstance` passthrough |

Nothing else is touched. The two `.g` files are generated — do not hand-edit
them; see below.

`AndroidVideoPlayer.setAudioEnabled` has no `@override`, because
`VideoPlayerPlatform` in `video_player_platform_interface` knows nothing about
it. Callers reach it by casting `VideoPlayerPlatform.instance`, which is what
`VideoPlayerService._setSpareAudio` does, guarded so every other platform is a
no-op.

## What it does not do

It is a toggle on a live player, not an option at creation. A player is
therefore born with audio and gives it up a moment later, rather than never
taking it. Passing a flag at creation would mean widening
`VideoCreationOptions` in `video_player_platform_interface` and the controller
in `video_player`, i.e. vendoring two more packages, which is not worth it:
what this reclaims is the whole time a spare sits warm — seconds to minutes —
against a few milliseconds around its creation.

## Updating to a newer upstream

1. `git rm -r third_party/video_player_android`, then copy the new version out
   of `~/.pub-cache/hosted/pub.dev/video_player_android-<version>/`, dropping
   `example/`.
2. Re-apply the five rows in the table above. The Java and Dart edits are
   small and self-contained; each is marked `LOCAL ADDITION` in the source, so
   `grep -rn "LOCAL ADDITION" third_party/video_player_android` finds every
   one.
3. **Regenerate, do not hand-port, the `.g` files:**
   ```
   cd third_party/video_player_android
   dart pub get
   dart run pigeon --input pigeons/messages.dart
   ```
4. Bump the `video_player_android` constraint in the root `pubspec.yaml` to
   match, so the override and the constraint cannot drift apart silently.
5. `flutter test` — `test/video_player_pool_test.dart` covers when the app asks
   for audio to be turned off and back on, and does not depend on Android.

If a future upstream grows a real API for this, delete the fork and the
override rather than keeping both.
