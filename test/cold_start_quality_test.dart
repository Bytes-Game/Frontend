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
