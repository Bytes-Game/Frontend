// The first page of the feed was sized by a number from a PREVIOUS run, and
// then never looked at again.
//
// ═══════════════════════════════════════════════════════════════════════
// WHAT THE DEVICE LOG SAID
// ═══════════════════════════════════════════════════════════════════════
//
//     quality{480p:29  link=4.2Mbps affords=480p}
//
// Printed before a single byte had moved. Twenty-nine videos — the whole
// first page, the ones actually watched — sized against a reading carried
// over from the last time the app ran. 4.2 Mbps misses the bar for 720p by
// one tenth of a megabit, so every one of them got the soft picture.
//
// The app HAS a defence against exactly this. A choice made before anything
// is known is marked provisional and made again once there is evidence.
//
// It stopped working the day the speed started being saved between runs.
// The test for "do we know anything" was "is there a number", and there
// always is one now — last time's. So the guesses were filed as INFORMED,
// and informed choices are never revisited. By the time this run measured
// the real link, the videos being watched had already been decided.
//
// The remembered number is a good OPENING GUESS. It is a terrible fact. It
// may have been taken on a different network altogether: yesterday's train,
// a neighbour's wifi, one bad minute on mobile data.
//
// The same mistake, from the same cause, has already been fixed once in
// this app: saving the speed made the read-ahead depth behave as though it
// had measured something, and the warm rate fell from 93% to 72%. Fixed
// there, missed here.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';

void main() {
  final net = NetworkQualityService.instance;

  const variants = {
    '480p': 'https://cdn/x/480p.mp4',
    '720p': 'https://cdn/x/720p.mp4',
    '720p_hq': 'https://cdn/x/720p_hq.mp4',
  };

  // measuredBps is a median, so feed it several readings.
  void measureThisRunAt(int bps) {
    for (var i = 0; i < 5; i++) {
      net.recordThroughput((bps ~/ 8) * 4, const Duration(seconds: 4));
    }
  }

  setUp(() {
    net.debugClearThroughput();
    net.debugClearChosenVariants();
    net.debugSetQuality(NetworkQuality.high);
    NetworkQualityService.isUrlCommitted = null;
  });

  tearDown(() {
    net.debugClearThroughput();
    net.debugClearChosenVariants();
    NetworkQualityService.isUrlCommitted = null;
  });

  group('what counts as knowing something', () {
    test('a fresh launch knows nothing', () {
      expect(net.pickedInTheDark, isTrue);
    });

    test('last run\'s number does not count as knowing', () {
      net.restoreRememberedBps(4200000);
      expect(net.measuredBps, NetworkQualityService.rememberedCeilingBps,
          reason: 'still the opening guess, but no bolder than a phone that '
              'remembers nothing — 4.2 is above that, so it is capped');
      expect(net.pickedInTheDark, isTrue,
          reason: 'a figure from a previous run, possibly a different '
              'network, was being treated as this run\'s evidence');
    });

    test('this run measuring something does', () {
      measureThisRunAt(12000000);
      expect(net.pickedInTheDark, isFalse);
    });

    test('and one or two readings are not yet enough', () {
      // A single slow download is a slow download, not a slow network.
      net.recordThroughput(500000, const Duration(seconds: 1));
      expect(net.pickedInTheDark, isTrue);
    });
  });

  group('the first page of a launch gets a second chance', () {
    test('the exact case from the log: 4.2 remembered, 12 real', () {
      net.restoreRememberedBps(4200000);

      final opening = net.stickyVariantUrl('challenge:1', variants);
      expect(opening, variants['480p'],
          reason: 'the opening guess itself is fine and is meant to be '
              'cautious — what matters is what happens next');

      // The app now downloads a few things and finds the link is fine.
      measureThisRunAt(12000000);

      expect(net.stickyVariantUrl('challenge:1', variants),
          isNot(variants['480p']),
          reason: 'twenty-nine videos kept the soft picture for the whole '
              'session, on a link that could carry the sharp one three '
              'times over');
    });

    test('but not once something has acted on it', () {
      // Changing our mind after a file is warmed or open throws that work
      // away, and restarts the video under the viewer. Not worth a rung.
      net.restoreRememberedBps(4200000);
      final opening = net.stickyVariantUrl('challenge:2', variants);
      NetworkQualityService.isUrlCommitted = (url) => url == opening;

      measureThisRunAt(12000000);

      expect(net.stickyVariantUrl('challenge:2', variants), opening,
          reason: 'the file is already warmed or playing; a sharper picture '
              'is worth less than the stall from swapping it');
    });

    test('and a choice made on real evidence stays put', () {
      // Only GUESSES are provisional. A measured choice is the answer, and
      // re-deciding it on every wobble is the churn stickiness prevents.
      measureThisRunAt(12000000);
      final chosen = net.stickyVariantUrl('challenge:3', variants);

      net.debugClearThroughput();
      measureThisRunAt(2000000);

      expect(net.stickyVariantUrl('challenge:3', variants), chosen);
    });

    test('a second look does not happen before there is evidence', () {
      // Re-deciding against the very same remembered number learns nothing
      // and rebuilds the page for no reason. The ANSWER is the same either
      // way, which is why the work is counted rather than the answer — a
      // wasted re-pick is invisible in what comes back.
      net.restoreRememberedBps(4200000);
      NetworkQualityService.variantPicks.clear();

      final first = net.stickyVariantUrl('challenge:4', variants);
      final picksAfterFirst = _totalPicks();

      expect(net.stickyVariantUrl('challenge:4', variants), first);
      expect(_totalPicks(), picksAfterFirst,
          reason: 'it decided again, against the identical guess it already '
              'had — every repeat of the feed page, for as long as the run '
              'has measured nothing');

      expect(net.debugBlindPickCount, 1,
          reason: 'it has to still be marked provisional, or the second '
              'chance never comes');
    });
  });
}

/// Every rendition choice the service has actually computed.
int _totalPicks() =>
    NetworkQualityService.variantPicks.values.fold(0, (a, b) => a + b);
