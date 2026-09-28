// The redesigned battle page: both videos side by side, the question, the
// counts, accepting, the score, and the first comments.
//
// Every test looks for something that IS on screen as well as for what is
// not, so a page broken into showing nothing cannot pass by having nothing
// to find.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/pages/video_player_page.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

Map<String, dynamic> challengeJson({required bool open, bool liked = false}) =>
    {
      'id': open ? '2' : '1',
      'creatorId': '9',
      'creatorUsername': open ? 'zara' : 'maya',
      'creatorLeague': 'Gold',
      'videoUrl': 'https://x/1.mp4',
      'prefix': 'Who can',
      'subject': open ? 'cook pasta in 5 minutes' : 'dance on a moving bus',
      'status': open ? 'open' : 'active',
      'visibility': 'arena',
      'category': 'dance',
      'likes': 1280,
      'views': 18400,
      'commentCount': 3,
      // A moment older than the live score below (21 and 42): the page
      // shows the live score's, the same as the rows under it.
      'voteCount': 20,
      'shareCount': 40,
      'isLiked': liked,
      'createdAt': '2026-09-20T10:00:00Z',
    };

/// Likes the page asked the server for.
late int likeCalls;
late bool refuseLikes;

/// How many times the page read the challenge, and the votes it sent. A
/// vote waits on [voteGate] when one is set.
late int detailCalls;
late List<String> votesSent;

/// Which lists (likes, votes, shares) the page asked for.
late List<String> peopleAsked;
Completer<void>? voteGate;

