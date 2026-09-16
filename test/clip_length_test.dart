// How long a clip is, and who decides.
//
// The app takes video up to three minutes because that is what the server
// takes. Three minutes is a CEILING, not what anybody should get by
// default: a short-video app that posts three minutes unless you stop it
// is not a short-video app. So the trim screen offers a choice — 30s,
// 1 min, 2 min, 3 min — and starts on one minute.
//
// These rules live in ClipLength rather than inside the trim page's State
// because a rule that only exists in a widget can only be checked by
// reading it and hoping. What gets uploaded is decided here.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/services/clip_length.dart';
import 'package:myapp/services/video_processor_service.dart';

void main() {
  const cap = AppConstants.maxVideoDuration;

  group('what the picker offers', () {
    test('the four lengths, shortest first', () {
      expect(ClipLength.optionsWithin(cap), [
        const Duration(seconds: 30),
        const Duration(minutes: 1),
        const Duration(minutes: 2),
        const Duration(minutes: 3),
      ]);
    });

    test('never a length the server would refuse', () {
      for (final d in ClipLength.optionsWithin(cap)) {
        expect(d <= cap, isTrue, reason: '$d is past the cap of $cap');
      }
    });

    test('the options follow the cap instead of going stale', () {
      // The whole reason this is computed rather than typed out. Drop the
      // cap and the options that no longer fit disappear on their own.
      expect(ClipLength.optionsWithin(const Duration(minutes: 2)),
          isNot(contains(const Duration(minutes: 3))));
      expect(ClipLength.optionsWithin(const Duration(seconds: 45)),
          [const Duration(seconds: 30)]);
    });

    test('the app and the trim screen read the same cap', () {
      expect(VideoProcessorService.maxReelDuration, cap,
          reason: 'two numbers that must agree, written twice');
    });
  });

  group('what you get if you choose nothing', () {
    test('one minute, not three', () {
      expect(ClipLength.defaultWithin(cap), const Duration(minutes: 1),
          reason: 'defaulting to the ceiling makes every upload as long as '
              'the app will allow, which is the opposite of the point');
    });

    test('the default is always an offered option', () {
      for (final c in [
        const Duration(minutes: 3),
        const Duration(minutes: 2),
        const Duration(minutes: 1),
        const Duration(seconds: 45),
      ]) {
        final options = ClipLength.optionsWithin(c);
        final chosen = ClipLength.defaultWithin(c);
        expect(options, contains(chosen),
            reason: 'with a cap of $c the screen opens on $chosen, which is '
                'not one of the buttons — so nothing looks selected');
      }
    });

    test('and never longer than the cap', () {
      expect(ClipLength.defaultWithin(const Duration(seconds: 30)),
          const Duration(seconds: 30));
    });
  });

  group('how the options read', () {
    test('seconds below a minute, minutes above', () {
      expect(ClipLength.label(const Duration(seconds: 30)), '30s');
      expect(ClipLength.label(const Duration(minutes: 1)), '1 min');
      expect(ClipLength.label(const Duration(minutes: 2)), '2 min');
      expect(ClipLength.label(const Duration(minutes: 3)), '3 min');
    });
  });

  group('where the window lands', () {
    test('a video shorter than the choice is taken whole', () {
      // The ask that started this: a clip that fits should not be cut, and
      // choosing a length longer than the video is not an error.
      final w = ClipLength.window(totalMs: 12000, limitMs: 180000, startMs: 0);
      expect(w.startMs, 0);
      expect(w.endMs, 12000, reason: 'twelve seconds became something else');
    });

    test('a three minute video at three minutes keeps all of it', () {
      final w =
          ClipLength.window(totalMs: 180000, limitMs: 180000, startMs: 0);
      expect(w.endMs - w.startMs, 180000);
    });

    test('a long video at the default gets the first minute', () {
      final w = ClipLength.window(totalMs: 180000, limitMs: 60000, startMs: 0);
      expect(w.startMs, 0);
      expect(w.endMs, 60000);
    });

    test('choosing a longer length keeps the moment already found', () {
      // Somebody scrubbed to 0:50 and then asked for two minutes. Jumping
      // back to the start would throw away the thing they were doing.
      final w =
          ClipLength.window(totalMs: 180000, limitMs: 120000, startMs: 50000);
      expect(w.startMs, 50000);
      expect(w.endMs, 170000);
    });

    test('a window that would run off the end slides back to fit', () {
      // At 0:50 of a 2:00 video, asking for two minutes cannot start at
      // 0:50. It should still give two minutes, from the beginning — not
      // seventy seconds.
      final w =
          ClipLength.window(totalMs: 120000, limitMs: 120000, startMs: 50000);
      expect(w.endMs - w.startMs, 120000,
          reason: 'the length asked for was silently shortened');
      expect(w.startMs, 0);
    });

    test('the window never leaves the video', () {
      for (final total in [1000, 12000, 60000, 120000, 180000]) {
        for (final limit in [30000, 60000, 120000, 180000]) {
          for (final start in [0, 5000, 50000, 179000, 500000]) {
            final w = ClipLength.window(
                totalMs: total, limitMs: limit, startMs: start);
            expect(w.startMs, greaterThanOrEqualTo(0),
                reason: 'total=$total limit=$limit start=$start');
            expect(w.endMs, lessThanOrEqualTo(total),
                reason: 'total=$total limit=$limit start=$start');
            expect(w.endMs - w.startMs, lessThanOrEqualTo(limit),
                reason: 'total=$total limit=$limit start=$start selected '
                    'more than was asked for');
          }
        }
      }
    });

    test('a source with no duration yet does not crash the screen', () {
      final w = ClipLength.window(totalMs: 0, limitMs: 60000, startMs: 0);
      expect(w.startMs, 0);
      expect(w.endMs, 0);
    });

    group('nonsense in, sensible out', () {
      // These two guards defend the contract of a pure function rather
      // than any path the trim screen takes today — a RangeSlider cannot
      // hand back a negative start, and a controller cannot report a
      // negative length. They are tested anyway, because a guard nothing
      // exercises is decoration: nobody finds out it stopped working, and
      // the next caller of this function is the one who pays.

      test('a negative start is pulled back to the beginning', () {
        final w =
            ClipLength.window(totalMs: 60000, limitMs: 30000, startMs: -5000);
        expect(w.startMs, 0,
            reason: 'a window starting before the video begins');
        expect(w.endMs, 30000);
      });

      test('a negative length gives an empty window, not a negative one', () {
        final w =
            ClipLength.window(totalMs: -1, limitMs: 60000, startMs: 0);
        expect(w.startMs, 0);
        expect(w.endMs, 0,
            reason: 'an end before the start is not a window, and every '
                'caller would have to check for it');
      });
    });
  });
}
