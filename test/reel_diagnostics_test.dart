// Tests for the playback diagnostics.
//
// These exist because of a specific failure: the media proxy shipped onto the
// critical path of every reel with all of its logging behind `kDebugMode`. That
// flag is false in profile builds — the only build whose timings mean anything —
// so the one build capable of answering "did the proxy even run?" printed
// nothing about it. The bug was not in the proxy; it was that the proxy was
// unobservable exactly where it needed observing.
//
// So the thing worth pinning down is the counting itself: that a reel started
// from the proxy is not quietly filed as a network start, which would make a
// broken cache look like a working one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/reel_diagnostics.dart';

void main() {
  setUp(() => ReelDiagnostics.instance.debugReset());
  tearDown(() => ReelDiagnostics.instance.debugReset());

  test('starts are attributed to the source they actually came from', () {
    final d = ReelDiagnostics.instance;
    d.recordProxiedStart();
    d.recordProxiedStart();
    d.recordWholeFileStart();
    d.recordOriginStart();

    expect(d.debugProxied, 2);
    expect(d.debugWholeFile, 1);
    expect(d.debugOrigin, 1);
  });

  test('the summary reports every source and their share', () {
    final d = ReelDiagnostics.instance;
    for (var i = 0; i < 3; i++) {
      d.recordProxiedStart();
    }
    d.recordOriginStart();

    final s = d.summary();
    expect(s, contains('starts=4'));
    expect(s, contains('proxy=3'));
    expect(s, contains('network=1'));
    expect(s, contains('75%'),
        reason: 'the proxy share is the number this exists to surface');
  });

  test('says so plainly before anything has played', () {
    expect(ReelDiagnostics.instance.summary(), 'no reels played yet');
  });

  test('prefix warm outcomes are tracked separately from playback', () {
    final d = ReelDiagnostics.instance;
    d.recordPrefixWarmed();
    d.recordPrefixWarmed();
    d.recordPrefixFailed();

    // Warming is not a playback: a warmed reel the user never reaches must
    // not inflate the start counts, or the proxy's hit rate reads high while
    // nothing is actually being played from it.
    expect(d.debugProxied, 0);
    expect(d.summary(), 'no reels played yet');

    d.recordProxiedStart();
    expect(d.summary(), contains('warmed=2 (+tail 0) failed=1'));
  });

  test('a warm that also cached the file\'s end says so', () {
    // The counter that replaced `bailed{moovAtEnd:n}`. Those files used to
    // fall out of prefix warming entirely; now they are warmed with their
    // index as well, and the summary has to distinguish the two kinds or
    // there is no way to tell the fix worked from the catalog never
    // having had the problem.
    final d = ReelDiagnostics.instance;
    d.recordPrefixWarmed();
    d.recordPrefixWarmed();
    d.recordTailWarmed();
    d.recordProxiedStart();

    // A tail always accompanies a prefix, so it is a subset, never a
    // separate warm.
    expect(d.summary(), contains('warmed=2 (+tail 1)'));
  });

  test('the summary carries the live pipeline snapshot', () {
    // The counters are cumulative, so they cannot distinguish "warming has
    // nothing left to fetch" from "warming is wedged with a queue behind
    // it" — both read as a download count that stopped climbing. The
    // snapshot is what separates them, so it has to reach the line.
    final d = ReelDiagnostics.instance;
    d.setPipelineProbe(() => 'queue=3 active=1/1 urls=15 cancelled=4');
    d.recordProxiedStart();

    expect(d.summary(), contains('queue=3 active=1/1 urls=15 cancelled=4'));
  });

  test('a probe that throws costs a snapshot, not the summary', () {
    // Losing the whole line to a fault in the observation code would be
    // the same class of mistake this file exists to fix.
    final d = ReelDiagnostics.instance;
    d.setPipelineProbe(() => throw StateError('probe blew up'));
    d.recordProxiedStart();

    final s = d.summary();
    expect(s, contains('starts=1'));
    expect(s, contains('pipeline unavailable'));
  });

  test('counting is not disabled outright', () {
    final d = ReelDiagnostics.instance;
    d.recordProxiedStart();
    expect(d.debugProxied, 1);
  });

  group('spares are tallied per gesture', () {
    // One shared warm/cold pair could not answer the question the second
    // read-ahead lane was added to settle — are FLIPS landing on a ready
    // player? Swipes vastly outnumber flips, so a single total is
    // dominated by them and a flip arriving cold every time is invisible
    // in it.
    test('each lane keeps its own warm and cold counts', () {
      final d = ReelDiagnostics.instance;
      d.debugReset();

      d.recordSpareWarm(SpareLane.nextReel);
      d.recordSpareWarm(SpareLane.nextReel);
      d.recordSpareCold(SpareLane.nextReel);
      d.recordSpareWarm(SpareLane.opponent);
      d.recordSpareCold(SpareLane.opponent);
      d.recordSpareCold(SpareLane.opponent);
      d.recordSpareCold(SpareLane.opponent);

      expect(d.debugSpareWarm(SpareLane.nextReel), 2);
      expect(d.debugSpareCold(SpareLane.nextReel), 1);
      expect(d.debugSpareWarm(SpareLane.opponent), 1);
      expect(d.debugSpareCold(SpareLane.opponent), 3);
    });

    test('the summary names both lanes, even an empty one', () {
      final d = ReelDiagnostics.instance;
      d.debugReset();
      d.recordProxiedStart();
      d.recordSpareWarm(SpareLane.nextReel);

      final line = d.summary();
      expect(line, contains('swipe 1/0'));
      expect(line, contains('flip 0/0'),
          reason: 'a lane with nothing in it is the finding, not a row to '
              'omit — "flip 0/0" on a battle-heavy session says no opponent '
              'was ever read ahead for, which a missing row cannot say');
      d.debugReset();
    });
  });

  test('visibility is gated on release, not on debug', () {
    // The exact regression being guarded: gating on kDebugMode makes every
    // counter a no-op in PROFILE, which is the only build whose numbers are
    // worth reading. A behavioural assertion cannot catch that — `flutter
    // test` runs in debug, where kDebugMode and !kReleaseMode are both true,
    // so the buggy and correct versions are indistinguishable at runtime.
    //
    // So this reads the source instead. Same tactic as the backend's
    // hls_worker_budget_test, which parses the workflow file for a value it
    // cannot otherwise observe. Ugly, but it fails when it should.
    final src = File('lib/services/reel_diagnostics.dart').readAsStringSync();
    final gate = RegExp(r'static const bool _visible\s*=\s*([^;]+);')
        .firstMatch(src);

    expect(gate, isNotNull, reason: 'the _visible gate should still exist');
    expect(gate!.group(1)!.trim(), '!kReleaseMode',
        reason: 'diagnostics must be visible in profile builds; gating on '
            'kDebugMode is the original bug and silences them exactly where '
            'they are needed');
  });
}
