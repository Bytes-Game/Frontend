// "Delete chat": hold a chat in the list, swipe it left, or tap the person
// at the top of an open chat. Each asks first, then asks the server to
// delete the whole chat for this person only.
//
// Every test checks what IS there (the other chat, the request the server
// got) as well as what went away, so a list broken into showing nothing
// cannot pass by having nothing to find.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';

/// What the server was asked to delete, by the other person's id.
List<String> deleted = [];

/// When true the server refuses to delete.
bool refuse = false;

void fakeServer() {
  deleted = [];
  refuse = false;
  final all = [
    for (final (id, name, last) in [
      ('u2', 'alice', 'see you there'),
      ('u3', 'bob', 'yo'),
    ])
      {
        'userId': id,
        'username': name,
        'lastMessage': last,
        'unreadCount': 0,
        'lastTime': DateTime.now().toUtc().toIso8601String(),
      },
  ];
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/chat/clear')) {
      if (refuse) return http.Response('{"error":"down"}', 500);
      deleted.add((json.decode(req.body) as Map)['otherUserId'] as String);
      return http.Response('{"cleared":true}', 200);
    }
    if (path.contains('/chat/conversations/')) {
      // Like the real server: a deleted chat is no longer listed.
      return http.Response(
        json.encode(
            all.where((c) => !deleted.contains(c['userId'])).toList()),
        200,
      );
    }
    if (path.contains('/chat/messages/')) {
      return http.Response(
        json.encode([
          {
            'id': 'm1',
            'senderId': 'u2',
            'receiverId': 'u1',
            'message': 'see you there',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        ]),
        200,
      );
    }
    if (path.contains('/chat/online/')) {
      return http.Response('{"online": false}', 200);
    }
    return http.Response('{}', 200);
  }));
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> openList(WidgetTester t) async {
  fakeServer();
  final dp = DataProvider()
    ..setUser(UserModel(
      id: 'u1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    ));
  EventTracker.instance.dispose();
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<DataProvider>.value(value: dp),
      Provider<WebSocketService>.value(value: WebSocketService('', '')),
    ],
    child: const MaterialApp(home: ChatListPage()),
  ));
  await settle(t);
  expect(find.text('alice'), findsOneWidget);
  expect(find.text('bob'), findsOneWidget);
}

Future<void> holdAndPickDelete(WidgetTester t, String name) async {
  await t.longPress(find.text(name));
  await settle(t);
  expect(find.text('Only for you'), findsOneWidget);
  await t.tap(find.byKey(const ValueKey('delete_chat')));
  await settle(t);
  expect(find.text('Delete chat with $name?'), findsOneWidget);
}

void main() {
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('hold a chat, Delete chat, Delete: the server deletes it and '
      'it leaves the list', (t) async {
    await openList(t);
    await holdAndPickDelete(t, 'alice');
    expect(find.text('This deletes the whole chat for you. alice will still '
        'have it.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('delete_chat_confirm')));
    await settle(t);

    expect(deleted, ['u2']);
    expect(find.text('alice'), findsNothing);
    expect(find.text('see you there'), findsNothing);
    expect(find.text('bob'), findsOneWidget, reason: 'only that chat goes');
  });

  testWidgets('changing your mind deletes nothing', (t) async {
    await openList(t);
    await holdAndPickDelete(t, 'alice');
    await t.tap(find.text('Cancel'));
    await settle(t);

    expect(deleted, isEmpty);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('swipe a chat left, Delete: gone', (t) async {
    await openList(t);
    await t.drag(find.text('bob'), const Offset(-500, 0));
    await settle(t);
    expect(find.text('Delete chat with bob?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('delete_chat_confirm')));
    await settle(t);

    expect(deleted, ['u3']);
    expect(find.text('bob'), findsNothing);
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('the server says no: the chat stays, and you are told',
      (t) async {
    await openList(t);
    refuse = true;
    await holdAndPickDelete(t, 'alice');
    await t.tap(find.byKey(const ValueKey('delete_chat_confirm')));
    await settle(t);

    expect(find.text('alice'), findsOneWidget);
    expect(find.text("Couldn't delete the chat. Try again."), findsOneWidget);
  });

  testWidgets('in a chat, tap the person at the top: Delete chat takes you '
      'back to a list without it', (t) async {
    await openList(t);
    await t.tap(find.text('alice'));
    await settle(t);
    expect(find.byType(ChatConversationPage), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('chat_person')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('delete_chat')));
    await settle(t);
    expect(find.text('Delete chat with alice?'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('delete_chat_confirm')));
    await settle(t);

    expect(deleted, ['u2']);
    expect(find.byType(ChatConversationPage), findsNothing);
    expect(find.text('bob'), findsOneWidget);
    expect(find.text('alice'), findsNothing);
  });
}
