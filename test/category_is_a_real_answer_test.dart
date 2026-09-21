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
//   * the picker starts on NOTHING, and skipping it sends "" — the server's
//     own word for "nobody said"
//   * "other" is not offered at all, so every pick means something
//
// Picking one is OPTIONAL. It can be, because the server does not need it:
// the transcode worker reads what is spoken in the video and written on its
// screen, and that reading BEATS a creator's pick in the ranker
// (categoryFromEvidence in the backend's content_tags.go). A pick is extra
// evidence, not a gap that must be filled.
//
// What is never allowed is an answer nobody gave. That is the whole bug.
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

      expect(find.text('Skip and we work it out from the video'),
          findsOneWidget,
          reason: 'A picker that opens already showing an answer is how the '
              'field stopped meaning anything.');
      // And it is not quietly sitting on a real category either.
      for (final c in ContentCategories.choosable) {
        final shown = c[0].toUpperCase() + c.substring(1);
        expect(find.text(shown), findsNothing,
            reason: 'Nothing should be pre-selected, least of all "$shown".');
      }
    });

    testWidgets('says what happens if you skip it', (tester) async {
      await openForm(tester);

      expect(find.text('Skip and we work it out from the video'),
          findsOneWidget,
          reason: 'Leaving it blank is a supported answer, so the form has '
              'to say so. Silence here reads as a field you forgot.');
      expect(find.text('CATEGORY (OPTIONAL)'), findsOneWidget);
    });

    testWidgets('picking one still works', (tester) async {
      await openForm(tester);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Comedy').last);
      await tester.pumpAndSettle();

      // Checking for PRESENCE. Every other check in this group is about
      // something NOT being shown, and a picker broken so badly it renders
      // nothing at all would sail through every one of them.
      expect(find.text('Comedy'), findsOneWidget);
      expect(find.text('Skip and we work it out from the video'), findsNothing);
    });

    testWidgets('posting without one is allowed', (tester) async {
      await openForm(tester);

      // Subject is genuinely required and starts empty, so fill it — other-
      // wise this test would pass on the subject blocking the post and prove
      // nothing about the category. (Prefix ships with default text.)
      await tester.enterText(find.byType(TextFormField).at(1), 'pranks');
      await tester.pump();

      await tester.tap(find.text('Post Challenge'));
      await tester.pump();

      // Nothing stops the submit on account of the category. The page gets
      // as far as the signed-in check, which is the step AFTER validation —
      // so seeing its message is proof the form validated.
      expect(find.text('You need to be signed in to post a challenge.'),
          findsOneWidget,
          reason: 'If the form refused here, the category would be blocking '
              'the post — which is the behaviour this change removes.');
    });
  });

  group('skipping it reaches the server as "nobody said"', () {
    // The point of the whole change. If a skipped picker arrives at the
    // server as any real-looking category, the server believes the creator
    // answered and stops preferring what it read off the video.

    test('createChallenge sends an empty category when none was picked', () async {
      Map<String, dynamic>? sent;
      ApiService.useClient(MockClient((req) async {
        sent = json.decode(req.body) as Map<String, dynamic>;
        return http.Response(json.encode({'id': '1'}), 201);
      }));
      addTearDown(() => ApiService.useClient(http.Client()));

      await ApiService.createChallenge(
        creatorId: 'u1',
        videoUrl: 'https://example.invalid/v.mp4',
        prefix: 'Who is better at',
        subject: 'pranks',
        visibility: 'arena',
      );

      expect(sent, isNotNull);
      expect(sent!['category'], '',
          reason: 'Anything else here is the app answering a question the '
              'creator did not answer. "other" would be read as a shrug by '
              'luck rather than by design, and any real category would be '
              'read as a claim nobody made.');
    });

    test('and sends the real one when there was a pick', () async {
      // The presence half. A createChallenge that dropped the field entirely
      // would pass the test above.
      Map<String, dynamic>? sent;
      ApiService.useClient(MockClient((req) async {
        sent = json.decode(req.body) as Map<String, dynamic>;
        return http.Response(json.encode({'id': '1'}), 201);
      }));
      addTearDown(() => ApiService.useClient(http.Client()));

      await ApiService.createChallenge(
        creatorId: 'u1',
        videoUrl: 'https://example.invalid/v.mp4',
        prefix: 'Who is better at',
        subject: 'pranks',
        visibility: 'arena',
        category: 'comedy',
      );

      expect(sent!['category'], 'comedy');
    });

    test('the form hands on what was picked, and "" when nothing was', () {
      final src = codeOnly(
          File('lib/pages/challenge_metadata_page.dart').readAsStringSync());
      expect(src, contains("category: _category ?? ''"),
          reason: 'The form must pass the empty string through, not fill the '
              'gap with a category of its own choosing.');
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
