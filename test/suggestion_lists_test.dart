// Suggestion lists put themselves away.
//
// The owner reported: on the posting page, typing in the subject brings up
// suggestions that sit over the fields below, and tapping somewhere else
// did not close them. On a phone, tapping elsewhere does not take the
// focus off a text field, so a list shown "while the field is focused"
// stayed open until another field was tapped.
//
// Now every suggestion list closes on a tap outside it and comes back on a
// tap on its field: the opener and subject lists, the tags, and @mentions.
// Each test checks the list IS there before checking that it is gone, so a
// list broken into never showing could not pass.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/mentions.dart';
import 'package:myapp/widgets/suggest_field.dart';
import 'package:myapp/widgets/tags_input.dart';

UserModel person(String id, String name) => UserModel(
  id: id,
  username: name,
  wins: 0,
  losses: 0,
  followersCount: 0,
  followingCount: 0,
);

Future<void> frames(WidgetTester t, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('a suggestion field', () {
    late List<String> asked;

    Future<TextEditingController> open(WidgetTester t) async {
      asked = [];
      final ctl = TextEditingController();
      addTearDown(ctl.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SuggestField<String>(
                    controller: ctl,
                    label: 'Subject',
                    suggestions: const ['pranks', 'prank calls'],
                    displayString: (s) => s,
                    buildRow: (s) => Text(s),
                    onQuery: asked.add,
                  ),
                  const Spacer(),
                  const Text('Somewhere else'),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      );
      return ctl;
    }

    testWidgets('a tap outside closes the list; a tap on the field brings '
        'it back', (t) async {
      await open(t);
      expect(find.text('pranks'), findsNothing, reason: 'not before use');

      await t.tap(find.byType(TextFormField));
      await frames(t);
      expect(find.text('pranks'), findsOneWidget);
      expect(asked, isNotEmpty, reason: 'it asked for suggestions');

      await t.tap(find.text('Somewhere else'));
      await frames(t);
      expect(find.text('pranks'), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()),
        reason: 'the field let go, so the keyboard goes too',
      );

      final before = asked.length;
      await t.tap(find.byType(TextFormField));
      await frames(t);
      expect(find.text('pranks'), findsOneWidget);
      expect(asked.length, greaterThan(before));
    });

    testWidgets('a tap on a suggestion picks it — the list does not close '
        'under the finger first', (t) async {
      final ctl = await open(t);
      await t.tap(find.byType(TextFormField));
      await frames(t);
      // A real finger: down, a moment, then up — frames are drawn in
      // between, so a list that closed on the way down would be gone by
      // the time the finger lifts.
      final finger = await t.startGesture(t.getCenter(find.text('prank calls')));
      await t.pump(const Duration(milliseconds: 80));
      await finger.up();
      await frames(t);
      expect(ctl.text, 'prank calls');
      expect(find.text('pranks'), findsNothing, reason: 'closed after');
    });
  });

  group('tags', () {
    late List<List<String>> changes;

    Future<void> open(WidgetTester t) async {
      changes = [];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TagsInput(
                    selectedTags: const [],
                    onChanged: changes.add,
                    onQuery: (_) {},
                    suggestions: const ['dance', 'comedy'],
                  ),
                  const Spacer(),
                  const Text('Somewhere else'),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('the suggestions show while the box is in use, close on a '
        'tap outside, and come back on a tap on the box', (t) async {
      await open(t);
      expect(find.text('dance'), findsNothing, reason: 'not before use');

      await t.tap(find.byKey(const ValueKey('tags_field')));
      await frames(t);
      expect(find.text('dance'), findsOneWidget);

      await t.tap(find.text('Somewhere else'));
      await frames(t);
      expect(find.text('dance'), findsNothing);

      await t.tap(find.byKey(const ValueKey('tags_field')));
      await frames(t);
      expect(find.text('dance'), findsOneWidget);

      // Picking one still works.
      await t.tap(find.text('comedy'));
      await frames(t);
      expect(changes.single, ['comedy']);
    });
  });

  group('@mentions', () {
    testWidgets('the list closes on a tap outside and comes back as you '
        'type on', (t) async {
      final ctl = TextEditingController();
      addTearDown(ctl.dispose);
      final dp = DataProvider()..setUser(person('1', 'me'));
      EventTracker.instance.dispose();
      final people = [person('2', 'maya'), person('3', 'mark')];
      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>.value(
          value: dp,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Text('Somewhere else'),
                  const Spacer(),
                  MentionSuggestions(controller: ctl, people: people),
                  TextField(controller: ctl),
                ],
              ),
            ),
          ),
        ),
      );
      await t.enterText(find.byType(TextField), 'hi @ma');
      await frames(t, 2);
      expect(find.byKey(const ValueKey('mention_suggestions')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention_pick_maya')), findsOneWidget);

      await t.tap(find.text('Somewhere else'));
      await frames(t, 2);
      expect(find.byKey(const ValueKey('mention_suggestions')), findsNothing);

      await t.enterText(find.byType(TextField), 'hi @may');
      await frames(t, 2);
      expect(find.byKey(const ValueKey('mention_pick_maya')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('mention_pick_maya')));
      await frames(t, 2);
      expect(ctl.text, startsWith('hi @maya'));
    });
  });

  group('the posting page', () {
    setUp(() {
      ApiService.useClient(MockClient((req) async {
        final p = req.url.path;
        if (p.contains('challenge-subject')) {
          return http.Response(
            json.encode({
              'items': [
                {'subject': 'pranks', 'usageCount': 4},
                {'subject': 'prank calls', 'usageCount': 2},
              ],
            }),
            200,
          );
        }
        if (p.contains('challenge-prefix')) {
          return http.Response(json.encode({'items': ['Who is better at']}),
              200);
        }
        return http.Response(json.encode([]), 200);
      }));
    });
    tearDown(() => ApiService.useClient(http.Client()));

    testWidgets("the subject's suggestions close when you tap elsewhere on "
        'the form, so they never cover it', (t) async {
      t.view.physicalSize = const Size(1000, 2400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider(create: (_) => DataProvider())],
          child: const MaterialApp(
            home: ChallengeMetadataPage(processedSourcePath: '/tmp/clip.mp4'),
          ),
        ),
      );
      await frames(t);
      final subject = find.byType(TextFormField).at(1);
      await t.tap(subject);
      await frames(t);
      expect(find.text('prank calls'), findsOneWidget);

      await t.tap(find.text('WHO CAN SEE IT'));
      await frames(t);
      expect(find.text('prank calls'), findsNothing);

      await t.tap(subject);
      await frames(t);
      expect(find.text('prank calls'), findsOneWidget);
    });
  });
}
