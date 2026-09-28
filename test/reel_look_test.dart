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
  'comments': 46,
  'views': 18400,
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

void fakeServer(Map<String, dynamic> first) {
  lastVote = null;
  standingsAsked = 0;
  refuseComments = false;
  posted = [];
  ApiService.useClient(
    MockClient((req) async {
      if (req.url.path.endsWith('/challenges/${first['id']}')) {
        return http.Response.bytes(
          utf8.encode(
            json.encode({
              'challenge': first,
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
      if (req.url.path.endsWith('/comments') && req.method == 'GET') {
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
                  'leading': !answerLeads,
                  'rank': answerLeads ? 2 : 1,
                },
                {
                  'username': 'leo_beats',
                  'role': 'responder',
                  'responseId': '77',
                  'votes': answerLeads ? 14 : 9,
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
}) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer(first);
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: '1',
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

    // One vote each: a second tap says who you voted for, opens nothing
    // and sends nothing.
    lastVote = null;
    await t.tap(find.byTooltip('You voted'));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('You voted for leo_beats. Everyone gets one vote.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('vote_creator')), findsNothing);
    expect(lastVote, isNull);
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
}
