// Render tests for the chat surfaces: the inbox and a thread.
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
import 'package:myapp/widgets/arena_ui.dart';

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

  group('ChatListPage — the inbox', () {
    testWidgets('renders the title, search, active strip and a chat row',
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

      // Title and the new-message button.
      expect(find.text('Messages'), findsOneWidget);
      expect(find.byTooltip('New message'), findsOneWidget);

      // Search field.
      expect(find.text('Search chats'), findsOneWidget);

      // Alice is online (the mock says so), so she is in the Active now
      // strip AND in the chat list.
      expect(find.text('Active now'), findsOneWidget);
      expect(find.text('alice'), findsNWidgets(2));

      // Row: name, last message, time, and the unread count.
      expect(find.text('see you there'), findsOneWidget);
      expect(find.text('2h'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      // The dead glyphs are gone: nothing on the row pretends to be a
      // camera, and there is no "Requests" link that only says "none".
      expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
      expect(find.text('Requests'), findsNothing);
    });

    testWidgets('nobody online, no Active now strip', (tester) async {
      _installMockApi(
        otherOnline: false,
        conversations: [
          {
            'userId': 'u2',
            'username': 'alice',
            'lastMessage': 'hi',
            'unreadCount': 0,
            'lastTime': DateTime.now().toUtc().toIso8601String(),
          },
        ],
      );
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Active now'), findsNothing);
    });

    testWidgets('tapping someone in Active now opens their chat',
        (tester) async {
      _installMockApi(conversations: [
        {
          'userId': 'u2',
          'username': 'alice',
          'lastMessage': 'hi',
          'unreadCount': 0,
          'lastTime': DateTime.now().toUtc().toIso8601String(),
        },
      ]);
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);

      // The first "alice" is the one in the Active now strip.
      await tester.tap(find.text('alice').first);
      await _settle(tester);
      expect(find.byType(ChatConversationPage), findsOneWidget);
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
      ], otherOnline: false);
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

    testWidgets('empty inbox says so and offers to start a chat',
        (tester) async {
      _installMockApi();
      final dp = _dp();

      await tester.pumpWidget(_wrap(const ChatListPage(), dp));
      await _settle(tester);

      expect(find.text('Message your friends'), findsOneWidget);
      expect(find.text('Start a chat'), findsOneWidget);
    });
  });

  group('ChatConversationPage — a thread', () {
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

    Future<void> openThread(WidgetTester tester,
        {List<Map<String, dynamic>> messages = const []}) async {
      _installMockApi(messages: messages);
      final dp = _dp();
      await tester.pumpWidget(_wrap(
        const ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice'),
        dp,
      ));
      await _settle(tester);
    }

    testWidgets('renders bubbles, activity subtitle and the Seen sign',
        (tester) async {
      await openThread(tester, messages: thread());

      // Header: name + "Active now" (mock reports online), call buttons.
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Active now'), findsOneWidget);
      expect(find.byTooltip('Audio call'), findsOneWidget);
      expect(find.byTooltip('Video call'), findsOneWidget);

      // Every message rendered.
      expect(find.text('hey'), findsOneWidget);
      expect(find.text('are you coming?'), findsOneWidget);
      expect(find.text('give me five minutes'), findsOneWidget);
      expect(find.text('on my way'), findsOneWidget);

      // The seen sign: exactly one caption, under the newest own message,
      // with the double tick.
      expect(find.text('Seen'), findsOneWidget);
      expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      expect(find.text('Delivered'), findsNothing);
    });

    testWidgets('your bubbles are plain blue, theirs plain grey', (
      tester,
    ) async {
      await openThread(tester, messages: thread());

      BoxDecoration bubbleOf(String text) => tester
          .widget<Container>(find
              .ancestor(of: find.text(text), matching: find.byType(Container))
              .first)
          .decoration! as BoxDecoration;

      final mine = bubbleOf('on my way');
      expect(mine.color, kAccent);
      expect(mine.gradient, isNull);
      final theirs = bubbleOf('hey');
      expect(theirs.color, isNot(kAccent));
      expect(theirs.gradient, isNull);
    });

    testWidgets('unread own message reads "Sent"', (tester) async {
      final now = DateTime.now().toUtc();
      await openThread(tester, messages: [
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

      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Seen'), findsNothing);
    });

    testWidgets('Send lights up once text is typed; no buttons that only say '
        '"coming soon"', (tester) async {
      await openThread(tester);
      IconBubble send() => tester.widget<IconBubble>(
          find.ancestor(of: find.byTooltip('Send'), matching: find.byType(IconBubble)));

      // At rest: Send is there but does nothing yet.
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(send().onTap, isNull);
      expect(find.byTooltip('Photo'), findsNothing);
      expect(find.byTooltip('Voice message'), findsNothing);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();

      expect(send().onTap, isNotNull);
    });

    testWidgets('sending appends the message optimistically', (tester) async {
      await openThread(tester);

      await tester.enterText(find.byType(TextField), 'first message');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await _settle(tester);

      expect(find.text('first message'), findsOneWidget);
      // A just-sent, unread message carries the "Sent" caption.
      expect(find.text('Sent'), findsOneWidget);
    });

    testWidgets('an empty chat offers openers that send with one tap',
        (tester) async {
      await openThread(tester);

      expect(find.text('Say hello to alice'), findsOneWidget);
      await tester.tap(find.text('👋 Hey!'));
      await _settle(tester);

      // It went through the real send path: a bubble with "Sent" under it,
      // and the openers are gone because the chat is no longer empty.
      expect(find.text('👋 Hey!'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Say hello to alice'), findsNothing);
    });

    testWidgets('swiping a message sideways starts a reply to it',
        (tester) async {
      await openThread(tester, messages: thread());

      expect(find.textContaining('Replying to'), findsNothing);
      await tester.drag(find.text('are you coming?'), const Offset(90, 0));
      await tester.pumpAndSettle();

      expect(find.text('Replying to alice'), findsOneWidget);
      // The banner quotes the message being replied to.
      expect(find.text('are you coming?'), findsNWidgets(2));
    });

    testWidgets('a short swipe is not a reply', (tester) async {
      await openThread(tester, messages: thread());

      // 40 pixels: past the ~18 the framework swallows before calling it a
      // drag at all, so the bubble really moves — about 22 pixels, short of
      // the reply line. A 20-pixel drag barely moves it, and would pass
      // whatever the line was set to.
      await tester.drag(find.text('are you coming?'), const Offset(40, 0));
      await tester.pumpAndSettle();

      expect(find.textContaining('Replying to'), findsNothing);
    });
  });
}
