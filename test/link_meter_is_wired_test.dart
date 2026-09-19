// The meter exists. Does anything feed it?
//
// ═══════════════════════════════════════════════════════════════════════
// THIS GAP HAS ALREADY COST TWO ROUNDS IN THIS REPO
// ═══════════════════════════════════════════════════════════════════════
//
// "There is a probe method" is not "the app runs it". The decoder budget
// shipped once with a reading nothing called, and the adaptive working set
// nearly shipped a measured number that startup never passed on. Both were
// found the same way: a mutation that severed the WIRE left every test
// green, because every test was calling the far end by hand.
//
// The same shape applies here, and worse. The meter can be perfect and the
// app can still measure nothing, or — the one that actually bites — can
// open a lane and never close it. A lane left open means the busy clock
// never stops, so every later reading is divided by time the link spent
// idle, and the app talks itself into a slower network than it has. Which
// is the exact fault the meter was added to fix.
//
// These are source checks rather than a running pipeline, because the
// download path needs a socket, a temp directory and a CDN to exercise —
// and none of that has any bearing on the question being asked, which is
// simply: is the wire connected at both ends.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/services/video_cache_service.dart').readAsStringSync();

  group('bytes off the network reach the meter', () {
    test('every chunk, from every download', () {
      // Per CHUNK, not per finished download. Measuring only completed
      // transfers is how a cancelled one — which still used the link —
      // went uncounted, and how three parallel downloads each looked like
      // the whole connection.
      expect(src, contains('noteBytesFromNetwork(chunk.length)'),
          reason: 'the meter is fed by nothing, so it measures nothing and '
              'the app falls back to last run\'s guess for ever');
    });

    test('and nothing still times one download on its own', () {
      // The old way. Leaving it in alongside the meter would put two
      // different answers to the same question into the same median.
      expect(src, isNot(contains('recordThroughput(')),
          reason: 'per-download timing is back, and it reads a shared link '
              'as one lane of itself');
    });
  });

  group('a lane is always closed', () {
    test('it is opened when the download starts', () {
      expect(src, contains('noteTransferStarted()'));
    });

    test('and closed in a finally, not on the happy path', () {
      // THE ONE THAT ACTUALLY BITES. A download that throws, times out or
      // is cancelled mid-flight must still give the lane back. If it does
      // not, the busy clock runs for ever and every reading afterwards is
      // divided by idle time.
      final body = bodyOf(src, 'Future<bool> _runPrefix(');
      final finallyAt = body.lastIndexOf('} finally {');
      final closeAt = body.lastIndexOf('closeLane();');
      expect(finallyAt, greaterThan(-1), reason: 'no finally block');
      expect(closeAt, greaterThan(finallyAt),
          reason: 'the lane is only given back when the download succeeds, '
              'so one failure poisons every reading after it');
    });

    test('and closing twice does nothing', () {
      // It is closed on the success path AND in the finally, so it runs
      // twice on every healthy download. Without the guard the in-flight
      // count would walk downwards and the busy clock would stop while
      // downloads were still running.
      final body = bodyOf(src, 'Future<bool> _runPrefix(');
      expect(body, contains('if (!laneOpen) return;'),
          reason: 'the count goes negative-ward on every completed '
              'download, which stops the clock while the link is busy');
    });

    test('the flag lives outside the try, or the finally cannot see it', () {
      // A `var laneOpen` declared inside the try is out of scope in the
      // finally — this does not compile, but it is the obvious edit
      // somebody makes while tidying, and the comment there explains why
      // it is where it is.
      final body = bodyOf(src, 'Future<bool> _runPrefix(');
      final declAt = body.indexOf('var laneOpen = false;');
      final tryAt = body.indexOf('try {');
      expect(declAt, greaterThan(-1));
      expect(declAt, lessThan(tryAt),
          reason: 'moved inside the try, where the finally cannot reach it');
    });
  });
}
