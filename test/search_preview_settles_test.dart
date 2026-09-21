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
// the search grid appears. The system also took decoders back off the app five
// times ("Released by resource manager"), which it only does when too many are
// held at once.
//
// The fix decides instantly and ACTS once the finger stops. These tests are
// about that gap, and about the two things that must NOT wait with it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

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

  group('opening a preview waits for the grid to hold still', () {
    test('the visibility rule schedules rather than opening', () {
      final body = bodyOf(coordinator(), 'void _maybePick()');
      expect(body.contains('_setActive('), isFalse,
          reason: 'A scroll decision must not open a player directly. Every '
              'call here has to go through _wantActive, which is where the '
              'settle lives — otherwise a fast flick opens one decoder per '
              'tile it passes.');
      expect(body.contains('_wantActive('), isTrue);
    });

    test('and the wait is short enough not to feel like lag', () {
      final body = bodyOf(coordinator(), 'static const Duration _kSettle');
      final ms = RegExp(r'milliseconds:\s*(\d+)').firstMatch(body);
      expect(ms, isNotNull, reason: 'the settle window must be in milliseconds');
      final value = int.parse(ms!.group(1)!);
      expect(value, greaterThanOrEqualTo(80),
          reason: 'Below about 80ms this is shorter than the tail of a flick, '
              'so the churn it exists to stop comes straight back.');
      expect(value, lessThanOrEqualTo(400),
          reason: 'Above about 400ms a deliberate pause on a tile feels like '
              'the page has stopped responding, which is the complaint this '
              'started from.');
    });
  });

  group('two things must never wait', () {
    test('stopping a preview is immediate', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      // The null branch hands a decoder back. Delaying that would hold the
      // scarce thing for longer, which is the opposite of the point.
      final nullBranch = body.substring(
          body.indexOf('if (id == null)'), body.indexOf('if (id == _activeId)'));
      expect(nullBranch.contains('_setActive(null)'), isTrue,
          reason: 'Releasing a decoder must happen at once. It is the scarce '
              'resource here — Android reclaimed five of them during the run '
              'this came from.');
      expect(nullBranch.contains('Timer('), isFalse,
          reason: 'Nothing about handing a decoder back should be scheduled.');
    });

    test('a steady target is not pushed away by every frame', () {
      final body = bodyOf(coordinator(), 'void _wantActive(String? id)');
      expect(body.contains('id == _pendingActive'), isTrue,
          reason: 'A slow drag over one tile reports a new fraction every '
              'frame while the winner stays the same. Resetting the timer on '
              'each of those means the preview never opens at all — the page '
              'would look permanently dead instead of merely stuttery. The '
              'timer may only restart when the INTENDED tile changes.');
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
