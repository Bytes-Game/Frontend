// How many reels ahead the warmer sets out to fetch.
//
// This used to be a small table against the KIND of connection — wifi, LTE,
// 3G. Wifi meant ten reels ahead, always, whatever wifi turned out to be.
//
// A device run on a wifi link measuring 2.1 to 4.5 Mbps:
//
//   starts=120   proxy=91 (76%)   network=29 (24%)
//   downloads=175   warmed=87   cancelled=88
//
// Half of every warm started was thrown away when the window moved past it.
// Not wasted alone — wasted while competing for the same link as the reel
// the viewer was actually watching.
//
// The window is now worked out from what the link measures: how many reels
// it can FINISH between one swipe and the next.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/video_player_service.dart';

void main() {
  final net = NetworkQualityService.instance;
  final cache = VideoCacheService.instance;

  // measuredBps takes the median of its samples and wants a few before it
  // will answer at all, so feed it several identical ones. Four seconds'
  // worth each, because recordThroughput ignores anything under 64 KB.
  void linkAt(int bps) {
    net.debugClearThroughput();
    for (var i = 0; i < 5; i++) {
      net.recordThroughput((bps ~/ 8) * 4, const Duration(seconds: 4));
    }
  }

  // How many reels a link SHOULD be able to finish in one dwell, worked out
  // here from the same public constants rather than typed in, so that moving
  // any of them moves the expectation with it.
  double reelsAffordableAt(int bps, {required int pictureBps}) {
    final spare = bps - pictureBps;
    return spare * NetworkQualityService.typicalDwellSeconds /
        (VideoCacheService.prefixBytes * 8);
  }

  setUpAll(() async {
    // The measured window is prefix mode only — a whole-file warm is not a
    // fixed 768 KB, so the sum does not describe it.
    await LocalMediaServer.instance.start();
  });

  setUp(() {
    net.debugClearThroughput();
    net.debugSetQuality(NetworkQuality.high);
  });

  tearDown(() => net.debugClearThroughput());

  group('the window is measured, not read off the connection type', () {
    test('wifi that is actually slow gets a small window, not ten', () {
      // The exact case from the device logs: the OS says wifi, so the old
      // table said ten. The link is 3 Mbps.
      net.debugSetQuality(NetworkQuality.high);
      linkAt(3000000);

      final depth = cache.prefetchDepth;

      expect(depth, lessThan(VideoCacheService.maxPrefetchDepth),
          reason: 'a 3 Mbps link cannot finish ten warms between swipes; '
              'setting out to is what produced 88 cancellations in 175');
      // 3 Mbps affords 480p (1.5 Mbps), leaving 1.5 Mbps spare, which is
      // about 1.4 reels per six-second dwell.
      //
      // Floored, though. This used to assert that number exactly, and the
      // exact number is below the count of players the app keeps ready —
      // so the app would hold four players against one reel of downloaded
      // bytes, which is three cold opens it chose to have.
      //
      // The 88-cancellations-in-175 this test was written for does not come
      // back with a floor of four: a warm that gets cancelled now KEEPS its
      // bytes and still counts, so an abandoned warm is no longer wasted
      // work. That was not true when this number was first chosen.
      final affordable =
          reelsAffordableAt(3000000, pictureBps: 1500000).round();
      expect(depth, affordable < VideoCacheService.minPrefetchDepth
          ? VideoCacheService.minPrefetchDepth
          : affordable);
    });

    test('never fewer reels of bytes than the app holds players', () {
      // The floor, and the reason for it. Two numbers that must agree,
      // in two files that cannot import each other — so they are pinned
      // here instead of one of them quietly drifting.
      expect(VideoCacheService.minPrefetchDepth,
          VideoPoolConfig.onScreenWorkingSet,
          reason: 'below this the app holds a player for a reel whose bytes '
              'it has not fetched, which is a cold open it chose to have');
    });

    test('even a link that can barely afford anything keeps the floor', () {
      linkAt(1200000); // slower than one 480p reel
      expect(cache.prefetchDepth, VideoCacheService.minPrefetchDepth,
          reason: 'the depth is not what protects the reel being watched — '
              'holdWarming is, and it stands every warm down the moment '
              'that reel starts waiting');
    });

    test('a fast link gets a deeper window than a slow one', () {
      linkAt(2500000);
      final slow = cache.prefetchDepth;
      linkAt(12000000);
      final fast = cache.prefetchDepth;

      expect(fast, greaterThan(slow),
          reason: 'the whole point is that the number follows the link');
    });

    test('the depth is what the spare bandwidth buys in one dwell', () {
      // Tied to the constants, not to a number somebody liked the look of.
      // Raising prefixBytes without touching this must shrink the window,
      // because each warm costs more while the link stays the same.
      linkAt(8000000);

      // 8 Mbps affords 720p_hq, the ceiling the feed asks for, at 3.5 Mbps.
      final expected = reelsAffordableAt(8000000, pictureBps: 3500000);
      expect(cache.prefetchDepth, expected.round());
      expect(expected, greaterThan(4),
          reason: 'sanity: a genuinely fast link should still read ahead '
              'properly — this change is about accuracy, not timidity');
    });

    test('the window never closes completely', () {
      // Slower than the smallest rendition. Nothing is spare. The next reel
      // is still one gesture away, so it still gets warmed.
      //
      // The speed is worked out from the ladder, not typed in. This used to
      // say 700000, which was below the smallest rung right up until a
      // smaller rung was added — at which point the link could afford it,
      // there WAS bandwidth spare, and the test was no longer about a link
      // with nothing to spare at all.
      final cheapest = (NetworkQualityService.bitrateNeededFor.values.toList()
            ..sort())
          .first;
      linkAt(cheapest ~/ 2);

      expect(net.spareBpsForReadAhead, 0);
      expect(cache.prefetchDepth, VideoCacheService.minPrefetchDepth);
      expect(VideoCacheService.minPrefetchDepth, greaterThan(0));
    });

    test('a fast speed from last run does not open ten deep', () {
      // The device log: remembered 61 Mbps, real 10. "depth=10" on five
      // lanes before a byte was measured, and three quarters of the videos
      // started from the network.
      net.debugClearThroughput();
      net.restoreRememberedBps(61100000);
      expect(cache.prefetchDepth, VideoCacheService.minPrefetchDepth);

      // Once this run has measured it for itself, the depth follows.
      linkAt(61100000);
      expect(cache.prefetchDepth, VideoCacheService.maxPrefetchDepth);
    });

    test('the window is never deeper than what shipped before', () {
      linkAt(100000000);

      expect(cache.prefetchDepth, VideoCacheService.maxPrefetchDepth,
          reason: 'this change may only ever make the window shallower; '
              'whether a very fast link wants more than ten is a separate '
              'question and is not answered here');
    });

    test('before anything is measured it falls back to the connection type',
        () {
      // The first seconds after launch, which is exactly when the first reel
      // is opening — there is no measurement yet and guessing zero would
      // mean opening the feed with nothing warm behind it.
      net.debugClearThroughput();
      expect(net.measuredBps, isNull);

      net.debugSetQuality(NetworkQuality.low);
      final onSlowType = cache.prefetchDepth;
      net.debugSetQuality(NetworkQuality.high);
      final onFastType = cache.prefetchDepth;

      expect(onSlowType, greaterThan(0));
      expect(onFastType, greaterThan(onSlowType),
          reason: 'with nothing measured, the kind of connection is still '
              'the best guess available');
    });
  });

  group('what read-ahead actually has to spend', () {
    test('it is not charged the headroom', () {
      // bitrateHeadroom is how much faster the link has to be before we will
      // PICK a rendition. It is not bandwidth the rendition spends. Charging
      // read-ahead for it understates the spare by a third of the picture —
      // most of a reel per swipe at 720p.
      linkAt(5000000);

      // 5 Mbps: 480p and 720p clear their headroom, 720p_hq (4.55 Mbps
      // needed) does not, so the picture is 720p at 2.5 Mbps.
      expect(net.affordableLabel, '720p');
      expect(net.spareBpsForReadAhead, 5000000 - 2500000);

      final withHeadroom = 5000000 -
          (2500000 * NetworkQualityService.bitrateHeadroom).round();
      expect(net.spareBpsForReadAhead, isNot(withHeadroom));
    });

    test('it is not charged for a rendition the feed never asks for', () {
      // affordableLabel will say 1080p on a fast enough link, but the feed
      // caps what it requests at reelsMaxLabel. Charging read-ahead for
      // 1080p would hide bandwidth that is genuinely free.
      linkAt(20000000);

      expect(net.affordableLabel, '1080p');
      expect(net.spareBpsForReadAhead,
          20000000 - NetworkQualityService.bitrateNeededFor[
              NetworkQualityService.reelsMaxLabel]!);
    });

    test('it says nothing rather than guessing', () {
      net.debugClearThroughput();
      expect(net.spareBpsForReadAhead, isNull);
    });
  });
}
