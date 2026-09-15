// A stalled download used to hold its slot for ever.
//
// There was no deadline of any kind on a warm — not on getting a response,
// not on the bytes arriving afterwards. A connection that went quiet mid-body
// simply sat there, holding one of the download slots until the app was
// killed. Four of those and warming is over for the session.
//
// From the device log, each line a summary taken ten reels apart:
//
//   downloads=45  warmed=25  queue=0  active=4/4
//   downloads=47  warmed=26  queue=1  active=4/4
//   downloads=50  warmed=26  queue=3  active=4/4
//   downloads=50  warmed=26  queue=1  active=4/4
//   downloads=50  warmed=26  queue=1  active=4/4
//
// Downloads stop at 50 and warmed stops at 26 while reels keep opening. Every
// slot busy, nothing finishing, the queue behind them growing. The hit rate
// fell 60% to 48% across that session as slots died one by one.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

import 'package:myapp/services/video_cache_service.dart';

void main() {
  final src = File('lib/services/video_cache_service.dart').readAsStringSync();

  group('a silent connection is given up on', () {
    test('every download path is bounded', () {
      // Three paths — the opening slice, the tail of a moov-at-end file, and
      // a whole file — and all three had the same hole.
      expect('_bounded(response.stream).listen('.allMatches(src).length, 3,
          reason: 'a download path listens to a raw stream again, so a '
              'stalled connection on it holds its slot until the app dies');
      expect(src, isNot(contains('response.stream.listen(')),
          reason: 'an unbounded listen is back');
    });

    test('and so is waiting for the response itself', () {
      expect('.timeout(responseTimeout)'.allMatches(src).length, 3,
          reason: 'httpClient.send here is the RAW client — the API '
              'wrapper\'s timeout is not on this path');
    });

    test('the clock resets on every chunk, not on the whole download', () {
      // A slow link is not a broken one. At the 2.9 Mbps this app measures a
      // slice legitimately takes seconds, and longer when several share the
      // link. A total-time cap would kill those.
      final body = bodyOf(src, 'static Stream<List<int>> _bounded(');
      expect(body, contains('body.timeout('),
          reason: 'Stream.timeout is per-event — that is what makes this an '
              'inactivity deadline rather than a total one');
      expect(body, contains('sink.addError('),
          reason: 'closing the sink instead would look like a SUCCESSFUL '
              'finish, and the reel would be registered as warm on a '
              'truncated file');
    });

    test('the deadline is long enough for a slow link', () {
      final m = RegExp(r'stallTimeout = Duration\(seconds: (\d+)\)')
          .firstMatch(src);
      expect(m, isNotNull, reason: 'the deadline is gone');
      final s = int.parse(m!.group(1)!);
      expect(s, greaterThanOrEqualTo(5),
          reason: 'shorter than this and a genuinely slow download is killed '
              'mid-flight, which is worse than the stall it prevents');
      expect(s, lessThanOrEqualTo(30),
          reason: 'longer than this and a dead connection still costs the '
              'session most of a slot');
    });
  });

  group('a stalled stream really does free the slot', () {
    // Not a source check: the whole point is what happens at runtime.
    test('it errors rather than completing quietly', () async {
      final controller = StreamController<List<int>>();
      // One chunk, then silence for ever.
      controller.add([1, 2, 3]);

      Object? err;
      var done = false;
      final got = <int>[];

      final sub = controller.stream
          .timeout(const Duration(milliseconds: 60),
              onTimeout: (sink) => sink.addError(
                  TimeoutException('download stalled')))
          .listen(got.addAll,
              onError: (Object e) => err = e,
              onDone: () => done = true,
              cancelOnError: true);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      await controller.close();

      expect(got, [1, 2, 3], reason: 'bytes that did arrive are kept');
      expect(err, isA<TimeoutException>(),
          reason: 'silence has to surface as a failure, which is what frees '
              'the slot and wakes anything waiting');
      expect(done, isFalse,
          reason: 'completing quietly would register a truncated download '
              'as a finished one');
    });

    test('a slow but moving download is left alone', () async {
      final controller = StreamController<List<int>>();
      final got = <int>[];
      Object? err;

      final sub = controller.stream
          .timeout(const Duration(milliseconds: 120),
              onTimeout: (sink) =>
                  sink.addError(TimeoutException('download stalled')))
          .listen(got.addAll, onError: (Object e) => err = e);

      // Chunks further apart than half the deadline, but never past it.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 70));
        controller.add([i]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await controller.close();

      expect(got, [0, 1, 2, 3, 4],
          reason: 'this is the case a total-time cap would have killed');
      expect(err, isNull);
    });
  });

  group('extra download slots follow the measurement, not the wifi icon', () {
    test('the rule reads spare bandwidth', () {
      final body = bodyOf(src, 'bool get _networkCanTakeMore');
      expect(body, contains('spareBpsForReadAhead'),
          reason: 'the device this is tested on reports wifi and measures '
              '2.9 Mbps — it was being given five parallel warms on a link '
              'that cannot carry two');
      expect(body, contains('perDwell >= 2'),
          reason: 'the bar is room for a second reel inside one dwell, the '
              'same arithmetic prefetchDepth uses');
    });

    test('the connection type is only the fallback', () {
      final body = bodyOf(src, 'bool get _networkCanTakeMore');
      final measuredAt = body.indexOf('spareBpsForReadAhead');
      final typeAt = body.indexOf('NetworkQuality.high');
      expect(measuredAt, lessThan(typeAt),
          reason: 'the kind of connection is for before anything has been '
              'measured, not instead of measuring');
    });

    test('the slot count still reacts to something', () {
      expect(VideoCacheService.instance.downloadSlotsForTest, greaterThan(0));
    });
  });
}
