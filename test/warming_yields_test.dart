// The reel on screen wins.
//
// ROOT CAUSE, from the device log rather than from reasoning:
//
//   link measured, this device    2.9 Mbps
//   480p needs, sustained         1.6 Mbps
//   read-ahead ran                up to four downloads, flat out
//
// Five streams share one link, so the reel being WATCHED got about a fifth
// of it — 0.58 Mbps against the 1.6 it needs. It played from the slice
// already on disk, reached the end of that, and starved. That is "it sticks
// at the start and then plays": the start is the part already downloaded.
//
// The decoder statistics say the same thing from the other side. In one
// session: 2,661 frames rendered, ZERO dropped, across 57 decoder instances.
// A decoder that never drops a frame is never behind — it is always waiting.
//
// readAheadReserveBps was supposed to cover this and cannot: it is an input
// to choosing a RENDITION, and nothing downstream makes read-ahead stay
// inside it. Four sockets pulling as hard as TCP allows do not know a
// reserve exists.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/video_cache_service.dart';

import 'support/dart_source.dart';

void main() {
  final cache = VideoCacheService.instance;

  setUp(() {
    // Short enough that the waits below stay quick, long enough that a
    // release cannot slip through between two statements.
    VideoCacheService.warmingResumesAfter = const Duration(milliseconds: 60);
  });

  tearDown(() {
    cache.releaseWarmingNow();
    VideoCacheService.warmingResumesAfter = const Duration(milliseconds: 500);
  });

  group('holding and releasing', () {
    test('starts released', () {
      expect(cache.isHeld, isFalse);
    });

    test('holds, and holding twice is not two holds', () {
      cache.holdWarming();
      expect(cache.isHeld, isTrue);
      cache.holdWarming();
      cache.releaseWarmingNow();
      expect(cache.isHeld, isFalse,
          reason: 'a second hold must not need a second release — the '
              'listener fires on every frame of buffering');
    });

    test('and that guard is load-bearing, because Dart COUNTS pauses',
        () async {
      // This is why holdWarming returns early when already held. The
      // buffering listener fires many times a second; without the guard
      // every download would be paused dozens of times, and the single
      // release would restart none of them. Read-ahead would be dead for
      // the rest of the session.
      final c = StreamController<int>();
      final got = <int>[];
      final sub = c.stream.listen(got.add);
      sub.pause();
      sub.pause();
      sub.resume();
      c.add(1);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(got, isEmpty,
          reason: 'two pauses need two resumes — so holdWarming must never '
              'pause a subscription twice');
      await sub.cancel();
      await c.close();
    });

    test('the guard is actually in holdWarming', () {
      final src =
          File('lib/services/video_cache_service.dart').readAsStringSync();
      final body = bodyOf(src, 'void holdWarming()');
      expect(body, contains('if (_held) return;'),
          reason: 'without it, repeated holds pause each download repeatedly '
              'and one release restarts nothing');
    });

    test('releasing when not held does nothing', () {
      cache.releaseWarming();
      expect(cache.isHeld, isFalse);
      cache.releaseWarmingNow();
      expect(cache.isHeld, isFalse);
    });

    // ───────────────────────────────────────────────────────────────────
    // THE HOLD HAS TO LAST LONG ENOUGH TO MEAN ANYTHING
    //
    // Measured on a device, this defence fired and achieved nothing:
    //
    //     warming stood down n=43 for 3.9s
    //
    // Forty-three stand-downs sharing under four seconds — ninety
    // milliseconds each, and almost all of that total is ONE hold. Over
    // the same session the decoder was still handed nothing to play 261
    // times, median a full second, exactly as bad as the run before.
    //
    // isBuffering does not stay true while a reel is dry. It flickers, and
    // every flicker was a hold and an instant release.
    // ───────────────────────────────────────────────────────────────────
    test('a recovery does not lift the hold straight away', () async {
      cache.holdWarming();
      cache.releaseWarming();
      expect(cache.isHeld, isTrue,
          reason: 'the downloads resumed on the first good tick, which is '
              'how forty-three stand-downs came to eighty milliseconds each');

      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(cache.isHeld, isFalse,
          reason: 'the hold never lifts, so read-ahead is dead for the rest '
              'of the session');
    });

    test('a reel that goes dry again keeps the hold', () async {
      cache.holdWarming();
      cache.releaseWarming();
      // Still struggling: buffering comes back inside the settle window.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cache.holdWarming();
      await Future<void>.delayed(const Duration(milliseconds: 160));

      expect(cache.isHeld, isTrue,
          reason: 'the pending resume was not cancelled, so downloads came '
              'back while the reel was still starving');
    });

    test('a steady recovery is not pushed further away by each tick',
        () async {
      // The listener fires many times a second while a reel plays. If each
      // good tick re-armed the timer, the resume would keep being pushed
      // out and would only arrive once the ticks STOPPED — which is to say
      // once the reel was paused or gone.
      //
      // So the check has to happen while the ticks are still coming. A
      // version of this that waited for them to finish passed either way.
      cache.holdWarming();
      var stillHeldWhileTicking = true;
      for (var i = 0; i < 12; i++) {
        cache.releaseWarming();
        await Future<void>.delayed(const Duration(milliseconds: 15));
        // 60ms settle, 15ms apart: by the fifth tick the correct code has
        // already resumed. Re-arming code is still held at the twelfth.
        if (i >= 6 && !cache.isHeld) stillHeldWhileTicking = false;
      }
      expect(stillHeldWhileTicking, isFalse,
          reason: 'every good tick pushed the resume back, so downloads '
              'stay stopped for as long as the reel keeps playing — which '
              'is exactly backwards');
    });

    test('the shipped wait is neither nothing nor forever', () {
      // Every test in this file overrides the duration, so none of them
      // can see the value the app actually ships with. A default of zero
      // is the bug this whole change fixes; a default of minutes would
      // stop read-ahead for the rest of the session.
      final src =
          File('lib/services/video_cache_service.dart').readAsStringSync();
      final m = RegExp(r'warmingResumesAfter = const Duration\(([a-z]+): (\d+)\)')
          .firstMatch(src);
      expect(m, isNotNull, reason: 'the default is not a plain Duration any '
          'more, so nothing here can check it');
      expect(m!.group(1), 'milliseconds',
          reason: 'a settle measured in seconds or minutes takes bandwidth '
              'from reading ahead for far too long');
      final ms = int.parse(m.group(2)!);
      expect(ms, greaterThanOrEqualTo(200),
          reason: 'too short to outlast the flicker it exists for: '
              'isBuffering goes true-false-true while a reel is dry');
      expect(ms, lessThanOrEqualTo(1500),
          reason: 'the next swipe lands cold because read-ahead spent this '
              'long standing still');
    });

    test('the reel changing resumes at once, without the wait', () {
      // Nothing left to protect, and making the INCOMING reel wait half a
      // second for the downloads it needs turns a defence into a delay.
      cache.holdWarming();
      cache.releaseWarmingNow();
      expect(cache.isHeld, isFalse);
    });
  });

  group('a paused download is not a dead one', () {
    // The hold pauses downloads rather than cancelling them, which only
    // works if the stall deadline stops counting while paused. Verified
    // here rather than assumed, because if it did keep counting the hold
    // would kill every download it touched.
    test('the stall clock stops while the subscription is paused', () async {
      final c = StreamController<List<int>>();
      Object? err;
      final sub = c.stream
          .timeout(const Duration(milliseconds: 80),
              onTimeout: (s) => s.addError(TimeoutException('stalled')))
          .listen((_) {}, onError: (Object e) => err = e);

      c.add([1]);
      sub.pause();
      // Five times the deadline, held.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final firedWhileHeld = err != null;
      sub.resume();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      await c.close();

      expect(firedWhileHeld, isFalse,
          reason: 'if the deadline counted through a hold, standing '
              'read-ahead down would destroy every download in flight');
    });
  });

  group('it is wired to the reel on screen', () {
    final player = File('lib/services/video_player_service.dart').readAsStringSync();
    final cacheSrc =
        File('lib/services/video_cache_service.dart').readAsStringSync();

    test('the player watches for starvation when the reel changes', () {
      final body = bodyOf(player, 'Future<void> pauseAllExcept(String activeUrl)');
      expect(body, contains('_watchForStarvation(activeUrl)'),
          reason: 'nothing notices the reel on screen running dry, which is '
              'the whole bug');
    });

    test('it reads the player saying it has run out', () {
      final body = bodyOf(player, 'void _watchForStarvation(String activeUrl)');
      expect(body, contains('v.isBuffering'),
          reason: 'isBuffering is the player saying it has reached the end '
              'of what it holds; it appeared nowhere in this codebase');
      expect(body, contains('holdWarming()'));
      expect(body, contains('releaseWarming'));
    });

    test('only while it is actually trying to play', () {
      // A paused reel is not starving. Holding for one would stop
      // read-ahead for as long as the finger is down.
      final body = bodyOf(player, 'void _watchForStarvation(String activeUrl)');
      expect(body, contains('v.isBuffering && v.isPlaying'));
    });

    test('the hold is released on every way out', () {
      final body = bodyOf(player, 'void _watchForStarvation(String activeUrl)');
      // Changing reel, the controller dying, and playing again.
      // Two of the three exits are not "the reel recovered" — the reel
      // changed, and the player died — and those resume at once rather
      // than waiting out the settle.
      expect('releaseWarming'.allMatches(body).length, greaterThanOrEqualTo(3),
          reason: 'a hold that is never lifted is worse than no hold: '
              'read-ahead would stop for the rest of the session');
      expect('releaseWarmingNow()'.allMatches(body).length, 2,
          reason: 'the reel changing or its player dying should not make '
              'the next reel wait out a settle for nothing');
      expect(body, contains('if (!isLive(controller))'),
          reason: 'a disposed controller stops firing, so the hold would '
              'never be lifted');
    });

    test('the old listener is detached when the reel changes', () {
      final body = bodyOf(player, 'void _watchForStarvation(String activeUrl)');
      expect(body, contains('previous.removeListener(listener)'),
          reason: 'one listener per reel accumulates a listener per swipe, '
              'each still holding and releasing on its own schedule');
    });

    test('holding stops new downloads starting, not just running ones', () {
      final body = bodyOf(cacheSrc, 'void _pump()');
      expect(body, contains('if (_held) return;'),
          reason: 'pausing the four in flight and then starting four more '
              'achieves nothing');
    });

    test('releasing resumes what it paused', () {
      final body = bodyOf(cacheSrc, 'void releaseWarming()');
      expect(body, contains('subscription?.resume()'),
          reason: 'downloads stay paused for ever and read-ahead never '
              'recovers after the first buffer');
      expect(body, contains('_pump()'),
          reason: 'resuming the paused ones without pumping leaves the '
              'queue that built up during the hold stuck');
    });

    test('it pauses rather than cancels', () {
      final body = bodyOf(cacheSrc, 'void holdWarming()');
      expect(body, contains('subscription?.pause()'));
      expect(body, isNot(contains('_cancel(')),
          reason: 'cancelling throws away everything already fetched, and '
              'the reel it was for is usually still coming');
    });
  });
}
