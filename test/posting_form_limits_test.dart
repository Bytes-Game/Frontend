// The form you fill in after choosing a video.
//
// The owner asked for: a 50-character limit on the prefix and 30 on the
// subject; the "energy is worked out…" line under the subject gone; the note
// under the battle length to read just "Voting starts when someone accepts.";
// and the category picker to show an example in light text instead of
// "Skip and we work it out from the video".

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

void main() {
  setUp(() {
    ApiService.useClient(MockClient((req) async {
      return http.Response(json.encode([]), 200);
    }));
  });
  tearDown(() => ApiService.useClient(http.Client()));

  Future<void> openForm(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider(create: (_) => DataProvider())],
        child: const MaterialApp(
          home: ChallengeMetadataPage(processedSourcePath: '/tmp/clip.mp4'),
        ),
      ),
    );
    await tester.pump();
  }

  String textOf(WidgetTester tester, int field) =>
      tester.widget<TextFormField>(find.byType(TextFormField).at(field))
          .controller!
          .text;

  testWidgets('the prefix stops at 50 characters and the subject at 30', (
    tester,
  ) async {
    await openForm(tester);
    expect(maxPrefix, 50);
    expect(maxSubject, 30);

    // What somebody pastes in, far past the limits.
    await tester.enterText(find.byType(TextFormField).at(0), 'p' * 70);
    await tester.enterText(find.byType(TextFormField).at(1), 's' * 45);
    await tester.pump();
    expect(textOf(tester, 0), 'p' * 50);
    expect(textOf(tester, 1), 's' * 30);

    // And the form shows how much room is left, the way the app counts it.
    expect(find.text('50/50'), findsOneWidget);
    expect(find.text('30/30'), findsOneWidget);
  });

  testWidgets('text within the limits goes through untouched', (tester) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextFormField).at(0), 'Who can');
    await tester.enterText(find.byType(TextFormField).at(1), 'juggle five');
    await tester.pump();
    expect(textOf(tester, 0), 'Who can');
    expect(textOf(tester, 1), 'juggle five');
    expect(find.text('7/50'), findsOneWidget);
    expect(find.text('11/30'), findsOneWidget);
  });

  testWidgets('the words the owner asked for, and none of the old ones', (
    tester,
  ) async {
    await openForm(tester);
    expect(find.text('Voting starts when someone accepts.'), findsOneWidget);
    expect(find.textContaining('longer later'), findsNothing);
    expect(find.textContaining('never shorter'), findsNothing);
    expect(find.textContaining('worked out from your subject'), findsNothing);
    expect(find.textContaining('work it out from the video'), findsNothing);
    expect(find.text('e.g. Dance, Comedy, Sports'), findsOneWidget);
  });

  test('the old sentences are gone from the page\'s code, not just hidden', () {
    // Comment lines stripped, so the note explaining the change can't pass
    // or fail this.
    final code = File('lib/pages/challenge_metadata_page.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    for (final gone in [
      'never shorter',
      'Energy is worked out',
      'energy is worked out',
      'Skip and we work it out from the video',
    ]) {
      expect(code.contains(gone), isFalse, reason: '"$gone" is still there');
    }
  });
}
