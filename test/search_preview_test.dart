// The search grid was streaming the raw upload.
//
// ChallengeModel.videoUrl is the file the phone sent, before the server
// re-encoded it. The feed has never played that — it picks a rendition sized
// for the connection. The search grid played the original.
//
// Measured across ten videos in this app:
//
//   video 43     1.0 MB raw     1.0 MB chosen     same
//   video 48     3.6 MB raw     2.0 MB chosen     1.8x
//   video 49    13.9 MB raw     2.4 MB chosen     5.8x
//   video 38    57.8 MB raw     4.5 MB chosen    12.9x
//
// On the link this app actually sees, 2 to 4 Mbps, 57 MB is not a video that
// plays. That is "every video on the search page sticks", and the feed being
// fine at the same moment is the clue: the two pages never shared this code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One function's body, so a check cannot match a line elsewhere in a
/// two-thousand-line file and pass for the wrong reason.
String bodyOf(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThan(-1), reason: 'could not find $signature');
  // Start at the brace that opens the BODY. A named-parameter list is
  // written ({String url = ''}), and counting from the signature closes on
  // the parameters and returns nothing — a check that stops checking.
  final open = src.indexOf(') {', at);
  expect(open, greaterThan(-1), reason: 'no body found for $signature');
  var depth = 0;
  for (var i = open + 2; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(at, i + 1);
    }
  }
  fail('never found the end of $signature');
}

void main() {
  final src = File('lib/pages/search_page.dart').readAsStringSync();

  group('a preview plays what the feed would play', () {
    test('the rendition is picked for the connection', () {
      final body = bodyOf(src, 'String _originUrl()');
      expect(body, contains('pickVariantUrl(c.videoVariants)'),
          reason: 'without this the grid streams the raw upload — up to '
              'thirteen times the bytes, on the slowest thing in the app');
    });

    test('the raw upload is only the fallback', () {
      final body = bodyOf(src, 'String _originUrl()');
      expect(body, contains(': c.videoUrl'),
          reason: 'a video with no renditions yet still has to play');
      final pickAt = body.indexOf('pickVariantUrl');
      final rawAt = body.indexOf('c.videoUrl');
      expect(pickAt, lessThan(rawAt),
          reason: 'the raw file must be the fallback, not the first choice');
    });

    test('the player is handed the cache, not the origin', () {
      final body = bodyOf(src, 'String _previewUrl()');
      expect(body, contains('playbackUrlFor('),
          reason: 'the preview goes straight to the CDN even when the '
              'opening bytes are already on disk');
    });

    test('and it is actually used', () {
      final body = bodyOf(src, 'Future<void> _ensurePlayerAndPlay()');
      expect(body, contains('final url = _previewUrl();'),
          reason: 'the choice is made and then ignored, which is the bug '
              'with extra code');
      expect(body, isNot(contains('widget.challenge.videoUrl')),
          reason: 'the raw upload is read directly again');
    });
  });

  group('one choice, not two', () {
    test('the played url is built from the warmed one', () {
      // Two copies of "which rendition" could disagree, and then the tile
      // warms one file and plays another — which costs the bandwidth and
      // fixes nothing.
      final body = bodyOf(src, 'String _previewUrl()');
      expect(body, contains('_originUrl()'),
          reason: 'the play path picks the rendition again on its own');
      expect(body, isNot(contains('pickVariantUrl')),
          reason: 'the choice is repeated here instead of reused');
    });

    test('warming is keyed by the origin, not the proxy address', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, isNot(contains('playbackUrlFor')),
          reason: 'the cache files bytes under the ORIGIN url; warming the '
              'proxy address stores them under a name nothing looks up');
      final report = bodyOf(src, 'Widget build(BuildContext context)');
      expect(src, contains('url: _originUrl()'),
          reason: 'the tile reports the proxied url, so the coordinator '
              'warms the wrong name');
      expect(report, isNotEmpty);
    });
  });

  group('the previews about to play are fetched first', () {
    test('visible tiles are warmed', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, contains('VideoCacheService.instance.warm('),
          reason: 'nothing is fetched ahead, so every preview starts from '
              'byte zero against the network');
    });

    test('most visible first', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, contains('b.value.compareTo(a.value)'),
          reason: 'unordered warming puts the tile about to take its turn '
              'behind two the user is scrolling past');
    });

    test('and the window is shallow', () {
      final m = RegExp(r'_warmAhead\s*=\s*(\d+)').firstMatch(src);
      expect(m, isNotNull, reason: 'the window is gone');
      final n = int.parse(m!.group(1)!);
      expect(n, greaterThan(0), reason: 'zero warms nothing, which is the bug');
      expect(n, lessThanOrEqualTo(4),
          reason: 'bytes spent ahead are bytes the preview playing right '
              'now does not get — the feed learned this the hard way');
    });

    test('a tile that scrolls away stops being warmed', () {
      final body = bodyOf(src, 'void report(String tileId, double fraction');
      expect(body, contains('_urls.remove(tileId)'),
          reason: 'urls pile up for tiles nobody can see, and the warm '
              'window fills with them');
    });

    test('warming runs when visibility changes, not only on activation', () {
      final body = bodyOf(src, 'void report(String tileId, double fraction');
      expect(body, contains('_warmVisible()'),
          reason: 'warming only when a tile activates is warming a video at '
              'the moment it needs to play, which is too late');
    });
  });
}
