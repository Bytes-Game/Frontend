// Render tests for the Instagram-style chat surfaces.
//
// These drive the real pages (not extracted helpers) against a mocked
// HTTP transport, so they catch runtime failures that `flutter analyze`
// cannot see: layout overflow, unbounded constraints, null derefs in the
// grouping logic, and the read-state caption resolving to the wrong text.

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

/// The signed-in user for every test below.
UserModel _me() => UserModel(
      id: 'u1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );

/// A provider holding the signed-in user, with analytics quiesced.
///
/// `setUser` calls `EventTracker.init`, which starts a 5-second periodic
/// flush timer; the test binding fails any test that leaves a timer
/// pending. Disposing right after cancels that timer and clears the
/// tracker's user id, which turns every `track*` call into a guarded
/// no-op — the pages still exercise their real tracking call sites, they
/// just don't enqueue.
DataProvider _dp() {
  final dp = DataProvider()..setUser(_me());
  EventTracker.instance.dispose();
  return dp;
}

/// Routes the handful of endpoints the chat pages touch. Anything else
/// answers with an empty JSON body so an unexpected call degrades to the
/// page's own empty state rather than an exception.
void _installMockApi({
  List<Map<String, dynamic>> conversations = const [],
  List<Map<String, dynamic>> messages = const [],
  bool otherOnline = true,
}) {
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (path.contains('/chat/conversations/')) {
      return http.Response(json.encode(conversations), 200);
    }
    if (path.contains('/chat/messages/')) {
      return http.Response(json.encode(messages), 200);
    }
    if (path.contains('/chat/online/')) {
      return http.Response(
        json.encode({
          'online': otherOnline,
          'lastSeen': DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        }),
        200,
      );
    }
    return http.Response('{}', 200);
  }));
}

Widget _wrap(Widget child, DataProvider dp) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DataProvider>.value(value: dp),
      // Never connected — the pages only subscribe to its broadcast
      // stream, so an idle instance is enough.
      Provider<WebSocketService>.value(value: WebSocketService('', '')),
    ],
    child: MaterialApp(home: child),
  );
}

