// The feed's dispose used to only pause.
//
// Three places tear reel player states down, and only ONE of them should
// hand the decoders back. Getting that wrong in either direction is a real
// fault, so each is pinned here:
//
//   * the whole feed going away  -> hand back. The page is gone; holding
//     four of the phone's decoders for it helps nobody.
//   * a refresh                  -> keep warm. The new page usually shows
//     some of the same reels, and the pool is how they stay instant.
//   * trimming reels far behind  -> keep warm. They are evicted in the
//     normal way when something else needs the slot.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
  final service =
      File('lib/services/video_player_service.dart').readAsStringSync();

  group('the page that is gone gives its decoders back', () {
    test('the feed disposes by handing back, not by pausing', () {
      final body = bodyOf(src, 'void dispose()');
      expect(body, contains('st.handBack()'),
          reason: 'leaving the feed leaves four players in the pool holding '
              'four decoders for a page nobody can see');
      expect(body, isNot(contains('st.dispose()')),
          reason: 'back to pausing, which is the leak');
    });

    test('handing back goes through the service, not round it', () {
      final body = bodyOf(src, 'void handBack()');
      expect(body, contains('VideoPlayerService.instance.handBack(url)'),
          reason: 'the pool owns these players; a tile disposing one behind '
              "the pool's back leaves an entry pointing at a dead player");
    });
  });

  group('the two places that must NOT hand back', () {
    test('a refresh keeps them warm', () {
      // The refreshed page usually shows some of the same reels. Handing
      // them back means paying for every one again.
      final at = src.indexOf('Drop stale (index → controller) mappings');
      expect(at, greaterThan(-1), reason: 'the refresh path moved');
      final window = src.substring(at, at + 900);
      expect(window, contains('st.dispose()'),
          reason: 'a refresh now throws away players the new page is about '
              'to ask for');
      expect(window, isNot(contains('st.handBack()')));
    });

    test('trimming reels far behind keeps them warm', () {
      final at = src.indexOf('Re-key player states for the new indices.');
      expect(at, greaterThan(-1), reason: 'the trim path moved');
      final window = src.substring(at, at + 500);
      expect(window, contains('v.dispose()'));
      expect(window, isNot(contains('v.handBack()')));
    });
  });

  group('the two halves stay different', () {
    test('release pauses, handBack shuts down', () {
      final rel = bodyOf(service, 'Future<void> release(String url)');
      final hand = bodyOf(service, 'Future<void> handBack(String url)');

      expect(rel, contains('pause()'));
      expect(rel, isNot(contains('_pool.remove')),
          reason: 'release started taking players out of the pool, so a '
              'reel one swipe away is no longer instant');

      expect(hand, contains('_pool.remove'));
      expect(hand, contains('_retire('),
          reason: 'taken out of the pool but never shut down is the worst '
              'of both: the decoder is still held and nothing can find it '
              'to release later');
    });

    test('handBack refuses the reel on screen', () {
      final hand = bodyOf(service, 'Future<void> handBack(String url)');
      expect(hand, contains('if (url == _activeUrl) return;'),
          reason: 'two feeds share this pool during a tab change, so the '
              'reel one has finished with may be the one the other has '
              'just started');
    });
  });
}
