// The phone that really IS short of video decoders.
//
// ═══════════════════════════════════════════════════════════════════════
// NOT THE EXPERIMENT. THE EXPERIMENT IS GONE.
// ═══════════════════════════════════════════════════════════════════════
//
// Holding a single player on EVERY phone was tried and measured, and it
// cost 252ms on every swipe to relieve decoder pressure that the measured
// phones did not have — fifteen decoders available, four needed. It was
// removed.
//
// What stays is the case it was always really for: a phone whose chip says
// it will only run a handful of decoders at once. VideoPoolConfig's
// working set drops such a phone to a single player automatically, and
// everything below describes what has to hold when it does.
//
// These three fixes came in with the experiment and are the only parts
// worth keeping, because each is a real fault on that phone rather than a
// consequence of the policy:
//
//   1. a pool of one must not ask for a spare it can never hold;
//   2. a cached opponent whose player was evicted must not be handed back;
//   3. flipping back to the challenger must re-open it, not give up.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_player_service.dart';

import 'support/dart_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a chip with few decoders still drops to one player', () {
    test('the ladder is unchanged by the experiment being removed', () {
      // The automatic path, which is the version worth having.
      expect(VideoPoolConfig.workingSetFor(5), 1);
      expect(VideoPoolConfig.workingSetFor(6), 2);
      expect(VideoPoolConfig.workingSetFor(15), 4,
          reason: 'the phone in the logs has fifteen and must keep its '
              'warm neighbours — that is the whole reason for the rollback');
    });

    test('and no phone is forced to one any more', () {
      for (final ramGb in <double>[1.5, 4, 8, 12]) {
        expect(VideoPoolConfig.forRam(ramGb).maxPoolSize, greaterThan(1),
            reason: 'a ${ramGb}GB phone is still being held to one player, '
                'which is the thing that was measured and removed');
      }
    });
  });

  group('a pool of one asks for no spare', () {
    test('because it could never hold one', () async {
      // _openSpare would have to evict to make room, the only entry is the
      // reel being watched, and eviction refuses to touch that. So the ask
      // is a decision taken every swipe that cannot succeed.
      final service = VideoPlayerService.instance;
      await service.disposeAll();

      service.configure(const VideoPoolConfig(
        maxPoolSize: 1,
        prefetchAhead: 0,
        prefetchAheadBurst: 0,
        prefetchBack: 0,
      ));
      service.prefetch(const ['a.mp4', 'b.mp4'],
          live: const [(SpareLane.nextReel, 'a.mp4')]);
      expect(service.debugWantedSpares, isEmpty);

      await service.disposeAll();
    });

    test('a pool with room still does', () async {
      final service = VideoPlayerService.instance;
      await service.disposeAll();
      service.configure(VideoPoolConfig.fallback);
      service.prefetch(const ['a.mp4', 'b.mp4'],
          live: const [(SpareLane.nextReel, 'a.mp4')]);
      expect(service.debugWantedSpares, {'a.mp4'},
          reason: 'the rollback is pointless if the pooled phone stopped '
              'keeping anything warm');
      await service.disposeAll();
    });

    test('a pool of TWO is not a pool of one', () async {
      // The off-by-one in the other direction, and it is not harmless: a
      // 2 GB phone holds two players, which is the reel on screen plus one
      // warm neighbour. Refusing the spare there takes the warmth away
      // from the phones that can least afford to rebuild on every swipe.
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
      expect(service.debugWantedSpares, {'a.mp4'},
          reason: 'a phone with room for one warm neighbour was refused it');
      await service.disposeAll();
    });

    test('an empty list is not a way to ask for nothing', () {
      // Why the check above lives where it does. Handing prefetch an empty
      // `live` list reads as "the caller has not thought about it", and it
      // picks the nearest url anyway.
      final targets = VideoPlayerService.spareTargets(
        const ['a.mp4', 'b.mp4'],
        const [],
      );
      expect(targets.keys, ['a.mp4']);
    });
  });

  group('the battle flip on a single-player phone', () {
    final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

    test('a cached opponent is checked before it is handed back', () {
      // Flipping back closes the opponent, so the cached state points at a
      // player that is gone. Handing that to VideoPlayer throws from
      // inside build and replaces the reel with an error box.
      final body = bodyOf(src, '_ReelPlayerState _ensureOpponentState()');
      expect(body, contains('VideoPlayerService.instance.isLive('),
          reason: 'the second flip hands over a disposed player');
    });

    test('flipping back re-opens the challenger instead of giving up', () {
      final body = bodyOf(src, 'Future<void> _startSide(bool show) async');
      final ask = body.indexOf('widget.onNeedPlayer()');
      final bail = body.indexOf('if (incoming == null) return;');
      expect(ask, greaterThan(-1),
          reason: 'coming back to the challenger finds no player and gives '
              'up, leaving a frozen picture with no way out but a swipe');
      expect(ask, lessThan(bail),
          reason: 'the give-up runs first, so the re-open is unreachable');
    });

    test('and only ever for the reel on screen', () {
      final body = bodyOf(src, 'void _reopenPlayer(int index)');
      expect(body, contains('index != _currentIndex'),
          reason: 'any tile could ask for a player, which is the fling '
              'decoder storm this feed spent releases removing');
      expect(body, contains('_playerStates.remove(index)'));
    });
  });

  group('nothing of the experiment is left', () {
    test('the flag and its file are gone', () {
      expect(File('lib/services/reel_player_mode.dart').existsSync(), isFalse,
          reason: 'the one-player switch is still in the tree');
      final pool =
          File('lib/services/video_player_service.dart').readAsStringSync();
      expect(pool, isNot(contains('ReelPlayerMode')));
      expect(pool, isNot(contains('onlyTheOneOnScreen')));
      final feed =
          File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
      expect(feed, isNot(contains('ReelPlayerMode')),
          reason: 'the feed still checks a flag that no longer exists');
    });
  });
}
