// How many players have been told to shut down and have not finished.
//
// The feed keeps four players. When a reel scrolls away its slot is handed
// to the next reel straight away — but telling the phone to shut the old
// one down is not instant, and the decoder stays occupied until it
// finishes. So the app's own books can say four while the phone is holding
// more.
//
// A device log showed THIRTEEN decoders alive at once against a pool of
// four, with eighty-six players retired over the session. The search grid
// was ruled out (it peaked at one), and the sizes say seven of the twelve
// created just before the peak were the feed's.
//
// This number says whether shutting down is the reason. Eight or nine is
// the answer. Zero rules it out — which is exactly what the preview count
// did to the previous theory, in one line, after a round of guessing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_player_service.dart';

import 'support/dart_source.dart';

void main() {
  late ReelDiagnostics d;

  late void Function(void Function()) originalDefer;

  setUp(() {
    d = ReelDiagnostics.instance;
    d.debugReset();
    originalDefer = VideoPlayerService.deferRelease;
  });

  tearDown(() {
    VideoPlayerService.deferRelease = originalDefer;
  });

  group('the count follows the shutdowns', () {
    test('starting one raises it, finishing lowers it', () {
      d.recordReleaseStarted();
      d.recordReleaseStarted();
      expect(d.debugReleasing, 2);
      d.recordReleaseFinished();
      expect(d.debugReleasing, 1);
    });

    test('the peak remembers the worst moment', () {
      // The whole question is how many were shutting down AT ONCE. A count
      // read afterwards is always zero, and zero is what "no problem here"
      // looks like too.
      for (var i = 0; i < 9; i++) {
        d.recordReleaseStarted();
      }
      for (var i = 0; i < 9; i++) {
        d.recordReleaseFinished();
      }
      expect(d.debugReleasing, 0);
      expect(d.debugReleasingPeak, 9);
    });

    test('and survives the count coming down and up again', () {
      for (var i = 0; i < 6; i++) {
        d.recordReleaseStarted();
      }
      for (var i = 0; i < 4; i++) {
        d.recordReleaseFinished();
      }
      d.recordReleaseStarted();
      expect(d.debugReleasing, 3);
      expect(d.debugReleasingPeak, 6,
          reason: 'the peak followed the current count back down, so the '
              'worst moment is gone from the log');
    });

    test('it cannot go negative', () {
      d.recordReleaseFinished();
      d.recordReleaseFinished();
      expect(d.debugReleasing, 0);
    });
  });

  group('it reaches the log', () {
    test('shown once anything has been retired', () {
      d.recordProxiedStart();
      d.recordPlayerRetired();
      d.recordReleaseStarted();
      expect(d.summary(), contains('shutting down now=1'));
      expect(d.summary(), contains('peak=1'));
    });

    test('shown even when it is zero, because zero is the answer', () {
      // Unlike the preview count, this one must NOT go quiet at zero. Zero
      // here rules the shutdown queue out as the cause, and a number that
      // disappears when it is interesting is no use.
      d.recordProxiedStart();
      d.recordPlayerRetired();
      expect(d.summary(), contains('shutting down now=0'),
          reason: 'the one reading that would settle the question is the '
              'one reading the log does not carry');
    });

    test('silent only when nothing has been retired at all', () {
      d.recordProxiedStart();
      expect(d.summary(), isNot(contains('shutting down')));
    });
  });

  group('the pool actually reports it', () {
    final src = File('lib/services/video_player_service.dart').readAsStringSync();

    test('a retirement starts the clock', () {
      final body = bodyOf(src, 'void _retire(VideoPlayerController controller)');
      expect(body, contains('recordReleaseStarted()'));
    });

    test('and finishing stops it', () {
      final body = bodyOf(src, 'void _retire(VideoPlayerController controller)');
      expect(body, contains('recordReleaseFinished'),
          reason: 'a count that only ever goes up measures retirements, '
              'which are already counted, and answers nothing');
    });

    test('the clock starts when the shutdown does, not when it is queued', () {
      // Release is deferred to the next frame. Counting at the queueing
      // point would include time the phone is not holding anything yet and
      // would overstate the problem.
      final body = bodyOf(src, 'void _retire(VideoPlayerController controller)');
      final defer = body.indexOf('deferRelease(');
      final start = body.indexOf('recordReleaseStarted()');
      expect(defer, greaterThan(-1));
      expect(start, greaterThan(defer),
          reason: 'counted before the shutdown is even asked for');
    });
  });

  group('it measures a real shutdown, end to end', () {
    test('the count rises when one starts and falls when it completes',
        () async {
      // Drive the seam by hand: the real one waits for a frame, which a
      // unit test has none of.
      final queued = <void Function()>[];
      VideoPlayerService.deferRelease = queued.add;

      final c = VideoPlayerController.networkUrl(Uri.parse('https://x/a.mp4'));
      VideoPlayerService.instance.debugRetire(c);

      expect(d.debugReleasing, 0,
          reason: 'counted at the queueing point, before the phone has been '
              'asked for anything');
      queued.single();
      expect(d.debugReleasing, 1);

      // dispose() on an uninitialised controller completes without a
      // platform; pumping the microtask queue lets whenComplete land.
      await Future<void>.delayed(Duration.zero);
      expect(d.debugReleasing, 0,
          reason: 'the count never comes back down, so it only ever climbs '
              'and every log reads like a disaster');
    });
  });
}
