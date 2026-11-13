// Asking to follow a private account.
//
// A private account's videos are for its followers. Following used to need
// nobody's say-so, so "private" kept nothing private. Now the server turns a
// follow of a private account into a request, and the owner says yes or no.
//
// These go through the real screens (profile, notifications, the lists,
// search) and the real store, with only the server faked, and check what
// is ON screen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/follow_requests_page.dart';
import 'package:myapp/pages/followers_page.dart';
import 'package:myapp/pages/following_page.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';

// ── The server, as these tests need it ──────────────────────────────────

/// Accounts that are private. maya is '5', kim is '8'.
late Set<String> privateIds;

/// Accounts I have asked to follow that have not answered.
late Set<String> iAsked;

/// Accounts I follow.
late List<String> iFollow;

/// People asking to follow me.
late List<Map<String, dynamic>> askers;

/// My notifications.
late List<Map<String, dynamic>> notes;

/// What the server was told, in order: 'follow:5', 'unfollow:5',
/// 'answer:9:true'.
late List<String> sent;

/// When true, the server does not take an answer to a request.
late bool answerFails;

/// When set, the server holds its answer about my own account until this
/// completes: a slow read, to tap during.
Completer<void>? holdMe;

/// When set, the server holds its answer to a follow until this completes.
Completer<void>? holdFollow;

http.Response jsonBody(Object o, [int status = 200]) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, dynamic> account(String id, String name) => {
  'id': id,
  'username': name,
  'league': 'Silver',
  'followers': 20,
  'visibility': privateIds.contains(id) ? 'friends' : 'public',
  if (iAsked.contains(id)) 'followRequested': true,
};

void fakeServer() {
  privateIds = {'5', '8'};
  iAsked = {};
  iFollow = [];
  askers = [];
  notes = [];
  sent = [];
  answerFails = false;
  holdMe = null;
  holdFollow = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/users/me')) {
        await holdMe?.future;
        return jsonBody({
          'id': '1',
          'username': 'me',
          'followers': 0,
          'followingList': List<String>.from(iFollow),
        });
      }
      if (p.endsWith('/users/maya')) return jsonBody(account('5', 'maya'));
      if (p.endsWith('/users/zed')) return jsonBody(account('9', 'zed'));
      if (p.endsWith('/followers') || p.endsWith('/following')) {
        return jsonBody([account('8', 'kim')]);
      }
      if (p.endsWith('/unfollow')) {
        final id = '${(json.decode(req.body) as Map)['unfollowedId']}';
        sent.add('unfollow:$id');
        iAsked.remove(id);
        iFollow.remove(id);
        return jsonBody({});
      }
      if (p.endsWith('/follow')) {
        final id = '${(json.decode(req.body) as Map)['followingId']}';
        sent.add('follow:$id');
        await holdFollow?.future;
        if (privateIds.contains(id) && !iFollow.contains(id)) {
          iAsked.add(id);
          return jsonBody({
            'requested': true,
            'message': "Requested. They'll see your request.",
          }, 202);
        }
        if (!iFollow.contains(id)) iFollow.add(id);
        return jsonBody({});
      }
      if (p.endsWith('/follow-requests')) {
        return jsonBody({'requests': askers, 'count': askers.length});
      }
      if (p.endsWith('/follow-requests/answer')) {
        final said = json.decode(req.body) as Map;
        sent.add('answer:${said['requesterId']}:${said['accept']}');
        if (answerFails) return jsonBody({'error': 'down'}, 500);
        final before = askers.length;
        askers.removeWhere((a) => a['id'] == said['requesterId']);
        if (askers.length == before) {
          return jsonBody({'error': 'gone', 'gone': true}, 404);
        }
        return jsonBody({'ok': true, 'accepted': said['accept']});
      }
      if (p.endsWith('/notifications') && req.method == 'GET') {
        return jsonBody({'items': notes, 'unread': notes.length});
      }
      if (p.endsWith('/battles')) {
        return jsonBody({'summary': {}, 'tab': 'live', 'battles': []});
      }
      if (p.endsWith('/challenges')) return jsonBody([]);
      if (p.endsWith('/search/recent')) {
        return jsonBody({'recent': [], 'accounts': []});
      }
      if (p.endsWith('/search/trending')) return jsonBody({'trending': []});
      if (p.endsWith('/search')) {
        return jsonBody({
          'accounts': [account('8', 'kim')],
          'battles': [],
          'shorts': [],
        });
      }
      if (p.contains('/feed/explore')) return jsonBody({'items': []});
      return jsonBody({});
    }),
  );
}

