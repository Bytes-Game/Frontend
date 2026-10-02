// The redesigned reel: who is in it, what it asks, and the buttons.
//
// Every test looks for something that IS on screen as well as for what was
// taken away, so a reel broken into showing nothing cannot pass by having
// nothing to find.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/widgets/battle_record_panel.dart' show LeagueEmblem;
import 'package:myapp/widgets/smart_reels_feed.dart';

Map<String, dynamic> battle() => {
  'id': '1',
  'creatorId': '9',
  'creatorUsername': 'maya',
  'creatorLeague': 'Gold',
  'videoUrl': 'https://x/1.mp4',
  'prefix': 'Who can',
  'subject': 'dance on a moving bus',
  'status': 'active',
  'likes': 1280,
  'commentCount': 46,
  'views': 18400,
  // The same numbers the live score below adds up to.
  'voteCount': 21,
  'shareCount': 42,
  'saveCount': 7,
  'createdAt': '2026-09-20T10:00:00Z',
  'responseCount': 1,
  'topResponseId': '77',
  'topResponseUsername': 'leo_beats',
  'topResponseLeague': 'Silver',
  'topResponseVideoUrl': 'https://x/r77.mp4',
  'topResponseLikes': 940,
};

Map<String, dynamic> short() => {
  'id': '2',
  'creatorId': '8',
  'creatorUsername': 'zara',
  'creatorLeague': 'Silver',
  'videoUrl': 'https://x/2.mp4',
  'prefix': 'Who can',
  'subject': 'cook pasta in 5 minutes',
  'status': 'open',
  'likes': 312,
  'views': 5400,
  'createdAt': '2026-09-20T10:00:00Z',
};

/// How many times the app asked for a battle's score.
int standingsAsked = 0;

/// When true the server refuses new comments.
bool refuseComments = false;

/// Comments the app tried to post.
List<String> posted = [];

/// The body of the last vote the app sent.
Map<String, dynamic>? lastVote;

/// When true the answer is ahead in the live score, 14 to 12.
bool answerLeads = false;

/// When true the battle is over and decided.
bool decided = false;

/// When true the live score takes two seconds to come — far longer than
/// the moment the app waits for it, as on a slow server.
bool standingsSlow = false;

/// What the server says a video's views are after a watch; null says
/// nothing, as an older server did.
int? watchViews;

/// When true the comments cannot be read.
bool commentsDown = false;

/// Laid over the video when the battle page reads it — what was done there.
Map<String, dynamic> detailOverride = {};

/// Lists asked for (likes, votes, shares) and shares sent.
List<String> peopleAsked = [];
List<Map<String, dynamic>> sharesSent = [];

/// Views the app reported.
List<Map<String, dynamic>> watchesSent = [];

/// Reports that a video doesn't match its challenge: where each went, and
/// which answer it named.
List<(String, String)> reportsSent = [];


