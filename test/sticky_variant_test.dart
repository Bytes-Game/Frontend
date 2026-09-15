// One video, one file.
//
// The rendition picker answers for the link AS IT IS RIGHT NOW, and the link
// moves. Measured in one session:
//
//   link=5.9Mbps  affords=720p_hq
//   link=2.9Mbps  affords=480p
//   link=3.7Mbps  affords=480p
//
// The feed re-parses the same videos constantly — the server deliberately
// re-sends them, repeat=20 of 20 on most pages — and every re-parse asked
// again. So a video would be warmed as 720p_hq and, minutes later, opened as
// 480p: a different file, with none of it on disk.
//
// The arithmetic from that session says exactly that. 67 distinct URLs were
// warmed out of a catalogue of 56 videos, so at least eleven videos were
// fetched under TWO addresses. And warming pulled away from playback:
//
//   starts=50  warmed=40  served from cache=30
//   starts=60  warmed=51  served from cache=32
//
// Eleven more warmed, two more used.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/network_quality_service.dart';

import 'support/dart_source.dart';

void main() {
  final net = NetworkQualityService.instance;

  const variants = {
    '480p': 'https://cdn/x/480p.mp4',
    '720p': 'https://cdn/x/720p.mp4',
    '720p_hq': 'https://cdn/x/720p_hq.mp4',
  };

  // measuredBps is the median and wants a few samples, so feed several.
  void linkAt(int bps) {
    net.debugClearThroughput();
    for (var i = 0; i < 5; i++) {
      net.recordThroughput((bps ~/ 8) * 4, const Duration(seconds: 4));
    }
  }

  setUp(() {
    net.debugClearThroughput();
    net.debugClearChosenVariants();
    net.debugSetQuality(NetworkQuality.high);
  });

  tearDown(() {
    net.debugClearThroughput();
    net.debugClearChosenVariants();
  });

  group('a video keeps the rendition it was first given', () {
    test('even after the link drops', () {
      linkAt(9000000);
      final first = net.stickyVariantUrl('challenge:7', variants);
      expect(first, isNotNull);

      linkAt(2900000); // the drop from the real session
      final second = net.stickyVariantUrl('challenge:7', variants);

      expect(second, first,
          reason: 'the video was warmed as $first and would now be opened '
              'as $second — a different file, with none of it on disk');
    });

    test('and after it improves', () {
      linkAt(2900000);
      final first = net.stickyVariantUrl('challenge:7', variants);
      linkAt(20000000);
      expect(net.stickyVariantUrl('challenge:7', variants), first,
          reason: 'a rung of quality is worth far less than the stall that '
              'comes from opening a file nothing warmed');
    });

    test('but a different video gets the current answer', () {
      linkAt(9000000);
      final fast = net.stickyVariantUrl('challenge:1', variants);
      linkAt(2000000);
      final slow = net.stickyVariantUrl('challenge:2', variants);

      expect(slow, isNot(fast),
          reason: 'stickiness is per video — a video arriving for the first '
              'time on a slow link must not inherit a fast link\'s choice');
    });

    test('the plain picker still answers for right now', () {
      // stickyVariantUrl must not have changed what pickVariantUrl means;
      // other callers depend on it being current.
      linkAt(9000000);
      final fast = net.pickVariantUrl(variants);
      linkAt(2000000);
      expect(net.pickVariantUrl(variants), isNot(fast));
    });
  });

  group('it does not grow without limit', () {
    test('a long session forgets the oldest choices', () {
      linkAt(5000000);
      for (var i = 0; i < 700; i++) {
        net.stickyVariantUrl('challenge:$i', variants);
      }
      // Nothing to assert on size from outside, so assert the behaviour the
      // cap produces: the oldest key has been forgotten and re-answers.
      linkAt(20000000);
      final old = net.stickyVariantUrl('challenge:0', variants);
      final recent = net.stickyVariantUrl('challenge:699', variants);
      expect(old, isNot(recent),
          reason: 'challenge:0 should have been evicted and re-picked at the '
              'new speed, while challenge:699 keeps its original choice');
    });

    test('an empty key is never remembered', () {
      linkAt(9000000);
      final first = net.stickyVariantUrl('', variants);
      linkAt(2000000);
      expect(net.stickyVariantUrl('', variants), isNot(first),
          reason: 'one shared entry for every video without an id would '
              'hand them all the same file');
    });
  });

  group('the feed actually uses it', () {
    final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

    test('every pick in the feed is sticky', () {
      expect(src, isNot(contains('NetworkQualityService.instance.pickVariantUrl(')),
          reason: 'a pick that is not sticky re-answers on every re-parse, '
              'which is the whole bug');
      expect('stickyVariantUrl('.allMatches(src).length, greaterThanOrEqualTo(4),
          reason: 'the challenger and the opponent, on both the feed-parse '
              'and the seeded-open paths');
    });

    test('keyed by the video, not by position', () {
      expect(src, contains("'challenge:\${c['id']}'"));
      expect(src, contains("'response:\${c['topResponseId']}'"));
    });

    test('the seeded path uses the same keys as the feed', () {
      // A video opened from a profile and the same video reached by
      // scrolling have to be one file, not two.
      final body = bodyOf(src, 'static _ReelItem? fromChallengeModel(');
      expect(body, contains("'challenge:\${c.id}'"));
      expect(body, contains("'response:\${c.topResponseId}'"));
      expect(body, isNot(contains('pickVariantUrl(')),
          reason: 'the seeded path re-picks, so tapping a video on a profile '
              'can open a different file from the one the feed warmed');
    });
  });
}
