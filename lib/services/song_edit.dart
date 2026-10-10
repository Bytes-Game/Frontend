import 'dart:math' as math;

import 'package:pro_video_editor/pro_video_editor.dart';

/// How a song sits under a video or a photo: which part of it, how loud it
/// is next to the video's own sound, and whether it fades in and out.
///
/// The same settings drive two things that must agree: what is heard while
/// editing ([volumeAt]) and what is saved ([track]). Both editors use it.
class SongEdit {
  /// Where in the song the post starts.
  Duration start;

  /// How loud the song is, from 0 to 1.
  double songVolume;

  /// How loud the video's own sound is, from 0 to 1. Not used for a photo,
  /// which has none.
  double videoVolume;

  /// The song rises from silence at the start of the post.
  bool fadeIn;

  /// The song falls to silence at the end of the post.
  bool fadeOut;

  SongEdit({
    this.start = Duration.zero,
    this.songVolume = 0.8,
    this.videoVolume = 1,
    this.fadeIn = false,
    this.fadeOut = false,
  });

  /// The longest a fade lasts.
  static const maxFade = Duration(seconds: 2);

  /// How long a fade lasts in a post [length] long: [maxFade], or a third
  /// of a short post, so a fade in and a fade out never meet in the middle.
  static Duration fadeFor(Duration length) {
    final third = length ~/ 3;
    return third < maxFade ? third : maxFade;
  }

  /// The furthest the song can start and still fill a post [length] long
  /// from a song [songLength] long. Zero when the song is the shorter: it
  /// then plays from its start and starts again.
  static Duration latestStart(Duration songLength, Duration length) =>
      songLength > length ? songLength - length : Duration.zero;

  /// [start] kept inside the song for a post [length] long.
  Duration startWithin(Duration songLength, Duration length) {
    final latest = latestStart(songLength, length);
    if (start < Duration.zero) return Duration.zero;
    return start > latest ? latest : start;
  }

  /// A little more of the song than the post needs, so rounding never
  /// leaves the post a few samples short (which would loop the song's
  /// first instant back in at the very end).
  static const endSpare = Duration(milliseconds: 500);

  /// The song as saved under a post [length] long, from the file at [path].
  VideoAudioTrack track(String path, {required Duration length}) {
    final fade = fadeFor(length);
    return VideoAudioTrack(
      path: path,
      volume: songVolume,
      // A song shorter than the post starts again.
      loop: true,
      audioStartTime: start > Duration.zero ? start : null,
      // Where the part used ends. Without it the phone reads the song from
      // the start of the part to the very end of the song before saving: a
      // device log shows a 7-second video taking 33 seconds to save, 31.5
      // of them spent reading three minutes of song it then threw away.
      audioEndTime: start + length + endSpare,
      fadeInDuration: fadeIn ? fade : Duration.zero,
      fadeOutDuration: fadeOut ? fade : Duration.zero,
    );
  }

  /// How loud the song should sound [into] a post [length] long, fades
  /// included: what the editor plays while editing.
  double volumeAt(Duration into, Duration length) {
    final fade = fadeFor(length);
    var gain = 1.0;
    if (fade > Duration.zero) {
      if (fadeIn && into < fade) {
        gain = math.min(gain, into.inMicroseconds / fade.inMicroseconds);
      }
      final left = length - into;
      if (fadeOut && left < fade) {
        gain = math.min(gain, left.inMicroseconds / fade.inMicroseconds);
      }
    }
    return songVolume * gain.clamp(0.0, 1.0);
  }
}
