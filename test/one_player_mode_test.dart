// EXPERIMENT BRANCH. One open video at a time.
//
// ═══════════════════════════════════════════════════════════════════════
// WHAT THIS IS TRYING TO FIND OUT
// ═══════════════════════════════════════════════════════════════════════
//
// The feed on main keeps the reel on screen open AND one warm spare for
// the next swipe, and during a battle turn the opponent as well. Each open
// video costs a hardware decoder, and on the cheap phones the logs keep
// coming from, decoders fighting each other is what sticking looks like.
//
// So: hold one. The next reel's picture is a still until the user arrives
// at it, and then its player is built — against bytes that are already on
// the phone, because the downloading-ahead is untouched.
//
// ═══════════════════════════════════════════════════════════════════════
// THE TRAP THIS FILE EXISTS TO CATCH
// ═══════════════════════════════════════════════════════════════════════
//
// The obvious way to stop the feed asking for a warm spare is to hand
// VideoPlayerService.prefetch an EMPTY list of urls-that-get-a-player.
// That does nothing. spareTargets reads an empty list as "the caller has
// not thought about it" and falls back to the nearest url in the window —
// so the spare opens anyway, and the experiment reads as switched on while
// changing nothing at all. That is asserted below, on purpose, because it
// is the kind of thing that only shows up as a device log that looks
// exactly like the one before it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/reel_player_mode.dart';
import 'package:myapp/services/video_player_service.dart';

