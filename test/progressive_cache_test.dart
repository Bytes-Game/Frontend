// Keeping the bytes a video has already streamed, so scrubbing is instant.
//
// The proxy served three things: a cached head, a cached tail, and the whole
// middle straight from origin — every time. The middle was never written
// down, so playing a reel twice fetched it twice, and seeking back ten
// seconds into a reel you were already watching went to the network for
// bytes that had crossed it a moment earlier.
//
// The app's own diagnostics said so and nobody had read them:
//
//     starts=50  proxy=41 (82%)  file=0 (0%)  network=9 (18%)
//
// `file=0 (0%)`. Not one reel in the session ever played from a complete
// local file, because nothing ever completed one.
//
// The fix is the one a progressive cache always makes: those bytes are
// already crossing the network on their way to the player, so write them to
// the end of the head file as they pass. No extra traffic, one disk write.
//
// The safety property that makes it simple: bytes are only ever APPENDED,
// and only when the range begins exactly where the file ends. So the file is
// a valid prefix of the video at every instant, whatever happens — a swipe
// away mid-write, the app killed, a full disk. Every reader already trusts
// its length on disk over any recorded number, so a short write costs a
// cache hit and never correctness.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';

Uint8List body(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i * 31 + 7) % 251));

void main() {
  const total = 5000;
  const prefixLen = 1200;
  final full = body(total);

  late Directory tmp;
  late File prefixFile;
  late List<String> originRanges;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('progcache');
    prefixFile = File('${tmp.path}/clip.prefix')
      ..writeAsBytesSync(full.sublist(0, prefixLen));
    originRanges = [];

    ApiService.useClient(MockClient.streaming((req, _) async {
      final header = req.headers[HttpHeaders.rangeHeader] ?? '';
      originRanges.add(header);
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header);
      if (m == null) {
        return http.StreamedResponse(Stream.value(full), 200,
            contentLength: total);
      }
      final s = int.parse(m.group(1)!);
      final e = min(int.parse(m.group(2)!), total - 1);
      final slice = full.sublist(s, e + 1);
      return http.StreamedResponse(Stream.value(slice), 206,
          contentLength: slice.length,
          headers: {'content-range': 'bytes $s-$e/$total'});
    }));

    LocalMediaServer.instance.debugReset();
    await LocalMediaServer.instance.start();
    LocalMediaServer.instance.register(
      originUrl: 'https://cdn/clip.mp4',
      prefixPath: prefixFile.path,
      prefixLength: prefixLen,
      totalLength: total,
    );
  });

  tearDown(() async {
    await LocalMediaServer.instance.stop();
    LocalMediaServer.instance.debugReset();
    ApiService.useClient(http.Client());
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String proxied() => LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;

  Future<List<int>> fetch({String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(proxied()));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final out = <int>[];
    await for (final chunk in res) {
      out.addAll(chunk);
    }
    client.close();
    return out;
  }

  test('watching a video writes what it streamed to the head file', () async {
    expect(prefixFile.lengthSync(), prefixLen,
        reason: 'precondition: only the opening slice is cached');

    final got = await fetch();
    expect(got, full, reason: 'the player must still get every byte, exactly');

    expect(
      prefixFile.lengthSync(),
      total,
      reason: 'the bytes went past on their way to the player and were not '
          'kept. Playing this reel again, or scrubbing back into it, will '
          'fetch them all over again.',
    );
  });

  test('what it wrote is the video, byte for byte', () async {
    // A cache that stores the wrong bytes is worse than one that stores
    // nothing: the player is handed corrupt media and fails to decode
    // rather than merely being slow.
    await fetch();
    expect(prefixFile.readAsBytesSync(), full);
  });

  test('the second play does not touch the network at all', () async {
    await fetch();
    originRanges.clear();

    final got = await fetch();
    expect(got, full);
    expect(originRanges, isEmpty,
        reason: 'the whole video is on disk and it went to origin anyway');
  });

  test('scrubbing back into a watched video is served from disk', () async {
    await fetch();
    originRanges.clear();

    // A seek into the middle — the case that used to always hit origin.
    final got = await fetch(range: 'bytes=2000-2999');
    expect(got, full.sublist(2000, 3000));
    expect(originRanges, isEmpty,
        reason: 'seeking into a part of the video already watched went back '
            'to the network for it');
  });

  group('the file is only ever a valid prefix', () {
    test('a seek past the cached head does not punch a hole', () async {
      // The player jumps straight to the middle without ever reading the
      // bytes in between. Appending here would leave a file whose length
      // says it holds bytes it does not.
      await fetch(range: 'bytes=3000-3999');
      expect(
        prefixFile.lengthSync(),
        prefixLen,
        reason: 'a non-contiguous range was appended, so the head file now '
            'claims a length it cannot honour and every later read of those '
            'bytes returns the wrong data',
      );
    });

    test('and the bytes it does hold are still right afterwards', () async {
      await fetch(range: 'bytes=3000-3999');
      expect(prefixFile.readAsBytesSync(), full.sublist(0, prefixLen));
    });

    test('a partial read extends it partway and stays correct', () async {
      // Swiping away mid-video: the response stops early. What was written
      // must still be exactly the opening of the file.
      await fetch(range: 'bytes=0-2499');
      final len = prefixFile.lengthSync();
      expect(len, greaterThan(prefixLen),
          reason: 'nothing was kept from a partial watch');
      expect(len, lessThanOrEqualTo(total));
      expect(prefixFile.readAsBytesSync(), full.sublist(0, len),
          reason: 'the head is no longer a prefix of the video');
    });

    test('and a later play picks up from where it got to', () async {
      await fetch(range: 'bytes=0-2499');
      originRanges.clear();
      final got = await fetch();
      expect(got, full);
      // It should only have asked for what it did not already have.
      for (final r in originRanges) {
        final m = RegExp(r'bytes=(\d+)-').firstMatch(r);
        expect(m, isNotNull);
        expect(int.parse(m!.group(1)!), greaterThanOrEqualTo(2000),
            reason: 're-fetched bytes that were already on disk: $r');
      }
    });
  });

  test('two players on the same video still leave a valid head', () async {
    // A reel and the battle opponent behind it can hold the same URL, and so
    // can the same reel reached twice.
    //
    // HONEST LIMIT OF THIS TEST. It checks the OUTCOME — both readers get
    // the right bytes and the head is still a prefix of the video — and it
    // does not prove the two guards in the append path are load-bearing.
    // Removing either one, or both, leaves this green: the origin mock
    // below holds its response until both requests are open, and even then
    // the second one's range works out empty by the time it looks.
    //
    // The guards stay because the cost of being wrong is a head file that
    // is not a prefix of anything, which hands the player bytes that are
    // not the video — and because a real network, unlike this mock, has no
    // obligation to be that tidy. They are belt and braces, and this test
    // is not the belt.
    final bothInFlight = Completer<void>();
    var opened = 0;
    ApiService.useClient(MockClient.streaming((req, _) async {
      final m = RegExp(r'bytes=(\d+)-(\d+)')
          .firstMatch(req.headers[HttpHeaders.rangeHeader] ?? '');
      final st = m == null ? 0 : int.parse(m.group(1)!);
      final en = m == null ? total - 1 : min(int.parse(m.group(2)!), total - 1);

      final controller = StreamController<List<int>>();
      if (++opened >= 2 && !bothInFlight.isCompleted) bothInFlight.complete();
      // Hand the bytes over only once both requests have opened, so the two
      // appends would overlap if anything let them.
      unawaited(bothInFlight.future
          .timeout(const Duration(seconds: 5), onTimeout: () {})
          .then((_) async {
        controller.add(full.sublist(st, en + 1));
        await controller.close();
      }));
      return http.StreamedResponse(controller.stream, 206,
          headers: {'content-range': 'bytes $st-$en/$total'});
    }));

    final results = await Future.wait([fetch(), fetch()]);
    for (final got in results) {
      expect(got, full, reason: 'a concurrent read got the wrong bytes');
    }

    final len = prefixFile.lengthSync();
    expect(len, lessThanOrEqualTo(total),
        reason: 'the head grew past the length of the video, which can only '
            'mean two writers both appended the same bytes');
    expect(prefixFile.readAsBytesSync(), full.sublist(0, len),
        reason: 'the head is not a prefix of the video — two writers '
            'interleaved');
  });
}
