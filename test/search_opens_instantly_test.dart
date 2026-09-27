// Search opens on its videos, not on an empty page waiting for the server.
//
// Every visit used to start from nothing: the page asked the server for its
// grid, showed "Find people and battles" while it waited, and threw the
// answer away when you left. These go through the real callers — the page
// opening, the app's main screen, signing out — rather than calling the
// cache by hand, so cutting any one of those wires turns something here red.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/auth_provider.dart';
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

/// How many times the app asked the server for the grid.
late int exploreAsks;

/// The last grid request, to see whether it was a refresh.
Uri? lastExploreAsk;

/// The ids the server hands out next.
late List<int> nextIds;

/// When set, the server holds its grid answer until this completes.
Completer<void>? holdExplore;

void fakeServer() {
  exploreAsks = 0;
  nextIds = [for (var i = 1; i <= 15; i++) i];
  holdExplore = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.contains('/feed/explore')) {
        exploreAsks++;
        lastExploreAsk = req.url;
        final hold = holdExplore;
        if (hold != null) await hold.future;
        return jsonBody({
          'items': [
            for (final id in nextIds)
              {'type': 'challenge', 'challenge': video(id)},
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

Finder tile(int id) => find.byKey(Key('preview_$id'));

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
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
    ExploreGridCache.instance.now = DateTime.now;
  });

  testWidgets('coming back to Search shows its videos on the first frame, '
      'without asking the server again', (t) async {
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    expect(tile(1), findsOneWidget);
    expect(exploreAsks, 1);

    // Off to another tab: the page is thrown away, as it is in the app.
    await t.pumpWidget(app(const SizedBox()));
    await t.pumpWidget(app(const SearchPage()));
    // One frame. No waiting for anything.
    expect(tile(1), findsOneWidget);
    expect(find.text('Find people and battles'), findsNothing);
    await settle(t);
    expect(exploreAsks, 1, reason: 'a fresh list is not fetched again');
  });

  testWidgets('pulling the grid down asks for a refresh and shows the new '
      'set', (t) async {
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    expect(tile(1), findsOneWidget);
    expect(lastExploreAsk!.queryParameters['refresh'], isNull);

    nextIds = [for (var i = 201; i <= 215; i++) i];
    await t.fling(
      find.byType(CustomScrollView).first,
      const Offset(0, 400),
      1200,
    );
    await settle(t);
    await t.pump(const Duration(seconds: 1));
    await settle(t);
    expect(lastExploreAsk!.queryParameters['refresh'], 'true');
    expect(tile(201), findsOneWidget);
    expect(tile(1), findsNothing);
  });

  testWidgets('with nothing in hand yet it shows a loading grid, not the '
      '"nothing here" screen', (t) async {
    holdExplore = Completer<void>();
    await t.pumpWidget(app(const SearchPage()));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Find people and battles'), findsNothing);
    expect(tile(1), findsNothing);

    holdExplore!.complete();
    await settle(t);
    expect(tile(1), findsOneWidget);
  });

  testWidgets('a server with nothing to give still ends on the "nothing here" '
      'screen, not a loading grid for ever', (t) async {
    nextIds = [];
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    expect(find.text('Find people and battles'), findsOneWidget);
  });

  group('an old list', () {
    Future<void> makeOld() async {
      final later = DateTime.now().add(
        ExploreGridCache.maxAge + const Duration(minutes: 1),
      );
      ExploreGridCache.instance.now = () => later;
    }

    testWidgets('still shows at once, and a new one replaces it while the '
        'grid is at the top', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await t.pumpWidget(app(const SizedBox()));
      await makeOld();
      nextIds = [for (var i = 101; i <= 115; i++) i];
      holdExplore = Completer<void>();

      await t.pumpWidget(app(const SearchPage()));
      expect(tile(1), findsOneWidget, reason: 'the old list, at once');
      await t.pump(const Duration(milliseconds: 50));
      expect(exploreAsks, 2, reason: 'and a new one is asked for');

      holdExplore!.complete();
      await settle(t);
      expect(tile(101), findsOneWidget);
      expect(tile(1), findsNothing);
    });

    testWidgets('does not swap the tiles under someone who has scrolled '
        'down; the new list waits for the next visit', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      await t.pumpWidget(app(const SizedBox()));
      await makeOld();
      nextIds = [for (var i = 101; i <= 115; i++) i];
      holdExplore = Completer<void>();

      await t.pumpWidget(app(const SearchPage()));
      await t.drag(find.byType(CustomScrollView).first, const Offset(0, -300));
      await t.pump();
      holdExplore!.complete();
      await settle(t);
      // What is on screen, not what exists: the test tools do not count a
      // tile that has scrolled out of view, so asking about one particular
      // tile could pass whichever list were showing.
      bool onScreen(int id) => tile(id).evaluate().isNotEmpty;
      expect(
        [for (var i = 1; i <= 15; i++) i].where(onScreen),
        isNotEmpty,
        reason: 'still looking through the old list',
      );
      expect(
        [for (var i = 101; i <= 115; i++) i].where(onScreen),
        isEmpty,
        reason: 'none of the new one has been swapped in under them',
      );
      expect(
        ExploreGridCache.instance.items.first.id,
        '101',
        reason: 'but the new one is kept for next time',
      );

      await t.pumpWidget(app(const SizedBox()));
      await t.pumpWidget(app(const SearchPage()));
      expect(tile(101), findsOneWidget);
    });
  });

  testWidgets('the fetch before Search is opened fills the grid, and '
      'starts downloading the first screen of pictures under the name the '
      'tiles ask for', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    // The image store files a picture under a key worked out from it, so
    // work out the keys the tiles will look up.
    Future<Object> keyOf(int id) => ExploreGridCache.posterImage(
      'https://x/$id.jpg',
    ).obtainKey(ImageConfiguration.empty);
    final first = await keyOf(1);
    final last = await keyOf(ExploreGridCache.prefetchPosters);
    final beyond = await keyOf(ExploreGridCache.prefetchPosters + 1);
    final cache = PaintingBinding.instance.imageCache;
    expect(cache.containsKey(first), isFalse, reason: 'nothing yet');

    await ExploreGridCache.instance.prefetch(ctx, '1');
    expect(cache.containsKey(first), isTrue);
    expect(cache.containsKey(last), isTrue);
    expect(
      cache.containsKey(beyond),
      isFalse,
      reason: 'one screen of pictures, not all of them',
    );

    // Search then opens on them with no request of its own.
    await t.pumpWidget(app(const SearchPage()));
    expect(tile(1), findsOneWidget);
    await settle(t);
    expect(exploreAsks, 1);
    PaintingBinding.instance.imageCache.clear();
  });

  testWidgets('a tile shows the picture the fetch downloaded, not a second '
      'copy of it', (t) async {
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    final img = t.widget<Image>(
      find.descendant(of: tile(1), matching: find.byType(Image)).first,
    );
    expect(img.image, ExploreGridCache.posterImage('https://x/1.jpg'));
  });

  test('the app fetches Search\'s grid a few seconds after it opens', () {
    final code = File(
      'lib/screens/main_shell.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(code, contains('Timer(prefetchDelay'));
    expect(code, contains('ExploreGridCache.instance.prefetch(context'));
    expect(code, contains('_searchPrefetch?.cancel()'));
  });

  testWidgets('signing out forgets the grid: it was picked for them', (
    t,
  ) async {
    await t.pumpWidget(app(const SearchPage()));
    await settle(t);
    expect(ExploreGridCache.instance.items, isNotEmpty);

    late BuildContext ctx;
    await t.pumpWidget(
      app(
        Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    AuthProvider().logout(ctx);
    await t.pump();
    expect(ExploreGridCache.instance.items, isEmpty);
  });

  test('an answer still on its way when they sign out does not bring their '
      'grid back', () async {
    holdExplore = Completer<void>();
    final pending = ExploreGridCache.instance.load('1');
    ExploreGridCache.instance.clear();
    holdExplore!.complete();
    await pending;
    expect(ExploreGridCache.instance.items, isEmpty);
  });
}
