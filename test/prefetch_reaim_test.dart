// When the feed re-aims its warm window, and when it waits.
//
// Background: warming is pointed at wherever the user is standing, and
// VideoCacheService.warm() cancels the download of any URL that has
// dropped out of that window. Re-aiming once per page change is right
// when the user is watching reels and self-defeating when they are
// flinging — each re-aim kills fetches the previous one started, so the
// download slots churn and nothing finishes. A device profile caught it
// exactly: 22 URLs seen, 18 of 22 downloads cancelled, and the reels the
// user actually landed on opening cold anyway.
//
// The fix defers the re-aim until the scrolling settles. The risk it
// introduces is the opposite one — a fling that lasts leaves the window
// pointed somewhere the user has left — so the backstop below matters as
// much as the deferral, and neither is visible from the counters.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/widgets/smart_reels_feed.dart';

void main() {
  final t0 = DateTime(2026, 8, 17, 23, 50);

  group('re-aiming the warm window', () {
    test('a deliberate swipe re-aims immediately', () {
      // Not bursting: the user is watching reels, one download slot is
      // not contended, and the window should follow them at once.
      expect(
        shouldReaimPrefetchNow(
          bursting: false,
          lastPrefetchAt: t0,
          now: t0.add(const Duration(milliseconds: 10)),
        ),
        isTrue,
      );
    });

    test('the first re-aim of a feed never waits', () {
      // Nothing has been warmed yet, so there is no in-flight work for a
      // re-aim to cancel — deferring here would only delay the first
      // swipe of the session, which is the one the cache is worst at.
      expect(
        shouldReaimPrefetchNow(
          bursting: true,
          lastPrefetchAt: null,
          now: t0,
        ),
        isTrue,
      );
    });

    test('a fling defers rather than cancelling what it just started', () {
      expect(
        shouldReaimPrefetchNow(
          bursting: true,
          lastPrefetchAt: t0,
          now: t0.add(const Duration(milliseconds: 400)),
        ),
        isFalse,
      );
    });

    test('a sustained fling still re-aims once the window goes stale', () {
      // The failure this guards against is silent: warming would keep
      // running, keep reporting downloads, and be pointed at reels the
      // user passed ten swipes ago.
      expect(
        shouldReaimPrefetchNow(
          bursting: true,
          lastPrefetchAt: t0,
          now: t0.add(prefetchMaxStale),
        ),
        isTrue,
      );
      expect(
        shouldReaimPrefetchNow(
          bursting: true,
          lastPrefetchAt: t0,
          now: t0.add(prefetchMaxStale * 3),
        ),
        isTrue,
      );
    });

    test('the backstop is the only thing holding a long fling together', () {
      // Just inside it defers, just outside it fires — pinned so the
      // constant cannot drift to something that never fires (warming
      // stops) or always fires (the churn comes back).
      final almost = t0.add(prefetchMaxStale - const Duration(milliseconds: 1));
      expect(
        shouldReaimPrefetchNow(
            bursting: true, lastPrefetchAt: t0, now: almost),
        isFalse,
      );
      expect(
        shouldReaimPrefetchNow(
            bursting: true,
            lastPrefetchAt: t0,
            now: almost.add(const Duration(milliseconds: 1))),
        isTrue,
      );
    });
  });
}