import 'support/dart_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ReelPlayerMode.reset);
  tearDown(ReelPlayerMode.reset);

  group('how many videos stay open', () {
    test('one, on every phone, whatever its memory', () {
      for (final ramGb in <double>[1.5, 2.5, 4, 6, 12, 24]) {
        final cfg = VideoPoolConfig.forRam(ramGb);
        expect(cfg.maxPoolSize, 1,
            reason: '${ramGb}GB phone kept more than the video on screen');
        expect(cfg.prefetchAhead, 0);
        expect(cfg.prefetchAheadBurst, 0);
        expect(cfg.prefetchBack, 0);
      }
    });

    test('and a roomy decoder does not talk it back up', () {
      // The whole point is to find out what ONE feels like on a phone that
      // could afford more. Sizing by the chip here would make every phone
      // a different experiment.
      final cfg = VideoPoolConfig.forRam(12, decoderBudget: 32);
      expect(cfg.maxPoolSize, 1);
      expect(cfg.prefetchAhead, 0);
    });

    test('the app starts that way too, before it has measured anything',
        () {
      // The window before the device probe lands is app start, which is
      // when the first reel is opening. Starting pooled there would open
      // spares for a few hundred milliseconds and close them again.
      expect(VideoPoolConfig.onlyTheOneOnScreen.maxPoolSize, 1);
      expect(VideoPoolConfig.onlyTheOneOnScreen.prefetchAhead, 0);
      expect(VideoPoolConfig.onlyTheOneOnScreen.prefetchAheadBurst, 0);
      expect(VideoPoolConfig.onlyTheOneOnScreen.prefetchBack, 0);
    });
  });

  group('turning it off puts everything back', () {
    test('the pooled sizes return, untouched', () {
      ReelPlayerMode.onePlayer = false;
      final low = VideoPoolConfig.forRam(1.5);
      expect(low.maxPoolSize, 2);
      expect(low.prefetchAhead, 1);

      final big = VideoPoolConfig.forRam(8);
      expect(big.maxPoolSize, VideoPoolConfig.maxConcurrentDecoders);
      expect(big.prefetchAhead, greaterThan(0),
          reason: 'the rollback has to be a real rollback, or there is '
              'nothing to compare the experiment against');
    });

    test('and the decoder budget still sizes them', () {
      ReelPlayerMode.onePlayer = false;
      expect(VideoPoolConfig.forRam(8, decoderBudget: 6).maxPoolSize, 2);
      expect(VideoPoolConfig.forRam(8, decoderBudget: 16).maxPoolSize,
          VideoPoolConfig.maxConcurrentDecoders);
    });
  });

  group('an empty list is not a way to ask for no spare', () {
    // Read the file header. This is the mistake the flag would otherwise
    // have made silently.
    test('it means "I have not thought about it", and picks one anyway', () {
      final targets = VideoPlayerService.spareTargets(
        const ['a.mp4', 'b.mp4', 'c.mp4'],
        const [],
      );
      expect(targets.keys, ['a.mp4'],
          reason: 'if this ever becomes empty, the guard in prefetch can '
              'go — but until then, passing [] opens a spare');
    });

    test('so the pool size is what actually decides it', () async {
      final service = VideoPlayerService.instance;
      await service.disposeAll();

      service.configure(VideoPoolConfig.onlyTheOneOnScreen);
      service.prefetch(const ['a.mp4', 'b.mp4'],
          live: const [(SpareLane.nextReel, 'a.mp4')]);
      expect(service.debugWantedSpares, isEmpty,
          reason: 'a pool that holds one holds the reel on screen; asking '
              'for a spare is a decision taken every swipe that cannot '
              'succeed');

      service.configure(const VideoPoolConfig(
        maxPoolSize: 4,
        prefetchAhead: 2,
        prefetchAheadBurst: 3,
        prefetchBack: 1,
      ));
      service.prefetch(const ['a.mp4', 'b.mp4'],
          live: const [(SpareLane.nextReel, 'a.mp4')]);
      expect(service.debugWantedSpares, {'a.mp4'},
          reason: 'with room for one, the feed is allowed to ask again');

      await service.disposeAll();
    });

    test('a pool of two is not a pool of one', () async {
      // The guard is `<= 1`, and the off-by-one in the other direction
      // would quietly switch the experiment on for a small phone that was
      // only ever meant to hold two.
      final service = VideoPlayerService.instance;
      await service.disposeAll();
      service.configure(const VideoPoolConfig(
        maxPoolSize: 2,
        prefetchAhead: 1,
        prefetchAheadBurst: 1,
        prefetchBack: 0,
      ));
      service.prefetch(const ['a.mp4', 'b.mp4'],
          live: const [(SpareLane.nextReel, 'a.mp4')]);
      expect(service.debugWantedSpares, {'a.mp4'});
      await service.disposeAll();
    });
  });

  group('the bytes still come down ahead of time', () {
    test('the warm window is not the player pool, and is left alone', () {
      // This is the part people mean by "TikTok does not preload". It
      // does. What it does not do is hold decoders open. Warming is
      // VideoCacheService's depth, which no part of this experiment
      // touches — so if this ever starts reading from the pool config,
      // the experiment has changed into a different one.
      final src =
          // ignore: avoid_slow_async_io
          File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
      expect(src, contains('VideoCacheService.instance.prefetchDepth'),
          reason: 'the forward warm window must stay the cache\'s, not the '
              'pool\'s — a pool of one would otherwise shrink it to zero '
              'and turn "one player" into "no preloading", which is a '
              'different experiment with a different answer');
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // The battle flip.
  //
  // A battle is two videos on the two faces of a turning cube. On main
  // BOTH faces are live video during the turn, which is two decoders. One
  // player cannot do that, so the face going away shows its cover picture
  // instead — which the cube already paints underneath every face, so
  // nothing new had to be drawn.
  //
  // Three things had to change for that not to break, and all three are
  // the kind that look fine until somebody flips twice on a real phone.
  // ───────────────────────────────────────────────────────────────────
  group('flipping a battle, with only one player to do it with', () {
    final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

    test('the opponent does not open on the first dragged frame', () {
      // On main it opens as soon as a finger moves, so both faces are
      // live for the turn. Here that would close the challenger — the
      // pool holds one — and the user is still WATCHING the challenger:
      // the face under their thumb would drop to a still the instant they
      // moved, and come back if they changed their mind.
      final body = bodyOf(src, 'void _onHorizontalDragStart(');
      expect(body, contains('if (!ReelPlayerMode.onePlayer)'),
          reason: 'the opponent opens on the drag, which shuts the video '
              'the user is currently looking at');
    });

    test('flipping back re-opens the challenger', () {
      // THE one that bites. Opening the opponent closed the challenger,
      // so on the way back widget.state points at a player that is gone,
      // and the old code returned early on exactly that condition —
      // leaving the user on a still picture with no way out but a swipe.
      final body = bodyOf(src, 'Future<void> _startSide(bool show) async');
      expect(body, contains('widget.onNeedPlayer()'),
          reason: 'coming back to the challenger finds no player and gives '
              'up, so the reel stays a frozen picture');
      final ask = body.indexOf('widget.onNeedPlayer()');
      final bail = body.indexOf('if (incoming == null) return;');
      expect(ask, greaterThan(-1));
      expect(bail, greaterThan(-1));
      expect(ask, lessThan(bail),
          reason: 'the give-up runs first, so the re-open is unreachable');
    });

    test('and only ever for the reel on screen', () {
      // An off-screen tile asking for a player is the fast-scroll decoder
      // storm this feed spent several releases removing.
      final body = bodyOf(src, 'void _reopenPlayer(int index)');
      expect(body, contains('index != _currentIndex'),
          reason: 'any tile could ask for a player, which is the thing '
              'that made a fling open one per reel flown past');
      expect(body, contains('_playerStates.remove(index)'),
          reason: 'without dropping the dead entry first the stale one '
              'comes straight back');
    });

    test('a second flip does not hand over a dead opponent', () {
      // _opponentState is cached on the tile. Flipping back closed it, so
      // the cached one points at a disposed player; handing that to
      // VideoPlayer throws "Bad state: No active player with ID n" from
      // inside build, which replaces the reel with an error box.
      final body = bodyOf(src, '_ReelPlayerState _ensureOpponentState()');
      expect(body, contains('VideoPlayerService.instance.isLive('),
          reason: 'the cached opponent is reused on the second flip '
              'without checking it still exists');
    });
  });
}