Map<String, dynamic> requestNote(String id, String actorId, String actor) => {
  'id': id,
  'type': 'follow_request',
  'text': 'wants to follow you.',
  'message': '$actor wants to follow you.',
  'timestamp': DateTime.now()
      .subtract(const Duration(minutes: 5))
      .toUtc()
      .toIso8601String(),
  'read': false,
  'actorId': actorId,
  'actorUsername': actor,
};

// ── The app ─────────────────────────────────────────────────────────────

UserModel person(String id, String name, {String visibility = 'public'}) =>
    UserModel(
      id: id,
      username: name,
      wins: 0,
      losses: 0,
      followersCount: 20,
      followingCount: 0,
      visibility: visibility,
    );

DataProvider signedIn() {
  final dp = DataProvider()..setUser(person('1', 'me'));
  EventTracker.instance.dispose();
  return dp;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> show(WidgetTester t, DataProvider dp, Widget page) async {
  await t.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: MaterialApp(home: page),
    ),
  );
  await settle(t);
}

/// maya's profile, opened from the copy of her the app had: [known] is
/// whether that copy says she is private.
Future<DataProvider> openMaya(
  WidgetTester t, {
  DataProvider? dp,
  bool known = true,
}) async {
  final store = dp ?? signedIn();
  await show(
    t,
    store,
    ProfilePage(
      // A new page each time, as opening it again is.
      key: UniqueKey(),
      user: person('5', 'maya', visibility: known ? 'friends' : 'public'),
      isEmbedded: false,
    ),
  );
  return store;
}

