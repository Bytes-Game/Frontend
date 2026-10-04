// Messages, instant: the list of chats, and a chat opened before.
//
// The Messages tab is built fresh each time it is tapped and asked the
// server for the list every time, with grey placeholder rows until the
// answer came. A chat asked for its messages every time too, with a
// spinner. Now both open on what the app already has, and the server's
// answer replaces it when it comes.
//
// These go through the real pages, with only the server faked, and check
// what is on screen.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

Map<String, dynamic> chat(String id, String name, String last) => {
  'userId': id,
  'username': name,
  'lastMessage': last,
  'unreadCount': 0,
  'lastTime': '2026-10-04T08:00:00Z',
};

Map<String, dynamic> message(String id, String text) => {
  'id': id,
  'senderId': 'u2',
  'senderUsername': 'maya',
  'receiverId': 'u1',
  'receiverUsername': 'me',
  'message': text,
  'isRead': true,
  'status': 'read',
  'createdAt': '2026-10-04T08:00:00Z',
  'kind': 'text',
};

/// What the server answers for the list of chats.
late List<Map<String, dynamic>> serverChats;

/// What it answers for the messages with maya.
late List<Map<String, dynamic>> serverMessages;

/// When set, the server holds its answers until this completes.
Completer<void>? hold;

/// When true, the server fails.
bool down = false;

/// Every path asked for.
late List<String> asked;

void fakeServer() {
  serverChats = [];
  serverMessages = [];
  hold = null;
  down = false;
  asked = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      asked.add(p);
      if (p.contains('/chat/conversations/') || p.contains('/chat/messages/')) {
        final h = hold;
        if (h != null) await h.future;
        if (down) return http.Response('{"error":"down"}', 500);
        return http.Response(
          json.encode(
            p.contains('/chat/messages/') ? serverMessages : serverChats,
          ),
          200,
        );
      }
      if (p.contains('/online')) return http.Response('{"online":false}', 200);
      return http.Response('{}', 200);
    }),
  );
}

Widget app(Widget home, {String userId = 'u1', WebSocketService? ws}) {
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
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DataProvider>.value(value: dp),
      Provider<WebSocketService>.value(value: ws ?? WebSocketService('', '')),
    ],
    child: MaterialApp(home: home),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  EventTracker.instance.dispose();
}

