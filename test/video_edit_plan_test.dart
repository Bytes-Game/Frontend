// How an edited video is saved — the quality promise, in numbers.
//
//   * nothing changed: the original file, untouched;
//   * only cut shorter: cut, not remade, so not one pixel changes;
//   * anything else: remade at the original's own size and data rate,
//     never below a healthy floor, never above 1080p.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/video_edit_plan.dart';

const _ten = Duration(seconds: 10);
const _max = Duration(minutes: 3);

VideoSavePlan _plan(
  VideoEdits edits, {
  Duration duration = _ten,
  int longSide = 1920,
  int bitrate = 12000000,
}) => planVideoSave(
  edits: edits,
  duration: duration,
  longSide: longSide,
  sourceBitrate: bitrate,
  maxLength: _max,
);

void main() {
  group('nothing changed', () {
    test('the original file goes, untouched', () {
      final plan = _plan(const VideoEdits());
      expect(plan.way, VideoSaveWay.original);
      expect(plan.isTrimmed, isFalse);
      expect(plan.bitrate, isNull, reason: 'nothing is remade');
    });

    test('a trim bar left a hair off the very ends is not a cut', () {
      final plan = _plan(
        const VideoEdits(
          start: Duration(milliseconds: 40),
          end: Duration(milliseconds: 9950),
        ),
      );
      expect(plan.way, VideoSaveWay.original);
    });

    test('the trim bar at exactly the start and the end is not a cut', () {
      final plan = _plan(const VideoEdits(start: Duration.zero, end: _ten));
      expect(plan.way, VideoSaveWay.original);
    });
  });

  group('only cut shorter', () {
    test('cut, not remade, at the points chosen', () {
      final plan = _plan(
        const VideoEdits(
          start: Duration(seconds: 2),
          end: Duration(seconds: 7),
        ),
      );
      expect(plan.way, VideoSaveWay.cut);
      expect(plan.start, const Duration(seconds: 2));
      expect(plan.end, const Duration(seconds: 7));
      expect(plan.bitrate, isNull, reason: 'a cut keeps the bytes as they are');
    });

    test('cut at one end only keeps the other end open', () {
      final plan = _plan(const VideoEdits(start: Duration(seconds: 3)));
      expect(plan.way, VideoSaveWay.cut);
      expect(plan.start, const Duration(seconds: 3));
      expect(plan.end, isNull);
    });

    test('never more than a post may hold, even if nobody cut it', () {
      final plan = _plan(
        const VideoEdits(),
        duration: const Duration(minutes: 4),
      );
      expect(plan.way, VideoSaveWay.cut);
      expect(plan.start, isNull);
      expect(plan.end, _max);
    });

    test(
      'a span longer than a post is cut to a post, from where it starts',
      () {
        final plan = _plan(
          const VideoEdits(start: Duration(seconds: 30)),
          duration: const Duration(minutes: 5),
        );
        expect(plan.start, const Duration(seconds: 30));
        expect(plan.end, const Duration(seconds: 30) + _max);
      },
    );
  });

  group('anything else is remade', () {
    for (final (name, edits) in [
      ('text, emoji or drawing', const VideoEdits(hasLayers: true)),
      ('a filter or brightness', const VideoEdits(hasColour: true)),
      ('blur', const VideoEdits(hasBlur: true)),
      ('crop, rotate or flip', const VideoEdits(isTransformed: true)),
      ('the sound turned off', const VideoEdits(muted: true)),
      ('a song added', const VideoEdits(hasMusic: true)),
    ]) {
      test(name, () {
        expect(_plan(edits).way, VideoSaveWay.remake);
      });
    }

    test('a remake keeps the cut too', () {
      final plan = _plan(
        const VideoEdits(
          hasLayers: true,
          start: Duration(seconds: 1),
          end: Duration(seconds: 6),
        ),
      );
      expect(plan.way, VideoSaveWay.remake);
      expect(plan.start, const Duration(seconds: 1));
      expect(plan.end, const Duration(seconds: 6));
    });
  });

  group('a remake keeps the original\'s own quality', () {
    test('1080p at 12 Mbit/s stays at 12', () {
      final plan = _plan(const VideoEdits(hasLayers: true));
      expect(plan.bitrate, 12000000);
      expect(plan.scale, 1, reason: '1080p is not shrunk');
    });

    test('1080p at 18 Mbit/s is held to 16, plenty for 1080p', () {
      final plan = _plan(const VideoEdits(hasLayers: true), bitrate: 18000000);
      expect(plan.bitrate, maxRemakeBitrate);
      expect(maxRemakeBitrate, 16000000);
    });

    test('720p kept at a low rate is lifted to a healthy floor', () {
      final plan = _plan(
        const VideoEdits(hasLayers: true),
        longSide: 1280,
        bitrate: 2000000,
      );
      expect(plan.bitrate, 5000000);
    });

    test('a phone that could not say the rate gets the floor for its size', () {
      expect(_plan(const VideoEdits(muted: true), bitrate: 0).bitrate, 8000000);
      expect(
        _plan(const VideoEdits(muted: true), longSide: 640, bitrate: 0).bitrate,
        1500000,
      );
    });

    test('4K is remade at 1080p, no bigger than the server ever shows', () {
      final plan = _plan(
        const VideoEdits(hasColour: true),
        longSide: 3840,
        bitrate: 45000000,
      );
      expect(plan.scale, 0.5);
      expect(plan.bitrate, maxRemakeBitrate);
    });

    test('the floors, size by size', () {
      expect(remakeFloor(1920), 8000000);
      expect(remakeFloor(1280), 5000000);
      expect(remakeFloor(854), 2500000);
      expect(remakeFloor(640), 1500000);
    });

    test('the shrink, size by size', () {
      expect(remakeScale(1920), 1);
      expect(remakeScale(1280), 1);
      expect(remakeScale(2560), 0.75);
      expect(remakeScale(3840), 0.5);
    });
  });
}
