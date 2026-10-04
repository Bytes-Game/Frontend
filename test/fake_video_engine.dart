// A stand-in for the phone's video tools (VideoEditEngine), shared by the
// tests that go through the video editor. It records what the editor asked
// of it, and makes real (tiny) files, so the next page has a file to read.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:pro_video_editor/pro_video_editor.dart';

import 'package:myapp/services/video_edit_engine.dart';

class FakeVideoEngine implements VideoEditEngine {
  FakeVideoEngine(this.dir);

  /// Where the files it makes go.
  final Directory dir;

  /// What every video the phone already had looks like: 10 seconds of
  /// portrait 1080p with sound, at 12 Mbit/s.
  VideoFacts source = const VideoFacts(
    duration: Duration(seconds: 10),
    resolution: Size(1080, 1920),
    bitrate: 12000000,
    hasSound: true,
  );

  /// When set, reading a video's facts fails: the editor cannot open it.
  Object? factsFail;

  /// Whether a video this engine remade still has its sound.
  bool remakeKeepsSound = true;

  /// Whether this phone can cut without remaking (an Android one can).
  bool canCutLossless = true;

  /// When set, remaking fails.
  Object? renderFail;

  /// When set, a remake waits for this before it finishes — the way a long
  /// one does on a phone — and Cancel stops it.
  Completer<void>? renderHeld;

  /// How far a remake has got, as the phone reports it.
  final progressReports = StreamController<double>.broadcast();

  final List<String> cancelled = [];

  final List<String> factsAsked = [];
  final List<({String path, Duration start, Duration end})> cuts = [];
  final List<VideoRenderData> renders = [];
  final Set<String> _made = {};
  int _n = 0;

  @override
  Future<VideoFacts> facts(String path) async {
    factsAsked.add(path);
    final fail = factsFail;
    if (fail != null) throw fail;
    if (_made.contains(path)) {
      return VideoFacts(
        duration: source.duration,
        resolution: source.resolution,
        bitrate: source.bitrate,
        hasSound: remakeKeepsSound,
      );
    }
    return source;
  }

  @override
  Future<List<Uint8List>> thumbnails(
    String path,
    Duration duration, {
    required int count,
    required double size,
  }) async => const [];

  @override
  Future<String?> cutLossless(String path, Duration start, Duration end) async {
    if (!canCutLossless) return null;
    cuts.add((path: path, start: start, end: end));
    return _file('cut');
  }

  @override
  Future<String> render(VideoRenderData data) async {
    renders.add(data);
    final fail = renderFail;
    if (fail != null) throw fail;
    final held = renderHeld;
    if (held != null) await held.future;
    return _file('edit');
  }

  @override
  Stream<double> progress(String taskId) => progressReports.stream;

  @override
  Future<void> cancel(String taskId) async {
    cancelled.add(taskId);
    final held = renderHeld;
    if (held != null && !held.isCompleted) {
      held.completeError(const RenderCanceledException());
    }
  }

  String _file(String kind) {
    final f = File('${dir.path}/${kind}_${_n++}.mp4')
      ..writeAsBytesSync(List.filled(1024, 3));
    _made.add(f.path);
    return f.path;
  }
}
