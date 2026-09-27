// Opening the app gives a fresh feed, the way a pull-to-refresh does.
//
// A device log showed why it did not: `new=0 repeat=20`. Every video in the
// first page had been seen before, and the app asked for page 1 as an
// ordinary request, so the server ranked the same videos the same way and
// every open began on the same first video. Pull-to-refresh on the Following
// and Explore tabs did not work either: the app dropped the refresh on the
// way out.
//
// These watch what the app actually ASKS the server for, through the real
// feed widget, so cutting any of those wires turns something here red.

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

/// Every feed request the app made, in order.
late List<Uri> asked;

void fakeServer() {
  asked = [];
  ApiService.useClient(
    MockClient((req) async {
      if (req.url.path.contains('/feed')) asked.add(req.url);
      return http.Response.bytes(
        utf8.encode(
          json.encode({
            'items': [
              for (var i = 1; i <= 3; i++)
                {
                  'type': 'challenge',
                  'challenge': {
                    'id': '$i',
                    'creatorId': '9',
                    'creatorUsername': 'leo',
                    'videoUrl': 'https://x/$i.mp4',
                    'prefix': 'Who can',
                    'subject': 'dance',
                    'status': 'open',
                    'createdAt': '2026-09-20T10:00:00Z',
                  },
                },
            ],
            'hasMore': false,
          }),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

Widget feed(FeedKind kind, {Key? key}) {
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
  return ChangeNotifierProvider<DataProvider>.value(
    value: dp,
    child: MaterialApp(
      home: Scaffold(
        body: SmartReelsFeed(key: key, userId: '1', kind: kind),
      ),
    ),
  );
}

/// Close the feed and let its timers run out, so none is left running when
/// the test ends.
Future<void> closeFeed(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox()));
  await t.pump(const Duration(seconds: 5));
  // The diagnostics start a repeating timer the first time anything plays,
  // and it runs for the life of the app. Stop it before the test ends.
  ReelDiagnostics.instance.debugReset();
  EventTracker.instance.dispose();
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

bool isRefresh(Uri u) => u.queryParameters['refresh'] == 'true';

void main() {
  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('the first feed after the app opens is asked for fresh; coming '
      'back from another tab is not', (t) async {
    await t.pumpWidget(feed(FeedKind.forYou));
    await settle(t);
    expect(asked, isNotEmpty);
    expect(
      isRefresh(asked.first),
      isTrue,
      reason: 'opening the app should deal a new hand, like a pull',
    );

    // Off to Search and back: the feed is rebuilt, as it is in the app.
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    asked.clear();
    await t.pumpWidget(feed(FeedKind.forYou));
    await settle(t);
    expect(asked, isNotEmpty);
    expect(
      isRefresh(asked.first),
      isFalse,
      reason: 'a tab switch carries on; it does not reshuffle',
    );
    await closeFeed(t);
  });

  testWidgets('each feed tab gets its own fresh first page', (t) async {
    await t.pumpWidget(feed(FeedKind.forYou));
    await settle(t);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    asked.clear();

    await t.pumpWidget(feed(FeedKind.shorts));
    await settle(t);
    expect(
      isRefresh(asked.first),
      isTrue,
      reason: 'Shorts has not been opened yet this run',
    );
    await closeFeed(t);
  });

  for (final kind in [FeedKind.following, FeedKind.explore]) {
    testWidgets('${kind.name}: the refresh actually reaches the server', (
      t,
    ) async {
      await t.pumpWidget(feed(kind));
      await settle(t);
      expect(asked, isNotEmpty);
      expect(
        isRefresh(asked.first),
        isTrue,
        reason: 'this tab used to drop the refresh on the way out',
      );
      await closeFeed(t);
    });
  }
}
