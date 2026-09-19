// Measuring the link, not one lane of it.
//
// ═══════════════════════════════════════════════════════════════════════
// WHY A 12 Mbps LINK READ AS 4
// ═══════════════════════════════════════════════════════════════════════
//
// Throughput used to be timed one download at a time: start a slice, finish
// it, divide. That answers "how fast was that download". It is not the
// question, because the app runs up to THREE at once.
//
// Three downloads sharing a 12 Mbps link each clock about 4. Every sample
// says 4, the median says 4, and the app concludes the link is 4 — a third
// of what it is. It then refuses 720p, which needs 4.3, and serves a soft
// picture on a connection that could carry the sharp one three times over:
//
//     quality{480p:29  link=4.2Mbps affords=480p}
//
// So the meter sums bytes across EVERYTHING in flight and divides by the
// time the link was actually busy. One download or four, it measures the
// same thing.
//
// Busy time, not wall time. A gap with nothing downloading is not a slow
// link, and counting it would drag every reading down in exactly the quiet
// stretches where somebody is watching rather than scrolling.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';

void main() {
  final net = NetworkQualityService.instance;

  setUp(() {
    net.debugClearThroughput();
    net.debugSetQuality(NetworkQuality.high);
  });

  tearDown(net.debugClearThroughput);

  /// Push [bytes] through the meter across [lanes] downloads, over roughly
  /// [ms] of real time. Real time, because the meter reads a stopwatch —
  /// the waits are short and every assertion below is a wide band, so a
  /// slow machine changes nothing.
  Future<void> transfer({
    required int lanes,
    required int bytes,
    required int ms,
  }) async {
    for (var i = 0; i < lanes; i++) {
      net.noteTransferStarted();
    }
    // Dribbled in, the way a real download arrives, rather than dumped at
    // the end. It matters: bytes and time have to accrue TOGETHER, or the
    // window boundaries land in places no real transfer would put them and
    // the test ends up measuring its own helper.
    const steps = 10;
    final perStep = bytes ~/ steps;
    final perLane = perStep ~/ lanes;
    for (var s = 0; s < steps; s++) {
      await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
      // Every lane delivers its share. That is the whole point.
      for (var i = 0; i < lanes; i++) {
        net.noteBytesFromNetwork(perLane);
      }
    }
    for (var i = 0; i < lanes; i++) {
      net.noteTransferFinished();
    }
  }

  group('three lanes are still one link', () {
    test('the reading is the total, not one lane of it', () async {
      // 1 MB in ~300ms is roughly 28 Mbps however it is split up. Split
      // three ways, the OLD per-download timing would have said about 9.
      await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);
      await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);
      await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);

      final bps = net.measuredBps;
      expect(bps, isNotNull);
      expect(bps!, greaterThan(15000000),
          reason: 'the link was read as one lane of itself, which is how a '
              'fast connection talks the app into a soft picture');
      // And an upper bound, because a meter that never clears what it has
      // counted climbs for ever. Too FAST is not the safe direction: it
      // picks a rendition the link cannot carry, which is a video that
      // stops rather than one that is soft.
      expect(bps, lessThan(45000000),
          reason: 'a ~28 Mbps transfer read as $bps — bytes from earlier '
              'windows are being counted a second time, so the reading '
              'climbs with every chunk. Too FAST is not the safe direction: '
              'it picks a rendition the link cannot carry, which is a video '
              'that stops rather than one that is soft');
    });

    test('and one lane alone reads the same as three', () async {
      // Same bytes, same time, different number of downloads carrying it.
      // The link did not change, so the answer must not either.
      for (var i = 0; i < 3; i++) {
        await transfer(lanes: 1, bytes: 1024 * 1024, ms: 300);
      }
      final solo = net.measuredBps!;

      net.debugClearThroughput();
      for (var i = 0; i < 3; i++) {
        await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);
      }
      final shared = net.measuredBps!;

      expect((shared - solo).abs() / solo, lessThan(0.5),
          reason: 'the same link measured $solo alone and $shared shared');
    });

    test('the log says how many lanes the reading came from', () async {
      await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);
      expect(net.lanesAtLastSample, 3,
          reason: 'a reading taken across three lanes means something '
              'different from the same reading across one, and the log '
              'could not tell them apart');
    });

    test('and it actually reaches the line that gets read', () async {
      // Knowing it internally is worth nothing. This number exists to be
      // read off a device log six weeks from now, next to the speed it
      // qualifies.
      for (var i = 0; i < 3; i++) {
        await transfer(lanes: 3, bytes: 1024 * 1024, ms: 300);
      }
      final line = NetworkQualityService.variantPicksSummary();
      expect(line, contains('link='));
      expect(line, contains('lanes=3'),
          reason: 'the log gives a speed with no way to tell whether it was '
              'divided by three, which is the confusion this ends');
    });
  });

  group('time the link was idle is not slow link', () {
    test('gaps between downloads are not charged to the network', () async {
      // Four bursts, each with a long idle stretch after it — somebody
      // watching a video rather than scrolling. Every burst moves 1 MB in
      // about 300ms, which is roughly 28 Mbps.
      //
      // If the idle time were counted too, each reading would be 1 MB over
      // 700ms rather than 300 — about 12 Mbps — and the app would decide
      // the link had thinned out every time the viewer stopped to watch
      // something, which is precisely when it has not.
      for (var i = 0; i < 4; i++) {
        await transfer(lanes: 1, bytes: 1024 * 1024, ms: 300);
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }

      expect(net.debugSampleCount, greaterThanOrEqualTo(3));
      expect(net.measuredBps!, greaterThan(20000000),
          reason: 'the idle milliseconds were charged to the network, so '
              'watching a video reads as the connection getting worse');
    });
  });

  group('what is too small to mean anything', () {
    test('a trickle does not produce a reading', () async {
      for (var i = 0; i < 5; i++) {
        net.noteTransferStarted();
        net.noteBytesFromNetwork(1024);
        net.noteTransferFinished();
      }
      expect(net.debugSampleCount, 0,
          reason: 'a few kilobytes timed to the millisecond is noise, and '
              'it would sit in the median like a real answer');
    });

    test('an instant burst does not either', () async {
      // A quarter of a megabyte out of a local buffer with no time on the
      // clock would read as a gigabit link.
      net.noteTransferStarted();
      net.noteBytesFromNetwork(2 * 1024 * 1024);
      net.noteTransferFinished();
      expect(net.debugSampleCount, 0);
    });

    test('a slow trickle over a long time is still not a reading', () async {
      // The other half of the guard. This one has plenty of TIME on the
      // clock — it is the bytes that are missing. One kilobyte across a
      // third of a second reads as a 25 kbps link, and it would sit in the
      // median looking exactly like a real answer.
      net.noteTransferStarted();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      net.noteBytesFromNetwork(1024);
      net.noteTransferFinished();
      expect(net.debugSampleCount, 0,
          reason: 'a kilobyte was recorded as this connection\'s speed');
    });

    test('a brief fast burst is not what the link can sustain', () async {
      // Plenty of bytes, but measured over a sliver of time. A quarter of a
      // megabyte out of a warm buffer or a CDN edge that already had it
      // arrives in a blink and reads as a far faster link than this phone
      // will ever actually get.
      //
      // Note this needs its own case: the existing "instant burst" test has
      // NO time on the clock at all, and is stopped by the intake floor
      // further down rather than by the window's own minimum. It would pass
      // with that minimum deleted.
      net.noteTransferStarted();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      net.noteBytesFromNetwork(300 * 1024);
      net.noteTransferFinished();
      expect(net.debugSampleCount, 0,
          reason: 'sixty milliseconds of a warm buffer was recorded as this '
              'connection\'s speed, and the app will pick a rendition the '
              'link cannot carry — a video that STOPS, which is worse than '
              'one that is soft');
    });

    test('a part-filled window waits rather than guessing', () async {
      // Between the two floors: plenty of time on the clock, and more than
      // the bare minimum of bytes, but not enough for the reading to mean
      // anything. A window this short is dominated by wherever the chunk
      // boundaries happened to fall.
      net.noteTransferStarted();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      net.noteBytesFromNetwork(100 * 1024);
      net.noteTransferFinished();
      expect(net.debugSampleCount, 0,
          reason: 'a hundred kilobytes decided what this connection is');
    });

    test('and nothing at all is not a reading of zero', () {
      expect(net.measuredBps, isNull);
      expect(net.lanesAtLastSample, 0);
    });
  });
}
