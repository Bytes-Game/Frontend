// The follower and following numbers on a profile: the server's, and they
// move the moment you follow or unfollow — they used to stay where they
// were until the page was opened again, and someone else's profile showed
// whatever copy of them the app happened to have.
//
// Each test checks numbers that ARE on screen, so a header broken into
// showing nothing cannot pass.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

/// The copy of maya the app had: hours old.
UserModel staleMaya() => UserModel(
      id: '5',
      username: 'maya',
      wins: 0,
      losses: 0,
      followersCount: 12,
      followingCount: 0,
    );

/// What the server says about maya now; null when it cannot be reached.
Map<String, dynamic>? mayaNow;

/// Follows and unfollows the server was sent.
List<String> sent = [];

void fakeServer() {
  sent = [];
  mayaNow = {
    'id': '5',
    'username': 'maya',
    'followers': 20,
    'followingList': ['1', '2', '3'],
  };
  ApiService.useClient(MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/users/maya')) {
      final now = mayaNow;
      return now == null
          ? http.Response('down', 503)
          : http.Response(json.encode(now), 200);
    }
    if (p.endsWith('/follow') || p.endsWith('/unfollow')) {
      sent.add(p.split('/').last);
      return http.Response('{}', 200);
    }
    if (p.endsWith('/battles')) {
      return http.Response(
          json.encode({'summary': {}, 'tab': 'live', 'battles': []}), 200);
    }
    if (p.endsWith('/challenges')) return http.Response('[]', 200);
    return http.Response('{}', 200);
  }));
}

Future<DataProvider> openProfile(WidgetTester t, UserModel who,
    {List<String> iFollow = const []}) async {
  final dp = DataProvider()
    ..setUser(UserModel(
      id: '1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 7,
      followingCount: iFollow.length,
      followingList: iFollow,
    ))
    ..setFollowing(List<String>.from(iFollow));
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ChangeNotifierProvider.value(
    value: dp,
    child: MaterialApp(home: ProfilePage(user: who, isEmbedded: false)),
  ));
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return dp;
}

String stat(WidgetTester t, String label) =>
    t.widget<Text>(find.byKey(ValueKey('stat_$label'))).data!;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('someone else\'s profile shows the server\'s numbers, not the '
      'old copy', (t) async {
    await openProfile(t, staleMaya());
    expect(stat(t, 'Followers'), '20');
    expect(stat(t, 'Following'), '3');
  });

  testWidgets('follow adds one to their followers; unfollow takes it away',
      (t) async {
    await openProfile(t, staleMaya());
    expect(stat(t, 'Followers'), '20');

    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    expect(sent, ['follow']);
    expect(stat(t, 'Followers'), '21');

    await t.tap(find.byKey(const ValueKey('following')));
    await settle(t);
    expect(sent, ['follow', 'unfollow']);
    expect(stat(t, 'Followers'), '20');
  });

  testWidgets('already following when it was read: unfollow takes one away',
      (t) async {
    // The server's 20 includes me.
    await openProfile(t, staleMaya(), iFollow: ['5']);
    expect(stat(t, 'Followers'), '20');
    await t.tap(find.byKey(const ValueKey('following')));
    await settle(t);
    expect(stat(t, 'Followers'), '19');
  });

  testWidgets('the server cannot be reached: the numbers the app had, and '
      'following still moves them', (t) async {
    mayaNow = null;
    await openProfile(t, staleMaya());
    expect(stat(t, 'Followers'), '12');
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    expect(stat(t, 'Followers'), '13');
  });

  testWidgets('my own profile: Following is the people I follow right now',
      (t) async {
    final me = UserModel(
      id: '1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 7,
      followingCount: 2,
      followingList: const ['5', '6'],
    );
    final dp = await openProfile(t, me, iFollow: ['5', '6']);
    expect(stat(t, 'Followers'), '7');
    expect(stat(t, 'Following'), '2');
    // Followed someone from elsewhere in the app.
    await dp.followUser(UserModel(
      id: '9',
      username: 'sam',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    ));
    await settle(t);
    expect(stat(t, 'Following'), '3');
  });
}
