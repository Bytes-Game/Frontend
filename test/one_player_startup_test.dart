// EXPERIMENT BRANCH. Two questions that cannot be asked in the same file
// as everything else, and both of which a whole branch hangs on.
//
// ═══════════════════════════════════════════════════════════════════════
// WHY THIS IS ITS OWN FILE
// ═══════════════════════════════════════════════════════════════════════
//
// VideoPlayerService is a singleton and its config is replaced by the
// first test that calls configure(). So "what does the app hold before
// anything has configured it" can only be asked in a file where nothing
// has. Each test file is its own isolate, so this one is that file, and it
// must stay small — anything added here that calls configure() silently
// turns the check below into a check of nothing.
//
// The other question is even simpler and was missed for the same reason:
// every other test resets the flag to ON in setUp, so not one of them
// would notice the branch shipping with the experiment switched OFF. The
// entire branch would then be a no-op and the whole suite would still be
// green.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_player_mode.dart';
import 'package:myapp/services/video_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the app holds one video from the very first frame', () {
    // Before any probe, before any configure. This window IS app start —
    // the moment the first reel is opening and the phone is busiest. The
    // pooled default here would open spares for a few hundred
    // milliseconds and close them again, which is precisely the cost this
    // branch exists to measure.
    //
    // KEEP THIS FIRST. Anything above it that calls configure() replaces
    // the value being asserted and this stops checking anything.
    final cfg = VideoPlayerService.instance.config;
    expect(cfg.maxPoolSize, 1,
        reason: 'the service starts on the pooled fallback, so the '
            'experiment does not begin until the device probe lands');
    expect(cfg.prefetchAhead, 0);
    expect(cfg.prefetchAheadBurst, 0);
    expect(cfg.prefetchBack, 0);
  });

  test('and this branch ships with the experiment switched ON', () {
    // Read from the source, not from the running value, because every
    // other test in the suite sets the flag in setUp — so the SHIPPED
    // default is the one thing none of them can see. A branch that ships
    // it off is a branch that changes nothing while every test passes.
    final src =
        File('lib/services/reel_player_mode.dart').readAsStringSync();
    expect(src, contains('static bool onePlayer = true;'),
        reason: 'the whole branch is a no-op, and the suite is green');
    // Sanity: the running value agrees, and nothing above flipped it.
    expect(ReelPlayerMode.onePlayer, isTrue);
  });
}
