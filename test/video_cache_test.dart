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
}
