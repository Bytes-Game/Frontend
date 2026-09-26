// The redesigned Search, Profile and shared parts.
//
// Every test here looks for something that IS on screen as well as for what
// was taken away, so a screen broken into showing nothing cannot pass by
// having nothing to find.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/edit_profile_page.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/widgets/user_tile.dart';

UserModel person(String id, String name, {String bio = ''}) => UserModel(
  id: id,
  username: name,
  wins: 3,
  losses: 1,
  followersCount: 12,
  followingCount: 4,
  league: 'Silver',
  rating: 1080,
  bio: bio,
);

Map<String, dynamic> challenge(int id, int responses) => {
  'id': '$id',
  'creatorId': '9',
  'creatorUsername': 'leo',
  'videoUrl': 'https://x/$id.mp4',
  'prefix': 'Who can',
  'subject': 'dance better',
  'status': responses > 0 ? 'active' : 'open',
  'views': 1200,
  'createdAt': '2026-09-20T10:00:00Z',
  'responseCount': responses,
};

http.Response jsonBody(Object o) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void fakeServer() {
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.contains('/feed/explore')) {
        return jsonBody({
          'items': [
            for (var i = 1; i <= 6; i++)
              {'type': 'challenge', 'challenge': challenge(i, i % 2)},
          ],
        });
      }
      if (p.endsWith('/search/recent')) {
        return jsonBody({
          'recent': ['dance'],
        });
      }
      if (p.endsWith('/search/trending')) {
        return jsonBody({
          'trending': ['freestyle'],
        });
      }
      if (p.endsWith('/search')) {
        return jsonBody({
          'accounts': [
            {
              'id': '5',
              'username': 'maya',
              'fullName': 'Maya Singh',
              'league': 'Gold',
              'wins': 12,
              'losses': 4,
            },
          ],
          'battles': [challenge(1, 1)],
          'shorts': [challenge(2, 0)],
        });
      }
      if (p.endsWith('/battles')) {
        return jsonBody({
          'summary': {
            'rating': 1080,
            'league': 'Silver',
            'wins': 3,
            'losses': 1,
            'counts': {'open': 1, 'live': 2, 'won': 3, 'lost': 1},
          },
          'battles': [],
        });
      }
      if (p.contains('/challenges')) return jsonBody([]);
      return jsonBody({});
    }),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Widget app(Widget home, {UserModel? me}) {
  final dp = DataProvider()..setUser(me ?? person('1', 'me'));
  EventTracker.instance.dispose();
  return ChangeNotifierProvider<DataProvider>.value(
    value: dp,
    child: MaterialApp(home: home),
  );
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ReelDiagnostics.instance.debugReset();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  group('Search', () {
    testWidgets('no title bar: the search bar is the top of the page', (
      t,
    ) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Search people, battles, shorts'), findsOneWidget);
      // Before searching: what people search for, then videos to discover.
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('Trending'), findsOneWidget);
      expect(find.text('Discover'), findsOneWidget);
      // The result tabs only arrive with results.
      expect(find.text('Accounts'), findsNothing);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('searching brings the tabs and a person card; clearing '
        'takes them away', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);

      await t.enterText(find.byType(TextField), 'may');
      await settle(t);

      expect(find.text('Top'), findsOneWidget);
      expect(find.text('Battles'), findsWidgets);
      expect(find.text('Maya Singh'), findsOneWidget);
      expect(find.text('@maya'), findsOneWidget);
      expect(find.text('12W · 4L'), findsOneWidget);

      await t.tap(find.byTooltip('Clear'));
      await settle(t);
      expect(find.text('Top'), findsNothing);
      expect(find.text('Discover'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('leaving the page opens no video on the way out', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      // The grid is on screen and has had its turn at opening previews.
      expect(find.text('Discover'), findsOneWidget);
      final before = ReelDiagnostics.instance.debugPreviewOpened;

      // Closing the page closes every tile. None of them may hand the
      // preview to a neighbour that is itself about to close — and none may
      // rebuild while the framework is tearing them down, which a debug
      // build reports as an error and fails this test.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));

      expect(ReelDiagnostics.instance.debugPreviewOpened, before);
    });
  });

  group('Profile', () {
    testWidgets('your own: edit, share and settings are icons in the bar, '
        'and the old row of buttons is gone', (t) async {
      final me = person('1', 'me', bio: 'dancer');
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app(ProfilePage(user: me, isEmbedded: false), me: me));
      await settle(t);

      expect(find.byTooltip('Edit profile'), findsOneWidget);
      expect(find.byTooltip('Share profile'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.text('Edit Profile'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
      // What is left under the arena: stats and the bio.
      expect(find.text('Followers'), findsOneWidget);
      expect(find.text('dancer'), findsOneWidget);

      await t.tap(find.byTooltip('Edit profile'));
      await settle(t);
      expect(find.byType(EditProfilePage), findsOneWidget);
    });

    testWidgets('someone else\'s: follow, plus message and battle as icons', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        app(ProfilePage(user: person('5', 'maya'), isEmbedded: false)),
      );
      await settle(t);

      expect(find.text('Follow'), findsOneWidget);
      expect(find.byTooltip('Message'), findsOneWidget);
      expect(find.byTooltip('Challenge to a battle'), findsOneWidget);
      expect(find.byTooltip('Share profile'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
      // Not yours to edit.
      expect(find.byTooltip('Edit profile'), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
    });
  });

  group('shared parts', () {
    testWidgets('a person row shows their league and record, and Follow '
        'does something', (t) async {
      var toggled = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserTile(
              user: person('5', 'maya'),
              isFollowing: false,
              onFollowToggle: () => toggled++,
            ),
          ),
        ),
      );
      expect(find.text('maya'), findsOneWidget);
      expect(find.text('Silver'), findsOneWidget);
      expect(find.text('3W · 1L'), findsOneWidget);
      await t.tap(find.text('Follow'));
      expect(toggled, 1);
    });

    testWidgets('an empty notifications page says what will appear', (t) async {
      await t.pumpWidget(app(const NotificationsPage()));
      await settle(t);
      expect(find.text('No notifications yet'), findsOneWidget);
    });
  });
}
