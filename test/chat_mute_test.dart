// Muting a chat: hold it in the list, or tap the person at the top of an
// open chat. Mute sits next to Delete. A muted chat sends no notifications;
// its messages still arrive. It shows a crossed-out bell, and the number on
// the Messages button leaves it out.
//
// Every test checks what IS there (the request the server got, the bell)
// as well as what is not.

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
import 'package:myapp/services/chat_badge.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';

/// What the server was asked: (who, muted).
List<(String, bool)> muteSent = [];

/// When true the server refuses.
bool refuse = false;

/// Who the server has as muted.
Set<String> mutedOnServer = {};

void fakeServer() {
  muteSent = [];
  refuse = false;
  mutedOnServer = {};
  ApiService.useClient(
    MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/chat/mute')) {
        if (refuse) return http.Response('{"error":"down"}', 500);
        final body = json.decode(req.body) as Map;
        final who = body['otherUserId'] as String;
        final muted = body['muted'] as bool;
        muteSent.add((who, muted));
        muted ? mutedOnServer.add(who) : mutedOnServer.remove(who);
        return http.Response(json.encode({'muted': muted}), 200);
      }
      if (path.contains('/chat/conversations/')) {
        return http.Response(
          json.encode([
            for (final (id, name, unread) in [
              ('u2', 'alice', 2),
              ('u3', 'bob', 1),
            ])
              {
                'userId': id,
                'username': name,
                'lastMessage': 'hi',
                'unreadCount': unread,
                'muted': mutedOnServer.contains(id),
                'lastTime': DateTime.now().toUtc().toIso8601String(),
              },
          ]),
          200,
        );
      }
      if (path.contains('/chat/messages/')) return http.Response('[]', 200);
      if (path.contains('/chat/online/')) {
        return http.Response('{"online": false}', 200);
      }
      return http.Response('{}', 200);
    }),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Future<void> openList(WidgetTester t) async {
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: 'u1',
        username: 'me',
        wins: 0,
        losses: 0,
        followersCount: 0,
        followingCount: 0,
      ),
    );
  EventTracker.instance.dispose();
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DataProvider>.value(value: dp),
        Provider<WebSocketService>.value(value: WebSocketService('', '')),
      ],
      child: const MaterialApp(home: Scaffold(body: ChatListPage())),
    ),
  );
  await settle(t);
  expect(find.text('alice'), findsOneWidget);
  expect(find.text('bob'), findsOneWidget);
}

/// The crossed-out bell in [name]'s row.
Finder bellOf(String name) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(Row)).first,
  matching: find.byKey(const ValueKey('chat_muted')),
);

Future<void> holdAndPick(WidgetTester t, String name, String option) async {
  await t.longPress(find.text(name));
  await settle(t);
  expect(find.text(option), findsOneWidget);
  expect(
    find.byKey(const ValueKey('delete_chat')),
    findsOneWidget,
    reason: 'Mute sits next to Delete',
  );
  await t.tap(find.byKey(const ValueKey('mute_chat')));
  await settle(t);
}

void main() {
  setUp(() {
    fakeServer();
    ChatCache.instance.debugReset();
    ChatBadge.instance.clear();
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    ChatBadge.instance.clear();
  });

  testWidgets('hold a chat, Mute messages: the server mutes it, the row '
      'shows the bell, and the Messages number leaves it out', (t) async {
    await openList(t);
    expect(ChatBadge.instance.people.value, 2, reason: 'alice and bob');
    expect(bellOf('alice'), findsNothing);

    await holdAndPick(t, 'alice', 'Mute messages');
    expect(muteSent, [('u2', true)]);
    expect(bellOf('alice'), findsOneWidget);
    expect(bellOf('bob'), findsNothing, reason: 'only that chat');
    expect(
      find.text("Muted. You won't be notified of alice's messages."),
      findsOneWidget,
    );
    expect(ChatBadge.instance.people.value, 1, reason: 'bob only now');
    expect(
      ChatCache.instance
          .chatsFor('u1')!
          .firstWhere((c) => c['userId'] == 'u2')['muted'],
      isTrue,
      reason: 'kept that way for the next open',
    );
    // Its messages still show as unread: only the notifications stop.
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('hold it again: Unmute messages, and it is back', (t) async {
    mutedOnServer = {'u2'};
    await openList(t);
    expect(
      bellOf('alice'),
      findsOneWidget,
      reason: 'muted, as the server says',
    );
    expect(ChatBadge.instance.people.value, 1);

    await holdAndPick(t, 'alice', 'Unmute messages');
    expect(muteSent, [('u2', false)]);
    expect(bellOf('alice'), findsNothing);
    expect(
      find.text("Unmuted. You'll be notified of alice's messages again."),
      findsOneWidget,
    );
    expect(ChatBadge.instance.people.value, 2);
  });

  testWidgets('the server says no: told, and nothing changes', (t) async {
    await openList(t);
    refuse = true;
    await holdAndPick(t, 'alice', 'Mute messages');
    expect(find.text("Couldn't mute the chat. Try again."), findsOneWidget);
    expect(bellOf('alice'), findsNothing);
    expect(ChatBadge.instance.people.value, 2);
  });

  testWidgets('in a chat, tap the person at the top: Mute is there too, and '
      'says Unmute once muted', (t) async {
    await openList(t);
    await t.tap(find.text('alice'));
    await settle(t);
    expect(find.byType(ChatConversationPage), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('chat_person')));
    await settle(t);
    expect(find.text('Mute messages'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('mute_chat')));
    await settle(t);
    expect(muteSent, [('u2', true)]);

    await t.tap(find.byKey(const ValueKey('chat_person')));
    await settle(t);
    expect(find.text('Unmute messages'), findsOneWidget);
    expect(find.text('Mute messages'), findsNothing);
  });
}
