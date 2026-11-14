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
import 'package:myapp/widgets/versus_bar.dart';

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
    bool reduceMotion = false,
  }) async {
    final votes = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // The phone's own "reduce motion" setting.
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: Scaffold(
              body: SingleChildScrollView(
                child: BattleScoreboard(
                  challengeId: '7',
                  viewerId: viewer,
                  onVote: (id) {
                    votes.add(id);
                    return server?.call() ??
                        Future.value(const ActionResult(true));
                  },
                ),
              ),
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

    /// Lets a number finish rolling to its new value: a few frames, for a
    /// little longer than one roll takes. (An animation begins on the
    /// frame after it is asked for, so one pump of exactly its length
    /// stops a frame short.)
    Future<void> rolled(WidgetTester t) async {
      final frames = RollingCount.roll.inMilliseconds ~/ 100 + 3;
      for (var i = 0; i < frames; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }
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
      expect(find.text('4'), findsNWidgets(2), reason: '3 votes + yours');
      expect(yours(), findsOneWidget);
      expect(tester.getCenter(yours()).dy, closeTo(rowOf(tester, 'leo'), 30));
      // The old count rolls away under the new one: for a moment both are
      // there. Then it has gone, and the server still has not answered.
      expect(find.text('3'), findsOneWidget, reason: 'the 3 is rolling out');
      await rolled(tester);
      expect(find.text('3'), findsNothing);
      expect(find.text('4'), findsNWidgets(2));
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
      expect(find.text('2'), findsNWidgets(2), reason: 'one taken off leo');
      // The old counts roll away; a moment later they have gone, with the
      // second answer still held.
      await rolled(tester);
      expect(find.text('3'), findsNothing);
      expect(find.text('6'), findsNothing);
      expect(find.text('2'), findsNWidgets(2));
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

  group('the bar between the two sides', () {
    VersusBarPainter bar(WidgetTester t) =>
        t
                .widget<CustomPaint>(find.byKey(const ValueKey('versus_bar')))
                .painter!
            as VersusBarPainter;

    /// The usual score (maya 6, leo 3, maya ahead), changed by [edit].
    http.Response Function(http.Request) score([
      void Function(List<Map<String, dynamic>> sides)? edit,
    ]) {
      final st = standings(endsAt: '2099-10-04T10:00:00Z');
      edit?.call((st['participants'] as List).cast<Map<String, dynamic>>());
      return (_) => http.Response(json.encode(st), 200);
    }

    testWidgets('leans toward whoever has more votes, and the one ahead '
        'glows', (tester) async {
      answer = score();
      await pump(tester, viewer: '9');

      // One bar for the two of them, not one under each.
      expect(find.byKey(const ValueKey('versus_bar')), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final p = bar(tester);
      // maya is on the left with 6 of the 9 votes.
      expect(p.seam.value, closeTo(6 / 9, 0.001));
      expect(p.leader, -1);
      expect(p.glow, VersusBarPainter.restGlow);
      expect(find.text('67%'), findsOneWidget);
      expect(find.text('33%'), findsOneWidget);
      // And the page has come to rest: nothing is still moving.
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a vote moves it: the seam slides, the glow flares and '
        'settles, and the share rolls to its new number', (tester) async {
      answer = score();
      final reply = Completer<ActionResult>();
      await pump(tester, viewer: '9', server: () => reply.future);
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // On its way: between where it was and where it is going.
      final moving = bar(tester);
      expect(moving.seam.value, lessThan(6 / 9));
      expect(moving.seam.value, greaterThan(0.6));
      expect(moving.glow, greaterThan(VersusBarPainter.restGlow));
      expect(find.text('60%'), findsOneWidget, reason: 'there from the start');

      // Then at rest: 6 against 4, the glow back to its usual strength,
      // the old numbers gone. The server has still not answered.
      await tester.pumpAndSettle();
      final rested = bar(tester);
      expect(rested.seam.value, closeTo(0.6, 0.001));
      expect(rested.glow, VersusBarPainter.restGlow);
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('67%'), findsNothing);
      expect(find.text('33%'), findsNothing);
      expect(sent, hasLength(1));
      reply.complete(const ActionResult(true));
      await tester.pumpAndSettle();
    });

    testWidgets('level votes and nobody ahead: half each, and no glow', (
      tester,
    ) async {
      answer = score((sides) {
        for (final p in sides) {
          p['votes'] = 3;
          p['leading'] = false;
        }
      });
      await pump(tester, viewer: '9');
      final p = bar(tester);
      expect(p.seam.value, 0.5);
      expect(p.leader, 0);
      expect(p.glow, 0);
      expect(find.text('50%'), findsNWidgets(2));
    });

    testWidgets('nobody has voted yet: half each, and no glow', (
      tester,
    ) async {
      answer = score((sides) {
        for (final p in sides) {
          p['votes'] = 0;
          p['leading'] = false;
        }
      });
      await pump(tester, viewer: '9');
      final p = bar(tester);
      expect(p.seam.value, 0.5);
      expect(p.glow, 0);
    });

    testWidgets('level on votes but ahead on likes: the bar is half each, '
        'and the glow is on whoever the server says is ahead', (tester) async {
      answer = score((sides) {
        for (final p in sides) {
          p['votes'] = 3;
        }
        sides[0]['leading'] = false;
        sides[1]['leading'] = true;
      });
      await pump(tester, viewer: '9');
      final p = bar(tester);
      expect(p.seam.value, 0.5);
      expect(p.leader, 1, reason: 'leo, on the right');
      expect(p.glow, VersusBarPainter.restGlow);
    });

    testWidgets('a phone set to reduce motion: the bar is in its new place '
        'at once, and nothing slides or flares', (tester) async {
      answer = score();
      final reply = Completer<ActionResult>();
      await pump(
        tester,
        viewer: '9',
        server: () => reply.future,
        reduceMotion: true,
      );
      expect(bar(tester).seam.value, closeTo(6 / 9, 0.001));
      await tester.tap(find.widgetWithText(FilledButton, 'Vote').at(1));
      await tester.pump();
      await tester.pump();

      final p = bar(tester);
      expect(p.seam.value, closeTo(0.6, 0.001));
      expect(p.glow, VersusBarPainter.restGlow);
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('67%'), findsNothing, reason: 'no roll either');
      reply.complete(const ActionResult(true));
      await tester.pumpAndSettle();
    });

    testWidgets('three sides: each keeps a bar of its own', (tester) async {
      final st = standings(endsAt: '2099-10-04T10:00:00Z');
      final sides = (st['participants'] as List).cast<Map<String, dynamic>>();
      // A list of its own: the one in the map only takes the two it has.
      st['participants'] = <Map<String, dynamic>>[
        ...sides,
        {
          ...sides[1],
          'userId': '3',
          'username': 'nina',
          'responseId': '13',
          'votes': 1,
          'rank': 3,
        },
      ];
      answer = (_) => http.Response(json.encode(st), 200);
      await pump(tester, viewer: '9');
      expect(find.text('nina'), findsOneWidget);
      expect(find.byKey(const ValueKey('versus_bar')), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    });
  });

  group('a number that rolls', () {
    Future<void> show(WidgetTester t, double value) => t.pumpWidget(
      MaterialApp(
        home: Center(
          child: RollingCount(
            value: value,
            text: value.toStringAsFixed(0),
            style: const TextStyle(fontSize: 40, height: 1),
          ),
        ),
      ),
    );

    testWidgets('up when it grows: the new one comes from below, and the '
        'old one has gone when the roll ends', (tester) async {
      await show(tester, 3);
      final rest = tester.getTopLeft(find.text('3')).dy;
      await show(tester, 4);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // Both on screen for a moment: the new one below where it will rest.
      expect(find.text('3'), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(tester.getTopLeft(find.text('4')).dy, greaterThan(rest));
      expect(tester.getTopLeft(find.text('3')).dy, lessThan(rest));

      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);
      expect(tester.getTopLeft(find.text('4')).dy, rest);
    });

    testWidgets('down when it drops: the new one comes from above', (
      tester,
    ) async {
      await show(tester, 3);
      final rest = tester.getTopLeft(find.text('3')).dy;
      await show(tester, 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(tester.getTopLeft(find.text('2')).dy, lessThan(rest));
      expect(tester.getTopLeft(find.text('3')).dy, greaterThan(rest));
      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);
      expect(tester.getTopLeft(find.text('2')).dy, rest);
    });

    testWidgets('the same number again does not roll', (tester) async {
      await show(tester, 3);
      await show(tester, 3);
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
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
    // A challenge sends the length chosen; a normal post has no battle.
    expect(form, contains('battleDays: open ? int.parse(_battleDays) : 0'));
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

  group('level on votes', () {
    Map<String, dynamic> level({
      required bool resolved,
      int mayaLikes = 9,
      int leoLikes = 4,
      int mayaRank = 1,
      int leoRank = 2,
    }) {
      final st = standings(
        endsAt: resolved ? '2026-09-27T10:00:00Z' : '2099-10-04T10:00:00Z',
        resolved: resolved,
      );
      final sides = st['participants'] as List;
      for (final p in sides.cast<Map<String, dynamic>>()) {
        p['votes'] = 3;
        p['countedVotes'] = 3;
        p['removedVotes'] = 0;
      }
      sides[0]['countedLikes'] = mayaLikes;
      sides[0]['likes'] = mayaLikes;
      sides[1]['countedLikes'] = leoLikes;
      sides[1]['likes'] = leoLikes;
      sides[0]['rank'] = mayaRank;
      sides[1]['rank'] = leoRank;
      sides[0]['leading'] = mayaRank == 1;
      sides[1]['leading'] = leoRank == 1;
      st['removed'] = <String, int>{};
      return st;
    }

    testWidgets('ahead on likes: it says so, so the mark is not a mystery',
        (tester) async {
      answer = (_) => http.Response(json.encode(level(resolved: false)), 200);
      await pump(tester, viewer: '9');
      expect(find.text('maya'), findsOneWidget);
      expect(find.text('Level on votes. maya is ahead on likes.'),
          findsOneWidget);
    });

    testWidgets('level on everything: a draw if it ended now',
        (tester) async {
      answer = (_) => http.Response(
          json.encode(level(resolved: false, leoLikes: 9, leoRank: 1)), 200);
      await pump(tester, viewer: '9');
      expect(find.text('maya'), findsOneWidget);
      expect(find.textContaining('A draw if it ended now.'), findsOneWidget);
    });

    testWidgets('level on everything when it closed: a draw, and why',
        (tester) async {
      answer = (_) => http.Response(
          json.encode(level(resolved: true, leoLikes: 9, leoRank: 1)), 200);
      await pump(tester, viewer: '9');
      expect(find.text("It's a draw."), findsOneWidget);
      expect(find.text('Level on votes, likes, views and shares.'),
          findsOneWidget);
    });

    testWidgets('more votes: no note, the votes say it', (tester) async {
      answer = (_) => http.Response(
        json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
        200,
      );
      await pump(tester, viewer: '9');
      expect(find.text('maya'), findsOneWidget);
      expect(find.byKey(const ValueKey('tie_break_note')), findsNothing);
    });
  });

  testWidgets('the rule is one tap away, in plain words', (tester) async {
    answer = (_) => http.Response(
      json.encode(standings(endsAt: '2099-10-04T10:00:00Z')),
      200,
    );
    await pump(tester, viewer: '9');
    await tester.tap(find.byKey(const ValueKey('battle_rules')));
    await tester.pumpAndSettle();
    expect(find.text('How the winner is decided'), findsOneWidget);
    expect(find.textContaining('Most votes wins.'), findsOneWidget);
    expect(find.textContaining('the battle is a draw'), findsOneWidget);
  });

  group('the short label on a reel', () {
    BattleStandings st({required bool resolved, required String endsAt,
        int leoRank = 2}) {
      final j = standings(endsAt: endsAt, resolved: resolved);
      final sides = j['participants'] as List;
      sides[1]['rank'] = leoRank;
      sides[1]['leading'] = leoRank == 1;
      return BattleStandings.fromJson(j);
    }

    test('never says "won" before the result is in', () {
      expect(st(resolved: false, endsAt: '2026-01-01T00:00:00Z').shortState,
          'Counting');
      expect(st(resolved: true, endsAt: '2026-01-01T00:00:00Z').shortState,
          'maya won');
      expect(st(resolved: true, endsAt: '2026-01-01T00:00:00Z', leoRank: 1)
          .shortState, 'Draw');
      expect(st(resolved: false, endsAt: '2099-01-01T00:00:00Z').shortState,
          '');
    });

    test('the reel uses it', () {
      final code = File('lib/widgets/smart_reels_feed.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, contains('st.shortState'));
    });
  });
}
