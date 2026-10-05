import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/api_service.dart';

/// One page of the picker's list.
class MusicSearchResult {
  /// The songs used most here — on the first page of an empty search only.
  final List<MusicTrack> popular;
  final List<MusicTrack> tracks;
  final bool hasMore;

  /// The music library would not answer just now: what is shown is what it
  /// found earlier, or only the popular songs.
  final bool busy;

  const MusicSearchResult({
    this.popular = const [],
    this.tracks = const [],
    this.hasMore = false,
    this.busy = false,
  });
}

/// The search could not reach the server at all.
class MusicUnavailable implements Exception {
  const MusicUnavailable();
  @override
  String toString() => 'the music library could not be reached';
}

/// Everything the Music button asks of the server and the network, with a
/// stand-in for tests (the way the gallery and the camera have one).
abstract class MusicLibrary {
  /// The one the app uses. A seam: tests put a stand-in here.
  static MusicLibrary instance = ServerMusicLibrary();

  /// Free songs matching [query]; every free song for an empty one.
  /// Throws [MusicUnavailable] when the server cannot be reached.
  Future<MusicSearchResult> search(String query, {int page = 1});

  /// Keeps [track] as picked, and answers it with our own id. Throws
  /// [ApiRefused] with the server's words when it cannot be used.
  Future<MusicTrack> pick(MusicTrack track);

  /// The song itself, on the phone, to mix into the video.
  Future<String> download(MusicTrack track);
}

class ServerMusicLibrary implements MusicLibrary {
  /// The most a song may weigh. A three-minute MP3 is about 5 MB.
  static const maxBytes = 40 * 1024 * 1024;

  @override
  Future<MusicSearchResult> search(String query, {int page = 1}) async {
    final j = await ApiService.searchMusic(query, page: page);
    if (j == null) throw const MusicUnavailable();
    List<MusicTrack> list(Object? raw) => [
      for (final t in (raw as List? ?? const []))
        if (t is Map<String, dynamic>) MusicTrack.fromJson(t),
    ];
    return MusicSearchResult(
      popular: list(j['popular']),
      tracks: list(j['tracks']),
      hasMore: j['hasMore'] == true,
      busy: j['busy'] == true,
    );
  }

  @override
  Future<MusicTrack> pick(MusicTrack track) async =>
      MusicTrack.fromJson(await ApiService.pickMusic(track.sourceId));

  @override
  Future<String> download(MusicTrack track) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/music');
    await dir.create(recursive: true);
    final safe = track.sourceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/$safe.mp3');
    // Picked before, on this phone: the same file again.
    if (await file.exists() && await file.length() > 0) return file.path;
    final res = await http
        .get(Uri.parse(track.audioUrl))
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw HttpException('the song answered ${res.statusCode}');
    }
    if (res.bodyBytes.isEmpty || res.bodyBytes.length > maxBytes) {
      throw HttpException('the song is ${res.bodyBytes.length} bytes');
    }
    final part = File('${file.path}.part');
    await part.writeAsBytes(res.bodyBytes, flush: true);
    await part.rename(file.path);
    return file.path;
  }
}

/// Plays a song: in the picker, to hear it before using it, and in the
/// editor, under the video. A stand-in for tests, like [MusicLibrary].
abstract class MusicPlayer {
  /// Makes the one a page uses. A seam: tests put a stand-in here.
  static MusicPlayer Function() create = DeviceMusicPlayer.new;

  /// Plays [source] — a web address or a file on the phone — from [from].
  /// [loop] starts it again when it ends.
  Future<void> play(String source, {Duration from, bool loop});
  Future<void> pause();
  Future<void> seek(Duration to);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

class DeviceMusicPlayer implements MusicPlayer {
  final _p = AudioPlayer();

  @override
  Future<void> play(
    String source, {
    Duration from = Duration.zero,
    bool loop = false,
  }) async {
    await _p.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
    await _p.play(
      source.startsWith('/') ? DeviceFileSource(source) : UrlSource(source),
      position: from,
    );
  }

  @override
  Future<void> pause() => _p.pause();

  @override
  Future<void> seek(Duration to) => _p.seek(to);

  @override
  Future<void> setVolume(double volume) => _p.setVolume(volume);

  @override
  Future<void> stop() => _p.stop();

  @override
  Future<void> dispose() async {
    try {
      await _p.dispose();
    } catch (e) {
      debugPrint('[music] could not let go of the player: $e');
    }
  }
}