void fakeServer(Map<String, dynamic> first) {
  lastVote = null;
  peopleAsked = [];
  sharesSent = [];
  watchesSent = [];
  reportsSent = [];
  standingsAsked = 0;
  refuseComments = false;
  posted = [];
  ApiService.useClient(
    MockClient((req) async {
      if (req.url.path.endsWith('/challenges/${first['id']}')) {
        return http.Response.bytes(
          utf8.encode(
            json.encode({
              'challenge': {...first, ...detailOverride},
              'responses': [
                if (first['topResponseId'] != null)
                  {
                    'id': first['topResponseId'],
                    'challengeId': first['id'],
                    'responderId': '8',
                    'responderUsername': first['topResponseUsername'],
                    'videoUrl': first['topResponseVideoUrl'],
                  },
              ],
              'votes': [],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.url.path.endsWith('/challenges/vote')) {
        lastVote = json.decode(req.body) as Map<String, dynamic>;
      }
      if (req.url.path.endsWith('/report')) {
        final body = json.decode(req.body) as Map<String, dynamic>;
        reportsSent.add((req.url.path, body['responseId'] as String? ?? ''));
        return http.Response(
          json.encode({'reported': true, 'message': 'Thanks for reporting.'}),
          200,
        );
      }
      if (req.url.path.endsWith('/people')) {
        peopleAsked.add(req.url.queryParameters['what'] ?? '');
        return http.Response(
          json.encode({
            'sides': [
              {
                'username': 'maya',
                'role': 'creator',
                'people': [
                  {'userId': '31', 'username': 'nina', 'at': ''},
                ],
              },
              {
                'username': 'leo_beats',
                'role': 'responder',
                'responseId': '77',
                'people': [
                  {'userId': '32', 'username': 'zoe', 'at': ''},
                ],
              },
            ],
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/watch')) {
        watchesSent.add(json.decode(req.body) as Map<String, dynamic>);
        return http.Response(
          json.encode({'message': 'ok', 'views': ?watchViews}),
          201,
        );
      }
      if (req.url.path.endsWith('/challenges/share')) {
        sharesSent.add(json.decode(req.body) as Map<String, dynamic>);
        return http.Response('{"shares": 43}', 200);
      }
      if (req.url.path.endsWith('/save')) {
        return http.Response('{"saved": true}', 200);
      }
      if (req.url.path.endsWith('/comments') && req.method == 'GET') {
        if (commentsDown) return http.Response('down', 503);
        return http.Response.bytes(
          utf8.encode(
            json.encode([
              {
                'authorUsername': 'sam',
                'text': 'that last move though',
                'createdAt': DateTime.now()
                    .subtract(const Duration(hours: 2))
                    .toUtc()
                    .toIso8601String(),
              },
            ]),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (req.url.path.endsWith('/challenges/comments')) {
        posted.add((json.decode(req.body) as Map)['text'] as String);
        return refuseComments
            ? http.Response('no', 503)
            : http.Response('{"id":"c1"}', 200);
      }
      if (req.url.path.endsWith('/standings')) {
        standingsAsked++;
        if (standingsSlow) await Future<void>.delayed(const Duration(seconds: 2));
        return http.Response.bytes(
          utf8.encode(
            json.encode({
              'challengeId': '1',
              'status': decided ? 'completed' : 'active',
              'resolved': decided,
              'battleDays': 7,
              'acceptedAt': DateTime.now()
                  .subtract(const Duration(days: 1))
                  .toIso8601String(),
              'endsAt': DateTime.now()
                  .add(const Duration(days: 2, hours: 3))
                  .toIso8601String(),
              'participants': [
                {
                  'username': 'maya',
                  'role': 'creator',
                  'votes': 12,
                  'likes': 1280,
                  'views': 6300,
                  'shares': 30,
                  'leading': !answerLeads,
                  'rank': answerLeads ? 2 : 1,
                },
                {
                  'username': 'leo_beats',
                  'role': 'responder',
                  'responseId': '77',
                  'votes': answerLeads ? 14 : 9,
                  'likes': 940,
                  'views': 12100,
                  'shares': 12,
                  'leading': answerLeads,
                  'rank': answerLeads ? 1 : 2,
                },
              ],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      final body = req.url.path.contains('/like')
          ? {'liked': true, 'likes': 1281}
          : req.url.path.contains('/feed')
          ? {
              'items': [
                {'type': 'challenge', 'challenge': first},
              ],
              'hasMore': false,
            }
          : {'ok': true};
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

Future<void> openReel(
  WidgetTester t,
  Map<String, dynamic> first, {
  ChallengeModel? seed,
  String meId = '1',
  String meName = 'me',
}) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer(first);
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: meId,
        username: meName,
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
        home: Scaffold(
          body: SmartReelsFeed(userId: '1', seedChallenge: seed),
        ),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> closeReel(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox()));
  await t.pump(const Duration(seconds: 5));
  ReelDiagnostics.instance.debugReset();
  EventTracker.instance.dispose();
}

void main() {
  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    answerLeads = false;
    decided = false;
    standingsSlow = false;
    watchViews = null;
    commentsDown = false;
    detailOverride = {};
  });

  group('reporting a video that doesn\'t match the challenge', () {
    Future<void> reportFromMenu(WidgetTester t, {bool confirm = true}) async {
      await t.tap(find.byKey(const ValueKey('reel_more')));
      // Two frames: the menu finishes opening, then takes taps.
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.byKey(const ValueKey('reel_report')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('report_dialog')), findsOneWidget);
      await t.tap(confirm
          ? find.byKey(const ValueKey('report_confirm'))
          : find.text('Cancel'));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('somebody else\'s video: the challenger\'s side reports the '
        'challenge\'s own video', (t) async {
      await openReel(t, battle());
      await reportFromMenu(t);
      expect(reportsSent, [('/api/v1/challenges/1/report', '')]);
      expect(find.text('Thanks for reporting.'), findsOneWidget);
      // Not taken down: the reel stays.
      expect(find.textContaining('dance on a moving bus'), findsWidgets);
      await closeReel(t);
    });

    testWidgets('on the answer\'s side it reports the answer', (t) async {
      answerLeads = true; // opens on the answer
      await openReel(t, battle());
      await reportFromMenu(t);
      expect(reportsSent, [('/api/v1/challenges/1/report', '77')]);
      await closeReel(t);
    });

    testWidgets('changing your mind sends nothing', (t) async {
      await openReel(t, battle());
      await reportFromMenu(t, confirm: false);
      expect(reportsSent, isEmpty);
      await closeReel(t);
    });

    testWidgets('your own challenge: delete, and no report', (t) async {
      await openReel(t, battle(), meId: '9', meName: 'maya');
      await t.tap(find.byKey(const ValueKey('reel_more')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete'), findsOneWidget);
      expect(find.byKey(const ValueKey('reel_report')), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pump(const Duration(milliseconds: 400));
      await closeReel(t);
    });

    testWidgets('your own answer on screen: nothing to report or delete', (
      t,
    ) async {
      answerLeads = true;
      await openReel(t, battle(), meId: '8', meName: 'leo_beats');
      expect(find.byKey(const ValueKey('reel_more')), findsNothing);
      await closeReel(t);
    });

    testWidgets('your own answer, but the challenger on screen: that one '
        'can be reported', (t) async {
      await openReel(t, battle(), meId: '8', meName: 'leo_beats');
      await reportFromMenu(t);
      expect(reportsSent, [('/api/v1/challenges/1/report', '')]);
      await closeReel(t);
    });

    testWidgets('after a report the video stays in the feed', (t) async {
      await openReel(t, battle());
      await reportFromMenu(t);
      expect(find.text('Thanks for reporting.'), findsOneWidget);
      expect(find.textContaining('dance on a moving bus'), findsWidgets);
      await closeReel(t);
    });

    testWidgets('in the battle yourself: told a false report costs you; a '
        'viewer is not', (t) async {
      Future<bool> warned() async {
        await t.tap(find.byKey(const ValueKey('reel_more')));
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 100));
        await t.tap(find.byKey(const ValueKey('reel_report')));
        await t.pump(const Duration(milliseconds: 400));
        await t.pump(const Duration(milliseconds: 100));
        final shown =
            find.byKey(const ValueKey('report_in_battle')).evaluate().isNotEmpty;
        await t.tap(find.text('Cancel'));
        await t.pump(const Duration(milliseconds: 400));
        return shown;
      }

      // leo answered; the challenger's side is on screen.
      await openReel(t, battle(), meId: '8', meName: 'leo_beats');
      expect(await warned(), isTrue);
      await closeReel(t);

      await openReel(t, battle());
      expect(await warned(), isFalse);
      await closeReel(t);
    });
  });

  // A few frames: the list's answer arrives between them, not inside one.
  Future<void> settleSheet(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  String count(WidgetTester t, String name) =>
      t.widget<Text>(find.byKey(ValueKey('count_$name'))).data!;

  group('a number under every button', () {
    testWidgets('votes, likes, comments, shares and saves — the same '
        'numbers as the live score', (t) async {
      await openReel(t, battle());
      expect(count(t, 'votes'), '21', reason: '12 + 9');
      expect(count(t, 'likes'), '1.3K', reason: "maya's side, on screen");
      expect(count(t, 'comments'), '46');
      expect(count(t, 'shares'), '42', reason: '30 + 12');
      expect(count(t, 'saves'), '7');
      await closeReel(t);
    });

    testWidgets('when the live score comes in, the reel follows it', (
      t,
    ) async {
      // The feed says 5 votes and 2 shares; the live score says 21 and 42.
      await openReel(t, {...battle(), 'voteCount': 5, 'shareCount': 2});
      expect(standingsAsked, 1);
      expect(count(t, 'votes'), '21');
      expect(count(t, 'shares'), '42');
      await closeReel(t);
    });

    testWidgets('saving and sharing move their numbers', (t) async {
      await openReel(t, battle());
      await t.tap(find.byTooltip('Save'));
      await t.pump(const Duration(milliseconds: 300));
      expect(count(t, 'saves'), '8');
      await t.tap(find.byTooltip('Share'));
      await t.pump(const Duration(milliseconds: 300));
      expect(sharesSent.single, {'challengeId': '1'}, reason: "maya's video");
      expect(count(t, 'shares'), '43', reason: "the server's total");
      await t.pump(const Duration(seconds: 3));
      await closeReel(t);
    });

    testWidgets('for the people in the battle, a number opens who', (
      t,
    ) async {
      // The answerer.
      await openReel(t, battle(), meId: '8', meName: 'leo_beats');
      await t.tap(find.byKey(const ValueKey('count_likes')));
      await settleSheet(t);
      expect(peopleAsked, ['likes']);
      expect(find.text('Liked by 2'), findsOneWidget);
      expect(find.text('nina'), findsOneWidget);
      await t.tapAt(const Offset(20, 40));
      await settleSheet(t);

      await t.tap(find.byKey(const ValueKey('count_votes')));
      await settleSheet(t);
      expect(peopleAsked, ['likes', 'votes']);
      expect(find.text('maya · 1'), findsOneWidget);
      await t.tapAt(const Offset(20, 40));
      await settleSheet(t);

      await t.tap(find.byKey(const ValueKey('count_shares')));
      await settleSheet(t);
      expect(peopleAsked, ['likes', 'votes', 'shares']);
      await t.tapAt(const Offset(20, 40));
      await settleSheet(t);
      await closeReel(t);
    });

    testWidgets('for anyone else, a number is only a number', (t) async {
      await openReel(t, battle());
      await t.tap(find.byKey(const ValueKey('count_likes')));
      await t.pump(const Duration(milliseconds: 400));
      expect(peopleAsked, isEmpty);
      expect(find.textContaining('Liked by'), findsNothing);
      // The number is part of the heart then: a tap likes.
      expect(find.byTooltip('Unlike'), findsOneWidget);
      await closeReel(t);
    });
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('a battle names both people at the top, under the tabs, with '
      'the question at the bottom', (t) async {
    await openReel(t, battle());
    expect(find.text('maya'), findsOneWidget);
    expect(find.text('leo_beats'), findsOneWidget);
    expect(find.text('VS'), findsOneWidget);
    expect(find.text('Who can dance on a moving bus?'), findsOneWidget);
    expect(find.text('18.4K views'), findsOneWidget);
    // No hint line, and no tab on the screen's edge.
    expect(find.textContaining('Swipe'), findsNothing);
    expect(find.byKey(const ValueKey('battle_side_tab')), findsNothing);
    // Names high on the screen, below Home's tabs; the question low.
    final names = t.getCenter(find.text('maya')).dy;
    expect(names, greaterThan(40), reason: 'under the tabs, not on them');
    expect(names, lessThan(160));
    expect(
      t.getCenter(find.text('Who can dance on a moving bus?')).dy,
      greaterThan(600),
    );
    // Side by side on one line.
    expect(t.getCenter(find.text('leo_beats')).dy, names);
    await closeReel(t);
  });

  testWidgets('the sound button is top left, clear of the top-right corner '
      'where the notifications bell sits', (t) async {
    await openReel(t, battle());
    final sound = t.getCenter(find.byKey(const ValueKey('reel_sound')));
    expect(sound.dx, lessThan(60));
    expect(sound.dy, lessThan(60));
    expect(find.byKey(const ValueKey('reel_back')), findsNothing,
        reason: 'a tab of Home has no back arrow');
    await closeReel(t);
  });

  testWidgets('while it runs, the names carry no trophy, no shield and no '
      'mark', (t) async {
    await openReel(t, battle());
    await t.pump(const Duration(milliseconds: 300));
    // The names are there, and maya is ahead 12 to 9...
    expect(find.text('maya'), findsOneWidget);
    expect(find.text('leo_beats'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    // ...and nothing beside either name says so.
    for (final side in ['matchup_challenger', 'matchup_opponent']) {
      final names = find.byKey(ValueKey(side));
      expect(names, findsOneWidget);
      expect(
        find.descendant(of: names, matching: find.byType(Icon)),
        findsNothing,
        reason: 'no trophy by $side',
      );
      expect(
        find.descendant(of: names, matching: find.byType(LeagueEmblem)),
        findsNothing,
        reason: 'no league shield by $side (maya is Gold, leo Silver)',
      );
    }
    expect(find.byKey(const ValueKey('matchup_winner')), findsNothing);
    await closeReel(t);
  });

  testWidgets('once decided, a green bar under the winner\'s name and '
      'nothing on the other', (t) async {
    decided = true;
    answerLeads = true;
    await openReel(t, battle());
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final bar = find.descendant(
      of: find.byKey(const ValueKey('matchup_opponent')),
      matching: find.byKey(const ValueKey('matchup_winner')),
    );
    expect(bar, findsOneWidget, reason: 'leo won 14 to 12');
    final border =
        (t.widget<Container>(bar).decoration! as BoxDecoration).border!
            as Border;
    expect(border.bottom.color, const Color(0xFF30D158));
    expect(
      find.descendant(of: bar, matching: find.text('leo_beats')),
      findsOneWidget,
      reason: 'the bar is under the name',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('matchup_challenger')),
        matching: find.byKey(const ValueKey('matchup_winner')),
      ),
      findsNothing,
    );
    expect(find.byType(LeagueEmblem), findsNothing);
    await closeReel(t);
  });

  group('a battle opens on whoever is ahead', () {
    testWidgets('the answer ahead: it opens on the answer, straight there', (
      t,
    ) async {
      answerLeads = true;
      await openReel(t, battle());
      // Past the wait for the video to be ready, which comes first.
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      // The answer's side: its likes on the heart, and its name lit.
      expect(find.text('940'), findsOneWidget, reason: "leo's likes");
      expect(find.text('1.3K'), findsNothing);
      final lit = t.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('matchup_opponent')),
          matching: find.text('leo_beats'),
        ),
      );
      expect(
        lit.style!.fontWeight,
        FontWeight.w800,
        reason: 'the side on screen',
      );
      expect(standingsAsked, 1, reason: 'asked once, shared');
      // The view is the answer's: it was the video on screen.
      await t.pump(const Duration(seconds: 2));
      final view = watchesSent.firstWhere(
        (w) => w['contentId'] == '1',
        orElse: () => const {},
      );
      expect(view['responseId'], '77');
      expect(view['opponentMs'], 1500);
      expect(view['creatorMs'], 0);
      // And the other side is one tap away, as ever.
      await t.tap(find.byKey(const ValueKey('matchup_challenger')));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('1.3K'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('the challenger ahead: it opens on the challenger, as '
        'before', (t) async {
      await openReel(t, battle());
      expect(find.text('1.3K'), findsOneWidget, reason: "maya's likes");
      expect(find.text('940'), findsNothing);
      await closeReel(t);
    });

    // The owner saw battles open on the side behind. The live score is a
    // second request, waited on for only a moment; on a slow server it
    // missed and the battle opened on the challenger whoever was winning.
    // Now the server says who is ahead with the video itself.
    Future<void> opensOn(WidgetTester t, String likes, String notLikes) async {
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(likes), findsOneWidget);
      expect(find.text(notLikes), findsNothing);
      // Let the slow score arrive before closing.
      await t.pump(const Duration(seconds: 2));
    }

    testWidgets('the server says the answer is ahead: it opens on the '
        'answer, with no wait for the slow live score', (t) async {
      answerLeads = true;
      standingsSlow = true;
      await openReel(t, battle()..['leader'] = 'answer');
      await opensOn(t, '940', '1.3K');
      await closeReel(t);
    });

    testWidgets('the same from a tap in search or a profile', (t) async {
      answerLeads = true;
      standingsSlow = true;
      final b = battle()..['leader'] = 'answer';
      await openReel(t, b, seed: ChallengeModel.fromJson(b));
      await opensOn(t, '940', '1.3K');
      await closeReel(t);
    });

    testWidgets('the server says nothing and the score is slow: the '
        'challenger, as before', (t) async {
      answerLeads = true;
      standingsSlow = true;
      await openReel(t, battle());
      await opensOn(t, '1.3K', '940');
      await closeReel(t);
    });

    testWidgets('the server says the challenger is ahead: the challenger',
        (t) async {
      standingsSlow = true;
      await openReel(t, battle()..['leader'] = 'creator');
      await opensOn(t, '1.3K', '940');
      await closeReel(t);
    });
  });

  testWidgets('tapping the other name switches to their side', (t) async {
    await openReel(t, battle());
    expect(find.text('1.3K'), findsOneWidget, reason: "maya's likes");
    await t.tap(find.byKey(const ValueKey('matchup_opponent')));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('940'), findsOneWidget, reason: "leo's likes now");

    await t.tap(find.byKey(const ValueKey('matchup_challenger')));
    await t.pump(const Duration(milliseconds: 700));
    expect(find.text('1.3K'), findsOneWidget);
    await closeReel(t);
  });

  testWidgets('the buttons: vote on a battle, like, comment, share, save — '
      'and views are not a button any more', (t) async {
    await openReel(t, battle());
    for (final tip in ['Vote', 'Like', 'Comments', 'Share', 'Save']) {
      expect(find.byTooltip(tip), findsOneWidget, reason: tip);
    }
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    await closeReel(t);
  });

  testWidgets('like turns the heart on', (t) async {
    await openReel(t, battle());
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    await t.tap(find.byTooltip('Like'));
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.byTooltip('Unlike'), findsOneWidget);
    await closeReel(t);
  });

  testWidgets('Vote opens both people side by side; picking one votes for '
      'them and the button says so', (t) async {
    await openReel(t, battle());
    await t.tap(find.byTooltip('Vote'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Who did it better?'), findsOneWidget);
    expect(find.byKey(const ValueKey('vote_creator')), findsOneWidget);
    expect(find.byKey(const ValueKey('vote_opponent')), findsOneWidget);
    // No Cancel, and one handle: the theme's is switched off.
    expect(find.text('Cancel'), findsNothing);
    expect(t.widget<BottomSheet>(find.byType(BottomSheet)).showDragHandle,
        isFalse);

    await t.tap(find.byKey(const ValueKey('vote_opponent')));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(lastVote?['responseId'], '77');
    expect(find.byTooltip('You voted'), findsOneWidget);
    expect(find.text('leo_beats'), findsWidgets);
    await t.pump(const Duration(seconds: 5));

    // Changing your mind: the sheet again, and the other side moves it.
    lastVote = null;
    await t.tap(find.byTooltip('You voted'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Change your vote'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('vote_creator')));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(lastVote?['side'], 'creator');
    expect(find.text('Vote moved to maya.'), findsOneWidget);
    expect(find.byTooltip('You voted'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await closeReel(t);
  });

  group('what you already did comes back', () {
    Map<String, dynamic> done() => {
      ...battle(),
      'isLiked': true,
      'isSaved': true,
      'hasVoted': true,
      'votedFor': 'maya',
      'topResponseLiked': true,
    };

    testWidgets('in the feed: liked, saved and voted show as done', (t) async {
      await openReel(t, done());
      expect(find.byTooltip('Unlike'), findsOneWidget);
      expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
      expect(find.byTooltip('Saved'), findsOneWidget);
      expect(find.byTooltip('You voted'), findsOneWidget);
      // And the answer's heart, on the answer's side.
      await t.tap(find.byKey(const ValueKey('matchup_opponent')));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.byTooltip('Unlike'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('opened from a profile or search: the same', (t) async {
      await openReel(
        t,
        short(),
        seed: ChallengeModel.fromJson({...done(), 'id': '31'}),
      );
      expect(find.byTooltip('Unlike'), findsOneWidget);
      expect(find.byTooltip('Saved'), findsOneWidget);
      expect(find.byTooltip('You voted'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('and nothing is marked when the server says nothing', (
      t,
    ) async {
      await openReel(t, battle());
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);
      expect(find.byTooltip('Vote'), findsOneWidget);
      await closeReel(t);
    });
  });

  testWidgets('a battle shows its live score where "View battle" was, '
      'and opens the battle from it', (t) async {
    await openReel(t, battle());
    expect(standingsAsked, 1);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    expect(find.text('  ·  2d left'), findsOneWidget);
    expect(find.text('View battle'), findsNothing);
    await t.tap(find.byKey(const ValueKey('battle_score')));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(Scaffold), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'ChallengeDetailPage',
      ),
      findsOneWidget,
    );
    await closeReel(t);
  });

  testWidgets('both names stay readable; the one on screen is the lit '
      'chip', (t) async {
    await openReel(t, battle());
    final other = t.widget<Text>(find.text('leo_beats'));
    expect(other.style!.color!.a, greaterThan(0.85));
    final onScreen = t.widget<Text>(find.text('maya'));
    expect(onScreen.style!.color, const Color(0xFF111114),
        reason: 'dark words on the white chip');
    await t.tap(find.byKey(const ValueKey('matchup_opponent')));
    await t.pump(const Duration(milliseconds: 700));
    expect(t.widget<Text>(find.text('leo_beats')).style!.color,
        const Color(0xFF111114));
    await closeReel(t);
  });

  testWidgets('the comment button is the drawn bubble', (t) async {
    await openReel(t, battle());
    expect(
      find.descendant(
        of: find.byTooltip('Comments'),
        matching: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_CommentGlyph',
        ),
      ),
      findsOneWidget,
    );
    await closeReel(t);
  });

  testWidgets('Accept challenge opens Record and Upload right there', (
    t,
  ) async {
    await openReel(t, short());
    await t.tap(find.text('Accept challenge'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    // Closing it goes back to the video, having started nothing.
    await t.tapAt(const Offset(20, 60));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Record'), findsNothing);
    await closeReel(t);
  });

  test('choosing Record or Upload goes on to accept, on the battle page', () {
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(
      code('lib/widgets/smart_reels_feed.dart'),
      contains('ChallengeDetailPage(challengeId: item.id, acceptWith: how)'),
    );
    final page = code('lib/pages/challenge_detail_page.dart');
    expect(page, contains('_startAcceptIfAsked();'));
    expect(page, contains('case CreateChoice.record:\n          _onRecord();'));
    expect(
      page,
      contains('case CreateChoice.upload:\n          _onPickFile();'),
    );
  });

  group('caption and comments', () {
    Map<String, dynamic> wordy() => {
      ...short(),
      'subject':
          'cook a three course dinner using only a kettle, a toaster and '
          'whatever is left in the fridge on a Sunday night',
    };
    const whole =
        'Who can cook a three course dinner using only a kettle, a toaster '
        'and whatever is left in the fridge on a Sunday night?';

    Future<void> openSheet(WidgetTester t, Finder from) async {
      await t.tap(from);
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('a long caption is one line on the video', (t) async {
      await openReel(t, wordy());
      final caption = t.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('reel_caption')),
          matching: find.byType(Text),
        ),
      );
      expect(caption.data, whole);
      expect(caption.maxLines, 1);
      expect(caption.overflow, TextOverflow.ellipsis);
      expect(
        t.getSize(find.byKey(const ValueKey('reel_caption'))).height,
        lessThan(24),
        reason: 'one line tall',
      );
      await closeReel(t);
    });

    testWidgets('tapping it opens the whole caption with the comments below', (
      t,
    ) async {
      await openReel(t, wordy());
      await openSheet(t, find.byKey(const ValueKey('reel_caption')));
      final full = t.widget<Text>(find.byKey(const ValueKey('full_caption')));
      expect(full.data, whole);
      expect(full.maxLines, isNull, reason: 'all of it');
      expect(find.text('1 comment'), findsOneWidget);
      expect(find.text('that last move though'), findsOneWidget);
      // The comment sits below the caption.
      expect(
        t.getTopLeft(find.text('that last move though')).dy,
        greaterThan(
          t.getBottomLeft(find.byKey(const ValueKey('full_caption'))).dy,
        ),
      );
      await closeReel(t);
    });

    testWidgets('the comment button opens the same sheet', (t) async {
      await openReel(t, wordy());
      await openSheet(t, find.byTooltip('Comments'));
      // The × is at the right edge, clear of the title.
      final close = t.getRect(find.byTooltip('Close'));
      final title = t.getRect(find.text('1 comment'));
      expect(close.left, greaterThan(title.right));
      expect(find.byKey(const ValueKey('full_caption')), findsOneWidget);
      expect(find.text('that last move though'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('a comment that could not be posted comes back to the box', (
      t,
    ) async {
      await openReel(t, wordy());
      // After opening: opening sets the fake server up afresh.
      refuseComments = true;
      await openSheet(t, find.byTooltip('Comments'));
      await t.enterText(find.byType(TextField), 'nice');
      await t.pump();
      await t.tap(find.byTooltip('Post'));
      for (var i = 0; i < 4; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(posted, ['nice']);
      expect(find.textContaining("Couldn't post"), findsOneWidget);
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'nice',
        reason: 'what they typed is not lost',
      );
      expect(find.text('2 comments'), findsNothing);
      await closeReel(t);
    });
  });

  testWidgets('a short says it is an open challenge and offers to take it '
      'on; no vote button', (t) async {
    await openReel(t, short());
    expect(find.text('zara'), findsOneWidget);
    expect(find.text('Open challenge'), findsOneWidget);
    expect(find.text('Who can cook pasta in 5 minutes?'), findsOneWidget);
    expect(find.text('Accept challenge'), findsOneWidget);
    expect(find.byKey(const ValueKey('battle_score')), findsNothing);
    expect(find.byKey(const ValueKey('battle_side_tab')), findsNothing);
    expect(find.text('5.4K views'), findsOneWidget);
    expect(find.byTooltip('Vote'), findsNothing);
    expect(find.text('VS'), findsNothing);
    await closeReel(t);
  });

  testWidgets('from the battle page, tapping the answer goes back to the '
      'reel on the answer\'s side', (t) async {
    await openReel(t, battle());
    expect(find.text('1.3K'), findsOneWidget, reason: "maya's side first");
    await t.tap(find.byKey(const ValueKey('battle_score')));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('card_answer')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('card_answer')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('card_answer')), findsNothing,
        reason: 'the battle page closed');
    expect(find.text('940'), findsOneWidget, reason: "leo's side now");
    await closeReel(t);
  });

  // "I commented but that did not count." Every number under a video moves
  // when it should — and only then.
  group('the numbers move', () {
    String count(WidgetTester t, String key) =>
        t.widget<Text>(find.byKey(ValueKey(key))).data!;

    Future<void> pumpFor(WidgetTester t, int tenths) async {
      for (var i = 0; i < tenths; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> comment(WidgetTester t, String text) async {
      await t.enterText(find.byType(TextField), text);
      await t.pump();
      await t.tap(find.byTooltip('Post'));
      await pumpFor(t, 4);
    }

    testWidgets('posting a comment adds one under the comment button',
        (t) async {
      await openReel(t, battle()..['commentCount'] = 1);
      expect(count(t, 'count_comments'), '1');
      await t.tap(find.byTooltip('Comments'));
      await pumpFor(t, 8);
      await comment(t, 'nice');
      expect(posted, ['nice']);
      expect(find.text('2 comments'), findsOneWidget);
      expect(count(t, 'count_comments'), '2',
          reason: 'the number under the button, not only the sheet');
      await comment(t, 'again');
      expect(count(t, 'count_comments'), '3');
      await closeReel(t);
    });

    testWidgets('opening the comments shows the real count', (t) async {
      // The video arrived saying 46; the server has one comment now.
      await openReel(t, battle());
      expect(count(t, 'count_comments'), '46');
      await t.tap(find.byTooltip('Comments'));
      await pumpFor(t, 8);
      expect(count(t, 'count_comments'), '1');
      await closeReel(t);
    });

    testWidgets('a comment the server refused adds nothing', (t) async {
      await openReel(t, battle()..['commentCount'] = 1);
      refuseComments = true;
      await t.tap(find.byTooltip('Comments'));
      await pumpFor(t, 8);
      await comment(t, 'nice');
      expect(find.textContaining("Couldn't post"), findsOneWidget);
      expect(count(t, 'count_comments'), '1');
      await closeReel(t);
    });

    testWidgets('comments that could not be read leave the number alone, '
        'not at 0', (t) async {
      await openReel(t, battle());
      commentsDown = true;
      await t.tap(find.byTooltip('Comments'));
      await pumpFor(t, 8);
      expect(count(t, 'count_comments'), '46');
      await closeReel(t);
    });

    testWidgets('views show what the server counted after a watch', (t) async {
      watchViews = 18523;
      await openReel(t, battle());
      expect(find.text('18.4K views'), findsOneWidget);
      // A video watched for 1.5 seconds is a view; the server answers with
      // the total.
      await pumpFor(t, 20);
      expect(watchesSent, isNotEmpty);
      expect(find.text('18.5K views'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('a server that does not say leaves the views alone',
        (t) async {
      await openReel(t, battle());
      await pumpFor(t, 20);
      expect(watchesSent, isNotEmpty);
      expect(find.text('18.4K views'), findsOneWidget);
      await closeReel(t);
    });

    testWidgets('back from the battle page, the video shows what was done '
        'there', (t) async {
      await openReel(t, battle());
      expect(count(t, 'count_likes'), '1.3K');
      expect(count(t, 'count_comments'), '46');
      await t.tap(find.byKey(const ValueKey('battle_score')));
      await pumpFor(t, 8);
      expect(find.byKey(const ValueKey('card_answer')), findsOneWidget);
      // On the battle page: a like, two comments, a save.
      detailOverride = {
        'likes': 1281,
        'isLiked': true,
        'commentCount': 48,
        'saveCount': 8,
        'isSaved': true,
      };
      t.state<NavigatorState>(find.byType(Navigator).first).pop();
      await pumpFor(t, 10);
      expect(find.byKey(const ValueKey('card_answer')), findsNothing);
      expect(count(t, 'count_comments'), '48');
      expect(count(t, 'count_saves'), '8');
      expect(find.byTooltip('Unlike'), findsOneWidget,
          reason: 'the heart is on: it was liked on the battle page');
      await closeReel(t);
    });
  });
}
