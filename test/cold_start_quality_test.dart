// The app used to assume the best case and find out later.
//
// A feed page arrives with twenty items and every one is assigned a
// rendition the MOMENT IT IS PARSED — before a single byte has been
// downloaded, so before anything has been measured. With nothing measured
// the ceiling stayed at the top rung, and the preference order for an
// unknown connection starts at 720p_hq, so the whole first page was
// committed to the largest files on no evidence at all.
//
// One session, from the device log:
//
//     quality{720p_hq:19 ... link=measuring}
//     quality{720p_hq:19 ... link=5.5Mbps affords=720p}
//     quality{720p_hq:19 ... link=4.0Mbps affords=480p}
//     quality{720p_hq:19 ... link=2.9Mbps affords=480p}
//
// Nineteen reels at the top rung while blind — and then the count never
// moved again across seventy more picks. Once it could measure, the app
// decided this link could not carry 720p_hq even once. It took nineteen
// reels to find that out, and those are the ones that stalled: every cold
// open in the session landed in the first fifty reels, and the last forty
// swipes had none at all.
//
// Two fixes, both tested here: open low while blind, and do not BE blind
// on every launch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';

void main() {
  const variants = {
    '480p': 'https://cdn/a/480p.mp4',
    '720p': 'https://cdn/a/720p.mp4',
    '720p_hq': 'https://cdn/a/720p_hq.mp4',
  };

  late NetworkQualityService nq;

  setUp(() {
    nq = NetworkQualityService.instance;
    nq.debugClearThroughput();
    nq.debugClearChosenVariants();
    NetworkQualityService.variantPicks.clear();
    NetworkQualityService.onSpeedSettled = null;
  });

  tearDown(() {
    nq.debugClearThroughput();
    nq.debugClearChosenVariants();
    NetworkQualityService.onSpeedSettled = null;
  });

  group('what the very first page gets', () {
    test('not the biggest file, on no evidence at all', () {
      expect(nq.measuredBps, isNull, reason: 'the test is not set up blind');
      final picked = nq.pickVariantUrl(Map.of(variants));
      expect(picked, isNot(contains('720p_hq')),
          reason: 'committing the first page to the largest files before a '
              'single byte has been measured is what stalled nineteen reels');
      expect(picked, contains('480p'));
    });

    test('the cautious rung is a real rung', () {
      expect(NetworkQualityService.bitrateNeededFor.keys,
          contains(NetworkQualityService.unmeasuredMaxLabel),
          reason: 'a ceiling nothing can satisfy leaves the picker nothing '
              'to choose');
    });

    test('and it is below the one used when measurements exist', () {
      expect(NetworkQualityService.unmeasuredMaxLabel,
          isNot(NetworkQualityService.reelsMaxLabel),
          reason: 'blind and informed picking the same rung is the bug');
    });

    test('a video that only has the big rung still plays', () {
      // The ceiling must not be able to refuse the only file there is.
      final only = {'720p_hq': 'https://cdn/b/720p_hq.mp4'};
      final picked = nq.pickVariantUrl(Map.of(only));
      expect(picked, isNotNull);
      expect(picked, isNotEmpty,
          reason: 'being cautious turned into serving nothing');
    });
  });

  group('once the link has been measured', () {
    test('a fast link is allowed past the cautious ceiling', () {
      // Three readings is what the median needs before it will speak.
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(1024 * 1024, const Duration(milliseconds: 100));
      }
      expect(nq.measuredBps, isNotNull);
      final picked = nq.pickVariantUrl(Map.of(variants));
      expect(picked, contains('720p'),
          reason: 'evidence of a fast link has to be able to raise the '
              'ceiling, or the app is permanently cautious');
    });

    test('a slow link stays low', () {
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(100 * 1024, const Duration(milliseconds: 900));
      }
      expect(nq.pickVariantUrl(Map.of(variants)), contains('480p'));
    });
  });

  group('not being blind on every launch', () {
    test('last run\'s reading opens this one', () {
      nq.restoreRememberedBps(12000000); // a fast link, measured before
      expect(nq.measuredBps, 12000000);
      expect(nq.pickVariantUrl(Map.of(variants)), contains('720p'),
          reason: 'the app re-paid the whole cold start on every launch');
    });

    test('this run\'s own readings beat it', () {
      nq.restoreRememberedBps(12000000); // was on fast wifi
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(100 * 1024, const Duration(milliseconds: 900));
      }
      expect(nq.measuredBps, lessThan(12000000),
          reason: 'moving to a slower connection has to correct itself, not '
              'be believed for the whole session');
      expect(nq.pickVariantUrl(Map.of(variants)), contains('480p'));
    });

    test('nonsense is not restored', () {
      // One at a time. Running them together proves nothing: the last call
      // would leave null behind whether the guard exists or not, so the
      // test passes with the guard deleted.
      for (final junk in <int?>[0, -1, null]) {
        nq.debugClearThroughput();
        nq.restoreRememberedBps(junk);
        expect(nq.measuredBps, isNull,
            reason: 'restoring $junk left the picker believing it, and a '
                'broken stored value then decides what quality people get');
      }
    });

    test('nonsense does not wipe a good value already restored', () {
      nq.restoreRememberedBps(5000000);
      nq.restoreRememberedBps(0);
      expect(nq.measuredBps, 5000000,
          reason: 'one unreadable write and the app is blind again');
    });
  });

  _provisionalTests();

  group('the stored reading is there before the feed needs it', () {
    // main() cannot be unit-tested, and the property matters: the first
    // feed page is parsed within moments of the app starting, and gives
    // every item on it a quality right then. If the read has not landed
    // yet, that whole page is chosen blind and the session opens soft on a
    // connection that was measured and stored yesterday.
    //
    // Fired and forgotten it USUALLY wins the race, which is the worst kind
    // of correct: it fails occasionally and looks like something else.
    final main = File('lib/main.dart').readAsStringSync();

    test('the read is awaited, not fired and forgotten', () {
      expect(main, contains('await LinkSpeedStore.instance.read()'),
          reason: 'a race whose prize is the quality of the whole first '
              'page, decided by whichever finishes first');
      expect(main, isNot(contains('LinkSpeedStore.instance.read().then')),
          reason: 'back to fire-and-forget');
    });

    test('and it happens before the app runs', () {
      final readAt = main.indexOf('LinkSpeedStore.instance.read()');
      final runAt = main.indexOf('runApp(');
      expect(readAt, greaterThan(-1));
      expect(runAt, greaterThan(-1));
      expect(readAt, lessThan(runAt),
          reason: 'awaited, but after the app has already started, which '
              'awaits nothing that matters');
    });
  });

  group('keeping the reading for next time', () {
    test('it is offered once there is something to say', () {
      final offered = <int>[];
      NetworkQualityService.onSpeedSettled = offered.add;
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(1024 * 1024, const Duration(milliseconds: 100));
      }
      expect(offered, isNotEmpty,
          reason: 'nothing is kept, so the next launch starts blind again');
    });

    test('not on every download', () {
      final offered = <int>[];
      NetworkQualityService.onSpeedSettled = offered.add;
      for (var i = 0; i < 8; i++) {
        // Same speed every time — the reading is not moving.
        nq.recordThroughput(1024 * 1024, const Duration(milliseconds: 100));
      }
      expect(offered.length, 1,
          reason: 'a disk write per video, for a number nothing reads until '
              'the next launch');
    });

    test('but again when the link really changes', () {
      final offered = <int>[];
      NetworkQualityService.onSpeedSettled = offered.add;
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(1024 * 1024, const Duration(milliseconds: 100));
      }
      final first = offered.length;
      for (var i = 0; i < 8; i++) {
        nq.recordThroughput(100 * 1024, const Duration(milliseconds: 900));
      }
      expect(offered.length, greaterThan(first),
          reason: 'the stored guess goes stale and the next launch opens on '
              'a speed this phone no longer has');
    });

    test('only a live reading is offered, never the restored one', () {
      // Writing the remembered value back would let one unusual session
      // pin the guess for ever.
      final offered = <int>[];
      NetworkQualityService.onSpeedSettled = offered.add;
      nq.restoreRememberedBps(9000000);
      expect(offered, isEmpty);
      expect(nq.bpsWorthRemembering, isNull);
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
// A GUESS MADE IN THE DARK SHOULD NOT OUTLIVE THE DARK
// ═══════════════════════════════════════════════════════════════════════
//
// Opening low while blind fixed the stalling — a later session logged 91
// swipes and NOT ONE cold open, where the session before it had ten. But
// the cautious choice was remembered, so it lasted the whole session:
//
//     quality{480p:28 link=measuring}                    <- first page
//     quality{480p:32 720p_hq:11 720p:4 link=8.7Mbps affords=720p_hq}
//
// The link turned out to be 8.7 Mbps, comfortably able to carry the best
// rendition there is, and the twenty-eight items at the top of the feed —
// the ones actually watched — stayed soft until the app was closed.
//
// So a blind choice is provisional, and made again once there is evidence.
// But only while nothing has acted on it: re-choosing after a file has been
// downloaded throws that work away, and re-choosing under a player that is
// open on it restarts the video in the viewer's face.

void _provisionalTests() {
  const variants = {
    '480p': 'https://cdn/p/480p.mp4',
    '720p': 'https://cdn/p/720p.mp4',
    '720p_hq': 'https://cdn/p/720p_hq.mp4',
  };

  late NetworkQualityService nq;

  setUp(() {
    nq = NetworkQualityService.instance;
    nq.debugClearThroughput();
    nq.debugClearChosenVariants();
    NetworkQualityService.isUrlCommitted = null;
    NetworkQualityService.onSpeedSettled = null;
  });

  tearDown(() {
    nq.debugClearThroughput();
    nq.debugClearChosenVariants();
    NetworkQualityService.isUrlCommitted = null;
  });

  void measureFast() {
    for (var i = 0; i < 3; i++) {
      nq.recordThroughput(2 * 1024 * 1024, const Duration(milliseconds: 100));
    }
  }

  group('a choice made in the dark is provisional', () {
    test('and is made again once the link has been measured', () {
      final blind = nq.stickyVariantUrl('c:1', Map.of(variants));
      expect(blind, contains('480p'), reason: 'not blind to begin with');

      measureFast();
      final after = nq.stickyVariantUrl('c:1', Map.of(variants));
      expect(after, isNot(contains('480p')),
          reason: 'the whole first page stays soft for the session, on a '
              'link that turned out to carry the best rendition there is');
    });

    test('but only once — after that it is settled', () {
      nq.stickyVariantUrl('c:2', Map.of(variants));
      measureFast();
      final first = nq.stickyVariantUrl('c:2', Map.of(variants));
      final second = nq.stickyVariantUrl('c:2', Map.of(variants));
      expect(second, first,
          reason: 'a reel whose choice keeps moving is a reel that keeps '
              'throwing away the download it just started');
    });

    test('a choice made WITH evidence is never revisited', () {
      measureFast();
      final chosen = nq.stickyVariantUrl('c:3', Map.of(variants));
      // The link gets worse. The reel keeps what it has, because warming
      // and playing have to agree on one file.
      nq.debugClearThroughput();
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(100 * 1024, const Duration(milliseconds: 900));
      }
      expect(nq.stickyVariantUrl('c:3', Map.of(variants)), chosen);
    });

    test('still blind means still the same answer', () {
      final a = nq.stickyVariantUrl('c:4', Map.of(variants));
      final b = nq.stickyVariantUrl('c:4', Map.of(variants));
      expect(b, a, reason: 'warming and playing disagreed while blind');
    });

    test('and is not re-chosen over and over while it stays blind', () {
      // Same answer every time, so a re-choice is invisible in the URL —
      // but not in the log. Every pass through the picker is counted, and
      // the feed re-parses constantly, so the quality line that these
      // fixes are read by would report hundreds of picks for twenty reels.
      NetworkQualityService.variantPicks.clear();
      for (var i = 0; i < 5; i++) {
        nq.stickyVariantUrl('c:10', Map.of(variants));
      }
      final total =
          NetworkQualityService.variantPicks.values.fold(0, (a, b) => a + b);
      expect(total, 1,
          reason: 'the quality line reported $total picks for one reel, '
              'which is the diagnostic lying about the size of the feed');
    });
  });

  group('work already started is never thrown away', () {
    test('a reel that has been downloaded keeps its choice', () {
      final blind = nq.stickyVariantUrl('c:5', Map.of(variants));
      NetworkQualityService.isUrlCommitted = (url) => url == blind;
      measureFast();
      expect(nq.stickyVariantUrl('c:5', Map.of(variants)), blind,
          reason: 'the downloaded file was abandoned for a sharper one, so '
              'the reel opens cold and the work is wasted');
    });

    test('a reel with a player open on it keeps its choice', () {
      // Same predicate, and the reason it also covers players: changing
      // the url under a player restarts the video in the viewer's face.
      final blind = nq.stickyVariantUrl('c:6', Map.of(variants));
      NetworkQualityService.isUrlCommitted = (_) => true;
      measureFast();
      expect(nq.stickyVariantUrl('c:6', Map.of(variants)), blind);
    });

    test('and it stops being asked about', () {
      final blind = nq.stickyVariantUrl('c:7', Map.of(variants));
      var asked = 0;
      NetworkQualityService.isUrlCommitted = (_) {
        asked++;
        return true;
      };
      measureFast();
      nq.stickyVariantUrl('c:7', Map.of(variants));
      nq.stickyVariantUrl('c:7', Map.of(variants));
      nq.stickyVariantUrl('c:7', Map.of(variants));
      expect(asked, 1,
          reason: 'a settled reel is re-examined on every single parse, and '
              'the feed re-parses constantly');
      expect(nq.stickyVariantUrl('c:7', Map.of(variants)), blind);
    });

    test('an untouched reel is free to change', () {
      final blind = nq.stickyVariantUrl('c:8', Map.of(variants));
      NetworkQualityService.isUrlCommitted = (_) => false;
      measureFast();
      expect(nq.stickyVariantUrl('c:8', Map.of(variants)), isNot(blind));
    });

    test('no predicate wired means nothing is assumed committed', () {
      // Tests and any surface that does not wire it still behave, rather
      // than silently freezing every blind choice.
      NetworkQualityService.isUrlCommitted = null;
      final blind = nq.stickyVariantUrl('c:9', Map.of(variants));
      measureFast();
      expect(nq.stickyVariantUrl('c:9', Map.of(variants)), isNot(blind));
    });
  });

  group('the provisional list does not grow without bound', () {
    test('it is forgotten alongside the choice it belongs to', () {
      // _chosenFor is capped and evicts oldest-first. A parallel set that
      // did not evict with it would be a slow leak for the session.
      for (var i = 0; i < 600; i++) {
        nq.stickyVariantUrl('bulk:$i', Map.of(variants));
      }
      expect(nq.debugBlindPickCount, lessThanOrEqualTo(500),
          reason: 'the provisional list outlived the choices it tracks');
    });
  });
}