Finder key(String k) => find.byKey(ValueKey(k));

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ExploreGridCache.instance.clear();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  group('asking to follow a private account', () {
    testWidgets('Follow asks instead: the button says Requested, the page '
        'stays closed, and a note says the request was sent', (t) async {
      final dp = await openMaya(t);
      expect(key('follow'), findsOneWidget);
      expect(key('locked'), findsOneWidget);
      expect(find.textContaining('They will be asked first'), findsOneWidget);

      await t.tap(key('follow'));
      await settle(t);

      expect(sent, ['follow:5']);
      expect(key('requested'), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
      expect(key('following'), findsNothing);
      expect(key('follow'), findsNothing);
      // Asking is not following: nothing of hers opens.
      expect(dp.following, isEmpty);
      expect(key('locked_requested'), findsOneWidget);
      expect(find.textContaining('You asked to follow @maya'), findsOneWidget);
      expect(find.text('Follow request sent to @maya.'), findsOneWidget);
      // Her follower count does not move for a request.
      expect(find.text('20'), findsOneWidget);
    });

    testWidgets('tapping Requested takes the request back', (t) async {
      final dp = await openMaya(t);
      await t.tap(key('follow'));
      await settle(t);
      expect(key('requested'), findsOneWidget);

      await t.tap(key('requested'));
      await settle(t);

      expect(sent, ['follow:5', 'unfollow:5']);
      expect(key('follow'), findsOneWidget);
      expect(key('requested'), findsNothing);
      expect(dp.requested, isEmpty);
      expect(key('locked'), findsOneWidget);
    });

    testWidgets('after the app was closed and opened, her profile still '
        'says Requested: the server remembers', (t) async {
      iAsked.add('5');
      // A new store: nothing kept from before.
      await openMaya(t);
      expect(key('requested'), findsOneWidget);
      expect(key('follow'), findsNothing);
      expect(sent, isEmpty);
    });

    testWidgets('when she says yes, her profile opens up', (t) async {
      final dp = await openMaya(t);
      await t.tap(key('follow'));
      await settle(t);
      expect(key('requested'), findsOneWidget);

      // She accepts, somewhere else.
      iAsked.remove('5');
      iFollow.add('5');
      await openMaya(t, dp: dp);

      expect(key('following'), findsOneWidget);
      expect(key('requested'), findsNothing);
      expect(key('locked'), findsNothing);
      expect(key('locked_requested'), findsNothing);
      expect(dp.following, ['5']);
    });

    testWidgets('when she says no, it is Follow again', (t) async {
      final dp = await openMaya(t);
      await t.tap(key('follow'));
      await settle(t);

      // She declines, somewhere else.
      iAsked.remove('5');
      await openMaya(t, dp: dp);

      expect(key('follow'), findsOneWidget);
      expect(key('requested'), findsNothing);
      expect(key('following'), findsNothing);
      expect(key('locked'), findsOneWidget);
    });

    testWidgets('a yes that arrives while the app is open flips the button '
        'at once', (t) async {
      final dp = await openMaya(t);
      await t.tap(key('follow'));
      await settle(t);
      expect(key('requested'), findsOneWidget);

      dp.addNotification(
        NotificationModel(
          id: 'n9',
          type: 'follow_accepted',
          message: 'maya accepted your follow request.',
          text: 'accepted your follow request.',
          timestamp: DateTime.now(),
          actorId: '5',
          actorUsername: 'maya',
        ),
      );
      await settle(t);

      expect(key('following'), findsOneWidget);
      expect(key('requested'), findsNothing);
      expect(key('locked_requested'), findsNothing);
    });

    testWidgets('an account that went private since the app last saw it is '
        'asked, not followed', (t) async {
      // The app's copy says public; the server says private.
      final dp = await openMaya(t, known: false);
      expect(key('locked'), findsOneWidget);

      holdFollow = Completer<void>();
      await t.tap(key('follow'));
      await settle(t);
      // Before the server has answered: already Requested, never
      // Following, because the page has read that she is private now.
      expect(key('requested'), findsOneWidget);
      expect(key('following'), findsNothing);

      holdFollow!.complete();
      await settle(t);
      expect(key('requested'), findsOneWidget);
      expect(key('following'), findsNothing);
      expect(dp.following, isEmpty);
    });

    testWidgets('a public account is followed at once, as before', (t) async {
      privateIds.remove('5');
      final dp = await openMaya(t, known: false);
      expect(key('locked'), findsNothing);

      await t.tap(key('follow'));
      await settle(t);

      expect(key('following'), findsOneWidget);
      expect(key('requested'), findsNothing);
      expect(dp.following, ['5']);
      expect(dp.requested, isEmpty);
      expect(find.text('21'), findsOneWidget);
    });

    testWidgets('the button goes straight to Requested: it never says '
        'Following while the server is being asked', (t) async {
      holdFollow = Completer<void>();
      final dp = await openMaya(t);

      await t.tap(key('follow'));
      await settle(t);
      // The server has not answered yet.
      expect(sent, ['follow:5']);
      expect(key('requested'), findsOneWidget);
      expect(key('following'), findsNothing);
      expect(dp.following, isEmpty);
      expect(key('locked_requested'), findsOneWidget);

      holdFollow!.complete();
      await settle(t);
      expect(key('requested'), findsOneWidget);
    });

    testWidgets('signing out forgets who was asked: the next person on '
        'this phone does not see Requested', (t) async {
      askers = [account('9', 'zed')];
      final dp = await openMaya(t);
      await t.tap(key('follow'));
      await settle(t);
      await dp.loadFollowRequests();
      expect(dp.requested, {'5'});
      expect(dp.followRequests.single.id, '9');

      dp.clearData();
      expect(dp.requested, isEmpty);
      // Nor who was asking the person before.
      expect(dp.followRequests, isEmpty);
    });
  });

  group('who you follow comes from the server', () {
    test('opening the app brings the list up to date: the copy on the '
        'phone is from the last sign-in', () async {
      iFollow.addAll(['5', '6']);
      final dp = signedIn()..setFollowing(['4']);
      await dp.refreshUser();
      expect(dp.following, ['5', '6']);
    });

    test('a follow tapped while that was being read is not undone by '
        'it', () async {
      privateIds.clear();
      holdMe = Completer<void>();
      final dp = signedIn();
      final reading = dp.refreshUser();
      // The read is out. A tap, answered before it.
      expect(await dp.follow(person('5', 'maya')), FollowOutcome.followed);
      expect(dp.following, ['5']);
      // The slow answer was written before that follow: it lists nobody.
      iFollow.clear();
      holdMe!.complete();
      await reading;
      expect(dp.following, ['5']);
    });

    test('when the server cannot be asked, the list stays as it was', () async {
      ApiService.useClient(MockClient((_) async => http.Response('', 503)));
      final dp = signedIn()..setFollowing(['4']);
      await dp.refreshUser();
      expect(dp.following, ['4']);
    });
  });

  group('people asking to follow you', () {
    Future<DataProvider> openNotifications(WidgetTester t) async {
      final dp = signedIn();
      await show(t, dp, const NotificationsPage());
      return dp;
    }

    testWidgets('notifications: a row at the top counts them, and a line '
        'has Accept and Decline only while that person waits', (t) async {
      askers = [account('9', 'zed')];
      notes = [
        requestNote('n1', '9', 'zed'),
        // An older line, from somebody already answered.
        requestNote('n2', '7', 'old'),
      ];
      await openNotifications(t);

      expect(key('follow_requests_row'), findsOneWidget);
      expect(find.text('1 person is waiting for your answer'), findsOneWidget);
      expect(key('request_accept_9'), findsOneWidget);
      expect(key('request_decline_9'), findsOneWidget);
      // The answered one is only a record.
      expect(key('request_accept_7'), findsNothing);
      expect(key('request_decline_7'), findsNothing);
      expect(
        find.textContaining('wants to follow you', findRichText: true),
        findsNWidgets(2),
      );
    });

    testWidgets('with nobody waiting there is no row and no buttons', (
      t,
    ) async {
      notes = [requestNote('n2', '7', 'old')];
      await openNotifications(t);
      expect(key('follow_requests_row'), findsNothing);
      expect(find.text('Accept'), findsNothing);
      expect(
        find.textContaining('wants to follow you', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('Accept tells the server yes; the buttons and the row go, '
        'and a note says they can see your videos', (t) async {
      askers = [account('9', 'zed')];
      notes = [requestNote('n1', '9', 'zed')];
      final dp = await openNotifications(t);

      await t.tap(key('request_accept_9'));
      await settle(t);

      expect(sent, ['answer:9:true']);
      expect(key('request_accept_9'), findsNothing);
      expect(key('follow_requests_row'), findsNothing);
      expect(dp.followRequests, isEmpty);
      expect(
        find.text('@zed can now see your videos and battles.'),
        findsOneWidget,
      );
    });

    testWidgets('Decline tells the server no', (t) async {
      askers = [account('9', 'zed')];
      notes = [requestNote('n1', '9', 'zed')];
      await openNotifications(t);

      await t.tap(key('request_decline_9'));
      await settle(t);

      expect(sent, ['answer:9:false']);
      expect(key('request_decline_9'), findsNothing);
      expect(find.text("@zed's request was declined."), findsOneWidget);
    });

    testWidgets('when the server does not take the answer, the buttons '
        'come back and a note says so', (t) async {
      askers = [account('9', 'zed')];
      notes = [requestNote('n1', '9', 'zed')];
      answerFails = true;
      final dp = await openNotifications(t);

      await t.tap(key('request_accept_9'));
      await settle(t);

      expect(sent, ['answer:9:true']);
      expect(key('request_accept_9'), findsOneWidget);
      expect(key('follow_requests_row'), findsOneWidget);
      expect(dp.followRequests.single.id, '9');
      expect(
        find.text("Couldn't answer @zed's request. Try again."),
        findsOneWidget,
      );
    });

    testWidgets('a request that arrives while the page is open shows at '
        'once, with its buttons', (t) async {
      final dp = await openNotifications(t);
      expect(key('follow_requests_row'), findsNothing);

      dp.addNotification(
        NotificationModel.fromJson(requestNote('n5', '9', 'zed')),
      );
      await settle(t);

      expect(key('follow_requests_row'), findsOneWidget);
      expect(key('request_accept_9'), findsOneWidget);
    });

    testWidgets('the row opens the list of everybody waiting, each with '
        'Accept and Decline', (t) async {
      askers = [account('9', 'zed'), account('10', 'ann')];
      notes = [requestNote('n1', '9', 'zed')];
      await openNotifications(t);
      expect(find.text('2 people are waiting for your answer'), findsOneWidget);

      await t.tap(key('follow_requests_row'));
      await settle(t);

      expect(find.byType(FollowRequestsPage), findsOneWidget);
      expect(key('follow_request_9'), findsOneWidget);
      expect(key('follow_request_10'), findsOneWidget);

      // ann has no line in the notifications; she is answered from here.
      await t.tap(
        find.descendant(
          of: find.byType(FollowRequestsPage),
          matching: key('request_accept_10'),
        ),
      );
      await settle(t);
      expect(sent, ['answer:10:true']);
      expect(key('follow_request_10'), findsNothing);
      expect(key('follow_request_9'), findsOneWidget);
    });

    testWidgets('the list says so when nobody is waiting', (t) async {
      await show(t, signedIn(), const FollowRequestsPage());
      expect(key('follow_requests_none'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
    });

    testWidgets('the list reads who is waiting when it is opened on its '
        'own', (t) async {
      askers = [account('9', 'zed')];
      // A store that has not been told about anybody.
      await show(t, signedIn(), const FollowRequestsPage());
      expect(key('follow_request_9'), findsOneWidget);
      expect(key('follow_requests_none'), findsNothing);
    });

    testWidgets('when the list cannot be read again, the people already on '
        'screen stay: a failed read is not "nobody is asking"', (t) async {
      askers = [account('9', 'zed')];
      final dp = signedIn();
      await show(t, dp, const FollowRequestsPage());
      expect(key('follow_request_9'), findsOneWidget);

      ApiService.useClient(MockClient((_) async => http.Response('', 503)));
      await dp.loadFollowRequests();
      await settle(t);

      expect(key('follow_request_9'), findsOneWidget);
      expect(key('follow_requests_none'), findsNothing);
    });
  });

  group('the Follow button in lists', () {
    Future<void> asksThenTakesBack(
      WidgetTester t,
      String followKey,
      String requestedKey,
    ) async {
      expect(find.text('Requested'), findsNothing);
      await t.tap(followKey.isEmpty ? find.text('Follow') : key(followKey));
      await settle(t);
      expect(sent, ['follow:8']);
      expect(key(requestedKey), findsOneWidget);
      expect(find.text('Requested'), findsOneWidget);
      expect(find.text('Following'), findsNothing);

      // A tap on Requested takes it back; it does not ask a second time.
      await t.tap(key(requestedKey));
      await settle(t);
      expect(sent, ['follow:8', 'unfollow:8']);
      expect(key(requestedKey), findsNothing);
      expect(find.text('Requested'), findsNothing);
    }

    testWidgets('followers: a private account is asked, and Requested '
        'takes it back', (t) async {
      await show(t, signedIn(), const FollowersPage(username: 'maya'));
      expect(find.text('kim'), findsOneWidget);
      await asksThenTakesBack(t, '', 'tile_requested');
    });

    testWidgets('following: the same', (t) async {
      await show(t, signedIn(), const FollowingPage(username: 'maya'));
      expect(find.text('kim'), findsOneWidget);
      await asksThenTakesBack(t, '', 'tile_requested');
    });

    testWidgets('search results: the same', (t) async {
      await show(t, signedIn(), const SearchPage());
      await t.enterText(find.byType(TextField), 'kim');
      await settle(t);
      expect(key('search_follow'), findsOneWidget);
      await asksThenTakesBack(t, 'search_follow', 'search_requested');
      expect(key('search_follow'), findsOneWidget);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('"Follow back" on somebody private who followed you: the '
        'same', (t) async {
      notes = [
        {
          ...requestNote('n3', '8', 'kim'),
          'type': 'follow',
          'text': 'started following you.',
        },
      ];
      await show(t, signedIn(), const NotificationsPage());
      expect(key('note_follow_back'), findsOneWidget);

      await t.tap(key('note_follow_back'));
      await settle(t);
      expect(sent, ['follow:8']);
      expect(key('note_requested'), findsOneWidget);
      expect(key('note_following'), findsNothing);

      await t.tap(key('note_requested'));
      await settle(t);
      expect(sent, ['follow:8', 'unfollow:8']);
      expect(key('note_follow_back'), findsOneWidget);
    });
  });
}
