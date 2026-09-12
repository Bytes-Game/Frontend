// Which reels behind the current one get warmed — and what happens when the
// feed says the user is standing somewhere that no longer exists.
//
// Background, from a device log. The forYou feed was refreshed after the
// user had scrolled through thirty-three reels. A refresh empties the list
// and refills it, and this time the new feed was twenty-one reels, not
// thirty-three. The position stayed where it was, so the back-buffer loop
// started at 25 and read off the end of a 21-item list:
//
//     RangeError (length): Invalid value: Not in inclusive range 0..20: 25
//     #0  _SmartReelsFeedState._prefetchUpcomingVideos
//     #1  _SmartReelsFeedState._loadInitialPage.<anonymous closure>
//
// Two things were wrong and both are fixed. The position not surviving a
// refresh is the real bug, fixed where the list is cleared. This file is
// about the other half: the loop that walked backwards trusted a number it
// was handed instead of bounding itself.
//
// The forward half of the same window always had `i < length`, because
// counting UP towards the end of a list makes you write that without
// thinking. Counting DOWN from where the user is makes `i >= 0` feel like
// the whole answer.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/widgets/smart_reels_feed.dart';

void main() {
  List<int> window({
    required int currentIndex,
    required int itemCount,
    int backCount = 2,
  }) => reelBackWindow(
    currentIndex: currentIndex,
    itemCount: itemCount,
    backCount: backCount,
  );

  group('the ordinary case', () {
    test('warms the reels immediately behind, nearest first', () {
      expect(window(currentIndex: 5, itemCount: 21), [4, 3]);
    });

    test('never returns more than it was asked for', () {
      expect(window(currentIndex: 10, itemCount: 21, backCount: 4),
          [9, 8, 7, 6]);
    });

    test('the first reel has nothing behind it', () {
      expect(window(currentIndex: 0, itemCount: 21), isEmpty);
    });

    test('near the start it stops at the start', () {
      expect(window(currentIndex: 1, itemCount: 21), [0]);
    });
  });

  group('the position is past the end of the list', () {
    // This is the crash. Every index it returns must be readable.
    test('never returns an index the list does not have', () {
      const count = 21;
      for (final stale in [21, 22, 25, 26, 100]) {
        final got = window(currentIndex: stale, itemCount: count);
        for (final i in got) {
          expect(i, lessThan(count),
              reason: 'index $i would read off the end of a $count-item feed '
                  '(position was $stale)');
          expect(i, greaterThanOrEqualTo(0));
        }
      }
    });

    test('falls back to the end of the list, which is the nearest thing '
        'to behind', () {
      expect(window(currentIndex: 26, itemCount: 21), [20, 19]);
    });

    test('the exact case from the device log does not read index 25', () {
      expect(window(currentIndex: 26, itemCount: 21), isNot(contains(25)));
    });
  });

  group('degenerate inputs', () {
    test('an empty feed warms nothing', () {
      expect(window(currentIndex: 0, itemCount: 0), isEmpty);
      expect(window(currentIndex: 9, itemCount: 0), isEmpty);
    });

    test('a back-buffer of zero warms nothing', () {
      expect(window(currentIndex: 5, itemCount: 21, backCount: 0), isEmpty);
    });

    test('a negative position warms nothing rather than throwing', () {
      expect(window(currentIndex: -1, itemCount: 21), isEmpty);
    });
  });

  group('the position is reset with the list, not separately', () {
    // The bound above makes the crash impossible. This is about the bug
    // that produced the bad number in the first place, and it is a
    // source-level check because the thing that went wrong is WHERE the
    // reset lives, not what it computes.
    //
    // It used to sit inside `if (refresh && _pageController.hasClients)`,
    // which is false at exactly the moment it matters: clearing the list
    // also sets _loadingFirstPage, which swaps the PageView for a loader,
    // so the pager has no clients and the reset was never scheduled. The
    // feed then knew it was on reel 26 of a 21-reel list — nothing played,
    // because every play path correctly refuses an index it cannot use.
    final src =
        File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

    test('emptying the list also resets the position', () {
      final clear = src.indexOf('_items.clear();');
      expect(clear, greaterThan(-1),
          reason: 'the refresh path moved; move this test with it');
      // The end of the setState block that does the clearing.
      final blockEnd = src.indexOf('});', clear);
      expect(blockEnd, greaterThan(clear));
      final block = src.substring(clear, blockEnd);

      expect(
        block.contains('_currentIndex = 0'),
        isTrue,
        reason: 'the list is emptied without resetting the position.\n\n'
            'They are one fact. Whatever resets the position elsewhere, it '
            'runs later or conditionally, and in between the feed is '
            'pointing at a reel that does not exist: nothing plays, and the '
            'warm window reads off the end.',
      );
    });

    test('the reset does not depend on the pager being attached', () {
      // The old shape. If it comes back, so does the bug — the pager is
      // detached precisely when the list is being replaced.
      expect(
        src.contains('_pageController.jumpToPage(0);\n          _currentIndex = 0;'),
        isFalse,
        reason: 'the position is reset inside a hasClients branch again',
      );
    });
  });
}
