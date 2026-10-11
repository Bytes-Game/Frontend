// The Search grid scrolls on until every video is in it, then just stops.
//
// The owner asked for two things: scrolling brings new videos, and when the
// server has none left the grid simply cannot scroll further — no "end of
// page" words. And the next videos should already be there by the time you
// reach them, so it feels like they were always loaded.
//
// These go through the real page and a fake server holding 75 videos, so
// cutting any wire — the scroll listener, the request, the cache — turns
// something here red.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';

Map<String, dynamic> video(int id) => {
  'id': '$id',
  'creatorId': '9',
  'creatorUsername': 'leo',
  'videoUrl': 'https://x/$id.mp4',
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

const catalog = 75;

/// What each next-batch request said the grid already held.
late List<List<int>> moreAsks;

/// When true, the server fails next-batch requests.
late bool moreFails;

void fakeServer() {
  moreAsks = [];
  moreFails = false;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.contains('/feed/explore') && req.method == 'POST') {
        final held = [
          for (final n in (json.decode(req.body)['exclude'] as List)) n as int,
        ];
        moreAsks.add(held);
        if (moreFails) return http.Response('down', 503);
        final next = [
          for (var i = 1; i <= catalog; i++)
            if (!held.contains(i)) i,
        ].take(30);
        return jsonBody({
          'items': [
            for (final id in next) {'type': 'challenge', 'challenge': video(id)},
          ],
        });
      }
      if (p.contains('/feed/explore')) {
        return jsonBody({
          'items': [
            for (var i = 1; i <= 30; i++)
              {'type': 'challenge', 'challenge': video(i)},
          ],
        });
      }
      if (p.endsWith('/search/recent')) return jsonBody({'recent': []});
      if (p.endsWith('/search/trending')) return jsonBody({'trending': []});
      return jsonBody({});
    }),
  );
}

Widget app(Widget home) {
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
    child: MaterialApp(home: home),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder get grid => find.byType(CustomScrollView).first;

ScrollPosition position(WidgetTester t) =>
    t.widget<CustomScrollView>(grid).controller!.position;

Future<void> scrollToBottom(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    final pos = position(t);
    if (pos.extentAfter < 1) break;
    await t.drag(grid, const Offset(0, -900));
    await settle(t);
  }
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ExploreGridCache.instance.clear();
    ExploreGridCache.instance.now = DateTime.now;
    fakeServer();
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    ExploreGridCache.instance.clear();
  });

  testWidgets('the next videos are asked for well before the bottom, naming '
      'the ones the grid already has', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);

    // Nobody has scrolled yet, and the next batch is already in.
    expect(moreAsks, isNotEmpty, reason: 'asked ahead, not at the bottom');
    expect(moreAsks.first, [for (var i = 1; i <= 30; i++) i]);
    final pos = position(t);
    expect(pos.extentAfter, greaterThan(pos.viewportDimension),
        reason: 'more than a screen of videos waiting below');
  });

  testWidgets('scrolling reaches every video once, then the grid just stops '
      '— no words at the end, and no more asking', (t) async {
    await t.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    await scrollToBottom(t);

    // Tiles far above are recycled as you scroll, so the grid's own count
    // and list say what is in it.
    final delegate = t.widget<SliverGrid>(find.byType(SliverGrid)).delegate
        as SliverChildBuilderDelegate;
    expect(delegate.childCount, catalog, reason: 'every video, once');
    expect(
      {for (final c in ExploreGridCache.instance.items) c.id},
      {for (var i = 1; i <= catalog; i++) '$i'},
    );
    // Presence before absence: the grid is there, and it ends on a tile.
    expect(find.byKey(const Key('preview_$catalog')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid_more_loading')), findsNothing);
    for (final words in ['end', 'no more', "that's all", 'all caught up']) {
      expect(
        find.byWidgetPredicate((w) =>
            w is Text && (w.data ?? '').toLowerCase().contains(words)),
        findsNothing,
        reason: 'nothing is written at the end ("$words")',
      );
    }

    // Near the end, a little up and back down: every move of the list near
    // its bottom is where the next batch would be asked for.
    final asked = moreAsks.length;
    for (var i = 0; i < 2; i++) {
      await t.drag(grid, const Offset(0, 300));
      await settle(t);
      await t.drag(grid, const Offset(0, -900));
      await settle(t);
    }
    expect(moreAsks.length, asked, reason: 'at the end it stops asking');

    // Back to Search later: still at the end, so it does not ask again.
    await t.pumpWidget(app(const SizedBox()));
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    await scrollToBottom(t);
    expect(moreAsks.length, asked);
  });

  testWidgets('a failed request is not the end: the next scroll asks again',
      (t) async {
    await t.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    moreFails = true;
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    expect(moreAsks, hasLength(1));

    // Not asked again on every frame of a scroll while it is down.
    await t.drag(grid, const Offset(0, -300));
    await t.pump(const Duration(milliseconds: 200));
    expect(moreAsks, hasLength(1));

    // Back up: a few seconds later it tries again by itself.
    moreFails = false;
    await t.pump(const Duration(seconds: 5));
    await settle(t);
    expect(moreAsks.length, greaterThan(1));
    await scrollToBottom(t);
    expect(find.byKey(const Key('preview_$catalog'), skipOffstage: false),
        findsOneWidget, reason: 'it carried on once the server was back');
  });
}
