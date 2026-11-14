// The win moment, on the real battle page.
//
// The moment itself is tested in win_moment_test.dart. This is the wire
// from the page to it: the person who won a decided battle sees the
// trophy when they open it, once; nobody else does.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/celebrated_wins.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/win_moment.dart';

/// The battle on the server: maya (id 9) against leo (id 8).
late bool decided;

/// Who came first: 'maya', 'leo', or 'draw'.
late String first;
late int mayaVotes;
late int leoVotes;

/// How many of maya's votes count towards the result. Null: all of them.
double? mayaCounted;

/// A third person in the battle, or null.
String? thirdSide;

void fakeServer() {
  decided = true;
  first = 'maya';
  mayaVotes = 12;
  leoVotes = 9;
  mayaCounted = null;
  thirdSide = null;
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
            'creatorLeague': 'Gold',
            'videoUrl': 'https://x/1.mp4',
            'prefix': 'Who can',
            'subject': 'dance on a moving bus',
            'status': decided ? 'completed' : 'active',
            'visibility': 'arena',
            'likes': 10,
            'views': 100,
            'commentCount': 0,
            'voteCount': mayaVotes + leoVotes,
            'shareCount': 0,
            'createdAt': '2026-09-20T10:00:00Z',
          },
          'responses': [
            {
              'id': '77',
              'challengeId': '1',
              'responderId': '8',
              'responderUsername': 'leo',
              'responderLeague': 'Silver',
              'videoUrl': 'https://x/r.mp4',
              'likes': 5,
              'views': 50,
            },
          ],
          'votes': [],
          'canAccept': false,
          'leagueMessage': '',
        };
      } else if (p.endsWith('/comments')) {
        body = [];
      } else if (p.endsWith('/standings')) {
        final ends = decided
            ? DateTime.now().subtract(const Duration(days: 1))
            : DateTime.now().add(const Duration(days: 2));
        body = {
          'challengeId': '1',
          'status': decided ? 'completed' : 'active',
          'battleDays': 7,
          'acceptedAt': DateTime.now()
              .subtract(const Duration(days: 8))
              .toIso8601String(),
          'endsAt': ends.toIso8601String(),
          'resolved': decided,
          'participants': [
            {
              'userId': '9',
              'username': 'maya',
              'role': 'creator',
              'votes': mayaVotes,
              'countedVotes': mayaCounted ?? mayaVotes,
              'likes': 10,
              'views': 100,
              'shares': 0,
              'rank': first == 'leo' ? 2 : 1,
              'leading': first != 'leo',
            },
            {
              'userId': '8',
              'username': 'leo',
              'role': 'responder',
              'responseId': '77',
              'votes': leoVotes,
              'countedVotes': leoVotes,
              'likes': 5,
              'views': 50,
              'shares': 0,
              'rank': first == 'maya' ? 2 : 1,
              'leading': first != 'maya',
            },
            if (thirdSide != null)
              {
                'userId': '7',
                'username': thirdSide,
                'role': 'responder',
                'responseId': '78',
                'votes': 2,
                'countedVotes': 2,
                'likes': 1,
                'views': 20,
                'shares': 0,
                'rank': 3,
                'leading': false,
              },
          ],
        };
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

/// Opens the battle's page as the account [me]: '9' is maya, '8' is leo,
/// anybody else is watching.
Future<void> openAs(WidgetTester t, String me) async {
  t.view.physicalSize = const Size(400, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: me,
        username: 'me',
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
      child: MaterialApp(
        // A new page each time, as opening it again is.
        home: ChallengeDetailPage(key: UniqueKey(), challengeId: '1'),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Lets the moment run its length and take itself away.
Future<void> letItFinish(WidgetTester t) async {
  for (var i = 0; i < 32; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await CelebratedWins.resetForTest();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('the winner opens their decided battle: the trophy, who it '
      'was against and the score, then the page as it was', (t) async {
    await openAs(t, '9');

    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('You won!'), findsOneWidget);
    expect(find.text('Against leo, 12 votes to 9.'), findsOneWidget);
    // The page is all there under it, saying the same.
    expect(find.text('You won.'), findsOneWidget);

    await letItFinish(t);
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('You won.'), findsOneWidget);
    expect(find.text('Live score'), findsOneWidget);
  });

  testWidgets('once: opening the same battle again shows the page and no '
      'trophy, also after the app has been closed', (t) async {
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsOneWidget);
    await letItFinish(t);

    await openAs(t, '9');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('You won.'), findsOneWidget);

    // Closed and opened: memory is gone, the phone's note is not.
    await CelebratedWins.resetForTest();
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('You won.'), findsOneWidget);
  });

  testWidgets('the one who lost sees who won, and no trophy', (t) async {
    await openAs(t, '8');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('maya won.'), findsOneWidget);
    expect(find.text('You won.'), findsNothing);
  });

  testWidgets('somebody watching sees who won, and no trophy', (t) async {
    await openAs(t, '55');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('maya won.'), findsOneWidget);
  });

  testWidgets('a battle still running: no trophy for whoever is ahead', (
    t,
  ) async {
    decided = false;
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('You won.'), findsNothing);
    expect(find.text('Live score'), findsOneWidget);
  });

  testWidgets('a draw: nobody gets a trophy', (t) async {
    first = 'draw';
    mayaVotes = 9;
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text("It's a draw."), findsOneWidget);
  });

  testWidgets('won on likes with the votes level: the trophy, without a '
      'score that would read as a tie', (t) async {
    mayaVotes = 9;
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('Against leo.'), findsOneWidget);
    await letItFinish(t);
  });

  testWidgets('won though the other side shows more votes, because some of '
      'theirs did not count: the trophy, and no score that reads as a '
      'loss', (t) async {
    first = 'leo';
    mayaVotes = 10;
    mayaCounted = 6.5;
    await openAs(t, '8');
    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('Against maya.'), findsOneWidget);
    expect(find.textContaining('votes to'), findsNothing);
    await letItFinish(t);
  });

  testWidgets('one vote is "1 vote", not "1 votes"', (t) async {
    mayaVotes = 1;
    leoVotes = 0;
    await openAs(t, '9');
    expect(find.text('Against leo, 1 vote to 0.'), findsOneWidget);
    await letItFinish(t);
  });

  testWidgets('against more than one person: the trophy, and nobody named', (
    t,
  ) async {
    thirdSide = 'zed';
    await openAs(t, '9');
    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('You won!'), findsOneWidget);
    expect(find.textContaining('Against'), findsNothing);
    await letItFinish(t);
  });

  testWidgets('the answer side wins: its owner gets the trophy too', (t) async {
    first = 'leo';
    mayaVotes = 3;
    await openAs(t, '8');
    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('Against maya, 9 votes to 3.'), findsOneWidget);
    await letItFinish(t);
  });
}