void fakeServer({required bool open, bool liked = false}) {
  likeCalls = 0;
  refuseLikes = false;
  detailCalls = 0;
  votesSent = [];
  peopleAsked = [];
  voteGate = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      Object body = {};
      var status = 200;
      if (p.endsWith('/challenges/1') || p.endsWith('/challenges/2')) {
        detailCalls++;
        body = {
          'challenge': challengeJson(open: open, liked: liked),
          'responses': open
              ? []
              : [
                  {
                    'id': '77',
                    'challengeId': '1',
                    'responderId': '8',
                    'responderUsername': 'leo_beats',
                    'responderLeague': 'Silver',
                    'videoUrl': 'https://x/r.mp4',
                    'likes': 940,
                    'views': 12100,
                  },
                ],
          'votes': [],
        };
      } else if (p.endsWith('/comments')) {
        body = [
          for (final t in ['first!', 'so good', 'rematch?'])
            {'authorUsername': 'sam', 'text': t, 'createdAt': ''},
        ];
      } else if (p.endsWith('/standings')) {
        body = {
          'challengeId': '1',
          'status': 'active',
          'battleDays': 7,
          'acceptedAt': DateTime.now()
              .subtract(const Duration(days: 1))
              .toIso8601String(),
          'endsAt': DateTime.now()
              .add(const Duration(days: 2, hours: 3))
              .toIso8601String(),
          'participants': [
            // The same numbers as the challenge above: 1280 + 940 likes,
            // 6300 + 12100 = 18400 views, 30 + 12 shares, 12 + 9 votes.
            {
              'username': 'maya',
              'role': 'creator',
              'votes': 12,
              'likes': 1280,
              'views': 6300,
              'shares': 30,
              'leading': true,
            },
            {
              'username': 'leo_beats',
              'role': 'responder',
              'responseId': '77',
              'votes': 9,
              'likes': 940,
              'views': 12100,
              'shares': 12,
            },
          ],
        };
      } else if (p.endsWith('/challenges/vote')) {
        votesSent.add(req.body);
        await voteGate?.future;
        body = {'voted': true, 'votes': []};
      } else if (p.endsWith('/people')) {
        peopleAsked.add(req.url.queryParameters['what'] ?? '');
        final what = req.url.queryParameters['what'];
        List<Map<String, String>> who(List<String> names) => [
          for (final n in names) {'userId': n, 'username': n, 'at': ''},
        ];
        body = {
          'sides': [
            {
              'username': 'maya',
              'role': 'creator',
              'people': who(switch (what) {
                'votes' => ['sam'],
                'likes' => ['nina'],
                _ => ['kai'],
              }),
            },
            {
              'username': 'leo_beats',
              'role': 'responder',
              'responseId': '77',
              'people': who(switch (what) {
                'votes' => ['priya', 'omar'],
                'likes' => ['zoe', 'ada', 'lu'],
                _ => [],
              }),
            },
          ],
        };
      } else if (p.endsWith('/challenges/like')) {
        likeCalls++;
        if (refuseLikes) {
          status = 503;
        } else {
          body = {'liked': !liked, 'likes': liked ? 1279 : 1281};
        }
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

Future<void> openPage(
  WidgetTester t, {
  required bool open,
  bool liked = false,
  String me = '1',
  ThemeData? theme,
}) async {
  t.view.physicalSize = const Size(400, 1400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer(open: open, liked: liked);
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
        theme: theme,
        home: ChallengeDetailPage(challengeId: open ? '2' : '1'),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('a battle: both videos side by side, the leader crowned, the '
      'question, and it is live', (t) async {
    await openPage(t, open: false);
    expect(find.byKey(const ValueKey('card_creator')), findsOneWidget);
    expect(find.byKey(const ValueKey('card_answer')), findsOneWidget);
    expect(find.text('VS'), findsOneWidget);
    // Side by side, not stacked.
    expect(
      t.getCenter(find.byKey(const ValueKey('card_creator'))).dy,
      t.getCenter(find.byKey(const ValueKey('card_answer'))).dy,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card_creator')),
        matching: find.text('Leading'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card_answer')),
        matching: find.text('Leading'),
      ),
      findsNothing,
    );
    expect(find.text('Who can dance on a moving bus?'), findsOneWidget);
    expect(find.textContaining('Live · 2d'), findsOneWidget);
    expect(find.text('Battle'), findsOneWidget);
    expect(find.text('Accept challenge'), findsNothing);
  });

  testWidgets('an open challenge offers the empty seat and the accept '
      'button, and both open Record and Upload', (t) async {
    await openPage(t, open: true);
    expect(find.text('Your move'), findsOneWidget);
    expect(find.text('Accept to take on zara'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('accept_button')));
    await settle(t);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    await t.tapAt(const Offset(20, 80));
    await settle(t);
    expect(find.text('Record'), findsNothing);

    await t.tap(find.byKey(const ValueKey('empty_seat')));
    await settle(t);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('your own open challenge waits; nothing to accept', (t) async {
    await openPage(t, open: true, me: '9');
    expect(find.text('Waiting for a challenger'), findsOneWidget);
    expect(find.byKey(const ValueKey('accept_button')), findsNothing);
    expect(find.text('Your move'), findsNothing);
  });

  testWidgets('the heart starts as you left it, and a refused like goes '
      'back', (t) async {
    await openPage(t, open: false, liked: true);
    expect(find.byTooltip('Unlike'), findsOneWidget);
    // Likes on both videos: 1280 + 940.
    expect(find.text('2.2K'), findsOneWidget);

    refuseLikes = true;
    await t.tap(find.byTooltip('Unlike'));
    await settle(t);
    expect(likeCalls, 1);
    expect(find.byTooltip('Unlike'), findsOneWidget, reason: 'put back');
    expect(find.text('2.2K'), findsOneWidget);
    expect(find.textContaining("Couldn't update your like"), findsOneWidget);
  });

  testWidgets('the counts, and the first comments with the way into all', (
    t,
  ) async {
    await openPage(t, open: false);
    // Every number is a total across both players — the same as the live
    // score's rows below add up to.
    String count(String name) => t
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('stat_count_$name')),
            matching: find.byType(Text),
          ).first,
        )
        .data!;
    expect(count('likes'), '2.2K', reason: '1280 + 940');
    expect(count('comments'), '3');
    expect(count('shares'), '42', reason: '30 + 12');
    expect(count('votes'), '21', reason: '12 + 9');
    expect(count('views'), '18.4K', reason: '6300 + 12100');
    expect(find.text('Answer'), findsWidgets);
    // No category tag, and the tags that stay are still there.
    expect(find.text('Dance'), findsNothing);
    expect(find.text('Public'), findsOneWidget);
    expect(find.textContaining('first!'), findsOneWidget);
    expect(find.textContaining('so good'), findsOneWidget);
    expect(
      find.textContaining('rematch?'),
      findsNothing,
      reason: 'two in the preview',
    );
    await t.tap(find.text('View all 3'));
    await settle(t);
    expect(find.byKey(const ValueKey('full_caption')), findsOneWidget);
    expect(find.text('3 comments'), findsOneWidget);
  });

  testWidgets('in the light theme the words on the dark page are still '
      'light, so none of them vanish', (t) async {
    await openPage(t, open: false, theme: AppTheme.lightTheme);
    Color colorOf(String text) =>
        t.renderObject<RenderParagraph>(find.text(text).first).text.style!.color!;
    for (final text in ['Battle', 'Live score', 'maya', 'leo_beats']) {
      expect(colorOf(text).computeLuminance(), greaterThan(0.5),
          reason: '"$text" is dark on a dark page');
    }
  });

  testWidgets('a vote shows the moment it is tapped, and the page is not '
      'loaded again for it', (t) async {
    await openPage(t, open: false);
    final before = detailCalls;
    voteGate = Completer<void>();
    final vote = find.widgetWithText(FilledButton, 'Vote').first;
    await t.ensureVisible(vote);
    await t.tap(vote);
    await t.pump();
    // Still waiting on the server, and it already shows — in the score
    // box, and in the page's total above it.
    expect(votesSent, hasLength(1));
    expect(find.byKey(const ValueKey('your_vote')), findsOneWidget);
    expect(find.text('13'), findsOneWidget, reason: "maya's 12 + this vote");
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('stat_count_votes')),
        matching: find.text('22'),
      ),
      findsOneWidget,
      reason: 'the total moves with it: 21 + 1',
    );
    voteGate!.complete();
    await settle(t);
    expect(
      detailCalls,
      before,
      reason: 'reloading the whole page after a vote is what made it slow',
    );
    // A tap on it says how to change it, and sends nothing.
    await t.tap(find.byKey(const ValueKey('your_vote')));
    await t.pump();
    expect(find.textContaining('To change it, tap Vote'), findsOneWidget);
    expect(votesSent, hasLength(1));
  });

  testWidgets('the people in the battle tap a number to see who: who '
      'voted for whom, who liked, who shared', (t) async {
    for (final me in ['9', '8']) {
      // The creator, then the answerer.
      await openPage(t, open: false, me: me);
      expect(find.byKey(const ValueKey('who_voted')), findsNothing);
      expect(find.byKey(const ValueKey('who_liked')), findsNothing);

      await t.tap(find.byKey(const ValueKey('stat_count_votes')));
      await settle(t);
      expect(find.text('3 votes'), findsOneWidget);
      expect(find.text('maya · 1'), findsOneWidget);
      expect(find.text('leo_beats · 2'), findsOneWidget);
      expect(find.text('sam'), findsOneWidget);
      await t.tap(find.text('leo_beats · 2'));
      await settle(t);
      expect(find.text('priya'), findsOneWidget);
      expect(find.text('omar'), findsOneWidget);
      await t.tapAt(const Offset(20, 40));
      await settle(t);

      await t.tap(find.byKey(const ValueKey('stat_count_likes')));
      await settle(t);
      expect(find.text('Liked by 4'), findsOneWidget);
      expect(find.text('nina'), findsOneWidget);
      await t.tapAt(const Offset(20, 40));
      await settle(t);

      await t.tap(find.byKey(const ValueKey('stat_count_shares')));
      await settle(t);
      expect(find.text('Shared by 1'), findsOneWidget);
      expect(find.text('kai'), findsOneWidget);
      await t.tapAt(const Offset(20, 40));
      await settle(t);
      expect(peopleAsked, ['votes', 'likes', 'shares']);
    }
  });

  testWidgets('anyone else sees the numbers, and a tap on one opens no list', (
    t,
  ) async {
    await openPage(t, open: false, me: '1');
    expect(find.byKey(const ValueKey('stats_bar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('stat_count_votes')));
    await settle(t);
    expect(peopleAsked, isEmpty);
    expect(find.text('3 votes'), findsNothing);
    // The page itself is there.
    expect(find.byKey(const ValueKey('card_creator')), findsOneWidget);
  });

  testWidgets('opened from somewhere else, a tap on a video opens it as a '
      'reel with its buttons, not a bare player', (t) async {
    await openPage(t, open: false);
    await t.tap(find.byKey(const ValueKey('card_creator')));
    await settle(t);
    expect(find.byType(SmartReelsFeed), findsOneWidget);
    expect(find.byTooltip('Like'), findsWidgets);
    expect(find.byType(VideoPlayerPage), findsNothing);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
  });
}
