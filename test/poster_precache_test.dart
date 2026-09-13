// The cover image, before it is needed.
//
// "Black screen for a few milliseconds before every video" — reported over
// and over, on warm reels as well as cold ones.
//
// Every reel already draws its poster behind the player, so there was
// supposed to be a picture there the whole time the video was opening. There
// was not. The poster is an Image.network and nothing asked for it until the
// reel BUILT, which is the same instant the video starts opening. The viewer
// waited for a picture that was only requested when they arrived.
//
// Warming the video and not its cover is warming the slow half and leaving
// the fast half to chance.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The body of one function, so a check cannot match a line somewhere else
/// in a five-thousand-line file and pass for the wrong reason.
String bodyOf(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThan(-1), reason: 'could not find $signature');
  // Start counting at the brace that opens the BODY, not at any brace in
  // the signature — a named-parameter list is written {required bool x},
  // and counting from there closes on the parameter list and returns
  // nothing. That is a check that quietly stops checking.
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
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

  group('the cover is asked for before the reel arrives', () {
    test('the prefetch pass asks for it', () {
      final body = bodyOf(src, 'void _prefetchUpcomingVideos()');
      expect(body, contains('_precacheUpcomingPosters()'),
          reason: 'warming runs and the covers are not part of it, so the '
              'poster is still first requested when the reel builds');
    });

    test('the reel on screen is included', () {
      // Same reason the video window starts at the current reel: on a
      // seeded open — tapping a video on a profile — nothing came before
      // it, so nothing else will ever have asked for its cover.
      final body = bodyOf(src, 'void _precacheUpcomingPosters()');
      expect(body, contains('add(current.thumbnailUrl)'));
      expect(body, contains('add(current.opponentThumbnailUrl)'),
          reason: "a battle's other side is one tap away with no swipe to "
              'warn us');
    });

    test('a cover that fails to load cannot break a swipe', () {
      final body = bodyOf(src, 'void _precacheUpcomingPosters()');
      expect(body, contains('.catchError('),
          reason: 'an unreachable poster would throw into the swipe handler; '
              'the fallback is the behaviour that existed before — black, '
              'with the video painting over it');
      expect(body, contains('if (!mounted) return;'),
          reason: 'precacheImage needs a live context');
    });
  });

  group('the window is deliberately shallow', () {
    test('shallower than the video window', () {
      // Covers are not free. Measured across this feed they run 3 KB to
      // 109 KB, median 35 KB. Ten of the larger ones is 662 KB — most of a
      // video prefix — spent on pictures instead of the video they sit in
      // front of.
      final decl = RegExp(r'_posterLookahead\s*=\s*(\d+)').firstMatch(src);
      expect(decl, isNotNull, reason: 'the lookahead is gone');
      final depth = int.parse(decl!.group(1)!);
      expect(depth, greaterThan(0),
          reason: 'zero would precache nothing ahead, which is the bug');
      expect(depth, lessThanOrEqualTo(4),
          reason: 'at a 35 KB median, a deeper window costs a video prefix '
              'in pictures — $depth ahead is about ${depth * 35} KB');
    });
  });

  group('it warms the key the widget actually reads', () {
    // The whole thing is a no-op if the provider precached is not the one
    // the widget asks for. It would look exactly like a fix, cost the
    // bandwidth, and change nothing on screen.
    test('a plain NetworkImage matches another of the same url', () {
      const url = 'https://cdn/x/poster.jpg';
      expect(NetworkImage(url), equals(NetworkImage(url)),
          reason: 'if these did not compare equal the cache could never hit');
    });

    test('wrapping or rescaling it would miss', () {
      const url = 'https://cdn/x/poster.jpg';
      expect(ResizeImage(NetworkImage(url), width: 360),
          isNot(equals(NetworkImage(url))),
          reason: 'this is the trap: decoding smaller looks like a saving '
              'and warms a key nothing reads');
      expect(const NetworkImage(url, scale: 2), isNot(equals(NetworkImage(url))));
    });

    test('the precache and the widget use the same plain provider', () {
      final body = bodyOf(src, 'void _precacheUpcomingPosters()');
      expect(body, contains('precacheImage(NetworkImage(url), context)'),
          reason: 'anything wrapped around NetworkImage here warms a cache '
              'key the reel never asks for');
      expect(body, isNot(contains('ResizeImage')),
          reason: 'the reel draws a plain Image.network, so a resized '
              'provider is a different key and a silent no-op');

      // And the display side has to stay plain for the same reason.
      final face = bodyOf(src, 'Widget _videoFace({required bool opponent})');
      expect(face, contains('Image.network(\n            poster,'),
          reason: 'the reel no longer draws the poster with a plain '
              'Image.network, so the precached key may not match');
    });
  });
}
