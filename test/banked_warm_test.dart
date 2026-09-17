// The app was doing the work, banking it, announcing it was warm, and then
// throwing it away.
//
// A warming download hands its slice to the proxy as soon as enough of it
// exists to start a player. From that moment the reel opens from the
// device instead of the network — the work is DONE. Then, if the viewer
// had scrolled past and the download was cancelled, the cancel path
// deleted the file. The registration survived and pointed at nothing, so
// the reel still LOOKED warm and went to the network for every byte.
//
// What that cost, from one device log:
//
//     downloads=80  prefixes warmed=37  cancelled=41
//     swipe 49/13 warm/cold        -> one swipe in five landed cold
//
// Scrolling fast is the normal way to use a short-video app, not a mistake
// to punish.
//
// These tests ask the proxy for bytes over a real socket and count what
// the ORIGIN was asked for. That is the only question that matters: did
// the reel open without going to the network? Asserting that a
// registration exists proves nothing — the whole bug was a registration
// that existed and had no bytes behind it.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';

Uint8List _box(String type, int size) {
  final b = BytesBuilder();
  b.add([(size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff]);
  b.add(type.codeUnits);
  return b.toBytes();
}

/// A faststart head: ftyp, then an index of [moovSize], then media.
Uint8List _head({int ftypSize = 32, required int moovSize}) {
  final b = BytesBuilder();
  b.add(_box('ftyp', ftypSize));
  b.add(Uint8List(ftypSize - 8));
  b.add(_box('moov', moovSize));
  return b.toBytes();
}

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
  late List<String> originRanges;

  const total = 9000000;
  const moovSize = 12288;
  // What a 480p file needs before a player can start: its index, then a
  // couple of seconds of video. Well under the whole slice, so the early
  // open lands while the download is still running and can be cancelled.
  final need = 32 + moovSize + VideoCacheService.mediaReadyBytesFor('x/480p.mp4');
  // What the head actually puts ON THE WIRE: box headers only. It declares
  // a 12 KB index in 40 bytes, which is the whole point of being able to
  // read the layout off the opening bytes long before the index arrives.
  const _headBytes = 8 + (32 - 8) + 8;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('bankedwarm');
    originRanges = [];
    VideoCacheService.instance.debugSetDirectory(tmp);
    await VideoCacheService.instance.clear();
    LocalMediaServer.instance.debugReset();
    await LocalMediaServer.instance.start();
  });

  tearDown(() async {
    await VideoCacheService.instance.clear();
    await LocalMediaServer.instance.stop();
    LocalMediaServer.instance.debugReset();
    LocalMediaServer.instance.debugSetBackfills(0);
    ApiService.useClient(http.Client());
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Serve a faststart head plus [extra] bytes, then hold the connection
  /// open until [release] — so a test can stop a download at a chosen
  /// point and cancel it there. Every request is recorded.
  /// Serve a faststart head, then [beforeOpen] bytes, then — as a SEPARATE
  /// chunk after a beat — [afterOpen] more, then hold until [release].
  ///
  /// The two chunks matter. The slice is handed to the proxy partway
  /// through, and the registration can only claim what was on disk at that
  /// instant. Bytes that land after it are the ones a test needs in order
  /// to tell "claimed what it had" from "claimed everything that arrived".
  /// Deliver it all in one chunk and those two are the same number, which
  /// is how a test can pass while proving nothing.
  void serveThenHold(int beforeOpen, Future<void> release,
      {int afterOpen = 0}) {
    ApiService.useClient(MockClient.streaming((req, _) async {
      // The "scroll away" urls exist only to move the window on. Serving
      // them would leave files of their own, and then a test that counts
      // what is left on the disk is counting the wrong thing.
      if (req.url.toString().contains('elsewhere')) {
        return http.StreamedResponse(const Stream.empty(), 404);
      }
      originRanges.add(req.headers[HttpHeaders.rangeHeader] ?? '(no range)');
      final controller = StreamController<List<int>>();
      controller.add(_head(moovSize: moovSize));
      controller.add(List.filled(beforeOpen, 2));
      unawaited(() async {
        if (afterOpen > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          controller.add(List.filled(afterOpen, 4));
        }
        await release;
        final sent = _headBytes + beforeOpen + afterOpen;
        controller.add(List.filled(VideoCacheService.prefixBytes - sent, 3));
        await controller.close();
      }());
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.partialContent,
        headers: {
          'content-range': 'bytes 0-${VideoCacheService.prefixBytes - 1}/$total',
        },
      );
    }));
  }

  Future<List<int>> fetch(String url, {String? range}) async {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
    final res = await req.close();
    final out = <int>[];
    await for (final c in res) {
      out.addAll(c);
    }
    client.close();
    return out;
  }

  /// Warm [url], wait for the slice to be handed to the proxy, then scroll
  /// away so the download is cancelled. Returns the proxy address.
  Future<String> warmThenScrollAway(String url, Completer<void> release,
      {Duration linger = Duration.zero}) async {
    VideoCacheService.instance.warm([url]);
    final opened = await eventually(
        () => LocalMediaServer.instance.localUrlFor(url) != null);
    expect(opened, isTrue,
        reason: 'the early open never happened, so this test proves nothing');
    // Cancelling stops the stream at once, so anything a test wants to
    // arrive AFTER the hand-over has to arrive before the viewer moves on.
    if (linger > Duration.zero) await Future<void>.delayed(linger);
    VideoCacheService.instance.warm(['https://cdn/elsewhere/480p.mp4']);
    release.complete();
    // Let the cancel path unwind, including any deleting it wants to do.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return LocalMediaServer.instance.localUrlFor(url)!;
  }

  group('a slice that became usable survives being cancelled', () {
    test('the opening still comes off the disk, not the network', () async {
      final release = Completer<void>();
      serveThenHold(VideoCacheService.mediaReadyBytesFor('x/480p.mp4') + 32768,
          release.future);
      const url = 'https://cdn/banked/480p.mp4';

      final proxy = await warmThenScrollAway(url, release);
      originRanges.clear(); // only count what PLAYBACK asks the network for

      final got = await fetch(proxy, range: 'bytes=0-${need - 1}');

      expect(got.length, need,
          reason: 'the player asked for the opening and did not get it');
      expect(originRanges, isEmpty,
          reason: 'the bytes were deleted, so the proxy had to fetch the '
              'opening from the network all over again — which is exactly '
              'the cold open the warm was paid for to avoid');
    });

    test('everything that arrived is used, not just what had arrived at the '
        'moment it was handed over', () async {
      final release = Completer<void>();
      // Just enough to trigger the hand-over, then a second helping that
      // lands afterwards.
      // Enough to cross what this file NEEDS (index included), so the
      // hand-over happens on THIS chunk and the next one lands after it.
      // Sized off the media alone it falls short by the index, the
      // hand-over slides onto the last chunk, and then "what it had" and
      // "everything that arrived" are the same number again.
      final openAt = need - _headBytes + 4096;
      const late_ = 65536;
      serveThenHold(openAt, release.future, afterOpen: late_);
      const url = 'https://cdn/more/480p.mp4';

      final proxy = await warmThenScrollAway(url, release,
          linger: const Duration(milliseconds: 200));
      originRanges.clear();

      // Squarely inside the bytes that arrived AFTER the hand-over. If the
      // registration still claims only what was there at that instant,
      // these come off the network instead of the disk.
      final from = _headBytes + openAt + 1024;
      final got = await fetch(proxy, range: 'bytes=$from-${from + 16384 - 1}');

      expect(got.length, 16384);
      expect(originRanges, isEmpty,
          reason: 'bytes that are sitting on the disk were fetched again '
              'because the registration froze at the hand-over point');
    });
    test('and the lane is given straight back, not held to the end', () async {
      // Banking is not the same as sparing. A spared download keeps running
      // and keeps its lane; a banked one can be let go the instant the
      // viewer moves on, because its bytes are already safe. That is the
      // difference between three lanes working for the reels ahead of you
      // and three lanes finishing reels you have already scrolled past.
      final release = Completer<void>();
      serveThenHold(VideoCacheService.mediaReadyBytesFor('x/480p.mp4') + 32768,
          release.future);
      const url = 'https://cdn/lane/480p.mp4';

      await warmThenScrollAway(url, release);

      expect(VideoCacheService.instance.debugPipeline, contains('spared=0'),
          reason: 'the download was kept alive to the end instead of being '
              'let go, so its lane was unavailable for the reels that are '
              'actually coming up');
      expect(LocalMediaServer.instance.localUrlFor(url), isNotNull,
          reason: 'let go AND lost, which is the worst of both');
    });

    test('and the log counts it as the warm reel it is', () async {
      // `prefixes warmed` against `cancelled` is the number these fixes
      // are read by. A banked reel that goes uncounted makes warming look
      // like it is failing when it is working, and this app has already
      // lost a round of diagnosis to a counter that told the wrong story.
      ReelDiagnostics.instance.debugReset();
      final release = Completer<void>();
      serveThenHold(VideoCacheService.mediaReadyBytesFor('x/480p.mp4') + 32768,
          release.future);
      const url = 'https://cdn/counted/480p.mp4';

      await warmThenScrollAway(url, release);

      expect(ReelDiagnostics.instance.debugPrefixWarmed, 1,
          reason: 'the reel is warm and playable but the log says it is not');
    });
  });

  group('whether a reel has been acted on yet', () {
    // The quality picker asks this before changing its mind about which
    // rendition a reel should use. "Acted on" has to include work that has
    // STARTED and not only work that has finished: abandoning a download
    // half way through wastes exactly as much as abandoning a finished one,
    // and the half-finished case is the common one during a fast scroll.

    test('a reel nothing has touched is free', () {
      expect(VideoCacheService.instance.isSpokenFor('https://cdn/nobody.mp4'),
          isFalse);
    });

    test('a reel being downloaded right now is spoken for', () async {
      final release = Completer<void>();
      serveThenHold(4096, release.future);
      const url = 'https://cdn/inflight/480p.mp4';
      VideoCacheService.instance.warm([url]);

      expect(await eventually(() => VideoCacheService.instance.isSpokenFor(url)),
          isTrue,
          reason: 'a download in flight reads as untouched, so the picker '
              'switches file and throws the work away');
      release.complete();
    });

    test('a reel waiting for a slot is spoken for', () async {
      // More urls than lanes, so at least one has to queue.
      final release = Completer<void>();
      serveThenHold(4096, release.future);
      final urls = [
        for (var i = 0; i < 9; i++) 'https://cdn/q$i/480p.mp4',
      ];
      VideoCacheService.instance.warm(urls);

      expect(
        await eventually(() => urls.any((u) =>
            VideoCacheService.instance.isSpokenFor(u))),
        isTrue,
        reason: 'a reel the app has already committed to fetching reads as '
            'untouched while it waits its turn',
      );
      release.complete();
    });
  });

  group('work that never became usable is still cleaned up', () {
    test('a few bytes of index is not a warm reel', () async {
      final release = Completer<void>();
      ApiService.useClient(MockClient.streaming((req, _) async {
        if (req.url.toString().contains('elsewhere')) {
          return http.StreamedResponse(const Stream.empty(), 404);
        }
        originRanges.add(req.headers[HttpHeaders.rangeHeader] ?? '');
        final controller = StreamController<List<int>>();
        controller.add(_head(moovSize: moovSize));
        unawaited(release.future.then((_) async => controller.close()));
        return http.StreamedResponse(
          controller.stream,
          HttpStatus.partialContent,
          headers: {
            'content-range':
                'bytes 0-${VideoCacheService.prefixBytes - 1}/$total',
          },
        );
      }));

      const url = 'https://cdn/tooLittle/480p.mp4';
      VideoCacheService.instance.warm([url]);
      expect(await eventually(() => VideoCacheService.instance.debugActive >= 1),
          isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      VideoCacheService.instance.warm(['https://cdn/elsewhere3/480p.mp4']);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(LocalMediaServer.instance.localUrlFor(url), isNull,
          reason: 'claiming a reel is warm when it cannot be played from '
              'disk is the cache-hit lie that moovAtEnd was added to stop');

      // And the scrap is not left lying on the device either. Keeping a
      // slice is only right when something can play it; keeping every
      // abandoned fragment just fills the phone with files nothing will
      // ever open.
      final leftovers =
          tmp.listSync().whereType<File>().where((f) => f.lengthSync() > 0);
      expect(leftovers, isEmpty,
          reason: 'a fragment too small to play was kept anyway');
    });
  });

  group('how much work is worth finishing', () {
    test('a download more than halfway to usable is allowed to finish',
        () async {
      // Below the OLD flat threshold of 384 KB, above half of what this
      // particular file needs. The old rule binned this; it was a fixed
      // byte count standing in for a question about a specific file.
      final half = need ~/ 2;
      expect(half, lessThan(VideoCacheService.cancelGraceBytes),
          reason: 'this test only means something while the proportional '
              'threshold is below the flat one it replaced');

      // NB the head helper writes box HEADERS only — it is 40 bytes on the
      // wire that DECLARE a 12 KB index, which is the whole point of
      // reading the layout off the opening bytes. So the served total is
      // 40 + extra, not 12 KB + extra.
      final release = Completer<void>();
      serveThenHold(half + 8192, release.future);
      const url = 'https://cdn/halfway/480p.mp4';

      VideoCacheService.instance.warm([url]);
      expect(await eventually(() => VideoCacheService.instance.debugActive >= 1),
          isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      // Scroll away. It has not opened early yet, so the only thing that
      // can save this work is the spare rule.
      VideoCacheService.instance.warm(['https://cdn/elsewhere4/480p.mp4']);
      release.complete();

      expect(
        await eventually(
            () => LocalMediaServer.instance.localUrlFor(url) != null),
        isTrue,
        reason: 'more than half the work was done and it was thrown away',
      );
    });
  });

  group('how many reels can be fetched at once', () {
    test('a bounded slice does not lose a lane just because a reel is '
        'still pulling bytes', () async {
      // Prefix warms are a fixed small slice each, so three of them in
      // flight is bounded extra traffic. The reel on screen is protected
      // by holdWarming, not by starving the queue: a device log ended a
      // session pinned at two lanes with 41 of 80 warms cancelled.
      LocalMediaServer.instance.debugSetBackfills(1);
      final release = Completer<void>();
      serveThenHold(1024, release.future);

      VideoCacheService.instance.warm([
        'https://cdn/l1/480p.mp4',
        'https://cdn/l2/480p.mp4',
        'https://cdn/l3/480p.mp4',
      ]);

      expect(await eventually(() => VideoCacheService.instance.debugActive >= 3),
          isTrue,
          reason: 'two lanes cannot get ahead of somebody scrolling');
      expect(VideoCacheService.instance.debugPipeline, contains('/3'),
          reason: 'the ceiling itself dropped, so the queue backs up the '
              'moment a reel is pulling bytes — which is most of the time');
      release.complete();
    });
  });
}
