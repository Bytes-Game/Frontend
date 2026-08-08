// Hard tests for the loopback media proxy.
//
// This sits on the critical path of EVERY video in the app, so the bar
// here is higher than elsewhere: these drive a real HttpServer over a
// real socket with a real HTTP client, and assert byte-exact output for
// the range patterns a video player actually issues. A player that gets
// one byte-offset wrong doesn't stutter — it fails to play at all.
//
// The cases that matter:
//   * a plain open (no Range) must return the whole file
//   * a range wholly inside the cached prefix must never touch origin
//   * a range that STRADDLES the prefix boundary must stitch cache and
//     origin together with no gap and no duplication — this is the one
//     that breaks in a hand-rolled proxy
//   * a seek past the prefix must proxy straight through
//   * an unsatisfiable range must 416 rather than serve nonsense
//   * repeated failure must DEMOTE the proxy so playback falls back

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';

/// Deterministic body so byte-exact comparisons are meaningful.
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
    tmp = Directory.systemTemp.createTempSync('mediaproxy');
    prefixFile = File('${tmp.path}/clip.prefix')
      ..writeAsBytesSync(full.sublist(0, prefixLen));
    originRanges = [];

    // Origin that honours byte ranges, recording what was asked for so
    // tests can prove the cache actually spared the network.
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

  /// Real socket request against the proxy.
  Future<HttpClientResponse> get(String url, {String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    return res;
  }

  Future<List<int>> bytesOf(HttpClientResponse res) async {
    final out = <int>[];
    await for (final chunk in res) {
      out.addAll(chunk);
    }
    return out;
  }

  test('serves a local url once a prefix is registered', () {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4');
    expect(url, isNotNull);
    expect(url, startsWith('http://127.0.0.1:'));
  });

  test('unknown urls get no proxy url — caller streams from origin', () {
    expect(LocalMediaServer.instance.localUrlFor('https://cdn/other.mp4'),
        isNull);
  });

  test('a plain open returns the whole file, byte for byte', () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url);
    expect(res.statusCode, 200);
    expect(res.headers.value(HttpHeaders.contentLengthHeader), '$total');
    expect(await bytesOf(res), full);
  });

  test('a range inside the prefix is served without touching origin',
      () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url, range: 'bytes=0-499');

    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 0-499/$total');
    expect(await bytesOf(res), full.sublist(0, 500));
    expect(originRanges, isEmpty,
        reason: 'the cached opening must cost no network at all');
  });

  test('a range straddling the prefix boundary stitches without a gap',
      () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    // Starts inside the cache, ends well past it — the stitch case.
    final res = await get(url, range: 'bytes=1000-2999');

    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1000-2999/$total');
    expect(await bytesOf(res), full.sublist(1000, 3000),
        reason: 'no missing or duplicated bytes across the seam');
    expect(originRanges.single, 'bytes=$prefixLen-2999',
        reason: 'origin must be asked for exactly the uncached remainder');
  });

  test('a seek past the prefix proxies straight through', () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url, range: 'bytes=4000-4499');

    expect(res.statusCode, 206);
    expect(await bytesOf(res), full.sublist(4000, 4500));
    expect(originRanges.single, 'bytes=4000-4499');
  });

  test('an open-ended range runs to the end of the file', () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url, range: 'bytes=4990-');

    expect(res.statusCode, 206);
    expect(res.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 4990-${total - 1}/$total');
    expect(await bytesOf(res), full.sublist(4990));
  });

  test('a suffix range returns the last n bytes', () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url, range: 'bytes=-100');

    expect(res.statusCode, 206);
    expect(await bytesOf(res), full.sublist(total - 100));
  });

  test('a range past the end of the file is refused, not fudged', () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final res = await get(url, range: 'bytes=99999-100000');

    expect(res.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes */$total');
  });

  test('an unknown id 404s rather than proxying anything', () async {
    final port = LocalMediaServer.instance.debugPort;
    final res = await get('http://127.0.0.1:$port/m/not-a-real-id');
    expect(res.statusCode, 404);
    expect(originRanges, isEmpty, reason: 'must never act as an open proxy');
  });

  test('concurrent requests for the same reel all get correct bytes',
      () async {
    final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
    final results = await Future.wait([
      get(url, range: 'bytes=0-99').then(bytesOf),
      get(url, range: 'bytes=1000-1999').then(bytesOf),
      get(url, range: 'bytes=3000-3099').then(bytesOf),
    ]);

    expect(results[0], full.sublist(0, 100));
    expect(results[1], full.sublist(1000, 2000));
    expect(results[2], full.sublist(3000, 3100));
  });

  group('the prefix disappearing underneath us', () {
    // The cache sweep deletes .prefix files by LRU. Whatever the proxy
    // does when it finds one gone, it must still return correct bytes and
    // must not burn the demotion budget — otherwise one sweep followed by
    // a burst scroll turns the whole feature off for the session.

    test('an evicted prefix still serves correct bytes, from origin',
        () async {
      final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
      prefixFile.deleteSync();

      final res = await get(url, range: 'bytes=0-1999');
      expect(res.statusCode, 206);
      expect(await bytesOf(res), full.sublist(0, 2000),
          reason: 'a missing cache must degrade to origin, not to a hole');
      expect(originRanges.single, 'bytes=0-1999');
    });

    test('overlapping opens after an eviction do not demote the proxy',
        () async {
      // Sequential misses can never demote — each clean response resets
      // the budget before the next request starts. The budget is only
      // reachable when misses OVERLAP, which is exactly what a burst
      // scroll produces, so that is the shape this has to be tested in.
      //
      // An instant mock origin does not reproduce it: each handler runs to
      // completion before the next connection is even accepted. So the
      // origin here is gated — it holds every response open until all of
      // them have arrived, guaranteeing the handlers are genuinely in
      // flight at the same time.
      const n = LocalMediaServer.maxFailuresBeforeDemote + 2;
      final allArrived = Completer<void>();
      var arrived = 0;

      ApiService.useClient(MockClient.streaming((req, _) async {
        if (++arrived == n && !allArrived.isCompleted) allArrived.complete();
        await allArrived.future;
        final m = RegExp(r'bytes=(\d+)-(\d+)')
            .firstMatch(req.headers[HttpHeaders.rangeHeader] ?? '')!;
        final s = int.parse(m.group(1)!);
        final e = min(int.parse(m.group(2)!), total - 1);
        final slice = full.sublist(s, e + 1);
        return http.StreamedResponse(Stream.value(slice), 206,
            contentLength: slice.length,
            headers: {'content-range': 'bytes $s-$e/$total'});
      }));

      final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
      prefixFile.deleteSync();

      final results = await Future.wait(
        List.generate(n, (_) => get(url, range: 'bytes=0-99').then(bytesOf)),
      ).timeout(const Duration(seconds: 10));

      expect(allArrived.isCompleted, isTrue,
          reason: 'the requests must really have overlapped, or this test '
              'proves nothing');
      for (final r in results) {
        expect(r, full.sublist(0, 100));
      }
      expect(LocalMediaServer.instance.healthy, isTrue,
          reason: 'cache eviction is housekeeping, not proxy failure — one '
              'sweep must not switch the feature off for the session');
    });

    test('a reel stays playable after its prefix is evicted mid-playback',
        () async {
      // The player has already opened this URL and will keep issuing
      // ranges against it. Retracting the entry would 404 those and break
      // playback outright — strictly worse than serving them from origin.
      final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
      await bytesOf(await get(url, range: 'bytes=0-99'));

      prefixFile.deleteSync();

      final res = await get(url, range: 'bytes=100-2099');
      expect(res.statusCode, 206,
          reason: 'a live player must never be 404ed by a cache sweep');
      expect(await bytesOf(res), full.sublist(100, 2100));
    });

    test('a truncated prefix is not trusted past its real length', () async {
      // Registered as prefixLen bytes, but only half of that survives on
      // disk. Promising the player bytes we cannot deliver hangs it.
      prefixFile.writeAsBytesSync(full.sublist(0, prefixLen ~/ 2));

      final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
      final res = await get(url, range: 'bytes=0-1999');

      expect(res.statusCode, 206);
      expect(res.headers.value(HttpHeaders.contentLengthHeader), '2000');
      expect(await bytesOf(res), full.sublist(0, 2000),
          reason: 'must deliver exactly the Content-Length it promised');
      expect(originRanges.single, 'bytes=${prefixLen ~/ 2}-1999',
          reason: 'the back-fill must start where the real bytes stop');
    });
  });

  group('self-demotion', () {
    test('stops handing out proxy urls once demoted', () {
      expect(LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4'),
          isNotNull);

      LocalMediaServer.instance.debugDemote('test');

      expect(LocalMediaServer.instance.healthy, isFalse);
      expect(LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4'),
          isNull,
          reason: 'a demoted proxy must make every caller fall back');
      expect(LocalMediaServer.instance.demotionReason, 'test');
    });

    test('demotes after repeated origin failures rather than failing forever',
        () async {
      // Origin that always errors, and a prefix short enough that every
      // request has to reach it.
      ApiService.useClient(
          MockClient((_) async => http.Response('gone', 500)));

      final url = LocalMediaServer.instance.localUrlFor('https://cdn/clip.mp4')!;
      for (var i = 0; i < LocalMediaServer.maxFailuresBeforeDemote; i++) {
        try {
          final res = await get(url, range: 'bytes=$prefixLen-${prefixLen + 10}');
          await bytesOf(res);
        } catch (_) {
          // Connection torn down mid-response is an expected symptom.
        }
      }

      expect(LocalMediaServer.instance.healthy, isFalse,
          reason: 'sustained origin failure must trip the fallback');
    });
  });
}
