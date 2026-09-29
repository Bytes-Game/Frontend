// Reporting a video that doesn't match its challenge, from the battle page,
// and what a challenge that was taken down looks like.
//
// Each test checks for something that IS there as well as what is not, so a
// page broken into showing nothing cannot pass by having nothing to find.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

/// Reports the page sent: (path, responseId).
late List<(String, String)> reports;

/// The challenge's status as the server reports it.
late String status;

/// When true a report is the one that takes the video down.
late bool takesDown;

void fakeServer() {
  reports = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      Object body = {};
      if (p.endsWith('/challenges/1')) {
        body = {
          'challenge': {
            'id': '1',
            'creatorId': '9',
            'creatorUsername': 'maya',
            'videoUrl': 'https://x/1.mp4',
            'prefix': 'Who can',
            'subject': 'juggle five',
            'status': status,
            'visibility': 'arena',
            'likes': 0,
            'views': 0,
            'createdAt': '2026-09-20T10:00:00Z',
          },
          'responses': [
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
      } else if (p.endsWith('/report')) {
        final sent = json.decode(req.body) as Map<String, dynamic>;
        reports.add((p, sent['responseId'] as String? ?? ''));
        if (takesDown) status = 'completed';
        body = {
          'reported': true,
          'takenDown': takesDown,
          'message': takesDown
              ? "Thanks. It didn't match the challenge, so it has been taken down."
              : 'Thanks for reporting.',
        };
      } else if (p.endsWith('/standings')) {
        body = {'challengeId': '1', 'status': status, 'participants': []};
      } else if (p.endsWith('/comments')) {
        body = [];
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

Future<void> openPage(WidgetTester t, {String me = '1', String name = 'me'}) async {
  t.view.physicalSize = const Size(400, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer();
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: me,
        username: name,
        wins: 0,
        losses: 0,
        followersCount: 0,
        followingCount: 0,
      ),
    );
  EventTracker.instance.dispose();
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: const MaterialApp(home: ChallengeDetailPage(challengeId: '1')),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() {
    status = 'active';
    takesDown = false;
  });
  tearDown(() => ApiService.useClient(http.Client()));

  group('the battle page', () {
    testWidgets('a viewer can report either video, by whose it is', (t) async {
      await openPage(t);
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
      expect(find.text("maya's video doesn't match"), findsOneWidget);
      expect(find.text("leo_beats's video doesn't match"), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('report_77')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_confirm')));
      await settle(t);
      expect(reports, [('/api/v1/challenges/1/report', '77')]);
      expect(find.text('Thanks for reporting.'), findsOneWidget);
    });

    testWidgets('the challenge\'s own video is reported with no answer named',
        (t) async {
      await openPage(t);
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_confirm')));
      await settle(t);
      expect(reports, [('/api/v1/challenges/1/report', '')]);
    });

    testWidgets('the one who answered can report the challenge, not their '
        'own answer', (t) async {
      await openPage(t, me: '8', name: 'leo_beats');
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_')), findsOneWidget);
      expect(find.byKey(const ValueKey('report_77')), findsNothing);
    });

    testWidgets('the challenger can report the answer, and still delete',
        (t) async {
      await openPage(t, me: '9', name: 'maya');
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
      expect(find.byKey(const ValueKey('report_77')), findsOneWidget);
      expect(find.byKey(const ValueKey('report_')), findsNothing);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('when a report takes it down, the page reads the battle '
        'again', (t) async {
      takesDown = true;
      await openPage(t);
      expect(find.text('Final'), findsNothing);
      await t.tap(find.byKey(const ValueKey('detail_more')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_77')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('report_confirm')));
      await settle(t);
      expect(
        find.text(
          "Thanks. It didn't match the challenge, so it has been taken down.",
        ),
        findsOneWidget,
      );
      // The server now says the battle is over; the page shows it.
      expect(find.text('Final'), findsOneWidget);
    });

    testWidgets('a challenge taken down says so, and offers nothing to '
        'report', (t) async {
      status = 'removed';
      await openPage(t);
      expect(find.byKey(const ValueKey('taken_down')), findsOneWidget);
      expect(find.text('Taken down'), findsOneWidget);
      expect(find.byKey(const ValueKey('detail_more')), findsNothing);
      expect(find.byKey(const ValueKey('accept_button')), findsNothing);
    });

    testWidgets('a live challenge has no taken-down notice', (t) async {
      await openPage(t);
      expect(find.text('Who can juggle five?'), findsOneWidget);
      expect(find.byKey(const ValueKey('taken_down')), findsNothing);
    });
  });

  group('the server call', () {
    test('sends which video and reads back what happened', () async {
      String? path;
      Map<String, dynamic>? body;
      ApiService.useClient(MockClient((req) async {
        path = req.url.path;
        body = json.decode(req.body) as Map<String, dynamic>;
        return http.Response(
          '{"reported":true,"takenDown":true,"message":"Gone."}',
          200,
        );
      }));
      final r = await ApiService.reportOffTopic(
        challengeId: '4',
        responseId: '71',
      );
      expect(path, '/api/v1/challenges/4/report');
      expect(body, {'responseId': '71'});
      expect((r.sent, r.takenDown, r.message), (true, true, 'Gone.'));
    });

    test('a refusal comes back in the server\'s words', () async {
      ApiService.useClient(MockClient((req) async =>
          http.Response("You can't report your own video.\n", 403)));
      final r = await ApiService.reportOffTopic(challengeId: '4');
      expect((r.sent, r.takenDown), (false, false));
      expect(r.message, "You can't report your own video.");
    });

    test('a server failure says to try again', () async {
      ApiService.useClient(
          MockClient((req) async => http.Response('boom', 500)));
      final r = await ApiService.reportOffTopic(challengeId: '4');
      expect(r.sent, isFalse);
      expect(r.message, 'Could not send the report. Try again.');
    });
  });

  group('a profile tile', () {
    Widget tile(String status) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              height: 300,
              child: VideoGridTile(
                video: ChallengeModel(
                  id: '1',
                  creatorId: '9',
                  creatorUsername: 'maya',
                  creatorLeague: '',
                  videoUrl: 'https://x/1.mp4',
                  prefix: 'Who can',
                  subject: 'juggle five',
                  visibility: 'arena',
                  status: status,
                  likes: 0,
                  views: 12,
                  createdAt: '',
                  responseCount: 0,
                ),
                onTap: () {},
              ),
            ),
          ),
        );

    testWidgets('a challenge taken down is marked on its owner\'s profile',
        (t) async {
      await t.pumpWidget(tile('removed'));
      expect(find.text('Taken down'), findsOneWidget);
      expect(find.textContaining('juggle five'), findsOneWidget);
    });

    testWidgets('any other is not', (t) async {
      await t.pumpWidget(tile('active'));
      expect(find.text('Taken down'), findsNothing);
      expect(find.textContaining('juggle five'), findsOneWidget);
    });
  });
}
