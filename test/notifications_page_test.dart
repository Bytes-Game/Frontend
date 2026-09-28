// The notifications page: the server's list, what is new, and what a tap
// does. Each test goes through the real page and the real store, with only
// the server faked.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

String ago(Duration d) => DateTime.now().subtract(d).toUtc().toIso8601String();

late int readCalls;
late List<String> follows;

void fakeServer() {
  readCalls = 0;
  follows = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      Object body = {};
      if (p.endsWith('/notifications') && req.method == 'GET') {
        body = {
          'items': [
            {
              'id': '3',
              'type': 'friend_challenge',
              'text': 'challenged you: “Who can juggle five?”',
              'message': 'maya challenged you: “Who can juggle five?”',
              'timestamp': ago(const Duration(minutes: 5)),
              'read': false,
              'actorId': '5',
              'actorUsername': 'maya',
              'challengeId': '40',
              'challengeTitle': 'Who can juggle five?',
            },
            {
              'id': '4',
              'type': 'battle_won',
              'text': 'You won “Who can juggle five?” against leo, 14–9.',
              'message': 'You won “Who can juggle five?” against leo, 14–9.',
              'timestamp': ago(const Duration(hours: 3)),
              'read': true,
              'challengeId': '40',
            },
            {
              'id': '2',
              'type': 'follow',
              'text': 'started following you.',
              'message': 'leo started following you.',
              'timestamp': ago(const Duration(days: 2)),
              'read': true,
              'actorId': '6',
              'actorUsername': 'leo',
            },
          ],
          'unread': 1,
        };
      } else if (p.endsWith('/notifications/read')) {
        readCalls++;
        body = {'ok': true};
      } else if (p.endsWith('/follow')) {
        follows.add(req.body);
        body = {'ok': true};
      } else if (p.endsWith('/challenges/40')) {
        body = {
          'challenge': {
            'id': '40',
            'creatorId': '5',
            'creatorUsername': 'maya',
            'videoUrl': 'https://x/40.mp4',
            'prefix': 'Who can',
            'subject': 'juggle five',
            'status': 'open',
            'visibility': 'friends',
            'likes': 0,
            'views': 0,
            'createdAt': '2026-09-20T10:00:00Z',
          },
          'responses': [],
          'votes': [],
        };
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

DataProvider signedIn() {
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
  return dp;
}

Future<DataProvider> openPage(WidgetTester t) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final dp = signedIn();
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: const MaterialApp(home: NotificationsPage()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return dp;
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('shows the server\'s list: new first, each with who and '
      'what, and marks it seen', (t) async {
    final dp = await openPage(t);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Earlier'), findsOneWidget);
    // Who, in bold, then what.
    final maya = find.textContaining('challenged you', findRichText: true);
    expect(maya, findsOneWidget);
    final rich = t.widget<RichText>(maya).text as TextSpan;
    // The Text.rich wraps its spans in one more span.
    final spans = rich.children!.first as TextSpan;
    final name = spans.children!.first as TextSpan;
    expect(name.text, 'maya ');
    expect(name.style!.fontWeight, FontWeight.w800);
    // New is marked, older is not.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('note_3')),
        matching: find.byKey(const ValueKey('note_new_dot')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('note_2')),
        matching: find.byKey(const ValueKey('note_new_dot')),
      ),
      findsNothing,
    );
    expect(find.text('5m'), findsOneWidget);
    expect(find.text('2d'), findsOneWidget);
    // Seen, here and on the server.
    expect(readCalls, 1);
    expect(dp.unreadNotifications, 0);
    // And it stays under New while the page is up.
    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('a battle you won: the sentence, a green trophy, and a tap '
      'opens the battle', (t) async {
    await openPage(t);
    final row = find.byKey(const ValueKey('note_4'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining(
          'You won “Who can juggle five?” against leo, 14–9.',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    final trophy = t.widget<Icon>(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.emoji_events_rounded),
      ),
    );
    expect(trophy.color, const Color(0xFF30D158));
    await t.tap(row);
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ChallengeDetailPage), findsOneWidget);
  });

  testWidgets('a follow offers to follow back', (t) async {
    await openPage(t);
    await t.tap(find.byKey(const ValueKey('note_follow_back')));
    await t.pump(const Duration(milliseconds: 300));
    expect(follows, hasLength(1));
    expect(find.byKey(const ValueKey('note_following')), findsOneWidget);
  });

  testWidgets('tapping a challenge opens it', (t) async {
    await openPage(t);
    await t.tap(find.textContaining('challenged you', findRichText: true));
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ChallengeDetailPage), findsOneWidget);
  });

  group('the store behind the bell', () {
    test('the count comes from the server', () async {
      final dp = signedIn();
      await dp.loadNotifications();
      expect(dp.unreadNotifications, 1);
      expect(dp.notifications, hasLength(3));
    });

    test('a live one already in the list is not added twice; chat is not a '
        'notification', () async {
      final dp = signedIn();
      await dp.loadNotifications();
      dp.addNotification(
        NotificationModel.fromJson({
          'id': '3',
          'type': 'friend_challenge',
          'message': 'again',
        }),
      );
      dp.addNotification(
        NotificationModel.fromJson({'type': 'chat', 'message': 'hi'}),
      );
      expect(dp.notifications, hasLength(3));
      expect(dp.unreadNotifications, 1);
      dp.addNotification(
        NotificationModel.fromJson({
          'id': '9',
          'type': 'follow',
          'message': 'new',
        }),
      );
      expect(dp.notifications, hasLength(4));
      expect(dp.unreadNotifications, 2);
    });
  });

  test('the app loads the list when it starts, so the bell\'s count is '
      'right before the page is ever opened', () {
    final main = File('lib/main.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(main, contains('dp.loadNotifications()'));
  });
}
