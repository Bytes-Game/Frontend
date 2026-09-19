// How many videos the app keeps open, decided by the phone rather than by
// a number somebody typed in.
//
// ═══════════════════════════════════════════════════════════════════════
// THIS LOWERS DEMAND, NOT THE CAP — AND THAT DISTINCTION IS EVERYTHING
// ═══════════════════════════════════════════════════════════════════════
//
// VideoPlayerService.maxConcurrentDecoders carries the account of a release
// that lowered the POOL and changed nothing at all: the screen still asked
// for the same players, so the same number were alive AND one was thrown
// away on every swipe — "40 player opens and 37 retirements for 14 distinct
// videos", with the reclaims undiminished.
//
//     "Fewer live decoders has to come from asking for fewer players, not
//      from a cap underneath the demand."
//
// So what moves here is prefetchAhead and prefetchBack, which decide
// whether a NEIGHBOUR is given a player at all. A phone that cannot afford
// a warm video above and below stops being offered one, instead of being
// given one and having it taken away again.
//
// Worth stating plainly: both phones measured so far answer 15 and 16, so
// on both of them every test below describes a no-op. This is for the
// phones nobody has held yet.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/decoder_budget.dart';
import 'package:myapp/services/device_capabilities.dart';
import 'package:myapp/services/video_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const full = VideoPoolConfig.onScreenWorkingSet;

  group('what the phone can afford', () {
    test('a phone with plenty is left completely alone', () {
      for (final budget in [8, 12, 15, 16, 32]) {
        expect(VideoPoolConfig.workingSetFor(budget), full,
            reason: 'a budget of $budget made the app ask for less than the '
                'screen needs, for no reason');
      }
    });

    test('a phone with few is asked for less', () {
      // budget minus what the rest of the app needs: one for the search
      // grid's preview, two for players still shutting down, one margin.
      expect(VideoPoolConfig.workingSetFor(6), 2);
      expect(VideoPoolConfig.workingSetFor(7), 3);
    });

    test('a phone with almost none still gets the video on screen', () {
      // Zero players is not an option: something has to play.
      for (final budget in [1, 2, 3, 4]) {
        expect(VideoPoolConfig.workingSetFor(budget), 1,
            reason: 'budget $budget left the app unable to play anything');
      }
    });

    test('never more than the screen needs, however generous the phone', () {
      expect(VideoPoolConfig.workingSetFor(64), full,
          reason: 'a fifth warm video is not on screen and not one gesture '
              'away, so it buys nothing anybody can see');
    });

    test('it only ever goes down, never up', () {
      for (var budget = 1; budget <= 64; budget++) {
        expect(VideoPoolConfig.workingSetFor(budget),
            lessThanOrEqualTo(full),
            reason: 'budget $budget made the app greedier than before');
      }
    });

    test('and never skips a step as the budget grows', () {
      var last = 0;
      for (var budget = 1; budget <= 32; budget++) {
        final w = VideoPoolConfig.workingSetFor(budget);
        expect(w, greaterThanOrEqualTo(last),
            reason: 'a BIGGER budget of $budget asked for FEWER players');
        last = w;
      }
    });
  });

  group('a phone that will not say', () {
    test('behaves exactly as it did before any of this existed', () {
      expect(VideoPoolConfig.workingSetFor(null), full);
    });

    test('and so does a nonsense answer', () {
      // Some devices report 0 for a codec they will not really run.
      expect(VideoPoolConfig.workingSetFor(0), full);
      expect(VideoPoolConfig.workingSetFor(-3), full);
    });
  });

  group('what actually changes in the config', () {
    test('a small budget stops the neighbours being asked for', () {
      // The lever that matters. prefetchAhead/Back is what decides whether
      // the video above and below get a player AT ALL — lowering the pool
      // alone would leave them still being built and then thrown away.
      final tight = VideoPoolConfig.forRam(8, decoderBudget: 5);
      expect(tight.maxPoolSize, 1);
      expect(tight.prefetchAhead, 0);
      expect(tight.prefetchBack, 0);
      expect(tight.prefetchAheadBurst, 0,
          reason: 'a fast scroll would still open a burst of players on a '
              'phone that cannot hold them');
    });

    test('a roomy budget leaves a big phone exactly as it was', () {
      final measured = VideoPoolConfig.forRam(8, decoderBudget: 16);
      final unmeasured = VideoPoolConfig.forRam(8);
      expect(measured.maxPoolSize, unmeasured.maxPoolSize);
      expect(measured.prefetchAhead, unmeasured.prefetchAhead);
      expect(measured.prefetchBack, unmeasured.prefetchBack);
      expect(measured.prefetchAheadBurst, unmeasured.prefetchAheadBurst);
    });

    test('a small phone is not made BIGGER by a generous budget', () {
      // RAM still sets the floor. A 1.5 GB phone with a generous decoder
      // does not get to hold five players — it would be killed for memory
      // long before it ran out of decoders.
      final small = VideoPoolConfig.forRam(1.5, decoderBudget: 32);
      expect(small.maxPoolSize, 2);
    });

    test('the pool never ends up below one', () {
      for (var budget = 1; budget <= 8; budget++) {
        final cfg = VideoPoolConfig.forRam(8, decoderBudget: budget);
        expect(cfg.maxPoolSize, greaterThanOrEqualTo(1),
            reason: 'budget $budget left a pool that cannot hold the video '
                'being watched');
      }
    });

    test('spares never exceed the pool that has to hold them', () {
      for (var budget = 1; budget <= 20; budget++) {
        final cfg = VideoPoolConfig.forRam(8, decoderBudget: budget);
        expect(cfg.prefetchAhead, lessThan(cfg.maxPoolSize + 1));
        expect(cfg.prefetchBack, lessThan(cfg.maxPoolSize + 1));
        expect(cfg.prefetchAheadBurst, lessThan(cfg.maxPoolSize + 1),
            reason: 'budget $budget asks for more warm videos than there is '
                'room to keep');
      }
    });
  });

  group('the reserve is what the rest of the app measured', () {
    test('it covers the grid preview, the shutdown queue and a margin', () {
      // 1 + 2 + 1. Each of the first two is a measured peak from a device
      // log, not a guess: `previews peak=1`, `shutting down peak=2`.
      expect(VideoPoolConfig.decoderReserve, 4);
    });

    test('and the ladder follows it', () {
      // If the reserve ever changes, these move with it rather than going
      // quietly stale.
      const r = VideoPoolConfig.decoderReserve;
      expect(VideoPoolConfig.workingSetFor(r + 1), 1);
      expect(VideoPoolConfig.workingSetFor(r + 2), 2);
      expect(VideoPoolConfig.workingSetFor(r + full), full);
    });
  });

  _startupUsesTheReadingTests();
}

