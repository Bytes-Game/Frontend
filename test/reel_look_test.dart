// The redesigned reel: who is in it, what it asks, and the buttons.
//
// Every test looks for something that IS on screen as well as for what was
// taken away, so a reel broken into showing nothing cannot pass by having
// nothing to find.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
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

/// The body of the last vote the app sent.
Map<String, dynamic>? lastVote;

void fakeServer(Map<String, dynamic> first) {
  lastVote = null;
  ApiService.useClient(
    MockClient((req) async {
      if (req.url.path.endsWith('/challenges/vote')) {
        lastVote = json.decode(req.body) as Map<String, dynamic>;
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

Future<void> openReel(WidgetTester t, Map<String, dynamic> first) async {
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
      child: const MaterialApp(
        home: Scaffold(body: SmartReelsFeed(userId: '1')),
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
  setUp(SmartReelsFeed.debugForgetAppOpen);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('a battle names both people beside the question, not in a '
      'panel at the top', (t) async {
    await openReel(t, battle());
    expect(find.text('maya'), findsOneWidget);
    expect(find.text('leo_beats'), findsOneWidget);
    expect(find.text('vs'), findsOneWidget);
    expect(find.text('Who can dance on a moving bus?'), findsOneWidget);
    expect(find.text('18.4K views  ·  Swipe to switch sides'), findsOneWidget);
    expect(find.text('View battle'), findsOneWidget);

    // The old top panel, gone.
    expect(find.text('CHALLENGER'), findsNothing);
    expect(find.text('Swipe left for opponent'), findsNothing);
    // And they sit in the bottom part of the screen, clear of Home's tabs.
    expect(t.getCenter(find.text('maya')).dy, greaterThan(500));
    await closeReel(t);
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

    await t.tap(find.byKey(const ValueKey('vote_opponent')));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(lastVote?['responseId'], '77');
    expect(find.byTooltip('You voted'), findsOneWidget);
    expect(find.text('leo_beats'), findsWidgets);
    await t.pump(const Duration(seconds: 5));
    await closeReel(t);
  });

  testWidgets('a short says it is an open challenge and offers to take it '
      'on; no vote button', (t) async {
    await openReel(t, short());
    expect(find.text('zara'), findsOneWidget);
    expect(find.text('Open challenge'), findsOneWidget);
    expect(find.text('Who can cook pasta in 5 minutes?'), findsOneWidget);
    expect(find.text('Take the challenge'), findsOneWidget);
    expect(find.text('5.4K views'), findsOneWidget);
    expect(find.byTooltip('Vote'), findsNothing);
    expect(find.text('vs'), findsNothing);
    await closeReel(t);
  });
}
