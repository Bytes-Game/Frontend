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
    _events[id]?.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        size: const Size(16, 9),
        duration: const Duration(seconds: 3),
      ),
    );
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

  /// Player ids whose `pause` never completes — no value, no error, just a
  /// future that stays pending. Stands in for a native player whose
  /// decoder the resource manager took, or whose playback thread has died:
  /// the method-channel reply never arrives, so the Dart side waits
  /// forever. A test cannot reproduce that with a throw, because a throw
  /// is the case the pool already handles.
  final Set<int> hangingPause = {};

  @override
  Future<void> pause(int playerId) {
    if (hangingPause.contains(playerId)) return Completer<void>().future;
    paused.add(playerId);
    return Future<void>.value();
  }

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

  /// Every audio-decoding request the pool made, oldest first, recorded as
  /// (data source, enabled). The production implementation of this needs the
  /// Android platform class; the fake platform here is deliberately none of
  /// the real ones, so the seam is what makes the DECISION testable without
  /// pretending to be ExoPlayer.
  late List<(String, bool)> audioCalls;

  /// The pool's most recent instruction for [u], or null if it never gave one.
  bool? audioFor(String u) {
    for (final call in audioCalls.reversed) {
      if (call.$1 == u) return call.$2;
    }
    return null;
  }

  /// Whether [u]'s player is decoding audio. A player is born decoding it, so
  /// silence from the pool means yes — the pool only ever has to speak up to
  /// take it away and to hand it back.
  bool audioOn(String u) => audioFor(u) ?? true;

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
    audioCalls = [];
    VideoPlayerService.setPlayerAudio = (controller, {required enabled}) async {
      audioCalls.add((controller.dataSource, enabled));
    };
    await service.disposeAll();
    ReelDiagnostics.instance.debugReset();
    service.configure(
      const VideoPoolConfig(
        maxPoolSize: 4,
        prefetchAhead: 2,
        prefetchAheadBurst: 3,
        prefetchBack: 1,
      ),
    );
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

      expect(
        service.debugPoolUrls,
        contains(url(0)),
        reason: 'the watched reel must survive every eviction round',
      );
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

      expect(
        service.debugPoolUrls,
        isNot(contains(url(0))),
        reason: 'reel 0 was the least recently used',
      );
      expect(service.debugPoolUrls, contains(url(4)));
      expect(
        service.debugPoolUrls,
        contains(url(3)),
        reason: 'reel 3 is on screen',
      );
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

      expect(
        service.debugPoolUrls,
        contains(url(99)),
        reason:
            'a full pool of watched reels must still make room for '
            'the reel one swipe ahead',
      );
      expect(
        service.debugPoolUrls,
        contains(url(3)),
        reason: 'and must not take that room from the reel on screen',
      );
    });

    test(
      'survives the next reel opening, rather than being first out',
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

        expect(
          service.debugPoolUrls,
          contains(url(3)),
          reason:
              'the spare is the likeliest next reel; evicting it first '
              'is what made every swipe rebuild a decoder',
        );
        expect(
          service.debugPoolUrls,
          isNot(contains(url(2))),
          reason: 'the stale reel is what should have gone instead',
        );
      },
    );

    test('counts a spare only when one was actually opened', () async {
      expect(ReelDiagnostics.instance.debugSpareWarm(SpareLane.nextReel), 0);

      service.debugOpenSpare(url(1), warm: true);
      await presentFrame();
      expect(ReelDiagnostics.instance.debugSpareWarm(SpareLane.nextReel), 1);

      // Now a pool with no room to spare: one slot, and the reel on
      // screen is in it. There is nothing to evict, so no spare opens —
      // and nothing may be counted.
      service.configure(
        const VideoPoolConfig(
          maxPoolSize: 1,
          prefetchAhead: 0,
          prefetchAheadBurst: 0,
          prefetchBack: 0,
        ),
      );
      await watch(url(5));
      await presentFrame();

      final before = ReelDiagnostics.instance.debugSpareWarm(
        SpareLane.nextReel,
      );
      service.debugOpenSpare(url(6), warm: true);
      await presentFrame();

      expect(
        ReelDiagnostics.instance.debugSpareWarm(SpareLane.nextReel),
        before,
      );
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
    test('the feed can name two, and each keeps its own gesture', () {
      final targets = VideoPlayerService.spareTargets(
        [url(1), url(2), url(3), url(9)],
        [(SpareLane.nextReel, url(1)), (SpareLane.opponent, url(9))],
      );

      expect(
        targets.keys,
        orderedEquals(<String>[url(1), url(9)]),
        reason:
            'the next reel and the opponent are both one gesture away, '
            'and the order is which wins the last slot',
      );
      expect(targets[url(1)], SpareLane.nextReel);
      expect(
        targets[url(9)],
        SpareLane.opponent,
        reason:
            'the lane is what lets the summary say whether flips are '
            'landing warm — one shared counter cannot, because swipes '
            'outnumber flips and drown them',
      );
    });

    test('naming nothing keeps the old single-spare behaviour', () {
      final targets = VideoPlayerService.spareTargets([
        url(1),
        url(2),
        url(3),
      ], const []);

      expect(
        targets.keys,
        orderedEquals(<String>[url(1)]),
        reason:
            'callers that never thought about this — a notification '
            'prewarming one url — must not start getting extra players',
      );
      expect(
        targets[url(1)],
        SpareLane.nextReel,
        reason: 'the nearest url in a window is a swipe away by definition',
      );
    });

    test('a url named twice is one player, on the first lane named', () {
      // Reachable: a battle whose opponent video is also the next reel's.
      // It gets one player, and it belongs to the gesture ranked higher —
      // counting it as a flip would overstate how well flips are served.
      final shared = VideoPlayerService.spareTargets(
        [url(1)],
        [(SpareLane.nextReel, url(1)), (SpareLane.opponent, url(1))],
      );
      expect(shared, hasLength(1));
      expect(shared[url(1)], SpareLane.nextReel);

      expect(
        VideoPlayerService.spareTargets(
          [url(1)],
          [(SpareLane.nextReel, ''), (SpareLane.opponent, url(1))],
        ),
        {url(1): SpareLane.opponent},
        reason:
            'an empty url is not a target, and must not swallow the lane '
            'of the one that follows it',
      );
      expect(VideoPlayerService.spareTargets(const [], const []), isEmpty);
    });

    test('each spare is counted against the gesture it serves', () async {
      // The point of the split. One shared counter could not say whether
      // a flip landed on a ready player, because swipes vastly outnumber
      // flips and a single total is dominated by them.
      // Deliberately crossed: the swipe opens COLD and the flip opens
      // WARM. Matching lane to warmth would let a counter that ignores
      // the lane entirely still pass.
      await watch(url(0));
      service.debugOpenSpare(url(1), warm: false, lane: SpareLane.nextReel);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      service.debugOpenSpare(url(9),
          warm: true, lane: SpareLane.opponent, wanted: {url(1), url(9)});
      await presentFrame();

      final d = ReelDiagnostics.instance;
      expect(d.debugSpareCold(SpareLane.nextReel), 1);
      expect(d.debugSpareWarm(SpareLane.nextReel), 0);
      expect(d.debugSpareWarm(SpareLane.opponent), 1,
          reason: 'a flip that opened warm has to be visible as a FLIP that '
              'opened warm, or the summary cannot say whether the read-ahead '
              'is reaching opponents at all');
      expect(d.debugSpareCold(SpareLane.opponent), 0);
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

      expect(
        service.debugPoolUrls,
        containsAll(<String>[url(1), url(9)]),
        reason:
            'a flip should land on a ready controller the same way a '
            'swipe does',
      );
      expect(
        service.debugPoolUrls,
        contains(url(0)),
        reason: 'and neither may cost the reel on screen',
      );
    });

    test('the second declines rather than evicting the first', () async {
      // Three slots: the reel on screen, one spare, and _openSpare keeps
      // the last one free. So the opponent arrives to a pool that has
      // nothing left it is allowed to take.
      service.configure(
        const VideoPoolConfig(
          maxPoolSize: 3,
          prefetchAhead: 1,
          prefetchAheadBurst: 2,
          prefetchBack: 1,
        ),
      );
      await watch(url(0));

      final wanted = {url(1), url(9)};
      service.debugOpenSpare(url(1), warm: true, wanted: wanted);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      service.debugOpenSpare(url(9), warm: true, wanted: wanted);
      await presentFrame();

      // Order is priority. The next reel went in first because swipes
      // vastly outnumber flips, and buying the opponent a slot by
      // evicting it would trade the common gesture for the rare one.
      expect(
        service.debugPoolUrls,
        contains(url(1)),
        reason: 'the next reel was named first and must keep its slot',
      );
      expect(
        service.debugPoolUrls,
        isNot(contains(url(9))),
        reason:
            'with no room left the opponent declines; the flip pays a '
            'cold open, which is cheaper than the swipe paying one',
      );
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
      expect(
        service.debugPoolUrls,
        isNot(contains(url(1))),
        reason: 'the stalest reel that is not on screen is the victim',
      );
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

      expect(
        platform.paused,
        contains(id),
        reason: 'reel 1 is not the reel on screen',
      );
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
        expect(
          platform.paused,
          contains(id),
          reason:
              'a decoder still feeding a surface that is being '
              'released is what floods the log with GraphicsTracker '
              'deallocate failures',
        );
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

      expect(
        platform.disposed,
        isEmpty,
        reason: 'nothing may be released before a frame has passed',
      );
      expect(
        service.debugPoolSize,
        lessThanOrEqualTo(4),
        reason:
            'but the entry is already out of the pool, so isLive is '
            'false and the tile has stopped painting it',
      );

      await presentFrame();
      expect(platform.disposed, isNotEmpty);
    });

    test('counts every player it retires', () async {
      await watch(url(0));
      for (var i = 1; i <= 6; i++) {
        await open(url(i));
      }
      await presentFrame();

      expect(
        ReelDiagnostics.instance.debugRetired,
        platform.disposed.length,
        reason:
            'starts counts players opened; this counts the other end, '
            'and the pair is the only direct read on churn',
      );
    });
  });

  group('the decoder budget', () {
    // The tiers were sized for the Java heap, which is not what runs out.
    // A profile run on an 8 GB phone — top tier, pool of 5 — was overruled
    // by the platform's resource manager reclaiming its decoders.
    test('caps every RAM tier, however much memory the device has',
        () async {
      for (final ramGb in <double>[1.5, 2.5, 4, 6, 12, 24]) {
        final cfg = VideoPoolConfig.forRam(ramGb);
        expect(
          cfg.maxPoolSize,
          lessThanOrEqualTo(VideoPoolConfig.maxConcurrentDecoders),
          reason: '${ramGb}GB tier must not exceed the decoder budget',
        );
      }
    });

    test('leaves small-RAM tiers alone', () async {
      // The clamp is a ceiling, not a floor. A 2 GB phone that should hold
      // two players must not be talked up to three by it.
      final low = VideoPoolConfig.forRam(1.5);
      expect(low.maxPoolSize, 2);
      expect(low.prefetchAhead, 1);
      expect(low.prefetchBack, 0);
    });

    test('keeps a slot for the reel on screen', () async {
      // Every spare count has to leave room for the active reel, or
      // _openSpare spends a decision per swipe declining spares the pool
      // was never able to hold.
      for (final ramGb in <double>[1.5, 2.5, 4, 6, 12]) {
        final cfg = VideoPoolConfig.forRam(ramGb);
        expect(cfg.prefetchAheadBurst, lessThanOrEqualTo(cfg.maxPoolSize - 1),
            reason: '${ramGb}GB burst window overcommits the pool');
        expect(cfg.prefetchAhead, lessThanOrEqualTo(cfg.maxPoolSize - 1));
        expect(cfg.prefetchBack, lessThanOrEqualTo(cfg.maxPoolSize - 1));
      }
    });

    test('never sits below what the screen has on it at once', () async {
      // The cap spent one release at 3, under the working set, on the
      // theory that a smaller pool means fewer live decoders. It does not:
      // getController builds a player for any tile that asks and evicts to
      // make room, so a cap under the demand holds the same number of
      // decoders and additionally throws one away per swipe. The device
      // run showed 40 opens and 37 retirements for 14 videos.
      expect(
        VideoPoolConfig.maxConcurrentDecoders,
        greaterThanOrEqualTo(VideoPoolConfig.onScreenWorkingSet),
        reason: 'a pool below the working set does not save decoders, it '
            'only evicts players the screen still needs',
      );
    });

    test('the top tier holds the whole working set', () async {
      // Anything from mid-tier up should be able to keep the reel on
      // screen, both swipe neighbours and a battle opponent alive at once.
      expect(
        VideoPoolConfig.forRam(8).maxPoolSize,
        VideoPoolConfig.onScreenWorkingSet,
      );
    });

    test('the startup default is inside the budget too', () async {
      // This is the config in force while DeviceCapabilities.probe is
      // still running — i.e. during app start, when the first reel is
      // opening and the decoder has least room to spare.
      expect(
        VideoPoolConfig.fallback.maxPoolSize,
        lessThanOrEqualTo(VideoPoolConfig.maxConcurrentDecoders),
      );
    });
  });

  group('audio decoding off screen', () {
    // Muting a player silences its OUTPUT. The decoder behind it keeps
    // running: a hardware AAC instance, an AudioTrack and its thread, and
    // every chunk of sound decoded and dropped. A device profile caught one
    // warm spare at "Qinput: 126, Render: 0, Drop: 122". Concurrent hardware
    // decoders are the budget this app actually runs out of, and every warm
    // player was spending two slots to use one.
    test('a warm spare gives up its audio decoder', () async {
      await watch(url(0));

      service.debugOpenSpare(url(1), warm: true);
      await settle();

      expect(
        audioOn(url(1)),
        isFalse,
        reason: 'a spare nobody can hear must not decode sound',
      );
      expect(
        audioOn(url(0)),
        isTrue,
        reason: 'the reel on screen must keep its audio',
      );
    });

    test('an off-screen neighbour gives up its audio decoder too', () async {
      // The PageView builds the tiles either side of the current one, and
      // those reach getController directly rather than through the spare
      // path. They are silent for the same reason and cost the same decoder.
      await watch(url(0));

      service.getController(url(1));
      await settle();

      expect(audioOn(url(1)), isFalse);
    });

    test('promoting a spare hands its audio back', () async {
      await watch(url(0));
      service.debugOpenSpare(url(1), warm: true);
      await settle();
      expect(audioOn(url(1)), isFalse);

      service.getController(url(1));

      expect(
        audioOn(url(1)),
        isTrue,
        reason: 'asked for on promotion rather than at play(), so the sound '
            'is ready before the first frame instead of behind it',
      );
    });

    test('the sweep moves audio to whichever reel is on screen', () async {
      // pauseAllExcept is the one place that knows what the user is looking
      // at, so it owns the answer for every player at once — the same way it
      // already owns volume.
      await watch(url(0));
      await open(url(1));
      await settle();

      await service.pauseAllExcept(url(1));

      expect(audioOn(url(1)), isTrue);
      expect(audioOn(url(0)), isFalse);
    });

    test('a spare promoted before it finishes loading stays audible',
        () async {
      // The user can swipe onto a spare while it is still initialising. The
      // spare's own initialize() continuation runs AFTER that, and used to
      // mute unconditionally — silencing the reel now on screen, with the
      // sweep that would have fixed it already run. Volume and audio
      // decoding both have to ask who is on screen rather than assume.
      platform.holdInit = true;
      await watch(url(0));
      service.debugOpenSpare(url(1), warm: true);
      await settle();

      // Swipe onto it before its first frame lands.
      await service.pauseAllExcept(url(1));
      platform.finishInit(platform.idFor(url(1)));
      await settle();

      expect(
        audioOn(url(1)),
        isTrue,
        reason: 'the late initialize() must not silence the reel on screen',
      );
      expect(
        platform.volume[platform.idFor(url(1))],
        isNot(0),
        reason: 'and must not mute it either',
      );
    });

    test('says nothing when nothing changed', () async {
      // Every call is a platform round trip. Players are born decoding
      // audio, so the reel on screen should need no instruction at all.
      await watch(url(0));
      await settle();
      final before = audioCalls.length;

      await service.pauseAllExcept(url(0));
      await service.pauseAllExcept(url(0));

      expect(audioCalls.length, before);
    });
  });

  group('handing over to the next reel', () {
    test('a player that never stops cannot hold the next reel back',
        () async {
      // The feed awaits pauseAllExcept before calling play(), so whatever
      // this future waits on is directly in front of the user's next
      // video. An outgoing player whose pause never returns — reclaimed
      // decoder, dead playback thread — used to leave that await pending
      // for the rest of the session: a reel frozen on its first frame,
      // with no error anywhere to say why.
      await watch(url(0));
      await open(url(1));
      platform.hangingPause.add(platform.idFor(url(0)));

      await service
          .pauseAllExcept(url(1))
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'pauseAllExcept never returned, so the incoming reel never '
              'gets to play() — the freeze this bound exists to prevent',
            ),
          );
    });

    test('still waits for players that do stop', () async {
      // The bound is a backstop, not the normal path: when the outgoing
      // players answer, the sweep must actually have stopped them by the
      // time it returns. That ordering is what keeps AudioFocus from
      // moving while the old decoder is still running.
      await watch(url(0));
      await open(url(1));

      await service.pauseAllExcept(url(1));

      expect(
        platform.paused,
        contains(platform.idFor(url(0))),
        reason: 'the outgoing player must be stopped before the caller '
            'starts the incoming one',
      );
    });

    test('names the incoming reel even when the outgoing one hangs',
        () async {
      // Eviction and volume both read the active URL. If a hung pause
      // could stop it being recorded, the reel on screen would be a legal
      // eviction victim and could come up silent.
      await watch(url(0));
      await open(url(1));
      platform.hangingPause.add(platform.idFor(url(0)));

      await service.pauseAllExcept(url(1));
      for (var i = 2; i < 8; i++) {
        await open(url(i));
      }
      await presentFrame();

      expect(service.debugPoolUrls, contains(url(1)));
    });
  });

  group('one spare at a time', () {
    // Building two spares in the same turn put three players into
    // MediaCodec's INITIALIZING state at once, which is where the vendor
    // stack starts handing back reclaims.
    test('a spare mid-construction holds the gate', () async {
      platform.holdInit = true;
      await watch(url(0));

      service.debugOpenSpare(url(1), warm: true);
      await settle();

      expect(
        service.debugSpareGateHeld,
        isTrue,
        reason: 'the next spare must wait while this one allocates a codec',
      );
    });

    test('finishing initialisation releases the gate', () async {
      platform.holdInit = true;
      await watch(url(0));

      service.debugOpenSpare(url(1), warm: true);
      await settle();
      platform.finishInit(platform.idFor(url(1)));
      await settle();

      expect(
        service.debugSpareGateHeld,
        isFalse,
        reason: 'a gate that is never released opens no further spares for '
            'the rest of the session, and no counter would show it',
      );
    });

    test('shutdown releases the gate', () async {
      // Otherwise the first spare of the NEXT session waits out the
      // timeout behind a player that no longer exists.
      platform.holdInit = true;
      await watch(url(0));
      service.debugOpenSpare(url(1), warm: true);
      await settle();
      expect(service.debugSpareGateHeld, isTrue);

      await service.disposeAll();

      expect(service.debugSpareGateHeld, isFalse);
    });
  });
}
