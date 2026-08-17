// Tests for the byte-prefetch layer that replaced player-per-upcoming-reel.
//
// Background: the feed used to make a reel "ready" by starting a whole
// player for it, so five ready reels meant five live video decoders plus
// five audio decoders. Device logs showed the audio ones decoding 144
// buffers and dropping all 144 — prefetched reels are silent — while
// background video decoders stalled for 5-9 seconds. VideoCacheService
// makes "ready" mean "the bytes are on disk", which costs no codec at
// all, so the window can be deeper AND lighter than before.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/device_capabilities.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_cache_service.dart';

/// Poll until [check] passes or we give up — downloads are async and
/// deliberately have no completion future on the public API.
Future<bool> eventually(bool Function() check,
    {Duration limit = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return check();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('reelcache');
    VideoCacheService.instance.debugSetDirectory(tmp);
    await VideoCacheService.instance.clear();
  });

  tearDown(() async {
    await VideoCacheService.instance.clear();
    ApiService.useClient(http.Client());
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('warm downloads a reel and then serves it from disk', () async {
    ApiService.useClient(
        MockClient((_) async => http.Response.bytes(List.filled(2048, 7), 200)));

    expect(VideoCacheService.instance.pathFor('https://cdn/a.mp4'), isNull,
        reason: 'nothing cached yet');

    VideoCacheService.instance.warm(['https://cdn/a.mp4']);

    expect(await eventually(() => VideoCacheService.instance.isReady('https://cdn/a.mp4')),
        isTrue);
    final path = VideoCacheService.instance.pathFor('https://cdn/a.mp4');
    expect(path, isNotNull);
    expect(File(path!).lengthSync(), 2048);
  });

  test('a cache miss reports null so the caller streams as before', () async {
    ApiService.useClient(MockClient((_) async => http.Response('nope', 404)));

    VideoCacheService.instance.warm(['https://cdn/missing.mp4']);
    // Give the failed download a chance to run.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(VideoCacheService.instance.pathFor('https://cdn/missing.mp4'), isNull);
    // And no half-written file is left claiming to be playable.
    expect(tmp.listSync().whereType<File>().length, 0);
  });

  test('refuses a file larger than the per-reel ceiling', () async {
    // Streaming mock so contentLength can be set independently of the
    // body — http.Response.bytes recomputes it, which silently defeated
    // an earlier version of this test.
    ApiService.useClient(MockClient.streaming((_, _) async =>
        http.StreamedResponse(
          Stream.value(List.filled(64, 1)),
          200,
          contentLength: VideoCacheService.maxPrefetchBytes + 1,
        )));

    VideoCacheService.instance.warm(['https://cdn/huge.mp4']);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(VideoCacheService.instance.isReady('https://cdn/huge.mp4'), isFalse);
    expect(tmp.listSync().whereType<File>().length, 0);
  });

  test('a url dropping out of the window stops being queued', () async {
    final requested = <String>[];
    ApiService.useClient(MockClient((req) async {
      requested.add(req.url.toString());
      return http.Response.bytes(List.filled(16, 3), 200);
    }));

    // Ask for a window far wider than the concurrency limit, then
    // immediately narrow it — the dropped urls must never be fetched.
    VideoCacheService.instance.warm([
      'https://cdn/1.mp4',
      'https://cdn/2.mp4',
      'https://cdn/3.mp4',
      'https://cdn/4.mp4',
      'https://cdn/5.mp4',
      'https://cdn/6.mp4',
    ]);
    VideoCacheService.instance.warm(['https://cdn/1.mp4']);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(requested, isNot(contains('https://cdn/6.mp4')),
        reason: 'scrolled-past reels must not keep consuming bandwidth');
  });

  test('re-warming an already-cached reel does not re-download', () async {
    var hits = 0;
    ApiService.useClient(MockClient((_) async {
      hits++;
      return http.Response.bytes(List.filled(32, 9), 200);
    }));

    VideoCacheService.instance.warm(['https://cdn/once.mp4']);
    expect(await eventually(() => VideoCacheService.instance.isReady('https://cdn/once.mp4')),
        isTrue);
    final first = hits;

    VideoCacheService.instance.warm(['https://cdn/once.mp4']);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(hits, first, reason: 'cached reel should not be fetched twice');
  });

  test('prefetch depth is a positive, connection-derived window', () {
    expect(VideoCacheService.instance.prefetchDepth, greaterThan(0));
  });

  // ── Prefix mode, and every way out of it ────────────────────────────
  //
  // Warming a sliver of many reels instead of all of a few is the whole
  // point of the proxy, but it puts a moving part on the critical path of
  // every video. So the requirement is not just that it works — it is
  // that every way it can fail lands back on the whole-file downloader
  // that shipped before it, with a complete, playable file on disk.
  group('prefix mode and its fallbacks', () {
    const fileSize = 4 * 1024 * 1024;

    /// Records whether each request carried a Range header, which is what
    /// distinguishes a sliver warm from a whole-file download.
    List<String?> rangesSeen = [];

    String? rangeOf(http.BaseRequest req) {
      for (final e in req.headers.entries) {
        if (e.key.toLowerCase() == 'range') return e.value;
      }
      return null;
    }

    setUp(() {
      rangesSeen = [];
      LocalMediaServer.instance.debugReset();
    });

    tearDown(() async {
      await LocalMediaServer.instance.stop();
      LocalMediaServer.instance.debugReset();
      NetworkQualityService.instance.debugSetQuality(NetworkQuality.unknown);
    });

    /// An origin that honours ranges, tracking how many bytes it served so
    /// a test can prove only a sliver was taken.
    int useRangeCapableOrigin() {
      var served = 0;
      ApiService.useClient(MockClient.streaming((req, _) async {
        final range = rangeOf(req);
        rangesSeen.add(range);
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
        if (m == null) {
          served += fileSize;
          return http.StreamedResponse(
              Stream.value(List.filled(fileSize, 1)), 200,
              contentLength: fileSize);
        }
        final s = int.parse(m.group(1)!);
        final e = m.group(2)!.isEmpty
            ? fileSize - 1
            : (int.parse(m.group(2)!) < fileSize - 1
                ? int.parse(m.group(2)!)
                : fileSize - 1);
        final len = e - s + 1;
        served += len;
        return http.StreamedResponse(
            Stream.value(List.filled(len, 1)), 206,
            contentLength: len,
            headers: {'content-range': 'bytes $s-$e/$fileSize'});
      }));
      return served;
    }

    test('warms only a sliver and routes playback through the proxy',
        () async {
      await LocalMediaServer.instance.start();
      useRangeCapableOrigin();

      VideoCacheService.instance.warm(['https://cdn/ok.mp4']);
      expect(
          await eventually(() =>
              LocalMediaServer.instance.localUrlFor('https://cdn/ok.mp4') !=
              null),
          isTrue,
          reason: 'a range-capable origin should produce a registered prefix');

      expect(VideoCacheService.instance.playbackUrlFor('https://cdn/ok.mp4'),
          startsWith('http://127.0.0.1:'));

      // The saving that justifies the whole design: a fraction of the reel
      // bought the same instant start as the entire reel used to.
      final onDisk = tmp
          .listSync()
          .whereType<File>()
          .fold<int>(0, (a, f) => a + f.lengthSync());
      expect(onDisk, lessThanOrEqualTo(VideoCacheService.prefixBytes));
      expect(onDisk * 4, lessThan(fileSize),
          reason: 'a sliver must be a small fraction of the reel');
    });

    /// Opening bytes that read as an MP4 keeping its index at the END:
    /// `ftyp` followed straight by `mdat`, so `moov` is somewhere past
    /// them. See [readMp4Layout].
    List<int> moovAtEndBytes(int len) {
      final out = List<int>.filled(len, 1);
      void box(int at, int size, String type) {
        out[at] = (size >> 24) & 0xff;
        out[at + 1] = (size >> 16) & 0xff;
        out[at + 2] = (size >> 8) & 0xff;
        out[at + 3] = size & 0xff;
        for (var i = 0; i < 4; i++) {
          out[at + 4 + i] = type.codeUnitAt(i);
        }
      }

      box(0, 16, 'ftyp');
      box(16, len - 16, 'mdat');
      return out;
    }

    /// A range-capable origin serving a moov-at-end file.
    void useMoovAtEndOrigin() {
      ApiService.useClient(MockClient.streaming((req, _) async {
        final range = rangeOf(req);
        rangesSeen.add(range);
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
        if (m == null) {
          return http.StreamedResponse(
              Stream.value(moovAtEndBytes(fileSize)), 200,
              contentLength: fileSize);
        }
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!) < fileSize - 1
            ? int.parse(m.group(2)!)
            : fileSize - 1;
        final len = e - s + 1;
        // Only the head has to look like boxes; the tail is opaque to
        // everything under test here.
        final bytes = s == 0 ? moovAtEndBytes(len) : List.filled(len, 2);
        return http.StreamedResponse(Stream.value(bytes), 206,
            contentLength: len,
            headers: {'content-range': 'bytes $s-$e/$fileSize'});
      }));
    }

    // A file whose index sits after the media used to fall out of prefix
    // warming altogether — the head alone cannot start it, so the path
    // bailed and left the reel to the whole-file fetch, which on a fast
    // scroll mostly never finished. A device profile bailed 23 of 38
    // warms this way. Now both ends are cached and the reel starts from
    // the proxy like any other.
    test('a moov-at-end file is warmed at both ends, not abandoned',
        () async {
      await LocalMediaServer.instance.start();
      useMoovAtEndOrigin();

      VideoCacheService.instance.warm(['https://cdn/moovend.mp4']);
      expect(
          await eventually(() =>
              LocalMediaServer.instance.localUrlFor('https://cdn/moovend.mp4') !=
              null),
          isTrue,
          reason: 'the reel must still be registered with the proxy');

      // The index lives in the last bytes of the file, so those are the
      // ones that had to be fetched in addition to the head.
      const tailFrom = fileSize - VideoCacheService.tailBytes;
      expect(rangesSeen, contains('bytes=$tailFrom-${fileSize - 1}'),
          reason: 'the end of the file is the half that makes this work');

      final tails =
          tmp.listSync().whereType<File>().where((f) => f.path.endsWith('.tail'));
      expect(tails, hasLength(1));
      expect(tails.first.lengthSync(), VideoCacheService.tailBytes);

      // And it is still a sliver: both ends together are a small fraction
      // of the reel, which is the whole reason for warming rather than
      // downloading.
      final onDisk = tmp
          .listSync()
          .whereType<File>()
          .fold<int>(0, (a, f) => a + f.lengthSync());
      expect(onDisk,
          VideoCacheService.prefixBytes + VideoCacheService.tailBytes);
      expect(onDisk * 3, lessThan(fileSize));
    });

    test('a moov-at-end reel small enough to fit in the head needs no tail',
        () async {
      // The opening slice already IS the whole file, index and all, so
      // there is no separate end to fetch — asking for one would re-fetch
      // bytes we are holding, and giving up would send a reel we have
      // completely cached down the whole-file path for no reason.
      await LocalMediaServer.instance.start();
      const small = 4096;
      ApiService.useClient(MockClient.streaming((req, _) async {
        rangesSeen.add(rangeOf(req));
        return http.StreamedResponse(
            Stream.value(moovAtEndBytes(small)), 206,
            contentLength: small,
            headers: {'content-range': 'bytes 0-${small - 1}/$small'});
      }));

      VideoCacheService.instance.warm(['https://cdn/tiny.mp4']);
      expect(
          await eventually(() =>
              LocalMediaServer.instance.localUrlFor('https://cdn/tiny.mp4') !=
              null),
          isTrue,
          reason: 'a fully-cached reel must be served from the proxy');
      expect(rangesSeen, hasLength(1),
          reason: 'one fetch was enough; there is no end left to ask for');
      expect(
          tmp.listSync().whereType<File>().where(
              (f) => f.path.endsWith('.tail')),
          isEmpty);
    });

    test('a moov-at-end file whose tail cannot be fetched falls back',
        () async {
      await LocalMediaServer.instance.start();
      // Head answers, tail refuses — the reel must not be left stranded
      // with a head that cannot start it.
      ApiService.useClient(MockClient.streaming((req, _) async {
        final range = rangeOf(req);
        rangesSeen.add(range);
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
        if (m == null) {
          return http.StreamedResponse(
              Stream.value(moovAtEndBytes(4096)), 200, contentLength: 4096);
        }
        final s = int.parse(m.group(1)!);
        if (s != 0) {
          return http.StreamedResponse(const Stream.empty(), 500,
              contentLength: 0);
        }
        final e = int.parse(m.group(2)!) < fileSize - 1
            ? int.parse(m.group(2)!)
            : fileSize - 1;
        final len = e - s + 1;
        return http.StreamedResponse(Stream.value(moovAtEndBytes(len)), 206,
            contentLength: len,
            headers: {'content-range': 'bytes $s-$e/$fileSize'});
      }));

      VideoCacheService.instance.warm(['https://cdn/tailfail.mp4']);
      expect(
          await eventually(() =>
              VideoCacheService.instance.pathFor('https://cdn/tailfail.mp4') !=
              null),
          isTrue,
          reason: 'it must still reach the whole-file path, as it used to');
      expect(LocalMediaServer.instance.localUrlFor('https://cdn/tailfail.mp4'),
          isNull,
          reason: 'a head that cannot start the reel must not be registered');
      expect(
          tmp.listSync().whereType<File>().where(
              (f) => f.path.endsWith('.tail')),
          isEmpty,
          reason: 'a partial tail is worse than none — see _fetchTail');
    });

    test('an origin that ignores Range falls back to the whole file',
        () async {
      await LocalMediaServer.instance.start();
      expect(LocalMediaServer.instance.healthy, isTrue);

      // Answers 200 with the full body no matter what was asked for —
      // the classic misbehaving CDN.
      ApiService.useClient(MockClient((req) async {
        rangesSeen.add(rangeOf(req));
        return http.Response.bytes(List.filled(4096, 6), 200);
      }));

      VideoCacheService.instance.warm(['https://cdn/norange.mp4']);
      expect(
          await eventually(() =>
              VideoCacheService.instance.pathFor('https://cdn/norange.mp4') !=
              null),
          isTrue,
          reason: 'a reel must still get cached when slivering is impossible');

      final path =
          VideoCacheService.instance.pathFor('https://cdn/norange.mp4')!;
      expect(File(path).lengthSync(), 4096,
          reason: 'the fallback file must be complete, not a fragment');
      expect(rangesSeen.first, isNotNull,
          reason: 'it should have tried a sliver first');
      expect(rangesSeen.last, isNull,
          reason: 'and then re-fetched without a Range');
      expect(LocalMediaServer.instance.localUrlFor('https://cdn/norange.mp4'),
          isNull,
          reason: 'nothing registered, so playback uses the file directly');
    });

    test('a demoted proxy sends warms straight down the whole-file path',
        () async {
      await LocalMediaServer.instance.start();
      LocalMediaServer.instance.debugDemote('forced for test');
      useRangeCapableOrigin();

      VideoCacheService.instance.warm(['https://cdn/demoted.mp4']);
      expect(
          await eventually(() =>
              VideoCacheService.instance.pathFor('https://cdn/demoted.mp4') !=
              null),
          isTrue);

      expect(File(VideoCacheService.instance.pathFor('https://cdn/demoted.mp4')!)
              .lengthSync(),
          fileSize,
          reason: 'demotion must yield whole, playable files');
      expect(rangesSeen, everyElement(isNull),
          reason: 'a demoted proxy must not even attempt a sliver fetch');
    });

    test('with no proxy at all, behaviour is exactly the old downloader',
        () async {
      expect(LocalMediaServer.instance.healthy, isFalse,
          reason: 'server never started');
      useRangeCapableOrigin();

      VideoCacheService.instance.warm(['https://cdn/noproxy.mp4']);
      expect(
          await eventually(() =>
              VideoCacheService.instance.pathFor('https://cdn/noproxy.mp4') !=
              null),
          isTrue);

      expect(rangesSeen, everyElement(isNull));
      expect(VideoCacheService.instance.playbackUrlFor('https://cdn/noproxy.mp4'),
          'https://cdn/noproxy.mp4',
          reason: 'no proxy means the player opens the origin as before');
    });

    test('the window only deepens when slivers are actually available',
        () async {
      NetworkQualityService.instance.debugSetQuality(NetworkQuality.high);

      final shallow = VideoCacheService.instance.prefetchDepth;
      await LocalMediaServer.instance.start();
      final deep = VideoCacheService.instance.prefetchDepth;

      expect(deep, greaterThan(shallow),
          reason: 'cheap slivers are what make a deeper window affordable; '
              'without them a deep window would just waste bandwidth');
    });

    test('an oversized reel still gets a sliver', () async {
      // Found in production: the feed carried legacy uploads of 57 MB,
      // 72 MB and one 249 MB clip. Every one of them was refused a prefix
      // because the total exceeded maxPrefetchBytes — a WHOLE-FILE budget
      // being applied to a fixed-size sliver — so the slowest videos in
      // the app were the only ones that opened with no warming at all.
      // Diagnostics showed it plainly: 20 reel starts, 1 prefix warmed.
      const huge = 249 * 1024 * 1024;
      expect(huge, greaterThan(VideoCacheService.maxPrefetchBytes));

      var servedBytes = 0;
      ApiService.useClient(MockClient.streaming((req, _) async {
        final range = rangeOf(req);
        rangesSeen.add(range);
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
        if (m == null) {
          // Whole-file path. It is right to refuse a 249 MB download, so
          // this must never be reached for the warm to be counted a win.
          return http.StreamedResponse(const Stream.empty(), 200,
              contentLength: huge);
        }
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        final len = e - s + 1;
        servedBytes += len;
        return http.StreamedResponse(
            Stream.value(List.filled(len, 1)), 206,
            contentLength: len,
            headers: {'content-range': 'bytes $s-$e/$huge'});
      }));

      await LocalMediaServer.instance.start();
      VideoCacheService.instance.warm(['https://cdn/movie.mp4']);

      expect(
          await eventually(() =>
              LocalMediaServer.instance.localUrlFor('https://cdn/movie.mp4') !=
              null),
          isTrue,
          reason: 'size gates the whole-file download, not the sliver — the '
              'first 768 KB of a 249 MB file costs exactly what the first '
              '768 KB of a 2 MB file costs, and buys far more');

      expect(servedBytes, lessThanOrEqualTo(VideoCacheService.prefixBytes),
          reason: 'warming a huge reel must stay a sliver, not creep toward '
              "the file's real size");
    });
  });

  _capTests();
}

