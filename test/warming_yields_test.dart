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

  tearDown(cache.releaseWarming);

  group('holding and releasing', () {
    test('starts released', () {
      expect(cache.isHeld, isFalse);
    });

    test('holds, and holding twice is not two holds', () {
      cache.holdWarming();
      expect(cache.isHeld, isTrue);
      cache.holdWarming();
      cache.releaseWarming();
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
      expect(body, contains('releaseWarming()'));
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
      expect('releaseWarming()'.allMatches(body).length, greaterThanOrEqualTo(3),
          reason: 'a hold that is never lifted is worse than no hold: '
              'read-ahead would stop for the rest of the session');
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
