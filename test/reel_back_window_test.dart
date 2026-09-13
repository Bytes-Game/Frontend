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

  group('warming the reel on screen', _currentReelWarming);

  group('warm before play', _warmBeforePlay);

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

// ════════════════════════════════════════════════════════════════════════════
// THE REEL ON SCREEN IS WARMED TOO
// ════════════════════════════════════════════════════════════════════════════
//
// The warm window used to start at currentIndex + 1, on the reasoning that
// the reel being watched is already open and needs nothing. True once it is
// playing; wrong at the moment that matters most.
//
// The FIRST reel of a feed has nobody ahead of it, so nothing ever warmed it
// and it opened straight against the network every time. Worst on a seeded
// open — tapping a video on a profile hands the feed that one reel and shows
// it immediately — which is where "even my own upload sticks at the start"
// came from.

void _currentReelWarming() {
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
  final body = src.substring(src.indexOf('void _prefetchUpcomingVideos()'));
  final upTo = body.substring(0, body.indexOf('VideoPlayerService.instance.prefetch'));

  test('the reel being watched is in the warm window', () {
    expect(
      upTo.contains('upcoming.insert(0, current.videoUrl)'),
      isTrue,
      reason: 'the window still starts after the current reel, so the first '
          'reel of every feed — and the whole of a seeded open — races the '
          'origin from byte zero with nothing warmed',
    );
  });

  test('and it goes first, ahead of the ones after it', () {
    // Position matters: only a few downloads run at once, and the reel on
    // screen is the one being watched right now. Behind the next reel is
    // still behind.
    final atCurrent = upTo.indexOf('upcoming.insert(0, current.videoUrl)');
    final atOpponent = upTo.indexOf('current.opponentVideoUrl);');
    expect(atCurrent, greaterThan(-1));
    expect(atOpponent, greaterThan(atCurrent),
        reason: 'the current reel is queued behind its own opponent');
  });

  test('the opponent still sits just behind it', () {
    // A flip is one gesture away with no swipe to warn us, so the opponent
    // stays near the front — but never ahead of the video actually playing.
    expect(upTo.contains('upcoming.insert(upcoming.isEmpty ? 0 : 1'), isTrue,
        reason: "the current reel's opponent lost its place near the front");
  });
}

// ════════════════════════════════════════════════════════════════════════════
// WARM FIRST, PLAY SECOND
// ════════════════════════════════════════════════════════════════════════════
//
// Both paths that open a reel used to play it and then ask for it to be
// warmed. Asking after the player has opened is asking too late — it has
// already gone to the network.
//
// Worst on a seeded open, where the feed is handed one reel and shows it
// immediately, so there is no earlier moment at which anything could have
// warmed it. That is the "my own upload sticks at the start" case.

void _warmBeforePlay() {
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

  /// The body of one function, so a mention of a name elsewhere in the file
  /// cannot be mistaken for the code being checked. That is exactly what the
  /// first version of this did: it matched a comment three hundred lines
  /// above the function and compared offsets that meant nothing.
  String bodyOf(String decl) {
    final i = src.indexOf(decl);
    expect(i, greaterThan(-1), reason: 'lost $decl');
    final rest = src.substring(i);
    final end = rest.indexOf('\n  }\n');
    return end > 0 ? rest.substring(0, end) : rest;
  }

  test('the first reel of a feed is warmed before it is played', () {
    final body = bodyOf('Future<void> _loadInitialPage(');
    final warm = body.indexOf('_prefetchUpcomingVideos();');
    final play = body.indexOf('_playCurrent(');
    expect(warm, greaterThan(-1));
    expect(play, greaterThan(-1));
    expect(warm, lessThan(play),
        reason: 'the player opens before anything asks for the reel, so it '
            'goes straight to the network every time');
  });

  test('and so is the one a swipe lands on', () {
    final body = bodyOf('void _onPageChanged(');
    final warm = body.indexOf('_schedulePrefetch();');
    final play = body.indexOf('_playCurrent();');
    expect(warm, greaterThan(-1));
    expect(play, greaterThan(-1));
    expect(warm, lessThan(play),
        reason: 'the swipe opens its player before re-aiming the window');
  });

  test('a deliberate open waits briefly for the warm', () {
    expect(src.contains('awaitReady('), isTrue,
        reason: 'nothing ever waits for a reel to become warm. '
            'VideoCacheService.awaitReady exists precisely for this and was '
            'never called, so every reel opened against whatever happened to '
            'be on disk at that instant.');
    expect(src.contains('_playCurrent(waitForWarm: true)'), isTrue,
        reason: 'the initial open does not ask to wait');
  });

  test('but a swipe never does', () {
    // A swipe has a rhythm. Pausing it to buy a smoother start trades a
    // fault the viewer notices for one they notice more.
    final body = bodyOf('void _onPageChanged(');
    final upTo = body.substring(0, body.indexOf('_maybePrefetchNextPage();'));
    expect(upTo.contains('waitForWarm: true'), isFalse,
        reason: 'swiping now pauses before it plays');
  });

  test('and the wait is short enough not to read as broken', () {
    final m = RegExp(r'_coldOpenGrace = Duration\(milliseconds: (\d+)\)')
        .firstMatch(src);
    expect(m, isNotNull, reason: 'the grace period is gone');
    final ms = int.parse(m!.group(1)!);
    expect(ms, lessThanOrEqualTo(600),
        reason: '${ms}ms of nothing before a video starts is a pause the '
            'viewer notices in its own right');
    expect(ms, greaterThanOrEqualTo(150),
        reason: 'too short to catch a warm that is nearly there, which is '
            'the only thing it is for');
  });

  test('a reel the viewer has left is not opened after the wait', () {
    // 400ms is long enough to swipe. Opening a player for a reel they have
    // gone past is worse than the cold open this avoids.
    // Checked as the very NEXT line, not merely somewhere later. There is
    // another index guard further down _playCurrent, and a player is opened
    // in between — so "somewhere later" is satisfied while the wrong reel
    // still gets a decoder. The first version of this test passed with the
    // guard deleted for exactly that reason.
    final body = bodyOf('Future<void> _playCurrent(');
    final lines = body.split('\n');
    final at = lines.indexWhere((l) => l.contains('awaitReady('));
    expect(at, greaterThan(-1), reason: 'nothing waits for the warm');
    expect(
      lines[at + 1].contains('_currentIndex != index'),
      isTrue,
      reason: 'the line after the wait is "${lines[at + 1].trim()}". It has '
          'to be the check that the viewer is still on this reel — 400ms is '
          'long enough to swipe, and the next thing this function does is '
          'open a player.',
    );
  });
}
