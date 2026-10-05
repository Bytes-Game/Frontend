// Stand-ins for the Music button's outside world, shared by the tests that
// go through it: the music library (the server and the network), the
// player, and — for a test that follows a video post all the way to the
// server — the phone's media tools that processing asks.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/video_processor_service.dart';

/// A free song, as a search finds it (no id of ours yet).
MusicTrack song(
  String id, {
  String? title,
  String artist = 'Some Artist',
  String licence = 'by',
  Duration duration = const Duration(minutes: 3),
}) => MusicTrack(
  sourceId: id,
  title: title ?? 'Song $id',
  artist: artist,
  duration: duration,
  audioUrl: 'https://files.example/$id.mp3',
  licence: licence,
  licenceVersion: licence == 'by' ? '4.0' : '',
  licenceUrl: 'https://creativecommons.org/licenses/by/4.0/',
  sourceUrl: 'https://www.jamendo.com/track/$id',
  attribution:
      '"${title ?? 'Song $id'}" by $artist is licensed under CC BY 4.0.',
);

class FakeMusicLibrary implements MusicLibrary {
  FakeMusicLibrary(this.dir);

  /// Where the songs it "downloads" go.
  final Directory dir;

  /// The songs used most here, on the first page of an empty search.
  List<MusicTrack> popular = [];

  /// Every free song, in pages of [pageSize]; a search keeps those whose
  /// title has the words in it.
  List<MusicTrack> all = [];
  int pageSize = 20;

  bool busy = false;

  /// When set, a search cannot reach the server.
  bool unreachable = false;

  /// When set, picking is refused with these words.
  String? refuse;

  final List<(String, int)> searches = [];
  final List<MusicTrack> picked = [];
  final List<MusicTrack> downloaded = [];

  /// The id the server gives a picked song.
  String idFor(MusicTrack t) => '7${t.sourceId.hashCode.abs() % 1000}';

  @override
  Future<MusicSearchResult> search(String query, {int page = 1}) async {
    searches.add((query, page));
    if (unreachable) throw const MusicUnavailable();
    final matching = [
      for (final t in all)
        if (query.isEmpty ||
            t.title.toLowerCase().contains(query.toLowerCase()))
          t,
    ];
    final from = (page - 1) * pageSize;
    final to = (from + pageSize).clamp(0, matching.length);
    return MusicSearchResult(
      popular: query.isEmpty && page == 1 ? popular : const [],
      tracks: from < matching.length ? matching.sublist(from, to) : const [],
      hasMore: to < matching.length,
      busy: busy,
    );
  }

  @override
  Future<MusicTrack> pick(MusicTrack track) async {
    picked.add(track);
    final no = refuse;
    if (no != null) throw ApiRefused(no);
    return MusicTrack(
      id: idFor(track),
      sourceId: track.sourceId,
      title: track.title,
      artist: track.artist,
      duration: track.duration,
      audioUrl: track.audioUrl,
      licence: track.licence,
      licenceVersion: track.licenceVersion,
      licenceUrl: track.licenceUrl,
      sourceUrl: track.sourceUrl,
      attribution: track.attribution,
    );
  }

  @override
  Future<String> download(MusicTrack track) async {
    downloaded.add(track);
    final f = File('${dir.path}/music_${track.sourceId}.mp3')
      ..writeAsBytesSync(List.filled(512, 9));
    return f.path;
  }
}

/// A player that plays nothing and remembers what it was asked.
class FakeMusicPlayer implements MusicPlayer {
  static final List<FakeMusicPlayer> made = [];
  FakeMusicPlayer() {
    made.add(this);
  }

  final List<String> calls = [];

  @override
  Future<void> play(
    String source, {
    Duration from = Duration.zero,
    bool loop = false,
  }) async => calls.add('play $source from ${from.inMilliseconds} loop $loop');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration to) async =>
      calls.add('seek ${to.inMilliseconds}');

  @override
  Future<void> setVolume(double volume) async =>
      calls.add('volume ${volume.toStringAsFixed(2)}');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

const _compress = MethodChannel('video_compress');
const _thumbnail = MethodChannel('plugins.justsoft.xyz/video_thumbnail');

/// Lets a video post be processed here as on a phone: the phone's tools
/// for reading a video and taking a picture of it answer for an 8-second
/// 1080p video, and the picture is a real (tiny) file.
void fakeVideoProcessing(WidgetTester t) {
  VideoProcessorService.debugSupported = true;
  final m = t.binding.defaultBinaryMessenger;
  m.setMockMethodCallHandler(_compress, (call) async {
    if (call.method == 'getMediaInfo') {
      final path = (call.arguments as Map)['path'] as String;
      return json.encode({
        'path': path,
        'title': '',
        'author': '',
        'width': 1080,
        'height': 1920,
        'orientation': 0,
        'filesize': File(path).existsSync() ? File(path).lengthSync() : 0,
        'duration': 8000.0,
      });
    }
    return null;
  });
  m.setMockMethodCallHandler(_thumbnail, (call) async {
    final dir =
        (call.arguments as Map)['path'] as String? ?? Directory.systemTemp.path;
    final f = File('$dir/thumb_${DateTime.now().microsecondsSinceEpoch}.jpg')
      ..writeAsBytesSync(List.filled(64, 1));
    return f.path;
  });
  addTearDown(() {
    VideoProcessorService.debugSupported = null;
    m.setMockMethodCallHandler(_compress, null);
    m.setMockMethodCallHandler(_thumbnail, null);
  });
}
