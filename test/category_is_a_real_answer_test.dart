// The Category picker was doing nothing, and looked like it was working.
//
// The server reads "other" as *nobody said* — not as "this video is an
// other", as no answer at all (usableCategory in the backend's
// content_tags.go). The dropdown on the upload form started on "Other".
//
// So every creator who did not open that dropdown posted a video the server
// filed as undescribed, while the form in front of them looked filled in.
// A check of the live platform found 43 of 44 videos with no creator
// category. Nothing the picker produced had ever been read.
//
// The fix is two-sided and both sides matter:
//
//   * the picker starts on NOTHING and will not let the form post until a
//     real category is chosen
//   * "other" is not offered at all, so every pick means something
//
// These tests hold both in place, plus the quieter copies of the same
// default that sat in the API layer and the interrupted-upload restore.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

/// Source with every comment line removed.
///
/// A test that reads source has to do this. Two tests in this repo once
/// matched the words in the comment explaining a trap rather than the code
/// that avoids it, and passed against code with the trap wide open.
String codeOnly(String source) => source
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  group('the list of categories', () {
    test('nothing a person can pick means "nobody said"', () {
      for (final shrug in ContentCategories.meansNobodySaid) {
        expect(ContentCategories.choosable, isNot(contains(shrug)),
            reason: 'The server throws "$shrug" away. Offering it gives the '
                'creator a choice that does nothing — which is exactly the '
                'bug that left 43 of 44 videos undescribed.');
      }
    });

    test('but there is still plenty to pick from', () {
      // The reverse check. "Offer nothing at all" would pass the test above
      // and break the form completely.
      expect(ContentCategories.choosable.length, greaterThan(10));
      expect(ContentCategories.choosable, contains('comedy'));
      expect(ContentCategories.choosable, contains('dance'));
    });

    test('the picker is the full vocabulary minus exactly "other"', () {
      final missing = ContentCategories.vocabulary
          .where((c) => !ContentCategories.choosable.contains(c))
          .toList();
      expect(missing, ['other'],
          reason: 'Anything else dropped from the picker is a category the '
              'server understands that nobody can ever choose.');
      for (final c in ContentCategories.choosable) {
        expect(ContentCategories.vocabulary, contains(c),
            reason: '"$c" is offered here but the server does not know it, '
                'so picking it is the same as picking nothing.');
      }
    });

    test('isRealAnswer matches what the server actually does', () {
      // Mirrors usableCategory() in content_tags.go.
      expect(ContentCategories.isRealAnswer('comedy'), isTrue);
      expect(ContentCategories.isRealAnswer('other'), isFalse);
      expect(ContentCategories.isRealAnswer('general'), isFalse);
      expect(ContentCategories.isRealAnswer(''), isFalse);
      expect(ContentCategories.isRealAnswer('   '), isFalse);
      expect(ContentCategories.isRealAnswer(null), isFalse);
      // Case and stray spaces are the same shrug wearing a different hat.
      expect(ContentCategories.isRealAnswer('Other'), isFalse);
      expect(ContentCategories.isRealAnswer(' OTHER '), isFalse);
    });
  });

  group('the upload form', () {
    setUp(() {
      // The page fetches prefix and subject suggestions on entry. Answer
      // with empty lists so the test is about the Category field only.
      ApiService.useClient(MockClient((req) async {
        return http.Response(json.encode([]), 200);
      }));
    });

    tearDown(() => ApiService.useClient(http.Client()));

    Future<void> openForm(WidgetTester tester) async {
      // The form is taller than the 800x600 default test window, and the
      // Post button sits below the fold — tapping it there silently misses.
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

    testWidgets('opens with no category chosen', (tester) async {
      await openForm(tester);

      expect(find.text('Choose a category'), findsOneWidget,
          reason: 'A picker that opens already showing an answer is how the '
              'field stopped meaning anything.');
      // And it is not quietly sitting on a real category either.
      for (final c in ContentCategories.choosable) {
        final shown = c[0].toUpperCase() + c.substring(1);
        expect(find.text(shown), findsNothing,
            reason: 'Nothing should be pre-selected, least of all "$shown".');
      }
    });

    testWidgets('refuses to post until a category is picked', (tester) async {
      await openForm(tester);

      await tester.tap(find.text('Post Challenge'));
      await tester.pump();

      expect(find.text('Pick what this video is about'), findsOneWidget,
          reason: 'Without this the form posts happily and the server files '
              'the video as undescribed.');
    });

    testWidgets('and accepts it once they do', (tester) async {
      await openForm(tester);

      await tester.tap(find.text('Post Challenge'));
      await tester.pump();
      expect(find.text('Pick what this video is about'), findsOneWidget);

      // Open the dropdown and choose one.
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comedy').last);
      await tester.pumpAndSettle();

      // Picking one is itself the answer to "does the field still work".
      // A picker broken so hard it renders nothing would pass the
      // disappearing-error check below all on its own.
      expect(find.text('Comedy'), findsOneWidget);
      expect(find.text('Choose a category'), findsNothing);
      expect(find.text('Pick what this video is about'), findsNothing);
    });
  });

  group('the same default had quieter copies', () {
    // The dropdown was the visible one. These two set the category when the
    // form is not involved at all — an API call made from elsewhere, and an
    // upload restored after the app was killed — and each would have gone
    // on filing videos as undescribed after the form was fixed.

    test('createChallenge does not invent a category', () {
      final src = codeOnly(
          File('lib/services/api_service.dart').readAsStringSync());
      expect(src, contains("String category = ''"),
          reason: 'The default must be empty. "other" reads as a real answer '
              'from this side and as no answer from the server, which is how '
              'this went unnoticed.');
      expect(src, isNot(contains("String category = 'other'")));
    });

    test('a restored upload does not invent one either', () {
      final src = codeOnly(
          File('lib/services/upload_job_manager.dart').readAsStringSync());
      expect(src, isNot(contains("category: metaJson['category'] "
          "as String? ?? 'other'")));
      expect(src, contains("category: metaJson['category'] as String? ?? ''"));
    });

    test('nothing in the app starts a category off on "other"', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = codeOnly(f.readAsStringSync());
        for (final line in src.split('\n')) {
          final l = line.trim();
          if (!l.toLowerCase().contains('category')) continue;
          // A category being SET to 'other' as a starting value or a
          // fallback. Reading one back from the server is fine.
          if (RegExp(r"category[^=]*=\s*'other'").hasMatch(l) ||
              RegExp(r"category[^?]*\?\?\s*'other'").hasMatch(l)) {
            offenders.add('${f.path}: $l');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'Each of these tells the server the creator answered when '
              'they did not:\n${offenders.join('\n')}');
    });
  });

  group('the interest picker had it too', () {
    test('it filters the server list instead of showing it raw', () {
      final src = codeOnly(
          File('lib/pages/onboarding_interests_page.dart').readAsStringSync());
      expect(src, contains('ContentCategories.isRealAnswer'),
          reason: 'The server sends its full vocabulary, "other" included. '
              'Shown raw, a new user can tap "other" as an interest — it '
              'counts towards the three this screen asks for and seeds '
              'nothing at all.');
    });
  });
}
