import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/leftover_files.dart';

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

  /// The folder the songs folder goes in: the app's temporary one. A seam
  /// for tests.
  @visibleForTesting
  static Future<Directory> Function() folder = getTemporaryDirectory;

  /// What fetches a song. A seam for tests.
  @visibleForTesting
  static http.Client Function() client = http.Client.new;

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

  /// Written to the phone a piece at a time as it arrives, rather than
  /// held whole in memory first: a song can be 40 MB, and holding that much
  /// at once can make a phone stutter. Kept in [LeftoverFiles.musicFolder],
  /// which the app empties as it starts and "Free up space" empties too.
  @override
  Future<String> download(MusicTrack track) async {
    final dir = Directory(
      '${(await folder()).path}/${LeftoverFiles.musicFolder}',
    );
    await dir.create(recursive: true);
    final safe = track.sourceId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/$safe.mp3');
    // Picked before, since the app started: the same file again.
    if (await file.exists() && await file.length() > 0) return file.path;
    final part = File('${file.path}.part');
    final http.Client c = client();
    IOSink? sink;
    try {
      final res = await c
          .send(http.Request('GET', Uri.parse(track.audioUrl)))
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) {
        throw HttpException('the song answered ${res.statusCode}');
      }
      final said = res.contentLength;
      if (said != null && said > maxBytes) {
        throw HttpException('the song is $said bytes');
      }
      sink = part.openWrite();
      var got = 0;
      // Gives up when nothing arrives for a minute, not after a minute in
      // all: a slow connection still gets a long song.
      await for (final piece in res.stream.timeout(
        const Duration(seconds: 60),
      )) {
        got += piece.length;
        if (got > maxBytes) {
          throw HttpException('the song is over $maxBytes bytes');
        }
        sink.add(piece);
      }
      await sink.close();
      sink = null;
      if (got == 0) throw const HttpException('the song is empty');
      await part.rename(file.path);
      return file.path;
    } catch (e) {
      // Nothing half-written is left behind to be mistaken for a song.
      try {
        await sink?.close();
        if (await part.exists()) await part.delete();
      } catch (cleanup) {
        debugPrint('[music] could not remove a half-downloaded song: $cleanup');
      }
      rethrow;
    } finally {
      c.close();
    }
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
