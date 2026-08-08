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
    expect(d.summary(), contains('warmed=2 failed=1'));
  });

  test('counting is not disabled outright', () {
    final d = ReelDiagnostics.instance;
    d.recordProxiedStart();
    expect(d.debugProxied, 1);
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
