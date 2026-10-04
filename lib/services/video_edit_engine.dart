import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

/// What the video editor needs to know about a video.
@immutable
class VideoFacts {
  final Duration duration;

  /// As it plays, with any rotation already applied: 1080 x 1920 for a
  /// portrait phone video.
  final Size resolution;

  /// How much data a second it keeps, in bits. 0 when the phone could not
  /// say.
  final int bitrate;

  final bool hasSound;

  const VideoFacts({
    required this.duration,
    required this.resolution,
    required this.bitrate,
    required this.hasSound,
  });

  int get longSide => resolution.longestSide.round();
}

/// Everything the video editor asks of the phone, in one place, with a
/// stand-in for tests (the way the camera and the gallery have one).
abstract class VideoEditEngine {
  /// The one the app uses. A seam: tests put a stand-in here.
  static VideoEditEngine instance = PhoneVideoEditEngine();

  Future<VideoFacts> facts(String path);

  /// Small pictures along the video, for the trim bar.
  Future<List<Uint8List>> thumbnails(
    String path,
    Duration duration, {
    required int count,
    required double size,
  });

  /// Cut [path] to [start]..[end] WITHOUT remaking it: the same bytes,
  /// shorter. Null when this phone cannot cut that way.
  Future<String?> cutLossless(String path, Duration start, Duration end);

  /// Save the edit described by [data] to a new file, and answer its path.
  Future<String> render(VideoRenderData data);

  /// How far along a [render] is, from 0 to 1.
  Stream<double> progress(String taskId);

  Future<void> cancel(String taskId);
}

/// The real phone: pro_video_editor for reading and remaking (Media3 on
/// Android, AVFoundation on iPhone), and on Android the app's own cutter.
class PhoneVideoEditEngine implements VideoEditEngine {
  ProVideoEditor get _editor => ProVideoEditor.instance;

  static const _cutter = MethodChannel('devf/video_trim');

  @override
  Future<VideoFacts> facts(String path) async {
    final video = EditorVideo.file(path);
    final meta = await _editor.getMetadata(video);
    var sound = meta.audioDuration != null;
    try {
      sound = await _editor.hasAudioTrack(video);
    } catch (e) {
      // The duration of the sound says the same thing, less directly.
      debugPrint('[editor] could not ask whether the video has sound: $e');
    }
    return VideoFacts(
      duration: meta.duration,
      resolution: meta.resolution,
      bitrate: meta.bitrate,
      hasSound: sound,
    );
  }

  @override
  Future<List<Uint8List>> thumbnails(
    String path,
    Duration duration, {
    required int count,
    required double size,
  }) {
    final step = duration.inMilliseconds / count;
    return _editor.getThumbnails(
      ThumbnailConfigs(
        video: EditorVideo.file(path),
        outputSize: Size.square(size),
        boxFit: ThumbnailBoxFit.cover,
        timestamps: [
          for (var i = 0; i < count; i++)
            Duration(milliseconds: ((i + 0.5) * step).round()),
        ],
        outputFormat: ThumbnailFormat.jpeg,
      ),
    );
  }

  @override
  Future<String?> cutLossless(String path, Duration start, Duration end) async {
    // Android: the app's own cutter, which copies the video and its sound
    // from one file to the other without touching either — the one that
    // has kept the sound on every phone (MediaTek ones included). There is
    // no such cutter on an iPhone; the caller remakes there instead.
    if (!Platform.isAndroid) return null;
    final dir = await getTemporaryDirectory();
    final dest =
        '${dir.path}/devf_cut_${DateTime.now().millisecondsSinceEpoch}.mp4';
    return _cutter.invokeMethod<String>('trimVideo', {
      'sourcePath': path,
      'startMs': start.inMilliseconds,
      'endMs': end.inMilliseconds,
      'destPath': dest,
    });
  }

  @override
  Future<String> render(VideoRenderData data) async {
    final dir = await getTemporaryDirectory();
    final dest =
        '${dir.path}/devf_edit_${DateTime.now().millisecondsSinceEpoch}.mp4';
    return _editor.renderVideoToFile(dest, data);
  }

  @override
  Stream<double> progress(String taskId) =>
      _editor.progressStreamById(taskId).map((p) => p.progress);

  @override
  Future<void> cancel(String taskId) => _editor.cancel(taskId);
}
