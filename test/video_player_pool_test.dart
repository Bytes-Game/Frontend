// Tests for the live-player pool: who gets evicted, who gets to make
// noise, and how a player is shut down.
//
// Background: a profile run scrolling ~20 reels created and destroyed 32
// hardware decoders in about 35 seconds, left players muted-but-audible
// off screen, and filled the log with `GraphicsTracker: cannot
// deallocate due to being stopped` on every teardown. Three separate
// faults in this file, none of them visible to the existing counters:
//
//   * the read-ahead spare stopped being opened a few swipes in, because
//     the only entries it was willing to evict no longer existed — and
//     the spare counters were recorded by the caller BEFORE the attempt,
//     so the summary reported spares that were never opened;
//   * eviction preferred prefetch entries, so each swipe threw away the
//     player for the reel it was about to need;
//   * players were released while their surface was still attached.
//
// These are plain `test`s rather than `testWidgets` on purpose:
// `VideoPlayerController.dispose()` does not complete inside the
// fake-async zone a `testWidgets` body runs in, so a suite written that
// way hangs on the first teardown. The frame wait that production uses
// is injected through [VideoPlayerService.deferRelease] instead, which
// is also the only part of it worth asserting on — that a player leaves
// the pool before it is released, not who owns the clock.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_player_service.dart';