// Reading the number and USING it are two different things, and only one of
// them is worth anything. Every test above works on VideoPoolConfig by hand;
// none of them would notice if the app at startup asked the chip, wrote the
// answer to the log, and then sized itself as though it had never asked.
//
// That is not hypothetical. This is the second time the same gap has shown
// up here: the reading itself shipped with a probe method nothing called.
void _startupUsesTheReadingTests() {
  group('startup actually sizes the app by the reading', () {
    setUp(() {
      DecoderBudget.instance.debugReset();
      DeviceCapabilities.instance.debugResetProbe();
      DecoderBudget.canAsk = () => true;
    });

    tearDown(() {
      DecoderBudget.instance.debugReset();
      DecoderBudget.canAsk = () => false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), null);
      // Put the app back to the config it starts life with, or the next
      // test in this file inherits a one-player phone.
      VideoPlayerService.instance.configure(VideoPoolConfig.fallback);
    });

    void phoneAnswers(Map<String, int> decoders) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('devf/device_media'), (call) async {
        return decoders;
      });
    }

    test('a phone that says it has few gets asked for few', () async {
      // Five decoders: four are spoken for by the rest of the app, so the
      // feed gets one — the video being watched, and no warm neighbours.
      phoneAnswers({'c2.mtk.avc.decoder': 5});

      await DeviceCapabilities.instance.probe();

      final cfg = VideoPlayerService.instance.config;
      expect(cfg.maxPoolSize, 1,
          reason: 'the chip was asked, the answer was written to the log, '
              'and then the app sized itself as though it had never asked');
      expect(cfg.prefetchAhead, 0);
      expect(cfg.prefetchAheadBurst, 0);
      expect(cfg.prefetchBack, 0,
          reason: 'warming a neighbour is the demand that has to come down; '
              'a smaller pool on its own only recycles players faster');
    });

    test('a phone with room to spare is left exactly as RAM had it', () async {
      phoneAnswers({'c2.mtk.avc.decoder': 16});

      await DeviceCapabilities.instance.probe();

      final cfg = VideoPlayerService.instance.config;
      final byRamAlone =
          VideoPoolConfig.forRam(DeviceCapabilities.instance.ramGb);
      expect(cfg.maxPoolSize, byRamAlone.maxPoolSize,
          reason: 'both phones measured so far answer 15 and 16, so this is '
              'the case that has to stay a no-op');
      expect(cfg.prefetchAhead, byRamAlone.prefetchAhead);
      expect(cfg.prefetchAheadBurst, byRamAlone.prefetchAheadBurst);
      expect(cfg.prefetchBack, byRamAlone.prefetchBack);
    });

    test('a phone that will not answer keeps what it had before', () async {
      // Only the software fallback, which reports a generous number it
      // cannot really deliver. That is not an opinion about the chip.
      phoneAnswers({'c2.android.avc.decoder': 32});

      await DeviceCapabilities.instance.probe();

      final cfg = VideoPlayerService.instance.config;
      final byRamAlone =
          VideoPoolConfig.forRam(DeviceCapabilities.instance.ramGb);
      expect(cfg.maxPoolSize, byRamAlone.maxPoolSize);
      expect(cfg.prefetchAhead, byRamAlone.prefetchAhead);
    });
  });
}
