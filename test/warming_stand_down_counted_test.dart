// Did the app ever notice the video on screen running dry?
//
// ═══════════════════════════════════════════════════════════════════════
// WHY THIS COUNTER EXISTS
// ═══════════════════════════════════════════════════════════════════════
//
// A 107,000-line device log showed the decoder being fed LATE 261 times —
// median a full second, worst seventeen seconds. That is the viewer's
// video sitting there with nothing to show.
//
// The app has a defence. When the player reports it is buffering, every
// background download pauses so the bandwidth goes to the reel being
// watched. It is wired up and it has tests.
//
// None of which answers the only question that matters: DID IT FIRE? The
// log could not say, because nothing counted it. "It is wired up, with
// tests" is not the same as "it happened" — and this repo has already been
// caught by that exact gap three times.
//
// So it is counted, and printed even when the answer is zero. Zero is the
// answer that matters most: it would mean the decoder starved for a second
// at a time and the app never noticed, which points the next round at the
// DETECTION rather than at the defence.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';

import 'support/dart_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final d = ReelDiagnostics.instance;

  setUp(d.debugReset);
  tearDown(d.debugReset);

  String summary() {
    d.recordProxiedStart();
    return d.summary();
  }

  group('counting the stand-downs', () {
    test('none is still reported, out loud', () {
      // The whole point. An absent line reads as "no answer"; n=0 is an
      // answer, and it is the one that would redirect the next round.
      expect(summary(), contains('warming stood down n=0'),
          reason: 'a session where the defence never fired looks identical '
              'to one where it was never measured');
    });

    test('each hold is counted once', () {
      d.recordWarmingHeld();
      d.recordWarmingReleased();
      d.recordWarmingHeld();
      d.recordWarmingReleased();
      expect(d.debugWarmingHolds, 2);
      expect(summary(), contains('warming stood down n=2'));
    });

    test('a repeated hold is not a second hold', () {
      // holdWarming() returns early when already held, so the counter must
      // agree with it — otherwise a listener firing on every value tick
      // would report hundreds of stand-downs that never happened.
      d.recordWarmingHeld();
      d.recordWarmingHeld();
      d.recordWarmingHeld();
      expect(d.debugWarmingHolds, 1);
    });

    test('a release without a hold counts nothing', () {
      d.recordWarmingReleased();
      d.recordWarmingReleased();
      expect(d.debugWarmingHolds, 0);
      expect(summary(), contains('warming stood down n=0'));
    });

    test('and holding again after a release does count', () {
      d.recordWarmingHeld();
      d.recordWarmingReleased();
      d.recordWarmingHeld();
      expect(d.debugWarmingHolds, 2);
    });
  });

  group('how long it stood down for', () {
    test('a hold still in progress is already counted', () async {
      // A hold that never ends is the worst case there is — every download
      // paused for the rest of the session. Waiting for a release before
      // counting the time would report that disaster as 0.0s.
      d.recordWarmingHeld();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(summary(), contains('warming stood down n=1 for 0.1s'),
          reason: 'a stand-down that never lifts reads as no time at all');
    });

    test('time is added up across holds', () async {
      d.recordWarmingHeld();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      d.recordWarmingReleased();
      d.recordWarmingHeld();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      d.recordWarmingReleased();

      final line = summary();
      expect(line, contains('n=2'));
      expect(line, contains(RegExp(r'for 0\.[23]s')),
          reason: 'only the last hold was counted, so a session full of '
              'short stalls reads as one short stall: $line');
    });

    test('no holds prints no duration', () {
      expect(summary(), contains('warming stood down n=0'));
      expect(summary(), isNot(contains('n=0 for')),
          reason: 'a meaningless "for 0.0s" on every line nobody needs');
    });
  });

  test('a reset clears it', () {
    d.recordWarmingHeld();
    d.debugReset();
    expect(d.debugWarmingHolds, 0);
    expect(summary(), contains('warming stood down n=0'),
        reason: 'a hold left open across a reset keeps counting time from '
            'a test that finished long ago');
  });

  // ─────────────────────────────────────────────────────────────────────
  // And the counter has to be CALLED.
  //
  // A counter nothing increments reports n=0 for ever, which is the exact
  // reading that would send the next round chasing the detection instead
  // of the defence. The wire matters more than the counter.
  //
  // This repo has now been caught by "it exists but nothing calls it"
  // three times: a decoder reading with no caller, a measured budget the
  // startup never passed on, and a link meter fed by nothing. Each was
  // found by a mutation that cut the wire while every test stayed green,
  // because every test was calling the far end by hand — exactly as the
  // tests above do.
  // ─────────────────────────────────────────────────────────────────────
  group('the cache actually reports its stand-downs', () {
    final src = File('lib/services/video_cache_service.dart').readAsStringSync();

    test('holding reports it', () {
      expect(src, contains('ReelDiagnostics.instance.recordWarmingHeld()'),
          reason: 'downloads stand down and nothing records it, so the log '
              'says n=0 whether the defence fired or not');
    });

    test('releasing reports it', () {
      expect(src, contains('ReelDiagnostics.instance.recordWarmingReleased()'),
          reason: 'every hold looks like it is still running, so the time '
              'climbs for the rest of the session');
    });

    test('and both sit AFTER the early return, not before', () {
      // holdWarming() returns early when already held. Reporting above
      // that line would count a stand-down on every value tick of the
      // player — hundreds of them, none real.
      final hold = bodyOf(src, 'void holdWarming()');
      expect(hold.indexOf('if (_held) return;'),
          lessThan(hold.indexOf('recordWarmingHeld()')),
          reason: 'a hold is counted on every tick while already held');

      final release = bodyOf(src, 'void releaseWarming()');
      expect(release.indexOf('if (!_held) return;'),
          lessThan(release.indexOf('recordWarmingReleased()')));
    });
  });
}
