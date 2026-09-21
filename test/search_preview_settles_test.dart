// Scrolling the search grid used to open a video decoder per tile passed.
//
// Every tile reports its visibility on every frame it moves, and the rule was
// "switch to whoever is most visible, immediately". So a fast flick handed the
// active slot to tile after tile, and each handover opened a hardware decoder
// and threw the previous one away — for videos nobody saw a frame of.
//
// A device log shows the cost. Eight separate decoders logged "sending message
// to a Handler on a dead thread" — a decoder still reporting back after its
// thread was torn down, which is what being disposed mid-startup looks like.
// The two biggest bursts, twenty warnings between them, land immediately after
// the search grid appears. Android also took decoders back off the app five
// times, which it only does when too many are held at once.
//
// ══════════════════════════════════════════════════════════════════════════
// AND THE FIX IS NOT A DELAY
// ══════════════════════════════════════════════════════════════════════════
//
// The first attempt waited a fixed 180ms after the last report. It stopped
// the churn and it was the wrong fix: it charged EVERY viewer a fifth of a
// second — including the one not scrolling at all — to solve a problem that
// only exists while the finger is moving.
//
// So the tests below are mostly about the opposite of waiting. Standing
// still, a preview must open with NO timer involved at all.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

/// Source with comment lines removed, so a check matches code and not the
/// comment explaining it.
String codeOnly(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  final file = File('lib/pages/search_page.dart').readAsStringSync();

  // Scope EVERY check to the coordinator class.
  //
  // This file holds three separate dispose() methods — the page's, a tile's
  // and the coordinator's. Searching the whole file for "void dispose()"
  // finds the page's and reports on the wrong one: the first run of this
  // test failed against code that was already correct. A source check that
  // matches the wrong function is worse than no check, because it reports
  // confidently on something nobody asked about.
  //
  // Lazy, because bodyOf asserts, and an assertion outside a test body has
  // no test to fail — it takes the whole file down at load instead.
  String coordinator() =>
      bodyOf(file, 'class _PreviewCoordinator extends ChangeNotifier');

  group('standing still, a preview opens with no wait', () {
    test('nothing is scheduled when the grid is not moving', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      // The still case must reach _setActive without going near a Timer.
      final stillBranch = body.substring(
          body.indexOf('if (!_isScrolling)'), body.indexOf('_pendingActive = id;'));
      expect(stillBranch.contains('_setActive(id)'), isTrue,
          reason: 'A viewer who is not scrolling must get their preview at '
              'once. This is the common case and it has to cost nothing.');
      expect(stillBranch.contains('Timer('), isFalse,
          reason: 'No timer may be created when the grid is still. A fixed '
              'delay charges everybody for a problem only scrolling causes.');
    });

    test('and the moment scrolling stops, the pick is opened', () {
      final body = bodyOf(coordinator(), 'void setScrolling(bool scrolling)');
      expect(body.contains('_openPending()'), isTrue,
          reason: 'The end of a scroll is the signal to open. Without this '
              'the only thing left is the safety timer, and the wait comes '
              'straight back.');
    });

    test('the page actually tells the coordinator', () {
      // The wire. Everything above is inert if nothing reports scroll state,
      // and the coordinator would then think the page is permanently still —
      // which is the original churn, restored in full.
      final page = codeOnly(File('lib/pages/search_page.dart').readAsStringSync());
      expect(page.contains('NotificationListener<ScrollNotification>'), isTrue,
          reason: 'Nothing is listening for scrolls, so setScrolling is never '
              'called and every flick churns decoders again.');
      expect(page.contains('setScrolling(true)'), isTrue);
      expect(page.contains('setScrolling(false)'), isTrue);
      expect(page.contains('return false;'), isTrue,
          reason: 'The notification must be passed on. Swallowing it breaks '
              'pull-to-refresh, which listens for the same events.');
    });
  });

  group('mid-scroll it holds, and cannot get stuck', () {
    test('a pick made while scrolling is remembered, not opened', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      expect(body.contains('_pendingActive = id;'), isTrue,
          reason: 'Mid-flick the pick has to be held, or every tile passed '
              'opens a decoder.');
    });

    test('the safety net is armed once, not pushed away every frame', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      expect(body.contains('_settleTimer ??='), isTrue,
          reason: 'Re-arming on every report means a continuous flick keeps '
              'resetting the one thing that can recover a lost end-of-scroll, '
              'so a dropped notification leaves the grid dead forever.');
    });

    test('the safety net is long, because it should never fire', () {
      final body = bodyOf(coordinator(), 'static const Duration _kScrollLost');
      final ms = RegExp(r'milliseconds:\s*(\d+)').firstMatch(body);
      expect(ms, isNotNull);
      expect(int.parse(ms!.group(1)!), greaterThanOrEqualTo(400),
          reason: 'This is a last resort for a lost scroll-end, not a policy. '
              'Short enough to be reached in normal use and it becomes the '
              'fixed delay this change removed.');
    });
  });

  group('two things must never wait', () {
    test('stopping a preview is immediate', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      final nullBranch = body.substring(
          body.indexOf('if (id == null)'), body.indexOf('if (id == _activeId)'));
      expect(nullBranch.contains('_setActive(null)'), isTrue,
          reason: 'Releasing a decoder must happen at once, scrolling or not. '
              'It is the scarce resource here — Android reclaimed five of '
              'them during the run this came from.');
      expect(nullBranch.contains('Timer('), isFalse);
    });
  });

  group('the timer cannot outlive the page', () {
    // A Timer holding a closure over a disposed ChangeNotifier is how a
    // "screen stuck on back" turns into a crash on the next screen.
    for (final fn in ['void clearActive()', 'void dispose()']) {
      test('$fn cancels it', () {
        final body = bodyOf(coordinator(), fn);
        expect(body.contains('_cancelSettle()'), isTrue,
            reason: '$fn leaves the settle timer running. It fires into a '
                'coordinator nobody is listening to, and on dispose that is a '
                'notifyListeners() after dispose().');
      });
    }
  });

  group('the auto-advance is not a scroll and does not wait', () {
    test('_autoAdvance still acts directly', () {
      // The 25s carousel tick is a deliberate, already-spaced decision. Putting
      // it behind the settle would add a second delay to something that is
      // already slow on purpose.
      final body = bodyOf(coordinator(), 'void _autoAdvance()');
      expect(body.contains('_setActive('), isTrue,
          reason: 'The carousel advance is not scroll churn and must not be '
              'debounced a second time.');
    });
  });
}
