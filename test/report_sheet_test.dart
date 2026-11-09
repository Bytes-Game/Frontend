// Reporting harm: a video, an answer, a comment or an account, with a
// reason, to a person who reads it (the server's /admin/reports).
//
// Before this, the profile's Report button said "Use the report flow on a
// specific post for now", and the only report anywhere was "doesn't match
// the challenge". The app stores ask for a way to report harmful posts AND
// accounts; these tests hold the app to that.
//
// Each test checks for something that IS there as well as what is not, so
// a sheet broken into showing nothing cannot pass by having nothing to find.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/legal_texts.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/feed_action_bar.dart';
import 'package:myapp/widgets/report_sheet.dart';

/// Every report the app sent to /api/v1/report.
late List<Map<String, dynamic>> sent;

/// What the server answers a report with.
late int status;

/// Whether the challenge on the video page is a plain post (no battles).
late bool plainPost;

void fakeServer() {
  sent = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      Object body = {};
      var code = 200;
      if (p == '/api/v1/report') {
        sent.add(json.decode(req.body) as Map<String, dynamic>);
        code = status;
        body = status == 200
            ? {'id': '4', 'alreadyReported': true}
            : {'id': '4'};
      } else if (p.endsWith('/challenges/1')) {
        body = {
          'challenge': {
            'id': '1',
            'creatorId': '9',
            'creatorUsername': 'maya',
            'videoUrl': 'https://x/1.mp4',
            'prefix': 'Who can',
            'subject': 'juggle five',
            'status': 'active',
            'visibility': 'arena',
            'closedToBattles': plainPost,
            'likes': 0,
            'views': 0,
            'createdAt': '2026-09-20T10:00:00Z',
          },
          'responses': plainPost
              ? []
              : [
                  {
                    'id': '77',
                    'challengeId': '1',
                    'responderId': '8',
                    'responderUsername': 'leo_beats',
                    'videoUrl': 'https://x/r.mp4',
                  },
                ],
          'votes': [],
        };
      } else if (p.endsWith('/comments')) {
        body = [
          {
            'id': '31',
            'challengeId': '1',
            'authorId': '8',
            'authorUsername': 'leo_beats',
            'text': 'you are all idiots',
            'createdAt': '2026-09-20T10:00:00Z',
          },
          {
            'id': '32',
            'challengeId': '1',
            'authorId': '1',
            'authorUsername': 'me',
            'text': 'my own comment',
            'createdAt': '2026-09-20T10:01:00Z',
          },
        ];
      } else if (p.endsWith('/standings')) {
        body = {'challengeId': '1', 'status': 'active', 'participants': []};
      } else if (p.endsWith('/users/maya')) {
        body = {'id': '5', 'username': 'maya', 'followers': 20};
      } else if (p == '/login') {
        code = 403;
        body = {
          'error':
              'This account is suspended for breaking the Community '
              'Guidelines. If you think this is a mistake, email '
              'support@flexete.com.',
          'suspended': true,
        };
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        code,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

DataProvider signedIn({String id = '1', String name = 'me'}) => DataProvider()
  ..setUser(
    UserModel(
      id: id,
      username: name,
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    ),
  );

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> show(WidgetTester t, Widget home, {DataProvider? dp}) async {
  t.view.physicalSize = const Size(420, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer();
  // Signing in starts the activity reports' timer; the test stops it.
  final provider = dp ?? signedIn();
  EventTracker.instance.dispose();
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: provider,
      child: MaterialApp(home: home),
    ),
  );
  await settle(t);
}

/// A button that opens the report sheet the way the app does.
Widget opener(ReportTarget target, String id, {String whose = ''}) => Scaffold(
  body: Builder(
    builder: (ctx) => Center(
      child: TextButton(
        key: const ValueKey('open'),
        onPressed: () =>
            reportHarm(ctx, target: target, targetId: id, whose: whose),
        child: const Text('open'),
      ),
    ),
  ),
);

/// Picks [reason], types [words], and sends.
Future<void> sendReport(
  WidgetTester t,
  String reason, {
  String words = '',
}) async {
  await t.tap(find.byKey(ValueKey('report_reason_$reason')));
  await settle(t);
  if (words.isNotEmpty) {
    await t.enterText(find.byKey(const ValueKey('report_words')), words);
  }
  await t.tap(find.byKey(const ValueKey('report_send')));
  await settle(t);
}

void main() {
  setUp(() {
    status = 201;
    plainPost = false;
  });
  tearDown(() => ApiService.useClient(http.Client()));

  group('the sheet', () {
    testWidgets('offers every reason, then a few words and Send', (t) async {
      await show(t, opener(ReportTarget.video, '1', whose: 'maya'));
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t);
      expect(find.text("Report maya's video"), findsOneWidget);
      for (final (code, label) in reportReasons) {
        expect(
          find.byKey(ValueKey('report_reason_$code')),
          findsOneWidget,
          reason: code,
        );
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('report_send')), findsNothing);

      await t.tap(find.byKey(const ValueKey('report_reason_hate')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_send')), findsOneWidget);
      expect(find.text('Hate speech'), findsOneWidget);

      // Back: the reasons again, nothing sent.
      await t.tap(find.byKey(const ValueKey('report_back')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_reason_spam')), findsOneWidget);
      expect(sent, isEmpty);
    });

    testWidgets('sends what was chosen and says it was sent', (t) async {
      await show(t, opener(ReportTarget.answer, '77', whose: 'leo_beats'));
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t);
      await sendReport(t, 'harassment', words: 'calls me names at 0:12');
      expect(sent, [
        {
          'targetId': '77',
          'targetType': 'response',
          'reason': 'harassment',
          'description': 'calls me names at 0:12',
        },
      ]);
      expect(find.byKey(const ValueKey('report_sheet')), findsNothing);
      expect(
        find.text(reportOutcomeMessage(ReportOutcome.sent)),
        findsOneWidget,
      );
    });

    testWidgets('says what came of it, whatever the server answers', (t) async {
      for (final (code, outcome) in [
        (200, ReportOutcome.alreadySent),
        (404, ReportOutcome.gone),
        (429, ReportOutcome.tooMany),
        (500, ReportOutcome.failed),
      ]) {
        status = code;
        await show(t, opener(ReportTarget.comment, '31'));
        await t.tap(find.byKey(const ValueKey('open')));
        await settle(t);
        await sendReport(t, 'spam');
        expect(
          find.text(reportOutcomeMessage(outcome)),
          findsOneWidget,
          reason: 'a $code',
        );
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 5));
      }
    });

    testWidgets('where somebody may be in danger now, says where to get help '
        'before the report is read', (t) async {
      await show(t, opener(ReportTarget.video, '1'));
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_reason_child_safety')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_urgent_help')), findsOneWidget);
      expect(find.textContaining('112'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('report_back')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_reason_self_harm')));
      await settle(t);
      expect(find.textContaining('14416'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('report_back')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_reason_spam')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_urgent_help')), findsNothing);
      expect(find.byKey(const ValueKey('report_send')), findsOneWidget);
    });
  });

  group('the video page', () {
    Future<void> openMenu(
      WidgetTester t, {
      String me = '1',
      String name = 'me',
    }) async {
      await show(
        t,
        const ChallengeDetailPage(challengeId: '1'),
        dp: signedIn(id: me, name: name),
      );
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
    }

    testWidgets('a viewer can report either video as harmful, by whose it is', (
      t,
    ) async {
      await openMenu(t);
      expect(find.text("Report maya's video"), findsOneWidget);
      expect(find.text("Report leo_beats's video"), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('harm_77')));
      await settle(t);
      await sendReport(t, 'violence');
      expect(sent.single['targetType'], 'response');
      expect(sent.single['targetId'], '77');
      expect(sent.single['reason'], 'violence');
    });

    testWidgets("the challenge's own video is reported as the post itself", (
      t,
    ) async {
      await openMenu(t);
      await t.tap(find.byKey(const ValueKey('harm_')));
      await settle(t);
      await sendReport(t, 'sexual_content');
      expect(sent.single['targetType'], 'challenge');
      expect(sent.single['targetId'], '1');
    });

    testWidgets('your own video is not offered', (t) async {
      await openMenu(t, me: '8', name: 'leo_beats');
      expect(find.byKey(const ValueKey('harm_')), findsOneWidget);
      expect(find.byKey(const ValueKey('harm_77')), findsNothing);
    });

    testWidgets('a plain post can be reported as harmful, though it answers '
        'no challenge', (t) async {
      plainPost = true;
      await openMenu(t);
      expect(find.byKey(const ValueKey('harm_')), findsOneWidget);
      // "Doesn't match" needs a challenge to match.
      expect(find.byKey(const ValueKey('report_')), findsNothing);
    });
  });

  group('an account', () {
    testWidgets("the profile's Report sends a report on the account", (
      t,
    ) async {
      await show(
        t,
        ProfilePage(
          user: UserModel(
            id: '5',
            username: 'maya',
            wins: 0,
            losses: 0,
            followersCount: 0,
            followingCount: 0,
          ),
          isEmbedded: false,
        ),
      );
      await t.tap(find.byTooltip('More'));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('profile_report')));
      await settle(t);
      expect(find.text('Report @maya'), findsOneWidget);
      // The old placeholder is gone.
      expect(
        find.textContaining('report flow on a specific post'),
        findsNothing,
      );
      await sendReport(t, 'impersonation', words: 'pretends to be me');
      expect(sent, [
        {
          'targetId': '5',
          'targetType': 'user',
          'reason': 'impersonation',
          'description': 'pretends to be me',
        },
      ]);
    });

    testWidgets('a suspended account is told why it cannot sign in', (t) async {
      FlutterSecureStorage.setMockInitialValues({});
      fakeServer();
      EventTracker.instance.dispose();
      await t.binding.setSurfaceSize(const Size(430, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider(create: (_) => DataProvider()),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ],
          child: const MaterialApp(home: LoginScreen()),
        ),
      );
      await settle(t);
      await t.enterText(
        find.byKey(const ValueKey('login_username')),
        'mod_creator',
      );
      await t.enterText(
        find.byKey(const ValueKey('login_password')),
        'password1234',
      );
      await t.ensureVisible(find.byKey(const ValueKey('login_submit')));
      await t.tap(find.byKey(const ValueKey('login_submit')));
      await settle(t);
      expect(
        find.textContaining('suspended for breaking the Community'),
        findsOneWidget,
      );
    });
  });

  group('a comment', () {
    testWidgets("press and hold somebody else's comment to report it", (
      t,
    ) async {
      await show(
        t,
        const Scaffold(body: ChallengeCommentSheet(challengeId: '1')),
      );
      expect(find.text('you are all idiots'), findsOneWidget);
      await t.longPress(find.text('you are all idiots'));
      await settle(t);
      expect(find.text("Report leo_beats's comment"), findsOneWidget);
      await sendReport(t, 'harassment');
      expect(sent.single['targetType'], 'comment');
      expect(sent.single['targetId'], '31');
    });

    testWidgets('your own comment: holding it does not offer a report', (
      t,
    ) async {
      await show(
        t,
        const Scaffold(body: ChallengeCommentSheet(challengeId: '1')),
      );
      expect(find.text('my own comment'), findsOneWidget);
      await t.longPress(find.text('my own comment'));
      await settle(t);
      expect(find.byKey(const ValueKey('report_sheet')), findsNothing);
    });
  });

  group('the documents', () {
    String all(LegalDocument d, String section) => d.sections
        .firstWhere(
          (s) => s.title == section,
          orElse: () => const LegalSection('', []),
        )
        .body
        .join(' ');

    test('the Community Guidelines say how to report, and who reads it', () {
      final reporting = all(communityGuidelines, 'Reporting');
      for (final want in [
        'choose Report',
        'press and hold',
        'A person reads every report',
        'Nobody is told who reported it',
        AppConstants.grievanceEmail,
      ]) {
        expect(reporting, contains(want));
      }
    });

    test(
      'the Terms name where complaints go, and how fast they are answered',
      () {
        final complaints = all(termsOfService, 'Complaints');
        for (final want in [
          'Grievance Officer',
          AppConstants.grievanceEmail,
          'within 24 hours',
          '15 days',
          'Grievance Appellate Committee',
        ]) {
          expect(complaints, contains(want));
        }
      },
    );

    test('the Privacy Policy gives the complaints address too', () {
      expect(
        all(privacyPolicy, 'Contact'),
        contains(AppConstants.grievanceEmail),
      );
    });
  });
}