// ── The 720p cap ────────────────────────────────────────────────────────
//
// The device that reported the problem has 7.1 GB of RAM, so the RAM
// tiers offered it 1080p on wifi — and the logs duly showed 1920x1080
// decoder sessions. RAM answers "what can this device survive?", which
// is the wrong question for a phone-sized vertical reel.
void _capTests() {
  group('reels variant cap', () {
    const variants = {
      '480p': 'https://cdn/480.mp4',
      '720p': 'https://cdn/720.mp4',
      '1080p': 'https://cdn/1080.mp4',
    };

    setUp(() {
      DeviceCapabilities.instance.ramGb = 7.1;
      // Wifi — the exact condition that produced 1920x1080 decoder
      // sessions on the reporting device. On `unknown` the order already
      // prefers 720p, so this test would pass without the cap at all.
      NetworkQualityService.instance.debugSetQuality(NetworkQuality.high);
    });
    tearDown(() {
      DeviceCapabilities.instance.ramGb = 4.0;
      NetworkQualityService.instance.debugSetQuality(NetworkQuality.unknown);
    });

    test('never picks 1080p for the feed, even on a 7GB phone on wifi', () {
      final url = NetworkQualityService.instance.pickVariantUrl(variants);
      expect(url, isNot('https://cdn/1080.mp4'));
      expect(url, 'https://cdn/720.mp4');
    });

    test('a surface that wants full detail can opt out of the cap', () {
      final url = NetworkQualityService.instance
          .pickVariantUrl(variants, maxLabel: '1080p');
      expect(url, 'https://cdn/1080.mp4');
    });

    test('device ceiling still wins when it is lower than the cap', () {
      DeviceCapabilities.instance.ramGb = 2.0; // 480p tier
      final url = NetworkQualityService.instance
          .pickVariantUrl(variants, maxLabel: '1080p');
      expect(url, 'https://cdn/480.mp4');
    });
  });

  // awaitReady exists so VideoPlayerService can hold its read-ahead spare
  // back until that reel's opening slice has actually landed. Before it,
  // prefetch() enqueued the warm and opened the player on the very next
  // line, so the answer to "is this cached?" could not yet be anything but
  // no — the one reel a single swipe away was the one reel guaranteed to
  // open against the network, and the slice it later downloaded was never
  // read by anyone.
  //
  // Two properties matter and both are timing-shaped, which is exactly the
  // kind of thing that rots silently:
  //   * it resolves as soon as the slice lands, not on a fixed delay
  //   * it never leaves a caller parked longer than warming can help
  group('awaitReady', () {
    const fileSize = 2 * 1024 * 1024;

    /// Long enough that a warm cannot land inside the short timeouts below,
    /// short enough that the stalled downloads release their slots before
    /// the next test needs them. maxConcurrentDownloads is a global, so a
    /// test that parks both slots for half a minute starves whatever runs
    /// after it — which is exactly how this group first failed.
    const stall = Duration(milliseconds: 800);

    tearDown(() async {
      await LocalMediaServer.instance.stop();
      LocalMediaServer.instance.debugReset();
    });

    /// A range-capable origin that stalls [delay] before answering, so a
    /// test can put the warm on a known side of the grace period.
    void useSlowOrigin(Duration delay) {
      ApiService.useClient(MockClient.streaming((req, _) async {
        await Future<void>.delayed(delay);
        final len = VideoCacheService.prefixBytes;
        return http.StreamedResponse(
          Stream.value(List.filled(len, 1)),
          206,
          contentLength: len,
          headers: {'content-range': 'bytes 0-${len - 1}/$fileSize'},
        );
      }));
    }

    test('resolves as soon as the sliver lands, well inside the grace',
        () async {
      LocalMediaServer.instance.debugReset();
      await LocalMediaServer.instance.start();
      useSlowOrigin(const Duration(milliseconds: 60));

      final started = DateTime.now();
      VideoCacheService.instance.warm(['https://cdn/slow.mp4']);
      final ready = await VideoCacheService.instance
          .awaitReady('https://cdn/slow.mp4', const Duration(seconds: 5));
      final waited = DateTime.now().difference(started);

      expect(ready, isTrue);
      // The point of the whole change: the caller is released by the
      // download finishing, not by the timeout expiring. If this ever
      // starts waiting out the full grace, the spare goes back to opening
      // cold and the proxy percentage collapses again.
      expect(waited, lessThan(const Duration(seconds: 2)));
      expect(VideoCacheService.instance.playbackUrlFor('https://cdn/slow.mp4'),
          startsWith('http://127.0.0.1:'));
    });

    test('gives up at the timeout rather than holding the spare forever',
        () async {
      LocalMediaServer.instance.debugReset();
      await LocalMediaServer.instance.start();
      useSlowOrigin(stall); // never lands inside the 150ms timeout below

      VideoCacheService.instance.warm(['https://cdn/stalled.mp4']);
      final ready = await VideoCacheService.instance
          .awaitReady('https://cdn/stalled.mp4', const Duration(milliseconds: 150));

      // False, not a hang and not a throw. A reel that will not warm still
      // has to get a player — a cold spare beats no spare.
      expect(ready, isFalse);
    });

    test('a url dropped from the window wakes its waiter immediately',
        () async {
      LocalMediaServer.instance.debugReset();
      await LocalMediaServer.instance.start();
      useSlowOrigin(stall);

      VideoCacheService.instance.warm(['https://cdn/a.mp4', 'https://cdn/b.mp4']);
      // b is queued behind a (maxConcurrentDownloads is 2, so give it a
      // third to be sure it is parked rather than running).
      VideoCacheService.instance
          .warm(['https://cdn/a.mp4', 'https://cdn/b.mp4', 'https://cdn/c.mp4']);

      final started = DateTime.now();
      final wait = VideoCacheService.instance
          .awaitReady('https://cdn/c.mp4', const Duration(seconds: 10));

      // The user scrolls; c leaves the window entirely.
      VideoCacheService.instance.warm(['https://cdn/a.mp4']);

      expect(await wait, isFalse);
      // Without the dequeue signal this sits out the full ten seconds for
      // a download that is never going to run.
      expect(DateTime.now().difference(started),
          lessThan(const Duration(seconds: 2)));
    });

    test('an already-warm url resolves without waiting at all', () async {
      ApiService.useClient(
          MockClient((_) async => http.Response.bytes(List.filled(1024, 3), 200)));

      VideoCacheService.instance.warm(['https://cdn/warm.mp4']);
      expect(
          await eventually(
              () => VideoCacheService.instance.isReady('https://cdn/warm.mp4')),
          isTrue);

      final started = DateTime.now();
      expect(
          await VideoCacheService.instance
              .awaitReady('https://cdn/warm.mp4', const Duration(seconds: 10)),
          isTrue);
      expect(DateTime.now().difference(started),
          lessThan(const Duration(milliseconds: 500)));
    });
  });

  group('yielding bandwidth to the reel on screen', () {
    // Warming is speculative — it is for reels the user has not swiped to
    // and may never swipe to. A back-fill is not: it is feeding a decoder
    // rendering to the screen this instant. They share one connection to
    // the CDN and so one congestion window, so treating them as equals
    // hands the watched reel a third of the bandwidth while two reels
    // nobody asked for take the rest, and the watched one stutters.

    tearDown(() {
      LocalMediaServer.instance.debugSetBackfills(0);
    });

    /// Runs [urls] through the warm pipeline against an origin that holds
    /// each request open, and reports the most downloads ever in flight
    /// at the same time.
    Future<int> peakConcurrency(List<String> urls) async {
      // A previous test's cancelled downloads can still be unwinding, and
      // they hold slots while they do — measure with those still in
      // flight and the reading is of the residue, not of the limit.
      await eventually(() => VideoCacheService.instance.debugActive == 0);

      var live = 0;
      var peak = 0;
      final started = <String>{};

      ApiService.useClient(MockClient.streaming((req, _) async {
        live++;
        if (live > peak) peak = live;
        started.add(req.url.toString());
        // Long enough that a second download would overlap this one if
        // the limit allowed it, short enough to keep the suite quick.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        live--;
        return http.StreamedResponse(
          Stream.value(List.filled(512, 1)), 200, contentLength: 512,
        );
      }));

      VideoCacheService.instance.warm(urls);
      await eventually(() => started.length == urls.length,
          limit: const Duration(seconds: 5));
      return peak;
    }

    test('two warms run side by side when nothing is playing', () async {
      // The control. Without this the test below proves only that the
      // pipeline is slow, not that it stood down.
      LocalMediaServer.instance.debugSetBackfills(0);
      expect(
        await peakConcurrency(
            ['https://cdn/i1.mp4', 'https://cdn/i2.mp4', 'https://cdn/i3.mp4']),
        VideoCacheService.maxConcurrentDownloads,
      );
    });

    test('whole-file warming stands down to one slot while a reel back-fills',
        () async {
      // No proxy bound, so warming fetches whole files. One of those is
      // unbounded up to maxPrefetchBytes, which alongside a playing reel
      // is already as much as the connection should carry.
      expect(LocalMediaServer.instance.healthy, isFalse);
      LocalMediaServer.instance.debugSetBackfills(1);
      expect(
        await peakConcurrency(
            ['https://cdn/b1.mp4', 'https://cdn/b2.mp4', 'https://cdn/b3.mp4']),
        VideoCacheService.maxConcurrentWholeFileDownloadsDuringBackfill,
        reason: 'the reel on screen has a deadline; these do not',
      );
    });

    test('prefix warming keeps two slots while a reel back-fills', () async {
      // A prefix is prefixBytes and no more, whatever the video weighs,
      // so two of them are a rounding error against a reel streaming for
      // its whole duration. Standing down to one slot here was throttling
      // the wrong thing: a device log showed five URLs queued behind that
      // single slot with most reels still opening cold.
      await LocalMediaServer.instance.start();
      addTearDown(() async {
        await LocalMediaServer.instance.stop();
        LocalMediaServer.instance.debugReset();
      });
      expect(LocalMediaServer.instance.healthy, isTrue);

      LocalMediaServer.instance.debugSetBackfills(1);
      expect(
        await peakConcurrency(
            ['https://cdn/p1.mp4', 'https://cdn/p2.mp4', 'https://cdn/p3.mp4']),
        VideoCacheService.maxConcurrentDownloadsDuringBackfill,
      );
    });

    test('but never to zero — the queue keeps moving', () async {
      // Standing down completely would be the same mistake in the other
      // direction: a long reel back-fills for its whole duration, so a
      // feed that only warms between reels is a feed with no warm reels.
      LocalMediaServer.instance.debugSetBackfills(1);
      ApiService.useClient(
          MockClient((_) async => http.Response.bytes(List.filled(512, 9), 200)));

      VideoCacheService.instance
          .warm(['https://cdn/q1.mp4', 'https://cdn/q2.mp4']);

      expect(
        await eventually(() =>
            VideoCacheService.instance.isReady('https://cdn/q1.mp4') &&
            VideoCacheService.instance.isReady('https://cdn/q2.mp4')),
        isTrue,
        reason: 'both must still finish, just one at a time',
      );
    });
  });

  group('finishing work that is nearly done', () {
    // Cancelling a warm that has left the window is meant to stop wasted
    // work. Past the halfway mark it starts causing it instead: the bytes
    // already fetched are thrown away, and a scroll back to that reel
    // pays for the whole prefix again. A device log showed the shape of
    // it — 14 cancellations against 8 downloads, and only 6 of 14 reels
    // ever warmed.

    setUp(() async {
      LocalMediaServer.instance.debugReset();
      await LocalMediaServer.instance.start();
    });

    tearDown(() async {
      await LocalMediaServer.instance.stop();
      LocalMediaServer.instance.debugReset();
    });

    /// An origin that honours ranges and hands over [head] bytes, then
    /// holds the connection open until [release] completes.
    void serveThenHold(int head, Future<void> release) {
      ApiService.useClient(MockClient.streaming((req, _) async {
        final controller = StreamController<List<int>>();
        controller.add(List.filled(head, 1));
        unawaited(release.then((_) async {
          controller.add(List.filled(VideoCacheService.prefixBytes - head, 2));
          await controller.close();
        }));
        return http.StreamedResponse(
          controller.stream,
          HttpStatus.partialContent,
          headers: {
            'content-range':
                'bytes 0-${VideoCacheService.prefixBytes - 1}/9000000',
          },
        );
      }));
    }

    test('a prefix past the halfway mark finishes instead of being dropped',
        () async {
      final release = Completer<void>();
      serveThenHold(VideoCacheService.cancelGraceBytes + 1024, release.future);

      VideoCacheService.instance.warm(['https://cdn/g1.mp4']);
      expect(await eventually(() => VideoCacheService.instance.debugActive == 1),
          isTrue);
      // Let the head arrive so the download is past the grace threshold.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The reel leaves the window.
      VideoCacheService.instance.warm(['https://cdn/other.mp4']);
      release.complete();

      expect(
        await eventually(
            () => VideoCacheService.instance.isReady('https://cdn/g1.mp4')),
        isTrue,
        reason: 'the remaining bytes cost less than fetching it all again',
      );
    });

    test('a prefix barely started is still dropped', () async {
      final release = Completer<void>();
      serveThenHold(1024, release.future);

      VideoCacheService.instance.warm(['https://cdn/g2.mp4']);
      expect(await eventually(() => VideoCacheService.instance.debugActive == 1),
          isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      VideoCacheService.instance.warm(['https://cdn/other.mp4']);
      release.complete();

      expect(
        await eventually(
            () => VideoCacheService.instance.debugActive == 0),
        isTrue,
      );
      expect(VideoCacheService.instance.isReady('https://cdn/g2.mp4'), isFalse,
          reason: 'nothing worth keeping had arrived yet');
    });

    test('a cancelled download releases its slot instead of wedging the queue',
        () async {
      // The bug this pins: cancelling a subscription fires neither onDone
      // nor onError, so the download sat forever on a future that would
      // never complete, still holding its slot. During back-fill there
      // was only one slot, so a single cancellation — which happens on
      // any ordinary scroll — stopped warming for the rest of the
      // session. On device that read `queue=5 active=1/1`, with the
      // queue never draining again.
      LocalMediaServer.instance.debugSetBackfills(1);
      addTearDown(() => LocalMediaServer.instance.debugSetBackfills(0));

      final started = <String>{};
      ApiService.useClient(MockClient.streaming((req, _) async {
        started.add(req.url.toString());
        // Never completes: every download stays in flight until cancelled,
        // so a slot can only come back by being released.
        return http.StreamedResponse(
          StreamController<List<int>>().stream,
          HttpStatus.partialContent,
          headers: {
            'content-range':
                'bytes 0-${VideoCacheService.prefixBytes - 1}/9000000',
          },
        );
      }));

      // Fill every slot, then queue one more behind them.
      final hogs = List.generate(
          VideoCacheService.maxConcurrentDownloadsDuringBackfill,
          (i) => 'https://cdn/hog$i.mp4');
      const behind = 'https://cdn/behind.mp4';
      VideoCacheService.instance.warm([...hogs, behind]);
      expect(
          await eventually(
              () => VideoCacheService.instance.debugActive == hogs.length),
          isTrue);
      expect(started, isNot(contains(behind)),
          reason: 'it should be queued behind the hogs, not running');

      // The window moves past every hog. Their slots must come back, and
      // the reel waiting behind them must get one.
      VideoCacheService.instance.warm([behind]);

      expect(
        await eventually(() => started.contains(behind)),
        isTrue,
        reason: 'a cancelled download must not hold its slot forever',
      );
    });
  });
}
