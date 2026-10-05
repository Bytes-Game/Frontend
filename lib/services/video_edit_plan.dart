import 'dart:math' as math;

/// How an edited video is saved, decided in one place so the promise about
/// quality is kept in one place.
///
/// The promise: an edit costs no quality you can see, and nothing at all
/// when nothing about the picture changed.
///
///   * Nothing changed: the original file goes up, untouched.
///   * Only cut shorter: the video is cut without being remade (see
///     [VideoSaveWay.cut]). Not a single pixel changes.
///   * Anything else — text, emoji, drawing, a filter, brightness, crop,
///     blur, the sound turned off, a song added — means it has to be remade with
///     the change baked in. Every app does this. It is remade at the
///     original video's own size and its own data rate (how much detail it
///     keeps each second), never less than a healthy floor and never above
///     1080p, which is the largest the server ever shows anybody.

/// The ways a video can leave the editor.
enum VideoSaveWay {
  /// The original file, untouched.
  original,

  /// Cut to the chosen start and end, not remade.
  cut,

  /// Remade with the edits in it.
  remake,
}

/// What the person did in the editor.
class VideoEdits {
  /// Text, emoji or drawing on top of the picture.
  final bool hasLayers;

  /// A filter or a brightness/colour change.
  final bool hasColour;

  /// Blur over the whole picture.
  final bool hasBlur;

  /// Cropped, rotated or flipped.
  final bool isTransformed;

  /// The sound turned off.
  final bool muted;

  /// A free song added under the video.
  final bool hasMusic;

  /// Where the kept part starts and ends; null for the very start and end.
  final Duration? start;
  final Duration? end;

  const VideoEdits({
    this.hasLayers = false,
    this.hasColour = false,
    this.hasBlur = false,
    this.isTransformed = false,
    this.muted = false,
    this.hasMusic = false,
    this.start,
    this.end,
  });

  /// Something in the picture itself changed.
  bool get changesPicture => hasLayers || hasColour || hasBlur || isTransformed;
}

/// The plan: how to save, what part to keep, and how to remake it.
class VideoSavePlan {
  final VideoSaveWay way;

  /// The part kept. Null when it is all of it.
  final Duration? start;
  final Duration? end;

  /// For a remake: the most data per second to keep, in bits.
  final int? bitrate;

  /// For a remake: how much to shrink the picture by, 1 for not at all.
  final double scale;

  const VideoSavePlan({
    required this.way,
    this.start,
    this.end,
    this.bitrate,
    this.scale = 1,
  });

  bool get isTrimmed => start != null || end != null;

  @override
  String toString() =>
      'VideoSavePlan(${way.name}, ${start?.inMilliseconds}..'
      '${end?.inMilliseconds}ms, bitrate $bitrate, scale '
      '${scale.toStringAsFixed(3)})';
}

/// The longest side the server ever plays: a 1080 x 1920 phone video.
const int maxRemakeLongSide = 1920;

/// The most data per second a remake keeps: plenty for 1080p ("1080p High"
/// in the video editor's own presets).
const int maxRemakeBitrate = 16000000;

/// Within this of the start or the end counts as not cut there: the trim
/// bar does not land on the exact millisecond.
const Duration trimSlack = Duration(milliseconds: 60);

/// The least data per second a remake keeps for a picture whose longest
/// side is [longSide] pixels. Remaking a video at a low rate that it already
/// had is what makes a copy look worse than the original; these floors give
/// every remake room to spare.
int remakeFloor(int longSide) {
  if (longSide >= 1700) return 8000000; // 1080p
  if (longSide >= 1100) return 5000000; // 720p
  if (longSide >= 760) return 2500000; // 480p
  return 1500000;
}

/// How much detail per second a remake keeps: the original's own rate,
/// with a healthy floor under it and a ceiling over it.
int remakeBitrate({required int sourceBitrate, required int longSide}) {
  final floor = remakeFloor(longSide);
  final source = sourceBitrate > 0 ? sourceBitrate : floor;
  return math.min(maxRemakeBitrate, math.max(floor, source));
}

/// How much to shrink a picture whose longest side is [longSide] so it is
/// no bigger than 1080p. 1 for one that is 1080p or smaller already.
double remakeScale(int longSide) =>
    longSide > maxRemakeLongSide ? maxRemakeLongSide / longSide : 1;

/// The plan for [edits] made to a video of [duration], [longSide] pixels on
/// its longest side (after any crop) and [sourceBitrate] bits a second.
///
/// [maxLength] is the longest a post may be: a plan never keeps more, even
/// if the person did not cut it down themselves.
VideoSavePlan planVideoSave({
  required VideoEdits edits,
  required Duration duration,
  required int longSide,
  required int sourceBitrate,
  required Duration maxLength,
}) {
  var start = edits.start;
  var end = edits.end;
  if (start != null && start <= trimSlack) start = null;
  if (end != null && end >= duration - trimSlack) end = null;
  // Never more than a post may hold, whatever the trim bar said.
  final from = start ?? Duration.zero;
  final to = end ?? duration;
  if (to - from > maxLength) end = from + maxLength;

  if (edits.changesPicture || edits.muted || edits.hasMusic) {
    return VideoSavePlan(
      way: VideoSaveWay.remake,
      start: start,
      end: end,
      bitrate: remakeBitrate(
        sourceBitrate: sourceBitrate,
        longSide: math.min(longSide, maxRemakeLongSide),
      ),
      scale: remakeScale(longSide),
    );
  }
  if (start != null || end != null) {
    return VideoSavePlan(way: VideoSaveWay.cut, start: start, end: end);
  }
  return const VideoSavePlan(way: VideoSaveWay.original);
}
