// The 300 MB limit on saved videos, and the 75 MB limit on any one video.
//
// The saved openings the proxy plays from grow into the whole video as it
// is watched, and the size limit used to skip them as "bounded and tiny".
// In a long session they were most of the folder and the one part the
// limit could not touch. These tests fill the cache the way watching does
// — through the proxy — and check the limit holds without taking away the
// video on screen or the ones next to it.
//
// The big files are sparse: they report their full size without using the
// disk, so a 300 MB limit can be tested in milliseconds.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/video_cache_service.dart';

const mb = 1024 * 1024;

/// What the origin claims each video weighs. Big enough that no saved copy
/// in these tests can be "the whole video".
const originSize = 200 * mb;

Future<bool> eventually(
  bool Function() check, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return check();
}

/// A player's request to the proxy.
Future<(int, int)> play(String address, int from, int to) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(address));
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
    final res = await req.close();
    final n = await res.fold<int>(0, (a, c) => a + c.length);
    return (res.statusCode, n);
  } finally {
    client.close();
  }
}

void main() {
  late Directory dir;
  final cache = VideoCacheService.instance;
  final proxy = LocalMediaServer.instance;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sizelimit');
    cache.debugSetDirectory(dir);
    await cache.clear();
    proxy.debugReset();
    await proxy.start();
    ApiService.useClient(
      MockClient.streaming((req, _) async {
        String? range;
        for (final e in req.headers.entries) {
          if (e.key.toLowerCase() == 'range') range = e.value;
        }
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
        final s = m == null ? 0 : int.parse(m.group(1)!);
        final asked = (m == null || m.group(2)!.isEmpty)
            ? originSize - 1
            : int.parse(m.group(2)!);
        final e = asked < originSize - 1 ? asked : originSize - 1;
        return http.StreamedResponse(
          Stream.value(List<int>.filled(e - s + 1, 1)),
          206,
          contentLength: e - s + 1,
          headers: {'content-range': 'bytes $s-$e/$originSize'},
        );
      }),
    );
  });

  tearDown(() async {
    await cache.clear();
    await proxy.stop();
    proxy.debugReset();
    ApiService.useClient(http.Client());
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Warm one reel on its own, so it becomes the whole warm window.
  Future<File> warmOne(String url) async {
    cache.warm([url]);
    expect(
      await eventually(() => cache.isReady(url)),
      isTrue,
      reason: '$url should have been saved',
    );
    expect(await eventually(() => cache.debugActive == 0), isTrue);
    return File('${cache.debugFileFor(url)}.prefix');
  }

  /// Make a saved opening look like [bytes] of watched video, last touched
  /// at [at] — what the proxy leaves behind after a viewing.
  void watched(File f, int bytes, DateTime at) {
    final raf = f.openSync(mode: FileMode.append);
    raf.truncateSync(bytes);
    raf.closeSync();
    f.setLastModifiedSync(at);
  }

  test('each video may keep a quarter of the cache at most', () {
    expect(
      LocalMediaServer.maxHeadBytes * 4,
      lessThanOrEqualTo(VideoCacheService.maxCacheBytes),
    );
  });

  test('watched videos count, and the oldest go first', () async {
    final said = <String>[];
    final realPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => said.add(m ?? '');
    addTearDown(() => debugPrint = realPrint);
    final now = DateTime.now();
    final a = await warmOne('https://cdn/a.mp4');
    final b = await warmOne('https://cdn/b.mp4');
    final d = await warmOne('https://cdn/d.mp4');
    final e = await warmOne('https://cdn/e.mp4');
    final addressOfA = cache.playbackUrlFor('https://cdn/a.mp4');
    final c = await warmOne('https://cdn/c.mp4'); // now the warm window

    // Four reels watched earlier in the session, oldest first, and the one
    // about to play. 4 x 70 + 60 = 340 MB against a 300 MB limit.
    watched(a, 70 * mb, now.subtract(const Duration(minutes: 40)));
    watched(b, 70 * mb, now.subtract(const Duration(minutes: 30)));
    watched(d, 70 * mb, now.subtract(const Duration(minutes: 20)));
    watched(e, 70 * mb, now.subtract(const Duration(minutes: 10)));
    watched(c, 60 * mb, now);

    // Play a little further into c, past what is saved. The proxy keeps
    // those bytes, and that is what has to trigger the size check.
    final cAddress = cache.playbackUrlFor('https://cdn/c.mp4');
    final (status, _) = await play(cAddress, 60 * mb - 10, 60 * mb + 989);
    expect(status, HttpStatus.partialContent);
    expect(
      c.lengthSync(),
      60 * mb + 990,
      reason: 'the watched bytes were kept',
    );

    expect(
      await eventually(() => !a.existsSync()),
      isTrue,
      reason: 'the least recently watched reel should be deleted',
    );
    expect(
      said.any((l) => l.contains('cache sweep: removed 1 (1 saved openings')),
      isTrue,
      reason: 'a deleted opening is a video that no longer starts '
          'instantly; the log has to say so. Said: $said',
    );
    expect(
      b.existsSync() && d.existsSync() && e.existsSync(),
      isTrue,
      reason: 'one deletion was enough to get under the limit',
    );
    expect(c.existsSync(), isTrue);
    expect(
      await cache.bytesOnDisk(),
      lessThanOrEqualTo(VideoCacheService.maxCacheBytes),
    );

    expect(
      cache.isReady('https://cdn/a.mp4'),
      isFalse,
      reason: 'its opening is gone, so it no longer starts instantly',
    );
    final (again, n) = await play(addressOfA, 0, 99);
    expect(
      again,
      HttpStatus.partialContent,
      reason: 'a player still holding its address must keep playing',
    );
    expect(n, 100);
  });

  test('a video looping on screen is not mistaken for an old one', () async {
    final now = DateTime.now();
    final looping = await warmOne('https://cdn/looping.mp4');
    final loopingAddress = cache.playbackUrlFor('https://cdn/looping.mp4');
    final older = await warmOne('https://cdn/older.mp4');
    final d = await warmOne('https://cdn/d.mp4');
    final e = await warmOne('https://cdn/e.mp4');
    final c = await warmOne('https://cdn/c.mp4');

    // The looping reel's file was written long ago: after the first pass it
    // plays from disk and adds nothing, so its file never looks recent.
    watched(looping, 70 * mb, now.subtract(const Duration(hours: 1)));
    watched(older, 70 * mb, now.subtract(const Duration(minutes: 30)));
    watched(d, 70 * mb, now.subtract(const Duration(minutes: 20)));
    watched(e, 70 * mb, now.subtract(const Duration(minutes: 10)));
    watched(c, 60 * mb, now);

    // It loops: the player reads its start again, all from disk.
    final (s1, _) = await play(loopingAddress, 0, 99);
    expect(s1, HttpStatus.partialContent);
    looping.setLastModifiedSync(now.subtract(const Duration(hours: 1)));

    final (s2, _) = await play(
      cache.playbackUrlFor('https://cdn/c.mp4'),
      60 * mb - 10,
      60 * mb + 989,
    );
    expect(s2, HttpStatus.partialContent);

    expect(await eventually(() => !older.existsSync()), isTrue);
    expect(
      looping.existsSync(),
      isTrue,
      reason:
          'it was played seconds ago; deleting it re-downloads it '
          'on every loop',
    );
  });

  test('the reels next to the viewer are kept, however old', () async {
    final now = DateTime.now();
    final a = await warmOne('https://cdn/a.mp4');
    final b = await warmOne('https://cdn/b.mp4');
    final d = await warmOne('https://cdn/d.mp4');
    final e = await warmOne('https://cdn/e.mp4');
    final behind = await warmOne('https://cdn/behind.mp4');
    final c = await warmOne('https://cdn/c.mp4');
    // The feed warms what is ahead AND the reel behind, so a flick back
    // lands instantly. That reel was watched a while ago.
    cache.warm(['https://cdn/c.mp4', 'https://cdn/behind.mp4']);

    watched(behind, 70 * mb, now.subtract(const Duration(hours: 2)));
    watched(a, 50 * mb, now.subtract(const Duration(minutes: 40)));
    watched(b, 50 * mb, now.subtract(const Duration(minutes: 30)));
    watched(d, 50 * mb, now.subtract(const Duration(minutes: 20)));
    watched(e, 50 * mb, now.subtract(const Duration(minutes: 10)));
    watched(c, 40 * mb, now);

    final (status, _) = await play(
      cache.playbackUrlFor('https://cdn/c.mp4'),
      40 * mb - 10,
      40 * mb + 989,
    );
    expect(status, HttpStatus.partialContent);

    expect(await eventually(() => !a.existsSync()), isTrue);
    expect(
      behind.existsSync(),
      isTrue,
      reason: 'the oldest file, but it is one swipe away',
    );
  });

  test('a video the player is reading right now is kept', () async {
    final now = DateTime.now();
    final reading = await warmOne('https://cdn/reading.mp4');
    final readingAddress = cache.playbackUrlFor('https://cdn/reading.mp4');
    final a = await warmOne('https://cdn/a.mp4');
    final b = await warmOne('https://cdn/b.mp4');
    final d = await warmOne('https://cdn/d.mp4');
    final c = await warmOne('https://cdn/c.mp4');

    // An internet connection that has sent nothing yet, so the player's
    // request for `reading` stays open for as long as the test needs.
    final stalled = Completer<void>();
    ApiService.useClient(
      MockClient.streaming((req, _) async {
        String? range;
        for (final e in req.headers.entries) {
          if (e.key.toLowerCase() == 'range') range = e.value;
        }
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '')!;
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        final body = req.url.path.contains('reading')
            ? stalled.future.asStream().map(
                (_) => List<int>.filled(e - s + 1, 1),
              )
            : Stream.value(List<int>.filled(e - s + 1, 1));
        return http.StreamedResponse(
          body,
          206,
          contentLength: e - s + 1,
          headers: {'content-range': 'bytes $s-$e/$originSize'},
        );
      }),
    );
    watched(reading, 70 * mb, now);
    final open = play(readingAddress, 70 * mb - 10, 70 * mb + 989);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Everything else was touched after the player started reading, so by
    // age alone `reading` is the one to go.
    final later = now.add(const Duration(minutes: 5));
    watched(a, 70 * mb, later);
    watched(b, 70 * mb, later.add(const Duration(minutes: 1)));
    watched(d, 70 * mb, later.add(const Duration(minutes: 2)));
    watched(c, 40 * mb, later.add(const Duration(minutes: 3)));

    final (status, _) = await play(
      cache.playbackUrlFor('https://cdn/c.mp4'),
      40 * mb - 10,
      40 * mb + 989,
    );
    expect(status, HttpStatus.partialContent);

    expect(await eventually(() => !a.existsSync()), isTrue);
    expect(
      reading.existsSync(),
      isTrue,
      reason: 'the player is streaming it this moment',
    );

    stalled.complete();
    await open;
  });

  test('nothing is deleted while the cache is inside its limit', () async {
    final a = await warmOne('https://cdn/a.mp4');
    final c = await warmOne('https://cdn/c.mp4');
    watched(a, 100 * mb, DateTime.now().subtract(const Duration(hours: 1)));
    watched(c, 50 * mb, DateTime.now());

    final (status, _) = await play(
      cache.playbackUrlFor('https://cdn/c.mp4'),
      50 * mb - 10,
      50 * mb + 989,
    );
    expect(status, HttpStatus.partialContent);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.existsSync(), isTrue);
    expect(cache.isReady('https://cdn/a.mp4'), isTrue);
  });

  test('one video stops being saved at the per-video limit', () async {
    final big = await warmOne('https://cdn/big.mp4');
    final almostFull = LocalMediaServer.maxHeadBytes - 500;
    watched(big, almostFull, DateTime.now());

    // 100 bytes from disk, then 1000 from the internet. Only 500 of those
    // fit under the limit.
    final address = cache.playbackUrlFor('https://cdn/big.mp4');
    final (status, n) = await play(address, almostFull - 100, almostFull + 999);
    expect(status, HttpStatus.partialContent);
    expect(n, 1100, reason: 'the player still gets every byte it asked for');
    expect(big.lengthSync(), LocalMediaServer.maxHeadBytes);

    // Already at the limit: nothing more is added.
    final full = LocalMediaServer.maxHeadBytes;
    final (again, m) = await play(address, full - 100, full + 999);
    expect(again, HttpStatus.partialContent);
    expect(m, 1100);
    expect(big.lengthSync(), LocalMediaServer.maxHeadBytes);
  });

  test(
    'the copy stops exactly at the limit and keeps a clean prefix',
    () async {
      final sink = File('${dir.path}/pipe.out').openWrite();
      final copy = File('${dir.path}/pipe.copy').openSync(mode: FileMode.write);
      final chunks = [for (var i = 0; i < 10; i++) List<int>.filled(100, i)];

      await proxy.debugPipeWithCopy(
        Stream.fromIterable(chunks),
        sink,
        copy,
        250,
      );
      await sink.close();
      copy.closeSync();

      expect(
        File('${dir.path}/pipe.out').lengthSync(),
        1000,
        reason: 'the player is never short-changed',
      );
      final kept = File('${dir.path}/pipe.copy').readAsBytesSync();
      expect(kept.length, 250);
      expect(kept.sublist(0, 100), everyElement(0));
      expect(kept.sublist(100, 200), everyElement(1));
      expect(
        kept.sublist(200, 250),
        everyElement(2),
        reason: 'the last chunk is cut, not skipped, so there is no gap',
      );
    },
  );
}
