// A run arrived with ONE video played and not a single summary line in it.
//
// ═══════════════════════════════════════════════════════════════════════
// WHAT WENT WRONG, AND WHY IT IS A BUG AND NOT BAD LUCK
// ═══════════════════════════════════════════════════════════════════════
//
// The summary printed only after TEN videos had started. The run captured
// one. So every counter in ReelDiagnostics — the whole point of the class
// — died unread, and the session could not be compared with anything.
//
// A measurement you only get when the session ends tidily is a measurement
// you do not have, because the sessions worth measuring are exactly the
// ones that end badly: killed for memory, closed by the phone's power
// manager, or stopped early because something already looked wrong.
//
// Two ways out, and BOTH are needed because they cover different endings:
//
//   * going to the background — an orderly exit, which gives a callback;
//   * a timer — a kill gives NO callback at all, so the only numbers that
//     survive one are the ones already written down before it happened.
//
// Gated on something having changed, or an app sitting idle prints the
// same line forever and buries the one worth reading.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    ReelDiagnostics.instance.debugReset();
    // A few milliseconds instead of twenty seconds. Every wait below is
    // many times this, so a slow machine changes nothing.
    ReelDiagnostics.heartbeatInterval = const Duration(milliseconds: 20);
    printed = [];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
  });

  tearDown(() {
    debugPrint = original;
    ReelDiagnostics.instance.debugReset();
    ReelDiagnostics.heartbeatInterval = const Duration(seconds: 20);
  });

  List<String> summaries() =>
      printed.where((l) => l.contains('starts=')).toList();

  group('a session that ends early still says what happened', () {
    test('one video played, then the app goes away', () {
      // The exact shape of the run that started all this.
      ReelDiagnostics.instance.recordProxiedStart();
      expect(summaries(), isEmpty, reason: 'nothing due yet, which is fine');

      ReelDiagnostics.instance.noteGoingToBackground();

      expect(summaries(), hasLength(1),
          reason: 'one video played and the app closed, and the numbers '
              'went with it — which is the whole failure');
      expect(summaries().single, contains('starts=1'));
    });

    test('nothing played, nothing printed', () {
      // An app opened and closed without reaching the feed has nothing to
      // say, and saying it anyway is noise in every log from then on.
      ReelDiagnostics.instance.noteGoingToBackground();
      expect(summaries(), isEmpty);
    });

    test('backgrounding twice does not repeat itself', () {
      ReelDiagnostics.instance.recordProxiedStart();
      ReelDiagnostics.instance.noteGoingToBackground();
      ReelDiagnostics.instance.noteGoingToBackground();
      expect(summaries(), hasLength(1),
          reason: 'a phone that pauses and resumes a few times would fill '
              'the log with identical lines');
    });

    test('and says the new numbers after more videos play', () {
      ReelDiagnostics.instance.recordProxiedStart();
      ReelDiagnostics.instance.noteGoingToBackground();
      ReelDiagnostics.instance.recordProxiedStart();
      ReelDiagnostics.instance.noteGoingToBackground();
      expect(summaries(), hasLength(2));
      expect(summaries().last, contains('starts=2'),
          reason: 'the second one has to carry the newer count, or the '
              'gate is suppressing real news');
    });
  });

  group('a session that is killed leaves a trail behind it', () {
    test('the numbers get written down while the app is still alive',
        () async {
      // A kill gives no callback, so nothing can be saved AT the kill. The
      // only defence is having already written it down before it happened.
      ReelDiagnostics.instance.recordProxiedStart();
      expect(summaries(), isEmpty, reason: 'nothing due yet');

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(summaries(), isNotEmpty,
          reason: 'a session killed part-way through leaves nothing behind '
              'at all, which is the failure this exists to stop');
      expect(summaries().first, contains('starts=1'));
    });

    test('an idle app stays quiet', () async {
      ReelDiagnostics.instance.recordProxiedStart();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final afterFirst = summaries().length;
      expect(afterFirst, 1);

      // Nobody is watching anything now, but the timer keeps ticking —
      // many more times than it took to produce that first line.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(summaries(), hasLength(afterFirst),
          reason: 'an app left open on a profile page repeats the same line '
              'for ever and buries the one worth reading');
    });

    test('one timer for the whole session, not one per video', () {
      // A LEAKED TIMER HERE IS INVISIBLE IN BEHAVIOUR, which is exactly why
      // it is counted rather than inferred.
      //
      // If every video started its own, twenty videos leave twenty ticking.
      // They all fire together — and the first clears the "something
      // changed" flag, so the other nineteen find nothing to say and stay
      // quiet. The log looks perfect while the app carries twenty timers it
      // will never stop. Asserting on the OUTPUT would pass either way.
      for (var i = 0; i < 20; i++) {
        ReelDiagnostics.instance.recordProxiedStart();
      }
      expect(ReelDiagnostics.instance.debugHeartbeatStarts, 1,
          reason: 'a timer started per video played, none of them stopped');
    });

    test('and starts talking again when watching resumes', () async {
      ReelDiagnostics.instance.recordProxiedStart();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(summaries(), hasLength(1));

      ReelDiagnostics.instance.recordProxiedStart();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(summaries(), hasLength(2),
          reason: 'the quiet gate latched on and the log stayed silent for '
              'the rest of the session');
      expect(summaries().last, contains('starts=2'));
    });
  });

  test('the ten-video summary still works', () {
    // The original trigger is not replaced, only backed up.
    for (var i = 0; i < 10; i++) {
      ReelDiagnostics.instance.recordProxiedStart();
    }
    expect(summaries(), hasLength(1));
    expect(summaries().single, contains('starts=10'));
  });
}
