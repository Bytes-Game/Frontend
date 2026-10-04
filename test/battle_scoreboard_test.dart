// The live score of a battle, as a person sees it.
//
// Every test here checks for something that IS on screen as well as for
// what is not, so a scoreboard broken into showing nothing at all cannot
// pass.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_scoreboard.dart';

Map<String, dynamic> standings({
  required String endsAt,
  bool resolved = false,
  int battleDays = 7,
  String yourVote = '',
}) => {
  if (yourVote.isNotEmpty) 'yourVote': yourVote,
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
      'votes': 6,
      'countedVotes': 4.5,
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
      'countedVotes': 3,
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

  Future<List<String>> pump(
    WidgetTester tester, {
    String? viewer,
    Future<ActionResult> Function()? server,
  }) async {
    final votes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BattleScoreboard(
              challengeId: '7',
              viewerId: viewer,
              onVote: (id) {
                votes.add(id);
                return server?.call() ?? Future.value(const ActionResult(true));
              },
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
    // Every vote cast, the same number as everywhere else...
    expect(find.text('6'), findsOneWidget, reason: "maya's six votes");
    expect(find.text('4.5'), findsNothing);
    // ...and the score that decides it, said once, with why.
    expect(
      find.text('Counting genuine votes only: maya 4.5 – leo 3. Why?'),
      findsOneWidget,
    );
    expect(find.text('Challenger'), findsOneWidget);
    expect(find.text('Answer'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);

    final buttons = find.widgetWithText(FilledButton, 'Vote');
    expect(buttons, findsNWidgets(2));
    expect(find.byKey(const ValueKey('your_vote')), findsNothing);
    await tester.tap(buttons.at(0));
    await tester.pumpAndSettle();
    // The creator's side by the challenge's own id, as every vote dialog
    // does.
    expect(votes, ['7']);
  });

  testWidgets('the creator cannot vote, and nobody can make it longer', (
    tester,
  ) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
      200,
    );
    await pump(tester, viewer: '1');

    expect(find.text('maya'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget);
    expect(find.text('Make it longer'), findsNothing);
    expect(find.byIcon(Icons.more_time), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Vote'), findsNothing);
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

  group('one vote, shown at once, and it can be moved', () {
    setUp(() {
      answer = (_) => http.Response(
        json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
        200,
      );
    });

    Finder yours() => find.byKey(const ValueKey('your_vote'));
    double rowOf(WidgetTester t, String name) => t.getCenter(find.text(name)).dy;

    testWidgets('a tap shows the vote before the server has answered', (
      tester,
    ) async {
      final reply = Completer<ActionResult>();
      final votes = await pump(
        tester,
        viewer: '9',
        server: () => reply.future,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(1));
      await tester.pump();

      // The server has not answered, and it already shows: leo's count is
      // up by one and his button reads "Your vote".
      expect(votes, ['12']);
      // (leo also has 4 likes, so "4" shows twice.)
      expect(find.text('3'), findsNothing);
      expect(find.text('4'), findsNWidgets(2), reason: '3 votes + yours');
      expect(yours(), findsOneWidget);
      expect(tester.getCenter(yours()).dy, closeTo(rowOf(tester, 'leo'), 30));
      expect(sent, hasLength(1), reason: 'nothing waited on a reload');

      reply.complete(const ActionResult(true));
      await tester.pumpAndSettle();
      // Then the server's own count, quietly.
      expect(sent, hasLength(2));
      expect(yours(), findsOneWidget);
    });

    testWidgets('voting for the other side moves the vote: one down, one up', (
      tester,
    ) async {
      // The server answers the first vote at once and holds the second, so
      // what shows is the move itself, before any fresh count.
      final second = Completer<ActionResult>();
      var calls = 0;
      final votes = await pump(
        tester,
        viewer: '9',
        server: () =>
            calls++ == 0 ? Future.value(const ActionResult(true)) : second.future,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(1));
      await tester.pumpAndSettle();
      // The other side still offers a vote.
      final other = find.widgetWithText(FilledButton, 'Vote');
      expect(other, findsOneWidget);
      await tester.tap(other);
      await tester.pump();
      expect(votes, ['12', '7']);
      expect(find.text('7'), findsOneWidget, reason: "maya's 6 + the vote");
      // The fake count still says 3 for leo (it never had the first vote),
      // and the move takes one off: 2. (maya's 2 shares show "2" too.)
      expect(find.text('3'), findsNothing);
      expect(find.text('2'), findsNWidgets(2), reason: 'one taken off leo');
      expect(tester.getCenter(yours()).dy, closeTo(rowOf(tester, 'maya'), 30));
      second.complete(const ActionResult(true));
      await tester.pumpAndSettle();
    });

    testWidgets('a tap on "Your vote" says how to change it, and sends '
        'nothing', (tester) async {
      final votes = await pump(tester, viewer: '9');
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(0));
      await tester.pumpAndSettle();
      await tester.tap(yours());
      await tester.pump();
      expect(find.textContaining('To change it, tap Vote'), findsOneWidget);
      expect(votes, ['7']);
    });

    testWidgets('a vote cast before shows from the start, and can still be '
        'moved', (tester) async {
      answer = (_) => http.Response(
        json.encode(standings(endsAt: '2099-10-04T10:00:00Z', yourVote: '12')),
        200,
      );
      await pump(tester, viewer: '9');
      expect(yours(), findsOneWidget);
      expect(tester.getCenter(yours()).dy, closeTo(rowOf(tester, 'leo'), 30));
      expect(find.text('3'), findsOneWidget, reason: 'the count is not bumped');
      // maya's side offers the move.
      final other = find.widgetWithText(FilledButton, 'Vote');
      expect(other, findsOneWidget);
      expect(tester.getCenter(other).dy, closeTo(rowOf(tester, 'maya'), 30));
    });

    testWidgets('turned down: taken back, with why', (tester) async {
      await pump(
        tester,
        viewer: '9',
        server: () async => const ActionResult(false, 'This battle has ended.'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(1));
      await tester.pumpAndSettle();
      expect(find.text('This battle has ended.'), findsOneWidget);
      expect(yours(), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Vote'), findsNWidgets(2));
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('a move that is turned down goes back to where it was', (
      tester,
    ) async {
      answer = (_) => http.Response(
        json.encode(standings(endsAt: '2099-10-04T10:00:00Z', yourVote: '12')),
        200,
      );
      await pump(
        tester,
        viewer: '9',
        server: () async => const ActionResult(false, 'Vote failed. Try again.'),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Vote'));
      await tester.pumpAndSettle();
      expect(find.text('Vote failed. Try again.'), findsOneWidget);
      expect(tester.getCenter(yours()).dy, closeTo(rowOf(tester, 'leo'), 30));
      expect(find.text('6'), findsOneWidget, reason: "maya's count unchanged");
    });
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
      3,
      reason: 'every way a challenge gets posted must send the length: a '
          'video prepared while typing, a video sent at Post, and a photo',
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
