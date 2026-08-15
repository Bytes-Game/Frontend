// Tests for "should this battle open its opponent's player yet?".
//
// Background: a profile run on a battle-heavy catalog showed audio being
// decoded and thrown away — `Qinput: 133, Render: 0, Drop: 124`. Prewarmed
// opponents are muted and paused, so every frame their audio decoder
// produces is discarded, and the old policy allocated one per battle the
// instant it became active. A user scrolling past a run of battles paid a
// video decoder and an audio decoder for each of them and flipped none.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_prewarm_policy.dart';

void main() {
  bool allow({
    bool isBattle = true,
    bool isActive = true,
    bool alreadyOpen = false,
    int maxPoolSize = 4,
  }) =>
      ReelPrewarmPolicy.shouldPrewarmOpponent(
        isBattle: isBattle,
        isActive: isActive,
        alreadyOpen: alreadyOpen,
        maxPoolSize: maxPoolSize,
      );

  group('shouldPrewarmOpponent', () {
    test('an active battle on a roomy pool prewarms', () {
      expect(allow(), isTrue);
    });

    test('a short is never a candidate', () {
      // Shorts carry one video. There is no second side to open, and
      // asking for one would read item.opponentVideoUrl — empty.
      expect(allow(isBattle: false), isFalse);
    });

    test('a battle the user is not on does not prewarm', () {
      // The whole point of the dwell delay: by the time it fires the tile
      // may no longer be the active reel, and re-asking must say no.
      expect(allow(isActive: false), isFalse);
    });

    test('an opponent already open is not opened twice', () {
      // Reached when the user flips before the dwell elapses —
      // _setShowOpponent builds the state itself.
      expect(allow(alreadyOpen: true), isFalse);
    });

    test('small pools keep create-on-flip', () {
      // A 2-slot pool holds the active reel and one read-ahead spare.
      // A third live decoder there is how the low-RAM tiers OOM.
      expect(allow(maxPoolSize: 2), isFalse);
      expect(allow(maxPoolSize: 3), isTrue);
    });
  });

  group('dwell', () {
    test('outlasts a fling but closes before anyone could flip', () {
      // Both bounds are load-bearing and they pull opposite ways.
      //
      // Floor: a fling passes a reel in 200-400ms. Below that the battles
      // in a fling start allocating a decoder pair again, which is the
      // entire failure this exists to stop — and zero is literally the
      // old behaviour.
      //
      // Ceiling: human reaction time. Nobody sees a battle arrive,
      // decides to flip, and gets a drag moving inside ~250ms plus the
      // gesture. Staying under that means the one case that costs
      // anything — a cube turn that starts on a poster because the
      // opponent is still opening — is not reachable by a real user.
      expect(ReelPrewarmPolicy.dwell.inMilliseconds, greaterThanOrEqualTo(400));
      expect(ReelPrewarmPolicy.dwell.inMilliseconds, lessThanOrEqualTo(600));
    });
  });
}
