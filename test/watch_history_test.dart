// Watch history as videos: a grid like everywhere else, and a tap plays your
// history from that video, one after another, with nothing else mixed in.
//
// Each test checks what IS on screen (tiles, the player, the empty or
// failed message), not only what is gone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/watch_history_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

Map<String, dynamic> item(String id, Duration ago) => {
      'eventId': 'e$id',
      'watchedAt': DateTime.now().subtract(ago).toUtc().toIso8601String(),
      'watchDurationMs': 4000,
      'completed': true,
      'challenge': {
        'id': id,
        'creatorId': '9',
        'creatorUsername': 'leo',
        'creatorLeague': 'Gold',
        'videoUrl': 'https://x/$id.mp4',
        'thumbnailUrl': '',
        'prefix': 'Who can',
        'subject': 'video $id',
        'status': 'open',
        'likes': 12,
        'views': 300,
        'responseCount': 0,
        'createdAt': '2026-09-20T10:00:00Z',
      },
    };

/// What the server answers; null fails.
List<Map<String, dynamic>>? history;
bool cleared = false;

void fakeServer() {
  cleared = false;
  history = [
    item('7', const Duration(hours: 2)),
    item('8', const Duration(days: 3)),
    item('9', const Duration(days: 9)),
  ];
  ApiService.useClient(MockClient((req) async {
    if (req.url.path.endsWith('/history')) {
      if (req.method == 'DELETE') {
        cleared = true;
        return http.Response('{"ok":true}', 200);
      }
      final h = history;
      if (h == null) return http.Response('down', 503);
      return http.Response(
          json.encode({'items': h, 'hasMore': false, 'nextCursor': ''}), 200);
    }
    return http.Response('{}', 200);
  }));
}

Future<void> openHistory(WidgetTester t) async {
  final dp = DataProvider()
    ..setUser(UserModel(
      id: '1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    ));
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ChangeNotifierProvider.value(
    value: dp,
    child: const MaterialApp(home: WatchHistoryPage()),
  ));
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('a grid of the videos you watched, newest first, with when',
      (t) async {
    await openHistory(t);
    expect(find.byKey(const ValueKey('history_tile_7')), findsOneWidget);
    expect(find.byKey(const ValueKey('history_tile_8')), findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('3d ago'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('a tap plays your history from that video, and only it',
      (t) async {
    await openHistory(t);
    await t.tap(find.byKey(const ValueKey('history_tile_8')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    final feed = t.widget<SmartReelsFeed>(find.byType(SmartReelsFeed));
    expect(feed.playlist!.map((c) => c.id), ['7', '8', '9'],
        reason: 'the next swipe is the next video you watched');
    expect(feed.startIndex, 1, reason: 'opens on the one tapped');
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  });

  testWidgets('clear all asks, then empties it', (t) async {
    await openHistory(t);
    await t.tap(find.byKey(const ValueKey('history_clear')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Clear watch history?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('history_clear_confirm')));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(cleared, isTrue);
    expect(find.byKey(const ValueKey('history_tile_7')), findsNothing);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('nothing watched yet says so', (t) async {
    history = [];
    await openHistory(t);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('history_clear')), findsNothing);
  });

  testWidgets("couldn't load says so, not 'nothing watched'", (t) async {
    history = null;
    await openHistory(t);
    expect(find.text("Couldn't load your history"), findsOneWidget);
    expect(find.text('Nothing here yet'), findsNothing);
  });
}
