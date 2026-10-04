// Search: the quality a video opened from it plays at, and the results as
// you type.
//
// Each of these goes through the real page. A check that called the cache
// or the picker by hand would pass with the wire to it cut, which is the
// most common bug this app has had.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/widgets/shimmer_loading.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

Map<String, dynamic> video(int id) => {
  'id': '$id',
  'creatorId': '9',
  'creatorUsername': 'leo',
  'videoUrl': 'https://x/$id.mp4',
  'videoVariants': {
    '480p': 'https://x/$id/480p.mp4',
    '720p': 'https://x/$id/720p.mp4',
    '720p_hq': 'https://x/$id/720p_hq.mp4',
  },
  'thumbnailUrl': 'https://x/$id.jpg',
  'prefix': 'Who can',
  'subject': 'dance better',
  'status': 'open',
  'views': 10,
  'createdAt': '2026-09-20T10:00:00Z',
};

http.Response jsonBody(Object o) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// The ids the server's grid hands out.
late List<int> gridIds;

/// When set, the server holds its grid answer until this completes.
Completer<void>? holdGrid;

/// Searches asked for, in order.
late List<Uri> searches;

/// When set, the server holds its answer to a search for this until
/// [holdSearch] completes.
String? holdQuery;
Completer<void>? holdSearch;

void fakeServer() {
  gridIds = [1, 2, 3];
  holdGrid = null;
  searches = [];
  holdQuery = null;
  holdSearch = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.contains('/feed/explore')) {
        final hold = holdGrid;
        if (hold != null) await hold.future;
        return jsonBody({
          'items': [
            for (final id in gridIds)
              {'type': 'challenge', 'challenge': video(id)},
          ],
        });
      }
      if (p.endsWith('/search')) {
        searches.add(req.url);
        final q = req.url.queryParameters['q'] ?? '';
        if (q == holdQuery) await holdSearch!.future;
        return jsonBody({
          'accounts': [
            {'id': '6', 'username': '${q}_person', 'visibility': 'public'},
          ],
          'battles': [],
          'shorts': [],
        });
      }
      if (p.endsWith('/search/recent')) return jsonBody({'recent': []});
      if (p.endsWith('/search/trending')) return jsonBody({'trending': []});
      return jsonBody({});
    }),
  );
}

Widget app(Widget home, {String userId = '1'}) {
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: userId,
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
    child: MaterialApp(home: home),
  );
}

Finder tile(int id) => find.byKey(Key('preview_$id'));

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}


