// Offering the creator what the model noticed on their own video.
//
// This sits in a feed somebody is scrolling, so the rule that matters is that
// it can be ignored completely: no spinner, no empty box, no layout shift on
// a reel that has nothing to offer — which is most reels, most of the time.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/tag_suggestion_strip.dart';

void main() {
  group('reading what the server sent', () {
    test('a normal answer', () {
      final s = TagSuggestions.fromJson({
        'suggested': ['surfing', 'wave'],
        'yours': ['beach'],
      });
      expect(s.suggested, ['surfing', 'wave']);
      expect(s.yours, ['beach']);
      expect(s.isEmpty, isFalse);
    });

    test('nothing to offer', () {
      final s = TagSuggestions.fromJson({'suggested': [], 'yours': ['beach']});
      expect(s.isEmpty, isTrue,
          reason: 'a video with no suggestions must render nothing');
    });

    test('a shape it did not expect', () {
      // Never throws into a feed. Missing, null, or the wrong type all mean
      // "nothing to show", which is where the creator was before this.
      for (final bad in <Map<String, dynamic>>[
        {},
        {'suggested': null, 'yours': null},
        {'suggested': 'surfing', 'yours': 42},
      ]) {
        final s = TagSuggestions.fromJson(bad);
        expect(s.isEmpty, isTrue, reason: 'from $bad');
        expect(s.yours, isEmpty);
      }
    });

    test('empty strings are dropped', () {
      final s = TagSuggestions.fromJson({
        'suggested': ['surfing', '', 'wave'],
        'yours': [],
      });
      expect(s.suggested, ['surfing', 'wave'],
          reason: 'a blank chip is a chip that does nothing');
    });
  });

  group('it takes up no space until it has something to say', () {
    testWidgets('nothing at all before the answer arrives', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: TagSuggestionStrip(videoId: 'never-answers'),
        ),
      ));
      await tester.pump();

      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: 'a spinner on every reel is worse than the thing it '
              'replaces — this must be invisible until it is useful');
      final box = tester.getSize(find.byType(TagSuggestionStrip));
      expect(box.height, 0,
          reason: 'anything taller than zero shifts the caption on every '
              'reel in the feed');
    });

    testWidgets('an empty id asks for nothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: TagSuggestionStrip(videoId: '')),
      ));
      await tester.pump();
      expect(tester.getSize(find.byType(TagSuggestionStrip)).height, 0);
    });
  });

  group('it cannot file tags against the wrong video', () {
    final src = File('lib/widgets/tag_suggestion_strip.dart').readAsStringSync();

    test('a reused tile drops what it loaded for the last reel', () {
      // Flutter reuses these tiles as the feed scrolls. Without this the tags
      // from the previous video show briefly on the next one, and a tap files
      // them against the wrong video.
      final body = bodyOf(src, 'void didUpdateWidget(TagSuggestionStrip old)');
      expect(body, contains('old.videoId != widget.videoId'),
          reason: 'the tile never notices it is showing a different reel');
      expect(body, contains('old.subject != widget.subject'),
          reason: 'a challenge and an answer can both be id 7, so the kind '
              'has to be part of what the tile notices changing');
      expect(body, contains('_s = null'),
          reason: 'the old suggestions stay on screen for the new reel');
    });

    test('an answer that arrives late is discarded', () {
      final body = bodyOf(src, 'Future<void> _load()');
      expect(body, contains('widget.videoId != id'),
          reason: 'a slow reply lands on whatever reel is showing by then');
    });

    test('a decision is checked against the reel it was made on', () {
      final body = bodyOf(src, 'Future<void> _decide(');
      expect(body, contains('widget.videoId != id'),
          reason: 'tapping add, then scrolling, would write the result onto '
              'the next video');
    });

    test('the build refuses to show tags loaded for another reel', () {
      final body = bodyOf(src, 'Widget build(BuildContext context)');
      expect(body, contains('_loadedFor != _currentKey'));
    });

    test('what is stored is what is compared', () {
      // The one failure mode the tests above cannot see. Every other check
      // here asserts the strip shows NOTHING, so a mismatch between the value
      // written when the answer lands and the value the build compares it
      // against passes all of them — and the strip silently never appears
      // again for anybody.
      expect(bodyOf(src, 'Future<void> _load()'),
          contains('_loadedFor = _currentKey'),
          reason: 'the build compares _loadedFor against _currentKey, so '
              'storing anything else means it never matches and the strip '
              'is invisible forever');
    });

    test('the tile is keyed by video', () {
      final feed =
          File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
      expect(feed, contains("key: ValueKey('tags-\${item.id}')"),
          reason: 'without a key per video Flutter reuses one state object '
              'across reels');
    });
  });

  group('only on your own video', () {
    test('the feed asks for it only when you are the creator', () {
      final feed =
          File('lib/widgets/smart_reels_feed.dart').readAsStringSync();
      expect(feed, contains('if (widget.isOwner && item.id.isNotEmpty)'),
          reason: 'the strip is built for every viewer, so every viewer '
              'asks the server about somebody else\'s video');
    });
  });

  group('a failed call changes nothing', () {
    test('the shown state is only replaced by a real answer', () {
      final src =
          File('lib/widgets/tag_suggestion_strip.dart').readAsStringSync();
      final body = bodyOf(src, 'Future<void> _decide(');
      expect(body, contains('if (got != null) _s = got;'),
          reason: 'guessing the new state and being wrong shows the creator '
              'tags they do not have');
    });
  });
}