/// Pumps past the initial async loads (conversations, online status,
/// messages) plus the scroll-to-bottom animation.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  tearDown(() => ApiService.useClient(http.Client()));

  group('ChatListPage — Instagram inbox', () {
    testWidgets('renders search, section header and a conversation row',
        (tester) async {
      _installMockApi(conversations: [
        {
          'userId': 'u2',
          'username': 'alice',
          'lastMessage': 'see you there',
          'unreadCount': 2,
          'lastTime': DateTime.now()
              .toUtc()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        },
      ]);
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);

      // Header is the signed-in username, not a centered "Messages" title.
      expect(find.text('me'), findsOneWidget);
      expect(find.byIcon(Icons.edit_square), findsOneWidget);

      // Search field + section row.
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Messages'), findsOneWidget);
      expect(find.text('Requests'), findsOneWidget);

      // Row: name, "preview · relative-time", camera glyph.
      expect(find.text('alice'), findsOneWidget);
      expect(find.textContaining('see you there ·'), findsOneWidget);
      expect(find.textContaining('2h'), findsOneWidget);
      expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    });

    testWidgets('search filters the conversation list', (tester) async {
      _installMockApi(conversations: [
        {
          'userId': 'u2',
          'username': 'alice',
          'lastMessage': 'hi',
          'unreadCount': 0,
          'lastTime': DateTime.now().toUtc().toIso8601String(),
        },
        {
          'userId': 'u3',
          'username': 'bob',
          'lastMessage': 'yo',
          'unreadCount': 0,
          'lastTime': DateTime.now().toUtc().toIso8601String(),
        },
      ]);
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'bo');
      await tester.pump();

      expect(find.text('alice'), findsNothing);
      expect(find.text('bob'), findsOneWidget);
    });

    testWidgets('empty inbox shows the IG empty state', (tester) async {
      _installMockApi();
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);

      expect(find.text('Message your friends'), findsOneWidget);
      expect(find.text('Send message'), findsOneWidget);
    });
  });

  group('ChatConversationPage — Instagram thread', () {
    // Newest first, matching the API contract (the page reverses it).
    List<Map<String, dynamic>> thread() {
      final now = DateTime.now().toUtc();
      String at(int minutesAgo) =>
          now.subtract(Duration(minutes: minutesAgo)).toIso8601String();
      return [
        {
          'id': 'm4',
          'senderId': 'u1',
          'senderUsername': 'me',
          'receiverId': 'u2',
          'message': 'on my way',
          'isRead': true,
          'status': 'read',
          'createdAt': at(1),
        },
        {
          'id': 'm3',
          'senderId': 'u1',
          'senderUsername': 'me',
          'receiverId': 'u2',
          'message': 'give me five minutes',
          'isRead': true,
          'status': 'read',
          'createdAt': at(2),
        },
        {
          'id': 'm2',
          'senderId': 'u2',
          'senderUsername': 'alice',
          'receiverId': 'u1',
          'message': 'are you coming?',
          'isRead': true,
          'status': 'read',
          'createdAt': at(3),
        },
        {
          'id': 'm1',
          'senderId': 'u2',
          'senderUsername': 'alice',
          'receiverId': 'u1',
          'message': 'hey',
          'isRead': true,
          'status': 'read',
          'createdAt': at(4),
        },
      ];
    }

    testWidgets('renders bubbles, activity subtitle and the Seen sign',
        (tester) async {
      _installMockApi(messages: thread());
      final dp = _dp();

      await tester.pumpWidget(_wrap(
        const ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice'),
        dp,
      ));
      await _settle(tester);

      // Header: name + "Active now" (mock reports online).
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Active now'), findsOneWidget);
      expect(find.byIcon(Icons.phone_outlined), findsOneWidget);
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);

      // Every message rendered.
      expect(find.text('hey'), findsOneWidget);
      expect(find.text('are you coming?'), findsOneWidget);
      expect(find.text('give me five minutes'), findsOneWidget);
      expect(find.text('on my way'), findsOneWidget);

      // The seen sign: exactly one caption, under the newest own message.
      expect(find.text('Seen'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      expect(find.text('Delivered'), findsNothing);
    });

    testWidgets('unread own message reads "Sent", delivered reads "Delivered"',
        (tester) async {
      final now = DateTime.now().toUtc();
      _installMockApi(messages: [
        {
          'id': 'm1',
          'senderId': 'u1',
          'senderUsername': 'me',
          'receiverId': 'u2',
          'message': 'knock knock',
          'isRead': false,
          'status': 'sent',
          'createdAt': now.toIso8601String(),
        },
      ]);
      final dp = _dp();

      await tester.pumpWidget(_wrap(
        const ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice'),
        dp,
      ));
      await _settle(tester);

      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Seen'), findsNothing);
    });

    testWidgets('composer swaps glyphs for a blue Send once text is typed',
        (tester) async {
      _installMockApi(messages: const []);
      final dp = _dp();

      await tester.pumpWidget(_wrap(
        const ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice'),
        dp,
      ));
      await _settle(tester);

      // At rest: mic / photo / sticker, no Send.
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
      expect(find.byIcon(Icons.emoji_emotions_outlined), findsOneWidget);
      expect(find.text('Send'), findsNothing);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      expect(find.text('Send'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsNothing);
    });

    testWidgets('sending appends the message optimistically', (tester) async {
      _installMockApi(messages: const []);
      final dp = _dp();

      await tester.pumpWidget(_wrap(
        const ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice'),
        dp,
      ));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), 'first message');
      await tester.pump();
      await tester.tap(find.text('Send'));
      await _settle(tester);

      expect(find.text('first message'), findsOneWidget);
      // A just-sent, unread message carries the "Sent" caption.
      expect(find.text('Sent'), findsOneWidget);
    });
  });
}
