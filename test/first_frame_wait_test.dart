// How long a reel takes to go from "on screen" to a moving picture.
//
// ═══════════════════════════════════════════════════════════════════════
// EVERY STALL MEASUREMENT BEFORE THIS ONE WAS MEDIATEK-ONLY
// ═══════════════════════════════════════════════════════════════════════
//
// Round after round of this app's tuning was read off a line the MediaTek
// decoder prints:
//
//     onReleaseOutputBuffer: Render time interval reaches 434ms
//
// That is not an Android line. It is that vendor's. A log from a Qualcomm
// phone contains ZERO of them — so on that phone there was no stall
// measurement at all, and every counter that DID exist said the session was
// going well while the person holding it said the feed stuck a lot:
//
//     swipe 54/4 warm/cold   proxy 73%   link 30 Mbps   hardware=16
//
// Every one of those describes the app's own plumbing. None of them is the
// thing a person experiences, which is: I swiped, and then I waited.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';

void main() {
  late ReelDiagnostics d;

  setUp(() {
    d = ReelDiagnostics.instance;
    d.debugReset();
  });

  tearDown(() => d.debugReset());

  group('what the line reports', () {
    test('the middle reel, not the average', () {
      // One reel that took eight seconds must not be allowed to describe
      // the other fifty. That is what an average does.
      for (final ms in [100, 120, 140, 160, 8000]) {
        d.recordFirstFrameWait(Duration(milliseconds: ms));
      }
      d.recordProxiedStart();
      expect(d.summary(), contains('median=140ms'));
      expect(d.summary(), contains('worst=8000ms'),
          reason: 'the worst wait is the one somebody remembers, so it is '
              'carried separately rather than hidden by the median');
    });

    test('and the slow tenth, which is where complaints come from', () {
      for (var i = 0; i < 10; i++) {
        d.recordFirstFrameWait(Duration(milliseconds: 100 + i * 100));
      }
      d.recordProxiedStart();
      expect(d.summary(), contains('p90='));
    });

    test('with a count, so a median of two is not read as a median of fifty',
        () {
      d.recordFirstFrameWait(const Duration(milliseconds: 200));
      d.recordProxiedStart();
      expect(d.summary(), contains('n=1'));
    });

    test('nothing at all before anything has been timed', () {
      d.recordProxiedStart();
      expect(d.summary(), isNot(contains('wait ')),
          reason: 'an empty reading in the one line that gets read is noise');
    });
  });

  group('what it refuses to record', () {
    test('a negative wait', () {
      // Clocks can go backwards. A negative reading would drag the median
      // somewhere no reel has ever been.
      d.recordFirstFrameWait(const Duration(milliseconds: -50));
      expect(d.debugFirstFrameCount, 0);
    });

    test('but zero is a real reading', () {
      // A warm reel that starts instantly is the thing this app has spent
      // ten changes trying to achieve. Dropping it would hide the wins.
      d.recordFirstFrameWait(Duration.zero);
      expect(d.debugFirstFrameCount, 1);
    });
  });

  group('it does not grow forever', () {
    test('a long session keeps the recent past, not all of it', () {
      for (var i = 0; i < 500; i++) {
        d.recordFirstFrameWait(Duration(milliseconds: i));
      }
      expect(d.debugFirstFrameCount, lessThanOrEqualTo(200));
    });

    test('and keeps the NEWEST, not the oldest', () {
      // Dropping new readings would freeze the number early in a session
      // and never show what changed — the reading would describe the first
      // twenty seconds of the app for ever.
      //
      // 300 readings counting up. Keeping the newest 200 means 100..299,
      // whose middle is 200. Keeping the OLDEST 200 means 0..199, whose
      // middle is 100. Asserting the actual number is what separates them;
      // "not 50" passes either way, which is how the first version of this
      // test let a reversed eviction through.
      for (var i = 0; i < 300; i++) {
        d.recordFirstFrameWait(Duration(milliseconds: i));
      }
      d.recordProxiedStart();
      expect(d.summary(), contains('median=200ms'),
          reason: 'the oldest readings survived and the recent ones were '
              'thrown away, so the line describes a session that has '
              'already ended');
    });

    test('a reset clears it', () {
      d.recordFirstFrameWait(const Duration(milliseconds: 200));
      d.debugReset();
      expect(d.debugFirstFrameCount, 0);
    });
  });
}
