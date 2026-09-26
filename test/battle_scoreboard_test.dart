// The live score of a battle, as a person sees it.
//
// Every test here checks for something that IS on screen as well as for
// what is not, so a scoreboard broken into showing nothing at all cannot
// pass.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_scoreboard.dart';

Map<String, dynamic> standings({
  required String endsAt,
  bool resolved = false,
  int battleDays = 7,
}) => {
  'challengeId': '7',
  'status': resolved ? 'completed' : 'active',
  'battleDays': battleDays,
  'acceptedAt': '2026-09-20T10:00:00Z',
  'endsAt': endsAt,
  'resolved': resolved,
  'participants': [
    {
      'userId': '1',
      'username': 'maya',
      'role': 'creator',
      'responseId': '',
      'votes': 4.5,
      'rawVotes': 6,
      'removedVotes': 1,
      'likes': 9,
      'views': 30,
      'shares': 2,
      'rank': 1,
      'leading': true,
    },
    {
      'userId': '2',
      'username': 'leo',
      'role': 'responder',
      'responseId': '12',
      'votes': 3,
      'rawVotes': 3,
      'removedVotes': 0,
      'likes': 4,
      'views': 21,
      'shares': 1,
      'rank': 2,
      'leading': false,
    },
  ],
  'removed': {'voted without watching': 1},
};

void main() {
  late List<http.Request> sent;
  late http.Response Function(http.Request) answer;

  setUp(() {
    sent = [];
    ApiService.useClient(
      MockClient((req) async {
        sent.add(req);
        return answer(req);
      }),
    );
  });
  tearDown(() => ApiService.useClient(http.Client()));

  Future<List<String>> pump(WidgetTester tester, {String? viewer}) async {
    final votes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BattleScoreboard(
              challengeId: '7',
              viewerId: viewer,
              onVote: (id) async => votes.add(id),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return votes;
  }

  testWidgets('a running battle: both sides, the score, and a vote each', (
    tester,
  ) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
      200,
    );
    final votes = await pump(tester, viewer: '9');

    expect(sent.single.url.path, '/api/v1/challenges/7/standings');
    expect(find.text('maya'), findsOneWidget);
    expect(find.text('leo'), findsOneWidget);
    expect(
      find.text('4.5'),
      findsOneWidget,
      reason: 'a half vote shows as one',
    );
    expect(find.text('Challenger'), findsOneWidget);
    expect(find.text('Answer'), findsOneWidget);
    expect(find.textContaining("1 vote didn't count"), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);

    final buttons = find.widgetWithText(FilledButton, 'Vote');
    expect(buttons, findsNWidgets(2));
    await tester.tap(buttons.at(0));
    await tester.tap(buttons.at(1));
    // The creator's side by the challenge's own id, as every vote dialog
    // does; the answer by its id.
    expect(votes, ['7', '12']);
    expect(
      find.text('Make it longer'),
      findsNothing,
      reason: 'only the person who posted it can',
    );
  });

  testWidgets('the creator can make it longer and cannot vote', (tester) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
      200,
    );
    await pump(tester, viewer: '1');

    expect(find.text('Make it longer'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Vote'), findsNothing);
    expect(find.text('maya'), findsOneWidget);
  });

  testWidgets('a battle whose time is up takes no votes', (tester) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2020-01-01T10:00:00Z')),
      200,
    );
    await pump(tester, viewer: '9');

    expect(find.textContaining('Voting has closed'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Vote'), findsNothing);
    expect(find.text('Closed'), findsOneWidget);
  });

  testWidgets('a decided battle says who won', (tester) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2020-01-01T10:00:00Z', resolved: true)),
      200,
    );
    await pump(tester, viewer: '9');

    expect(find.text('maya won.'), findsOneWidget);
    expect(find.byIcon(Icons.emoji_events), findsOneWidget);
  });

  testWidgets('a score that will not load says so, with a retry', (
    tester,
  ) async {
    answer = (_) => http.Response('boom', 500);
    await pump(tester, viewer: '9');

    expect(find.text("Couldn't load the score."), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
  });

  test('time left reads like a person would say it', () {
    expect(timeLeft(const Duration(days: 3, hours: 4, minutes: 5)), '3d 4h');
    expect(timeLeft(const Duration(hours: 5, minutes: 12)), '5h 12m');
    expect(timeLeft(const Duration(minutes: 12)), '12m');
    expect(timeLeft(const Duration(seconds: 20)), 'under a minute');
  });

  test('the battle page shows the live score and the form offers a length', () {
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(
      code('lib/pages/challenge_detail_page.dart'),
      contains('BattleScoreboard('),
    );
    final form = code('lib/pages/challenge_metadata_page.dart');
    expect(form, contains("_section('Battle length')"));
    expect(form, contains('battleDays: int.parse(_battleDays)'));
    final jobs = code('lib/services/upload_job_manager.dart');
    expect(
      'battleDays: meta.battleDays'.allMatches(jobs).length,
      2,
      reason: 'both ways a challenge gets posted must send the length',
    );
  });

  test('posting sends the chosen length', () async {
    answer = (_) => http.Response('{"id": "7"}', 201);
    await ApiService.createChallenge(
      creatorId: '1',
      videoUrl: 'https://v/x.mp4',
      prefix: 'who',
      subject: 'dances better',
      visibility: 'arena',
      battleDays: 14,
    );
    expect(json.decode(sent.single.body)['battleDays'], 14);
  });
}