void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ExploreGridCache.instance.debugReset();
    fakeServer();
  });

  tearDown(() {
    ApiService.useClient(http.Client());
    ExploreGridCache.instance.debugReset();
  });

  group('a video opened from Search chooses its own quality', () {
    late Directory cacheDir;
    final nq = NetworkQualityService.instance;

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync('search_speed_cache');
      VideoCacheService.instance.debugSetDirectory(cacheDir);
      nq.debugClearThroughput();
      nq.debugClearChosenVariants();
    });

    tearDown(() {
      VideoCacheService.instance.warm(const []);
      nq.debugClearThroughput();
      nq.debugClearChosenVariants();
      if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
    });

    testWidgets('not the one the grid saw when Search opened', (t) async {
      // For a while the grid chose the quality for every video it showed,
      // at whatever speed the connection had when Search opened, and the
      // full-screen player was held to it. Two device logs after that show
      // the videos opened from Search starving.

      // Search opens on a slow link: the grid takes the small file.
      for (var i = 0; i < 3; i++) {
        nq.recordThroughput(100 * 1024, const Duration(milliseconds: 900));
      }
      gridIds = [1];
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      expect(tile(1), findsOneWidget);
      final c = ChallengeModel.fromJson(video(1));
      final gridSaw = nq.pickVariantUrl(c.videoVariants);
      expect(gridSaw, contains('480p'));
      expect(VideoCacheService.instance.debugWindow, contains(gridSaw),
          reason: 'the grid fetched the start of the small file');

      // Then the link gets fast, and the video is tapped.
      for (var i = 0; i < 12; i++) {
        nq.recordThroughput(8 * 1024 * 1024, const Duration(seconds: 1));
      }
      final fastPick = nq.pickVariantUrl(c.videoVariants);
      expect(fastPick, isNot(gridSaw),
          reason: 'without this the test would prove nothing');
      expect(SmartReelsFeed.playbackUrlFor(c), fastPick,
          reason: 'the full-screen player picks for the link it has now');
    });
  });

  group('typing a search', () {
    Future<void> type(WidgetTester t, String text) async {
      await t.enterText(find.byType(TextField), text);
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
    }

    testWidgets('keeps the last results on screen while the next ones come',
        (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await type(t, 'da');
      await settle(t);
      expect(find.text('da_person'), findsWidgets);

      holdQuery = 'dan';
      holdSearch = Completer<void>();
      await type(t, 'dan');
      expect(find.text('da_person'), findsWidgets,
          reason: 'the results already there stay while the next come');
      expect(find.byType(SearchGridSkeleton), findsNothing,
          reason: 'not wiped for grey placeholders');
      expect(find.byKey(const ValueKey('search_updating')), findsOneWidget,
          reason: 'a thin bar says they are being updated');

      holdSearch!.complete();
      await settle(t);
      expect(find.text('dan_person'), findsWidgets);
      expect(find.byKey(const ValueKey('search_updating')), findsNothing);
    });

    testWidgets('the very first search still shows placeholders: there is '
        'nothing to keep yet', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      holdQuery = 'da';
      holdSearch = Completer<void>();
      await type(t, 'da');
      expect(find.byType(SearchGridSkeleton), findsOneWidget);
      holdSearch!.complete();
      await settle(t);
      expect(find.text('da_person'), findsWidgets);
    });

    testWidgets('typing back to a search already answered shows it at once, '
        'without asking again', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await type(t, 'da');
      await settle(t);
      await type(t, 'dan');
      await settle(t);
      expect(searches.map((u) => u.queryParameters['q']), ['da', 'dan']);

      // The server would now take its time — it is not asked.
      holdQuery = 'da';
      holdSearch = Completer<void>();
      await type(t, 'da');
      expect(find.text('da_person'), findsWidgets);
      expect(find.byKey(const ValueKey('search_updating')), findsNothing);
      expect(searches.map((u) => u.queryParameters['q']), ['da', 'dan']);
      holdSearch!.complete();
    });

    testWidgets('pressing search after the results came in as you typed '
        'still goes into the history', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await type(t, 'dan');
      await settle(t);
      await t.testTextInput.receiveAction(TextInputAction.search);
      await settle(t);
      expect(find.text('dan_person'), findsWidgets);
      expect(
        searches.where((u) => u.queryParameters['record'] == '1'),
        hasLength(1),
        reason: 'only the server keeps the history, so it is still told',
      );
    });

    testWidgets('a search that failed is not remembered as "nothing found"',
        (t) async {
      var fail = true;
      ApiService.useClient(
        MockClient((req) async {
          if (req.url.path.endsWith('/search')) {
            searches.add(req.url);
            if (fail) return http.Response('down', 503);
            return jsonBody({
              'accounts': [
                {'id': '6', 'username': 'back_person', 'visibility': 'public'},
              ],
              'battles': [],
              'shorts': [],
            });
          }
          if (req.url.path.contains('/feed/explore')) {
            return jsonBody({'items': []});
          }
          return jsonBody({});
        }),
      );
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await type(t, 'da');
      await settle(t);
      await type(t, 'd');
      await settle(t);
      fail = false;
      await type(t, 'da');
      await settle(t);
      expect(find.text('back_person'), findsWidgets,
          reason: 'asked again, not answered with the failure');
    });
  });
}
