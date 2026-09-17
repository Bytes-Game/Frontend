// How many video players the SEARCH GRID is holding.
//
// The feed's players come from a pool that cannot exceed four. The grid's
// do not — each tile owns its own — so the two have to be told apart to
// know which part of the app is holding the phone's decoders.
//
// A device log showed the live decoder count climbing from five to TWELVE,
// every one of them in the stretch just after the search page opened, with
// seven created and not one released. Android reclaimed a decoder by force
// during it.
//
// It could NOT be settled from that log. Reels are now served at the same
// 480p the grid uses, so a decoder's size no longer says which part of the
// app asked for it — the one signal that separated them is gone. Rather
// than guess at it for another round, the app says it out loud.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';

import 'support/dart_source.dart';

void main() {
  late ReelDiagnostics d;

  setUp(() {
    d = ReelDiagnostics.instance;
    d.debugReset();
  });

  group('the count follows the players', () {
    test('opening one raises it, giving it back lowers it', () {
      d.recordPreviewOpened();
      d.recordPreviewOpened();
      expect(d.debugPreviewLive, 2);
      d.recordPreviewReleased();
      expect(d.debugPreviewLive, 1);
    });

    test('the peak remembers the worst moment, not the current one', () {
      // The number that matters is how many were alive AT ONCE. A count
      // read after everything settled would have shown five in the log
      // that prompted this, and five is fine.
      for (var i = 0; i < 7; i++) {
        d.recordPreviewOpened();
      }
      for (var i = 0; i < 7; i++) {
        d.recordPreviewReleased();
      }
      expect(d.debugPreviewLive, 0);
      expect(d.debugPreviewPeak, 7,
          reason: 'a peak that decays hides exactly the event it exists to '
              'catch');
    });

    test('and survives the count coming back down and up again', () {
      // The realistic shape: tiles open and close as the grid scrolls, so
      // the live count goes up, down, and up again by less. Only rising
      // monotonically — which is what the test above does — would pass
      // with the peak simply tracking the current value.
      for (var i = 0; i < 5; i++) {
        d.recordPreviewOpened();
      }
      for (var i = 0; i < 3; i++) {
        d.recordPreviewReleased();
      }
      d.recordPreviewOpened();
      expect(d.debugPreviewLive, 3);
      expect(d.debugPreviewPeak, 5,
          reason: 'the peak followed the current count back down, so the '
              'worst moment of the session is gone from the log');
    });

    test('it cannot go negative', () {
      // Release without an open — a double release, or one that survived a
      // hot reload. A negative count would read as nonsense and make the
      // whole line untrustworthy.
      d.recordPreviewReleased();
      d.recordPreviewReleased();
      expect(d.debugPreviewLive, 0);
    });
  });

  group('it reaches the log', () {
    test('the summary carries it once the grid has opened one', () {
      d.recordProxiedStart(); // summary stays silent with no reels at all
      d.recordPreviewOpened();
      expect(d.summary(), contains('previews live=1'));
      expect(d.summary(), contains('peak=1'));
    });

    test('and says nothing at all when search was never opened', () {
      d.recordProxiedStart();
      expect(d.summary(), isNot(contains('previews')),
          reason: 'a row of zeroes on every session that never went near '
              'the search page is noise in the one line that gets read');
    });
  });

  group('the grid actually reports', () {
    final src = File('lib/pages/search_page.dart').readAsStringSync();

    test('every player it builds', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('recordPreviewOpened()'),
          reason: 'a count that misses the players being built answers the '
              'question backwards');
    });

    test('and every one it gives back', () {
      final body = bodyOf(src, 'void _releasePlayer()');
      expect(body, contains('recordPreviewReleased()'));
    });

    test('the release is reported before the controller is disposed', () {
      // Not for correctness — for reading the log. Reporting after a
      // fire-and-forget dispose would put the two halves of one event in
      // an order that does not match what happened.
      final body = bodyOf(src, 'void _releasePlayer()');
      final rec = body.indexOf('recordPreviewReleased()');
      final dis = body.indexOf('c.dispose()');
      expect(rec, greaterThan(-1));
      expect(rec, lessThan(dis));
    });
  });
}
