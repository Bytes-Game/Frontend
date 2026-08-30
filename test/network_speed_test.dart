// Picking a video quality the connection can actually carry.
//
// Everything else in the app answers "what KIND of connection is this?" —
// wifi, mobile, none. That is not the same question as "can it carry this
// video", and treating it as though it were is what made reels freeze.
//
// A device log made the gap plain: 96% of reels started instantly from
// cache, the download queue was empty and every slot idle, and the decoder
// still ran dry 394 times across 160 reels. Nothing was competing for the
// connection. The connection simply could not carry a 3.5 Mbps video, and
// the app had no way to find out — it saw wifi, called it fast, and served
// 720p to something that could not stream it.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';

void main() {
  final net = NetworkQualityService.instance;

  setUp(() {
    net.debugClearThroughput();
    net.debugSetQuality(NetworkQuality.high);
  });

  /// Feed [n] samples of a given speed by describing a transfer that took
  /// exactly that long.
  void sampleAt(double mbps, {int n = 4}) {
    const bytes = 768 * 1024;
    final ms = (bytes * 8 * 1000 / (mbps * 1e6)).round();
    for (var i = 0; i < n; i++) {
      net.recordThroughput(bytes, Duration(milliseconds: ms));
    }
  }

  test('says nothing until it has enough evidence', () {
    expect(net.measuredBps, isNull,
        reason: 'no samples yet, so there is nothing to claim');

    sampleAt(10, n: 1);
    expect(net.measuredBps, isNull,
        reason: 'one slow or fast download is a download, not a network — '
            'acting on it would swing quality on every reel');
  });

  test('a fast link is allowed the full quality', () {
    sampleAt(20);
    expect(net.affordableLabel, '1080p');

    final variants = {'480p': 'a', '720p': 'b'};
    expect(net.pickVariantUrl(variants), 'b',
        reason: 'a 20 Mbps link was not given 720p');
  });

  test('a link that cannot carry 720p is given 480p instead', () {
    // The case from the device log. 3 Mbps is a real, working connection —
    // it just cannot sustain a 3.5 Mbps video, and being handed one is how
    // a reel ends up freezing part-way through.
    sampleAt(3.0);

    expect(net.affordableLabel, '480p',
        reason: '3 Mbps cannot carry a 3.5 Mbps file with anything to spare');

    final variants = {'480p': 'small', '720p': 'big'};
    expect(net.pickVariantUrl(variants), 'small',
        reason: 'the app served 720p over a link too slow for it, which is '
            'exactly the freezing this exists to stop');
  });

  test('being on wifi does not override what the link is doing', () {
    // The specific bug. Connection TYPE said high; the actual speed did not.
    net.debugSetQuality(NetworkQuality.high);
    sampleAt(2.5);

    final variants = {'480p': 'small', '720p': 'big'};
    expect(net.pickVariantUrl(variants), 'small',
        reason: 'wifi was trusted over the measured speed. Slow wifi is the '
            'case that broke, not mobile data.');
  });

  test('headroom is required, not just the bare bitrate', () {
    // A link matching the file exactly has nothing left for a slow moment,
    // and a reel only has to fall behind once to visibly stop.
    sampleAt(3.6);
    expect(net.affordableLabel, '480p',
        reason: '3.6 Mbps barely covers a 3.5 Mbps file and leaves nothing '
            'for a dip; that is a stall waiting to happen');

    net.debugClearThroughput();
    sampleAt(5.0);
    expect(net.affordableLabel, '720p',
        reason: '5 Mbps carries a 3.5 Mbps file with room to spare');
  });

  test('never refuses to serve anything at all', () {
    // Even a link too slow for the smallest rendition gets the smallest
    // rendition. A soft picture that plays beats a sharp one that stops.
    sampleAt(0.2);
    expect(net.affordableLabel, '480p');
    expect(net.pickVariantUrl({'480p': 'small', '720p': 'big'}), 'small');
  });

  test('a cancelled or trivial transfer is not treated as a speed reading', () {
    // Scrolling fast cancels warms part-way. Those stopped for our reasons,
    // not the network's, and counting them would read as a slow link every
    // time somebody flicks through the feed.
    for (var i = 0; i < 8; i++) {
      net.recordThroughput(1024, const Duration(seconds: 5)); // too small
      net.recordThroughput(768 * 1024, const Duration(milliseconds: 1)); // too quick
    }
    expect(net.measuredBps, isNull,
        reason: 'tiny and instant transfers were counted as measurements');
  });

  test('the rating follows the connection when it changes', () {
    // Walking out of wifi range, or into it. Old samples must age out or the
    // app would hold onto a speed the viewer no longer has.
    sampleAt(20, n: 8);
    expect(net.affordableLabel, '1080p');

    sampleAt(2.0, n: 8);
    expect(net.affordableLabel, '480p',
        reason: 'the link got slower and the app kept serving the old '
            'quality, which is the freeze happening again');
  });
}
