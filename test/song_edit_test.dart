// How a song sits under a post (SongEdit), and the strip that picks its
// part (SongPartStrip). The editors' own tests go through both from the
// editor's Music button; these pin the arithmetic they rely on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/song_edit.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/widgets/song_sheet.dart';

void main() {
  group('SongEdit', () {
    test('a fade is 2 seconds, or a third of a short post', () {
      expect(SongEdit.fadeFor(const Duration(seconds: 30)),
          const Duration(seconds: 2));
      expect(SongEdit.fadeFor(const Duration(seconds: 3)),
          const Duration(seconds: 1));
    });

    test('the song cannot start so late that it runs out under the post', () {
      final edit = SongEdit(start: const Duration(seconds: 170));
      expect(
        edit.startWithin(
          const Duration(minutes: 3),
          const Duration(seconds: 15),
        ),
        const Duration(seconds: 165),
      );
      expect(
        SongEdit.latestStart(
          const Duration(seconds: 8),
          const Duration(seconds: 15),
        ),
        Duration.zero,
        reason: 'a song shorter than the post plays from its start',
      );
    });

    test('saved as set: part, volume, fades, and starting again if short', () {
      final edit = SongEdit(
        start: const Duration(seconds: 42),
        songVolume: 0.5,
        fadeIn: true,
      );
      final track = edit.track('/s.mp3', length: const Duration(seconds: 15));
      expect(track.path, '/s.mp3');
      expect(track.audioStartTime, const Duration(seconds: 42));
      expect(
        track.audioEndTime,
        const Duration(seconds: 57, milliseconds: 500),
        reason: 'only the part used is read, not the rest of the song',
      );
      expect(track.volume, 0.5);
      expect(track.loop, isTrue);
      expect(track.fadeInDuration, const Duration(seconds: 2));
      expect(track.fadeOutDuration, Duration.zero);
      expect(
        SongEdit().track('/s.mp3', length: const Duration(seconds: 15))
            .audioStartTime,
        isNull,
        reason: 'from the very start is no start time at all',
      );
    });

    test('while editing, a fade rises from silence and falls back to it', () {
      final edit = SongEdit(songVolume: 0.8, fadeIn: true, fadeOut: true);
      const post = Duration(seconds: 10);
      expect(edit.volumeAt(Duration.zero, post), 0);
      expect(edit.volumeAt(const Duration(seconds: 1), post), closeTo(0.4, 1e-9));
      expect(edit.volumeAt(const Duration(seconds: 5), post), 0.8);
      expect(edit.volumeAt(const Duration(seconds: 9), post), closeTo(0.4, 1e-9));
      expect(
        SongEdit(songVolume: 0.8).volumeAt(Duration.zero, post),
        0.8,
        reason: 'no fade: full from the first moment',
      );
    });
  });

  group('the strip', () {
    Future<Duration> strip(
      WidgetTester t, {
      required Duration song,
      required Duration length,
      required Duration start,
      Offset drag = Offset.zero,
    }) async {
      var at = start;
      var ended = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) => SizedBox(
                width: 300,
                child: SongPartStrip(
                  songLength: song,
                  length: length,
                  start: at,
                  onChanged: (s) => set(() => at = s),
                  onChangeEnd: () => ended++,
                ),
              ),
            ),
          ),
        ),
      );
      if (drag != Offset.zero) {
        await t.drag(find.byKey(const ValueKey('song_part')), drag);
        await t.pump();
        expect(ended, 1, reason: 'told once, when the drag ends');
      }
      return at;
    }

    testWidgets('says which part plays, as long as the post', (t) async {
      await strip(
        t,
        song: const Duration(minutes: 1),
        length: const Duration(seconds: 15),
        start: const Duration(seconds: 30),
      );
      expect(find.text('0:30 – 0:45  of 1:00'), findsOneWidget);
    });

    testWidgets('dragged past the end, it stops where the song still fills '
        'the post', (t) async {
      final at = await strip(
        t,
        song: const Duration(minutes: 1),
        length: const Duration(seconds: 15),
        start: const Duration(seconds: 30),
        drag: const Offset(400, 0),
      );
      expect(at, const Duration(seconds: 45));
      expect(find.text('0:45 – 1:00  of 1:00'), findsOneWidget);
    });

    testWidgets('a song shorter than the post is all of it', (t) async {
      await strip(
        t,
        song: const Duration(seconds: 8),
        length: const Duration(seconds: 15),
        start: Duration.zero,
      );
      expect(
        find.text('The whole song (0:08), then again from the start'),
        findsOneWidget,
      );
    });
  });

  group('a photo made into a video', () {
    test('keeps its shape, no bigger than 1080 x 1920, in even pixels', () {
      expect(stillVideoSize(const Size(1600, 1200)), const Size(1440, 1080));
      expect(stillVideoSize(const Size(1200, 1600)), const Size(1080, 1440));
      expect(stillVideoSize(const Size(4000, 3000)), const Size(1440, 1080));
      expect(stillVideoSize(const Size(641, 481)), const Size(642, 482),
          reason: 'small stays its size, made even');
      expect(stillVideoSize(Size.zero), const Size(1080, 1920));
    });
  });
}
