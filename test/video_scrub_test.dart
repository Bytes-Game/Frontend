// Tests for moving a video to a different spot by hand.
//
// The bar along the bottom of a reel is now a handle: drag it and the video
// jumps to where your finger is. All of those jumps go through one method on
// the player pool, and they go through it for a reason that has nothing to do
// with playback.
//
// The feed works out two of its strongest signals — "watched the whole thing"
// and "watched it twice" — by noticing where the playhead is. A finger on the
// bar moves the playhead in ways watching never does: drag to the end and it
// looks like a full watch; drag back to the start and it looks like a replay.
// Both are things the backend acts on. So the pool counts hand-moves, the feed
// watches that count, and a reel somebody dragged stops claiming either.
//
// That makes the counter load-bearing, and these tests are mostly about it
// being honest: it must move when a person actually moved a video, and it must
// not move when nothing happened.
//
// Plain `test`s rather than `testWidgets`, for the same reason the pool suite
// gives: VideoPlayerController.dispose() never completes inside the fake-async
// zone a testWidgets body runs in, so a suite written that way hangs on the
// first teardown.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/services/video_player_service.dart';

/// A platform that opens instantly and writes down every seek it is asked
/// for. Everything else is the minimum a VideoPlayerController needs.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, String> createdFor = {};

  /// Every seek that reached the platform, oldest first.
  final List<(int, Duration)> seeks = [];

  /// How long the fake's videos are. The clamp has to have something to
  /// clamp to.
  static const Duration clipLength = Duration(seconds: 10);

  /// When true, `createWithOptions` does NOT report the video as ready.
  /// Stands in for a player that has been asked for but has not opened its
  /// file yet — it has no length, so it has nowhere to seek to.
  bool holdInit = false;

  int _nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    // Single-subscription, not broadcast: `initialized` is emitted before
    // VideoPlayerController attaches its listener, and a broadcast
    // controller would drop it.
    _events[id] = StreamController<VideoEvent>();
    createdFor[id] = options.dataSource.uri ?? '';
    if (!holdInit) {
      _events[id]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(16, 9),
          duration: clipLength,
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    // Deliberately not closing the stream: the controller cancels its
    // subscription first, and awaiting close() on an already-cancelled
    // single-subscription controller never returns.
    _events.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double v) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add((playerId, position));
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlatform platform;
  final service = VideoPlayerService.instance;

  const reel = 'https://cdn.example/reel0.mp4';
  const other = 'https://cdn.example/reel1.mp4';

  Future<void> settle() => pumpEventQueue(times: 40);

  /// Open [u] and wait for it to be ready, the way the feed does.
  Future<void> open(String u) async {
    service.getController(u);
    await settle();
  }

  setUp(() async {
    platform = _FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    VideoPlayerService.deferRelease = (cb) => cb();
    VideoPlayerService.setPlayerAudio = (controller, {required enabled}) async {};
    await service.disposeAll();
    service.feedMuted.value = false;
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
  });

  group('moving a video by hand', () {
    test('lands where it was asked to', () async {
      await open(reel);

      await service.seekTo(reel, const Duration(seconds: 4));

      expect(platform.seeks.map((s) => s.$2), [const Duration(seconds: 4)]);
    });

    test('a drag off the right-hand end stops at the last frame', () async {
      // A finger that leaves the bar keeps reporting positions past its
      // edge. Refusing those would make the end of the video unreachable by
      // exactly the sloppy gesture people use to get there.
      await open(reel);

      await service.seekTo(reel, const Duration(minutes: 5));

      expect(platform.seeks.single.$2, _FakeVideoPlatform.clipLength,
          reason: 'asked for five minutes into a ten-second clip');
    });

    test('a drag off the left-hand end stops at the start', () async {
      await open(reel);

      await service.seekTo(reel, const Duration(seconds: -30));

      expect(platform.seeks.single.$2, Duration.zero);
    });

    test('moves the video the caller named, not the one on screen', () async {
      // On a battle the reel showing is not always the one the tile was
      // built around, so the bar says which video it means. Getting this
      // wrong scrubs the opponent's video while the challenger's plays.
      await open(reel);
      await open(other);
      service.pauseAllExcept(reel);
      await settle();

      await service.seekTo(other, const Duration(seconds: 3));

      final movedId = platform.seeks.single.$1;
      expect(platform.createdFor[movedId], other);
    });
  });

  group('the count the feed reads', () {
    // The feed only ever asks "has this changed since the reel came on
    // screen?". Anything that makes it change without a person having
    // dragged something costs a real completion signal; anything that fails
    // to make it change lets a dragged video claim a full watch.

    test('goes up once per move', () async {
      await open(reel);
      final before = service.seekCount;

      await service.seekTo(reel, const Duration(seconds: 2));
      await service.seekTo(reel, const Duration(seconds: 5));

      expect(service.seekCount, before + 2);
    });

    test('does not move for a reel that has no player', () async {
      // Nothing was dragged, because there is nothing to drag. If this
      // counted, the reel actually on screen would stop reporting that it
      // was watched to the end.
      final before = service.seekCount;

      await service.seekTo('https://cdn.example/never-opened.mp4',
          const Duration(seconds: 2));

      expect(service.seekCount, before);
      expect(platform.seeks, isEmpty);
    });

    test('does not move for a player that has not opened its file', () async {
      // A seek here has nowhere to land — the player has no length yet and
      // has not decided where it is starting. Sending it anyway races the
      // player's own opening position, and counting it would suppress a
      // signal for a video nobody touched.
      platform.holdInit = true;
      service.getController(reel);
      await settle();
      final before = service.seekCount;

      await service.seekTo(reel, const Duration(seconds: 2));

      expect(service.seekCount, before);
      expect(platform.seeks, isEmpty);
    });

    test('ordinary playback never touches it', () async {
      // The whole distinction rests on this. Starting, pausing and swapping
      // reels all move the playhead, and none of them is a person dragging
      // a bar.
      await open(reel);
      final before = service.seekCount;

      await service.showAndPlay(reel);
      await service.pauseActive();
      await service.resumeActive();
      await open(other);
      service.pauseAllExcept(other);
      await settle();

      expect(service.seekCount, before);
    });
  });
}