/// A platform that hands out ids and records what was done to each one.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};

  /// Player id → the URL it was created for, in creation order.
  final Map<int, String> createdFor = {};
  final Map<int, double> volume = {};
  final Set<int> paused = {};
  final List<int> disposed = [];

  /// When true, `createWithOptions` does NOT emit `initialized`; the test
  /// releases it by hand with [finishInit]. Lets a test open a controller
  /// and change which reel is active before initialisation lands — the
  /// ordering that used to leave off-screen players at full volume.
  bool holdInit = false;

  int _nextId = 0;

  int idFor(String url) =>
      createdFor.entries.firstWhere((e) => e.value == url).key;

  void finishInit(int id) {
    _events[id]?.add(VideoEvent(
      eventType: VideoEventType.initialized,
      size: const Size(16, 9),
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    // Single-subscription, not broadcast: `initialized` is emitted before
    // VideoPlayerController attaches its listener, and a broadcast
    // controller would drop it — leaving every initialize() pending.
    _events[id] = StreamController<VideoEvent>();
    createdFor[id] = options.dataSource.uri ?? '';
    if (!holdInit) finishInit(id);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    // Deliberately not closing the stream: the controller cancels its
    // subscription first, and awaiting close() on an already-cancelled
    // single-subscription controller never returns.
    _events.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double v) async => volume[playerId] = v;

  @override
  Future<void> pause(int playerId) async => paused.add(playerId);

  @override
  Future<void> play(int playerId) async => paused.remove(playerId);

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlatform platform;

  /// Releases the pool has deferred to the next frame, drained by hand.
  late List<VoidCallback> pendingReleases;

  final service = VideoPlayerService.instance;

  String url(int i) => 'https://cdn.example/reel$i.mp4';

  /// Let every pending initialize/volume/dispose future settle.
  Future<void> settle() => pumpEventQueue(times: 40);

  /// Stand in for the frame production waits on.
  Future<void> presentFrame() async {
    final due = pendingReleases.toList();
    pendingReleases.clear();
    for (final r in due) {
      r();
    }
    await settle();
  }

  setUp(() async {
    platform = _FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    pendingReleases = [];
    VideoPlayerService.deferRelease = pendingReleases.add;
    await service.disposeAll();
    ReelDiagnostics.instance.debugReset();
    service.configure(const VideoPoolConfig(
      maxPoolSize: 4,
      prefetchAhead: 2,
      prefetchAheadBurst: 3,
      prefetchBack: 1,
    ));
  });

  tearDown(() async {
    await service.disposeAll();
    ReelDiagnostics.instance.debugReset();
  });

  /// Open [u] as the reel on screen, the way the feed does: build the
  /// controller for the tile, then declare it active. The pause between
  /// calls keeps `lastUsed` ordering real — DateTime.now() is coarse
  /// enough that same-tick entries tie.
  Future<void> watch(String u) async {
    service.getController(u);
    service.pauseAllExcept(u);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }

  Future<void> open(String u) async {
    service.getController(u);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }

  group('eviction', () {
    test('keeps the reel on screen no matter how full the pool is', () async {
      await watch(url(0));
      for (var i = 1; i <= 8; i++) {
        await open(url(i));
      }
      await presentFrame();

      expect(service.debugPoolUrls, contains(url(0)),
          reason: 'the watched reel must survive every eviction round');
      expect(service.debugPoolSize, lessThanOrEqualTo(4));
    });

    test('drops the stalest reel, not the one just opened', () async {
      for (var i = 0; i < 4; i++) {
        await open(url(i));
      }
      service.pauseAllExcept(url(3));

      // A fifth reel has to displace something.
      await open(url(4));
      await presentFrame();

      expect(service.debugPoolUrls, isNot(contains(url(0))),
          reason: 'reel 0 was the least recently used');
      expect(service.debugPoolUrls, contains(url(4)));
      expect(service.debugPoolUrls, contains(url(3)),
          reason: 'reel 3 is on screen');
    });
  });

  group('the read-ahead spare', () {
    test('is still opened after several reels have been watched', () async {
      // Fill the pool with watched (promoted, non-prefetch) reels — the
      // state the old code could not recover from, because it would only
      // ever evict a prefetch entry and by now there are none.
      for (var i = 0; i < 4; i++) {
        await watch(url(i));
      }
      await settle();

      service.debugOpenSpare(url(99), warm: true);
      await presentFrame();

      expect(service.debugPoolUrls, contains(url(99)),
          reason: 'a full pool of watched reels must still make room for '
              'the reel one swipe ahead');
      expect(service.debugPoolUrls, contains(url(3)),
          reason: 'and must not take that room from the reel on screen');
    });

    test('survives the next reel opening, rather than being first out',
        () async {
      await watch(url(0));
      await open(url(1));
      await open(url(2));

      // The spare goes in last, so it is the newest entry in the pool.
      service.debugOpenSpare(url(3), warm: true);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      // Fill to capacity, then force one eviction. Reel 2 is now the
      // stalest thing that isn't on screen; the spare is the freshest.
      await open(url(4));
      await open(url(5));
      await presentFrame();

      expect(service.debugPoolUrls, contains(url(3)),
          reason: 'the spare is the likeliest next reel; evicting it first '
              'is what made every swipe rebuild a decoder');
      expect(service.debugPoolUrls, isNot(contains(url(2))),
          reason: 'the stale reel is what should have gone instead');
    });

    test('counts a spare only when one was actually opened', () async {
      expect(ReelDiagnostics.instance.debugSpareWarm, 0);

      service.debugOpenSpare(url(1), warm: true);
      await presentFrame();
      expect(ReelDiagnostics.instance.debugSpareWarm, 1);

      // Now a pool with no room to spare: one slot, and the reel on
      // screen is in it. There is nothing to evict, so no spare opens —
      // and nothing may be counted.
      service.configure(const VideoPoolConfig(
        maxPoolSize: 1,
        prefetchAhead: 0,
        prefetchAheadBurst: 0,
        prefetchBack: 0,
      ));
      await watch(url(5));
      await presentFrame();

      final before = ReelDiagnostics.instance.debugSpareWarm;
      service.debugOpenSpare(url(6), warm: true);
      await presentFrame();

      expect(ReelDiagnostics.instance.debugSpareWarm, before);
      expect(service.debugPoolUrls, isNot(contains(url(6))));
    });
  });

  // A battle is two videos, and a horizontal flip reaches its opponent in
  // exactly the way a vertical swipe reaches the next reel. Both are one
  // gesture away, so both are named in `live` and both go through this
  // same path — rather than the opponent getting a lookalike of it in the
  // widget, which is what the tile used to do and what opened a decoder
  // pair for every battle scrolled past.
  group('more than one reel a gesture away', () {
    test('the feed can name two, and both are targeted', () {
      expect(
        VideoPlayerService.spareTargets(
          [url(1), url(2), url(3), url(9)],
          [url(1), url(9)],
        ),
        orderedEquals(<String>[url(1), url(9)]),
        reason: 'the next reel and the opponent are both one gesture away, '
            'and the order is which wins the last slot',
      );
    });

    test('naming nothing keeps the old single-spare behaviour', () {
      expect(
        VideoPlayerService.spareTargets([url(1), url(2), url(3)], const []),
        orderedEquals(<String>[url(1)]),
        reason: 'callers that never thought about this — a notification '
            'prewarming one url — must not start getting extra players',
      );
    });

    test('a url named twice is one player', () {
      // Reachable: a battle whose opponent video is also the next reel's.
      expect(
        VideoPlayerService.spareTargets([url(1)], [url(1), url(1)]),
        hasLength(1),
      );
      expect(VideoPlayerService.spareTargets([url(1)], ['', url(1)]),
          orderedEquals(<String>[url(1)]));
      expect(VideoPlayerService.spareTargets(const [], const []), isEmpty);
    });

    test('both wanted spares can be live at once', () async {
      await watch(url(0));

      // The next reel and the active reel's opponent, as the feed names
      // them: nearest swipe first, flip second.
      final wanted = {url(1), url(9)};
      service.debugOpenSpare(url(1), warm: true, wanted: wanted);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      service.debugOpenSpare(url(9), warm: true, wanted: wanted);
      await presentFrame();

      expect(service.debugPoolUrls, containsAll(<String>[url(1), url(9)]),
          reason: 'a flip should land on a ready controller the same way a '
              'swipe does');
      expect(service.debugPoolUrls, contains(url(0)),
          reason: 'and neither may cost the reel on screen');
    });

    test('the second declines rather than evicting the first', () async {
      // Three slots: the reel on screen, one spare, and _openSpare keeps
      // the last one free. So the opponent arrives to a pool that has
      // nothing left it is allowed to take.
      service.configure(const VideoPoolConfig(
        maxPoolSize: 3,
        prefetchAhead: 1,
        prefetchAheadBurst: 2,
        prefetchBack: 1,
      ));
      await watch(url(0));

      final wanted = {url(1), url(9)};
      service.debugOpenSpare(url(1), warm: true, wanted: wanted);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      service.debugOpenSpare(url(9), warm: true, wanted: wanted);
      await presentFrame();

      // Order is priority. The next reel went in first because swipes
      // vastly outnumber flips, and buying the opponent a slot by
      // evicting it would trade the common gesture for the rare one.
      expect(service.debugPoolUrls, contains(url(1)),
          reason: 'the next reel was named first and must keep its slot');
      expect(service.debugPoolUrls, isNot(contains(url(9))),
          reason: 'with no room left the opponent declines; the flip pays a '
              'cold open, which is cheaper than the swipe paying one');
    });

    test('a spare still evicts a stale reel to get its slot', () async {
      // The protection is for spares of the CURRENT window only — a reel
      // watched a while ago is still exactly what should make way.
      await watch(url(0));
      await open(url(1));
      await open(url(2));
      await open(url(3));

      service.debugOpenSpare(url(9), warm: true, wanted: {url(9)});
      await presentFrame();

      expect(service.debugPoolUrls, contains(url(9)));
      expect(service.debugPoolUrls, isNot(contains(url(1))),
          reason: 'the stalest reel that is not on screen is the victim');
    });
  });

  group('audio', () {
    test('a reel that is not on screen comes up silent', () async {
      platform.holdInit = true;
      await watch(url(0));

      // The neighbour tile the PageView builds ahead of time. It
      // initialises AFTER the active reel was declared — the ordering
      // that used to leave it at full volume, because the old code set
      // activeVolume unconditionally once initialisation landed and
      // relied on a mute sweep that had already run.
      service.getController(url(1));
      await settle();

      final neighbour = platform.idFor(url(1));
      platform.finishInit(neighbour);
      await settle();

      expect(platform.volume[neighbour], 0.0);
      expect(platform.paused, contains(neighbour));
    });

    test('the reel on screen is audible', () async {
      platform.holdInit = true;
      await watch(url(0));

      final active = platform.idFor(url(0));
      platform.finishInit(active);
      await settle();

      expect(platform.volume[active], 1.0);
    });

    test('a muted feed keeps the reel on screen silent', () async {
      platform.holdInit = true;
      service.feedMuted.value = true;
      addTearDown(() => service.feedMuted.value = false);

      await watch(url(0));
      final active = platform.idFor(url(0));
      platform.finishInit(active);
      await settle();

      expect(platform.volume[active], 0.0);
    });

    test('a spare is opened silent', () async {
      platform.holdInit = true;
      await watch(url(0));

      service.debugOpenSpare(url(1), warm: true);
      await settle();
      final spare = platform.idFor(url(1));
      platform.finishInit(spare);
      await settle();

      expect(platform.volume[spare], 0.0);
    });

    test('a play requested before initialising does not start a reel the '
        'user has already scrolled past', () async {
      // The feed calls play() on a tile's controller as soon as the tile
      // becomes current, which can be before the player is ready.
      // video_player remembers that request and replays it on
      // initialisation — so a swipe during the gap would otherwise leave
      // an off-screen reel decoding and holding AudioFocus.
      platform.holdInit = true;
      await watch(url(0));

      final neighbour = service.getController(url(1));
      await neighbour.play();
      final id = platform.idFor(url(1));

      platform.finishInit(id);
      await settle();

      expect(platform.paused, contains(id),
          reason: 'reel 1 is not the reel on screen');
      expect(platform.volume[id], 0.0);
    });
  });

  group('teardown', () {
    test('pauses and mutes a player before releasing it', () async {
      await watch(url(0));
      for (var i = 1; i <= 4; i++) {
        await open(url(i));
      }
      await settle();

      expect(pendingReleases, isNotEmpty, reason: 'something was evicted');
      // The shutdown half happens immediately, at eviction time.
      for (final id in platform.createdFor.keys) {
        if (service.debugPoolUrls.contains(platform.createdFor[id])) continue;
        expect(platform.paused, contains(id),
            reason: 'a decoder still feeding a surface that is being '
                'released is what floods the log with GraphicsTracker '
                'deallocate failures');
        expect(platform.volume[id], 0.0);
      }
    });

    test('leaves the widget tree a frame to drop the texture', () async {
      // Removing the entry from the pool is what makes isLive() false,
      // and the reel tile checks isLive before handing the controller to
      // VideoPlayer. Releasing in the same turn tears the native player
      // down under a still-mounted view.
      await watch(url(0));
      for (var i = 1; i <= 4; i++) {
        await open(url(i));
      }
      await settle();

      expect(platform.disposed, isEmpty,
          reason: 'nothing may be released before a frame has passed');
      expect(service.debugPoolSize, lessThanOrEqualTo(4),
          reason: 'but the entry is already out of the pool, so isLive is '
              'false and the tile has stopped painting it');

      await presentFrame();
      expect(platform.disposed, isNotEmpty);
    });

    test('counts every player it retires', () async {
      await watch(url(0));
      for (var i = 1; i <= 6; i++) {
        await open(url(i));
      }
      await presentFrame();

      expect(ReelDiagnostics.instance.debugRetired, platform.disposed.length,
          reason: 'starts counts players opened; this counts the other end, '
              'and the pair is the only direct read on churn');
    });
  });
}
