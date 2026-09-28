// The search history: deleting from it, and accounts opened from search.
//
// Each test goes through the real page and watches what it asks the server,
// so a button that only hides a row, or an account tap that never records,
// turns something here red.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';

http.Response jsonBody(Object o, [int status = 200]) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Every request the page sent that changes the history.
late List<http.Request> changes;

/// When true the server refuses to delete.
late bool refuseDeletes;

/// Every search the page ran, as asked.
late List<Uri> searches;

void fakeServer() {
  changes = [];
  refuseDeletes = false;
  searches = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/search/recent') && req.method == 'GET') {
        return jsonBody({
          'recent': ['dance', 'cooking'],
          'accounts': [
            {
              'id': '5',
              'username': 'maya',
              'fullName': 'Maya Singh',
              'league': 'Gold',
              'visibility': 'public',
            },
          ],
        });
      }
      if (p.endsWith('/search/recent') && req.method == 'DELETE') {
        changes.add(req);
        return refuseDeletes
            ? jsonBody({'error': 'no'}, 503)
            : jsonBody({'ok': true});
      }
      if (p.endsWith('/search/recent/account')) {
        changes.add(req);
        return jsonBody({'ok': true});
      }
      if (p.endsWith('/search/trending')) return jsonBody({'trending': []});
      if (p.endsWith('/search')) {
        searches.add(req.url);
        return jsonBody({
          'accounts': [
            {
              'id': '6',
              'username': 'leo',
              'league': 'Silver',
              'visibility': 'public',
            },
          ],
          'battles': [],
          'shorts': [],
        });
      }
      if (p.contains('/feed/explore')) return jsonBody({'items': []});
      return jsonBody({});
    }),
  );
}

Widget app() {
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
    child: const MaterialApp(home: SearchPage()),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openHistory(WidgetTester t) async {
  await t.pumpWidget(app());
  await settle(t);
  await t.tap(find.byType(TextField));
  await settle(t);
}

Finder removeButtonOf(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byTooltip('Remove from history'),
);

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ExploreGridCache.instance.clear();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('the history shows accounts you opened as well as searches', (
    t,
  ) async {
    await openHistory(t);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Maya Singh'), findsOneWidget);
    expect(find.text('@maya · Gold'), findsOneWidget);
    expect(find.text('dance'), findsOneWidget);
    expect(find.text('cooking'), findsOneWidget);
  });

  testWidgets('× deletes one search, on the server too', (t) async {
    await openHistory(t);
    await t.tap(removeButtonOf('history_search_dance'));
    await settle(t);
    expect(find.text('dance'), findsNothing);
    expect(find.text('cooking'), findsOneWidget);
    expect(changes.single.method, 'DELETE');
    expect(changes.single.url.queryParameters, {'q': 'dance'});
  });

  testWidgets('× deletes one account', (t) async {
    await openHistory(t);
    await t.tap(removeButtonOf('history_account_5'));
    await settle(t);
    expect(find.text('Maya Singh'), findsNothing);
    expect(changes.single.url.queryParameters, {'userId': '5'});
  });

  testWidgets('a delete the server refused comes back, and says so', (t) async {
    refuseDeletes = true;
    await openHistory(t);
    await t.tap(removeButtonOf('history_search_dance'));
    await settle(t);
    expect(find.text('dance'), findsOneWidget);
    expect(find.textContaining("Couldn't delete"), findsOneWidget);
  });

  testWidgets('Clear all asks first, then empties everything', (t) async {
    await openHistory(t);
    await t.tap(find.text('Clear all'));
    await settle(t);
    expect(find.text('Clear search history?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(changes, isEmpty, reason: 'cancel sends nothing');
    expect(find.text('dance'), findsOneWidget);

    await t.tap(find.text('Clear all'));
    await settle(t);
    await t.tap(find.text('Clear all').last);
    await settle(t);
    expect(changes.single.method, 'DELETE');
    expect(changes.single.url.queryParameters, isEmpty);
    expect(find.text('dance'), findsNothing);
    expect(find.text('Maya Singh'), findsNothing);
  });

  testWidgets('opening an account from the results puts it in the history', (
    t,
  ) async {
    await openHistory(t);
    await t.enterText(find.byType(TextField), 'le');
    await t.pump(const Duration(milliseconds: 600));
    await settle(t);
    await t.tap(find.text('leo').first);
    await settle(t);
    expect(find.byType(ProfilePage), findsOneWidget);
    final record = changes.singleWhere((r) => r.method == 'POST');
    expect(json.decode(record.body), {'userId': '6'});

    // Back, and into the bar again: leo is now the first account.
    Navigator.of(t.element(find.byType(ProfilePage))).pop();
    await settle(t);
    await t.tap(find.text('Cancel'));
    await settle(t);
    await t.tap(find.byType(TextField));
    await settle(t);
    final leo = t.getTopLeft(find.byKey(const ValueKey('history_account_6')));
    final maya = t.getTopLeft(find.byKey(const ValueKey('history_account_5')));
    expect(leo.dy, lessThan(maya.dy));
  });

  testWidgets('typing searches without saving; pressing search saves it, '
      'and so does tapping a past search', (t) async {
    await openHistory(t);
    await t.enterText(find.byType(TextField), 'dan');
    await settle(t);
    expect(searches, isNotEmpty, reason: 'results come as you type');
    expect(searches.any((u) => u.queryParameters['record'] == '1'), isFalse,
        reason: '"dan" is not a search anybody made');

    searches.clear();
    await t.testTextInput.receiveAction(TextInputAction.search);
    await settle(t);
    expect(searches.single.queryParameters['q'], 'dan');
    expect(searches.single.queryParameters['record'], '1');

    // A past search, tapped, is a search made.
    await t.enterText(find.byType(TextField), '');
    await settle(t);
    searches.clear();
    await t.tap(find.text('cooking'));
    await settle(t);
    expect(searches.single.queryParameters['record'], '1');
  });

  testWidgets('no Trending, only your own history', (t) async {
    await openHistory(t);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Trending'), findsNothing);
  });
}