const chatWithMaya = ChatConversationPage(
  otherUserId: 'u2',
  otherUsername: 'maya',
);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('chats_instant');
    ChatCache.directory = () async => dir;
    fakeServer();
  });

  tearDown(() {
    ApiService.useClient(http.Client());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Runs the app once far enough for the chats to be fetched and written
  /// down, then forgets everything in memory, as closing the app does.
  Future<void> lastRun(WidgetTester t, {String userId = 'u1'}) async {
    await t.runAsync(() async {
      await ChatCache.instance.load(userId);
      await ChatCache.instance.debugLastSave;
      ChatCache.instance.debugReset();
      await ChatCache.instance.restore();
    });
  }

  group('opening Messages', () {
    testWidgets('shows last time\'s chats on the first frame, while the '
        'new list comes', (t) async {
      serverChats = [chat('u2', 'maya', 'see you there')];
      await lastRun(t);
      serverChats = [
        chat('u4', 'nina', 'new one'),
        chat('u2', 'maya', 'see you there'),
      ];
      hold = Completer<void>();

      await t.pumpWidget(app(const ChatListPage()));
      expect(find.text('maya'), findsOneWidget, reason: 'at once');
      expect(
        find.byType(ChatListSkeleton),
        findsNothing,
        reason: 'no grey rows when there is a list to show',
      );

      hold!.complete();
      await settle(t);
      expect(find.text('nina'), findsOneWidget, reason: 'the fresh list');
      await close(t);
    });

    testWidgets('the very first time, with nothing kept, it shows '
        'placeholders and then the chats', (t) async {
      serverChats = [chat('u2', 'maya', 'hi')];
      hold = Completer<void>();
      await t.pumpWidget(app(const ChatListPage()));
      expect(find.byType(ChatListSkeleton), findsOneWidget);
      hold!.complete();
      await settle(t);
      expect(find.text('maya'), findsOneWidget);
      await close(t);
    });

    testWidgets('a list that did not arrive leaves the chats on screen', (
      t,
    ) async {
      serverChats = [chat('u2', 'maya', 'see you there')];
      await lastRun(t);
      down = true;
      await t.pumpWidget(app(const ChatListPage()));
      await settle(t);
      expect(
        find.text('maya'),
        findsOneWidget,
        reason: 'a failed request is not "no chats"',
      );
      await close(t);
    });

    testWidgets('somebody else\'s chats are not shown', (t) async {
      serverChats = [chat('u2', 'maya', 'see you there')];
      await lastRun(t, userId: 'u9');
      hold = Completer<void>();
      await t.pumpWidget(app(const ChatListPage()));
      expect(find.text('maya'), findsNothing);
      expect(find.byType(ChatListSkeleton), findsOneWidget);
      hold!.complete();
      await settle(t);
      await close(t);
    });

    testWidgets('signing out deletes them from the phone', (t) async {
      serverChats = [chat('u2', 'maya', 'see you there')];
      await lastRun(t);
      expect(File('${dir.path}/chat_list.json').existsSync(), isTrue);
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
      for (var i = 0; i < 6; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
      }
      expect(File('${dir.path}/chat_list.json').existsSync(), isFalse);
      expect(ChatCache.instance.chatsFor('u1'), isNull);
    });

    test('the app reads them before the first frame', () {
      final code = File('lib/main.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, contains('ChatCache.instance.restore()'));
    });
  });

  group('opening a chat opened before', () {
    testWidgets('shows its messages at once, while the new ones come', (
      t,
    ) async {
      serverMessages = [message('1', 'first visit')];
      await t.pumpWidget(app(chatWithMaya));
      await settle(t);
      expect(find.text('first visit'), findsOneWidget);
      await close(t);

      serverMessages = [
        message('1', 'first visit'),
        message('2', 'while you were away'),
      ];
      hold = Completer<void>();
      await t.pumpWidget(app(chatWithMaya));
      await t.pump();
      expect(find.text('first visit'), findsOneWidget, reason: 'at once');
      expect(find.byType(CircularProgressIndicator), findsNothing);

      hold!.complete();
      await settle(t);
      expect(find.text('while you were away'), findsOneWidget);
      await close(t);
    });

    testWidgets('with what came in while it was open, too', (t) async {
      serverMessages = [message('1', 'first visit')];
      final ws = WebSocketService('', '');
      await t.pumpWidget(app(chatWithMaya, ws: ws));
      await settle(t);
      ws.debugReceive({
        'type': 'chat',
        'messageId': '9',
        'senderId': 'u2',
        'senderUsername': 'maya',
        'receiverId': 'u1',
        'receiverUsername': 'me',
        'message': 'live one',
        'timestamp': '2026-10-04T08:01:00Z',
      });
      await settle(t);
      expect(find.text('live one'), findsOneWidget);
      await close(t);

      hold = Completer<void>();
      await t.pumpWidget(app(chatWithMaya));
      await t.pump();
      expect(find.text('live one'), findsOneWidget, reason: 'kept on leaving');
      hold!.complete();
      await settle(t);
      await close(t);
    });

    testWidgets('messages that did not arrive leave the chat as it was', (
      t,
    ) async {
      serverMessages = [message('1', 'first visit')];
      await t.pumpWidget(app(chatWithMaya));
      await settle(t);
      await close(t);

      down = true;
      await t.pumpWidget(app(chatWithMaya));
      await settle(t);
      expect(
        find.text('first visit'),
        findsOneWidget,
        reason: 'a failed request is not an empty chat',
      );
      await close(t);
    });

    testWidgets('a chat never opened still waits for its messages, and none '
        'are fetched for it before it opens', (t) async {
      // Fetching a chat's messages tells the other person they were read.
      serverChats = [chat('u2', 'maya', 'hi')];
      await t.pumpWidget(app(const ChatListPage()));
      await settle(t);
      expect(find.text('maya'), findsOneWidget);
      expect(asked.where((p) => p.contains('/chat/messages/')), isEmpty);
      await close(t);

      hold = Completer<void>();
      serverMessages = [message('1', 'hello')];
      await t.pumpWidget(app(chatWithMaya));
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      hold!.complete();
      await settle(t);
      expect(find.text('hello'), findsOneWidget);
      await close(t);
    });
  });
}
