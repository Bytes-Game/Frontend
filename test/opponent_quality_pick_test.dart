// The quality line in the log was accusing the catalog of a fault it did
// not have.
//
// Every feed item asked the quality picker two questions: which rendition
// for this video, and which for the opponent's. Most items in the feed are
// plain shorts with no opponent at all, so the second question was asked
// about a video that does not exist, got an empty map back, and was counted
// as "no quality versions available".
//
// What that did to the log:
//
//     quality{720p_hq:18 none:146 720p:17 480p:28 ...}
//
// read as "146 videos in this feed have no quality versions", on a catalog
// where all 44 challenges and all 12 responses have them, every one checked
// against the server. A whole round of investigation went looking for
// missing renditions that were never missing.
//
// A diagnostic that lies costs more than no diagnostic.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

  group('the quality counter only counts real videos', () {
    test('the parse path asks about an opponent only when there is one', () {
      final body = bodyOf(src, 'static _ReelItem? fromFeedEntry(');
      expect(body, contains('final hasOpponent ='),
          reason: 'asking about a video that does not exist counts a fault '
              'against the catalog');
      final askAt = body.indexOf("'response:\${c['topResponseId']}'");
      final guardAt = body.indexOf('hasOpponent');
      expect(askAt, greaterThan(-1));
      expect(guardAt, lessThan(askAt),
          reason: 'the guard has to come before the question');
    });

    test('the model path does the same', () {
      final body = bodyOf(src, 'static _ReelItem? fromChallengeModel(');
      expect(body, contains('final hasOpponent ='),
          reason: 'two paths build reel items and both were asking');
    });

    test('an item with no opponent still plays its own video', () {
      // The guard must not take the challenge video down with it.
      for (final fn in ['static _ReelItem? fromFeedEntry(', 'static _ReelItem? fromChallengeModel(']) {
        final body = bodyOf(src, fn);
        final ownPick = body.indexOf("'challenge:");
        final guard = body.indexOf('final hasOpponent =');
        expect(ownPick, greaterThan(-1), reason: '$fn stopped picking a '
            'rendition for the video the item is actually about');
        expect(ownPick, lessThan(guard),
            reason: "$fn: the item's own pick must be unconditional");
      }
    });

    test('a genuinely empty rendition map is still counted', () {
      // This is the case the counter exists for: a real video that has no
      // renditions. Silencing THAT would trade a lying diagnostic for a
      // blind one.
      final picker =
          File('lib/services/network_quality_service.dart').readAsStringSync();
      final body = bodyOf(picker, 'String? pickVariantUrl(');
      expect(body, contains("_countPick('none')"),
          reason: 'a real video with no renditions is worth knowing about');
    });
  });
}
