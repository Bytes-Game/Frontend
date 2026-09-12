// Leaving the link enough room to fetch the NEXT reel while this one plays.
//
// The quality picker used to compare a rendition's bitrate against the whole
// link, as though the video on screen were the only thing using it. It is
// not. The warmer is fetching the reels the user is about to swipe to, over
// the same connection, and if it never finishes then every swipe stops.
//
// A device run at 3.3 Mbps, before this existed:
//
//   reel 30    93% of starts warm    28 warms finished     7 cancelled
//   reel 80    54% of starts warm    32 warms finished    60 cancelled
//
// Fifty reels apart: sixty-one more downloads started, four finished. The
// app had decided 3.3 Mbps affords 720p, which costs 2.5 Mbps to play,
// leaving 0.8 Mbps to read ahead with. Six reels of read-ahead is about
// 9 MB, which at 0.8 Mbps takes ninety seconds; the user crosses six reels
// in fifteen.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_cache_service.dart';

void main() {
  final net = NetworkQualityService.instance;

  // measuredBps is the median of the samples, so one sample of the rate we
  // want is enough to pin it.
  void linkAt(int bps) {
    net.debugClearThroughput();
    // measuredBps needs a few samples before it will answer and takes the
    // median, so feed it several identical ones. Four seconds' worth each,
    // because recordThroughput ignores anything under 64 KB — at the slowest
    // rate here, one second would not clear that floor.
    for (var i = 0; i < 5; i++) {
      net.recordThroughput((bps ~/ 8) * 4, const Duration(seconds: 4));
    }
  }

  setUp(() {
    net.debugClearThroughput();
    net.debugSetQuality(NetworkQuality.high);
  });

  group('the reserve is what read-ahead actually costs', () {
    test('it is one reel of read-ahead per reel watched', () {
      // Tied to the slice the warmer fetches, not typed in. Raising
      // prefixBytes without raising the reserve would quietly put the
      // starvation back, because each warm would cost more while the
      // bandwidth set aside for it stayed the same.
      final need = (VideoCacheService.prefixBytes * 8) /
          NetworkQualityService.typicalDwellSeconds;
      expect(
        NetworkQualityService.readAheadReserveBps,
        closeTo(need, need * 0.05),
        reason: 'the reserve (${NetworkQualityService.readAheadReserveBps} bps) '
            'no longer matches what one warm per reel costs '
            '(${need.round()} bps). Move them together.',
      );
    });
  });

  group('the case from the device log', () {
    test('3.3 Mbps no longer claims to afford 720p', () {
      linkAt(3300000);
      expect(
        net.affordableLabel,
        '480p',
        reason: 'at 3.3 Mbps, 720p costs 2.5 Mbps to play and leaves 0.8 '
            'Mbps to read ahead with — which is how the warmer ended up '
            'finishing four downloads in fifty reels',
      );
    });

    test('and what it picks does leave room to read ahead', () {
      linkAt(3300000);
      final label = net.affordableLabel!;
      final cost = NetworkQualityService.bitrateNeededFor[label]!;
      final spare = 3300000 - cost;
      expect(
        spare,
        greaterThanOrEqualTo(NetworkQualityService.readAheadReserveBps),
        reason: 'the chosen rendition leaves $spare bps for read-ahead, '
            'under the ${NetworkQualityService.readAheadReserveBps} it needs',
      );
    });
  });

  group('a link with room to spare is not punished', () {
    test('a fast connection still gets the best picture', () {
      linkAt(12000000);
      expect(net.affordableLabel, '1080p');
    });

    test('the reserve only moves the answer near a boundary', () {
      // Comfortably above 720p_hq plus the reserve.
      linkAt(6000000);
      expect(net.affordableLabel, '720p_hq');
    });
  });

  group('a link with nothing to spare', () {
    test('still gets a picture rather than nothing', () {
      // A soft picture that plays beats a sharp one that stops — and beats
      // no answer at all, which would leave the caller with no ceiling.
      linkAt(400000);
      expect(net.affordableLabel, '480p');
    });

    test('and having measured nothing means having no opinion', () {
      net.debugClearThroughput();
      expect(net.affordableLabel, isNull);
    });
  });

  group('the reserve is real, not decorative', () {
    test('every rendition it allows leaves the reserve behind', () {
      for (final bps in [
        1000000,
        2000000,
        3300000,
        4000000,
        5000000,
        6000000,
        8000000,
        12000000,
      ]) {
        linkAt(bps);
        final label = net.affordableLabel!;
        final cost = NetworkQualityService.bitrateNeededFor[label]!;
        if (label == '480p' && bps < 3000000) {
          // The documented floor: below this nothing fits and 480p is served
          // anyway, because a soft picture beats a stopped one.
          continue;
        }
        expect(
          bps - cost,
          greaterThanOrEqualTo(NetworkQualityService.readAheadReserveBps),
          reason: 'at $bps bps it chose $label, leaving ${bps - cost} bps '
              'for read-ahead',
        );
      }
    });
  });
}
