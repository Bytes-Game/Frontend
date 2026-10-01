// "Seen", "Delivered", "typing…" and calls, on the real chat screens.
//
// The bug: you sent a message, they read it, and your screen kept saying
// "Sent" until you left the chat and came back. These tests open the real
// pages with the server faked, then hand the live signals in exactly as the
// server sends them (websocket debugReceive goes through the same code as a
// real message) and check the screen changes without being reloaded.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/call_page.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/call_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/call_host.dart';

import 'support/call_fakes.dart';

DataProvider _dp() {
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
  return dp;
}

String _ago(int minutes) => DateTime.now()
    .toUtc()
    .subtract(Duration(minutes: minutes))
    .toIso8601String();

Map<String, dynamic> _mine(String id, String text,
        {String status = 'sent', bool read = false}) =>
    {
      'id': id,
      'senderId': 'u1',
      'senderUsername': 'me',
      'receiverId': 'u2',
      'message': text,
      'isRead': read,
      'status': status,
      'createdAt': _ago(1),
    };

/// What the fake server answers to sending a message. Swapped per test.
Future<http.Response> Function(http.Request) _onSend =
    (_) async => http.Response(json.encode({'id': '99'}), 200);

void _server({
  List<Map<String, dynamic>> messages = const [],
  List<Map<String, dynamic>> conversations = const [],
  List<Map<String, dynamic>> notifications = const [],
}) {
  ApiService.useClient(MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/notifications') && req.method == 'GET') {
      return http.Response(
          json.encode({'items': notifications, 'unread': notifications.length}),
          200);
    }
    if (p.contains('/chat/messages/')) {
      // Newest first, as the server sends them.
      return http.Response(json.encode(messages.reversed.toList()), 200);
    }
    if (p.contains('/chat/conversations/')) {
      return http.Response(json.encode(conversations), 200);
    }
    if (p.contains('/chat/send')) return _onSend(req);
    if (p.contains('/chat/online/')) {
      return http.Response(json.encode({'online': false, 'lastSeen': ''}), 200);
    }
    return http.Response('{}', 200);
  }));
}

final _navigator = GlobalKey<NavigatorState>();

/// The app as main.dart builds it around a page: the live connection, the
/// calls, and the call screen host above the navigator.
Widget _app(Widget home, RecordingSocket socket, CallService calls,
    {SilentSounds? sounds}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DataProvider>.value(value: _dp()),
      Provider<WebSocketService>.value(value: socket),
      ChangeNotifierProvider<CallService>.value(value: calls),
    ],
    child: MaterialApp(
      navigatorKey: _navigator,
      builder: (_, child) => CallHost(
        call: calls,
        navigator: _navigator,
        sounds: sounds ?? SilentSounds(),
        child: child!,
      ),
      home: home,
    ),
  );
}

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

const _thread =
    ChatConversationPage(otherUserId: 'u2', otherUsername: 'alice');

void main() {
  late RecordingSocket socket;
  late CallService calls;
  late List<FakeCallMedia> made;

  setUp(() {
    socket = RecordingSocket();
    made = [];
    calls = fakeCalls(socket, made: made);
    _onSend = (_) async => http.Response(json.encode({'id': '99'}), 200);
  });

  tearDown(() {
    calls.dispose();
    socket.dispose();
    ApiService.useClient(http.Client());
  });

  Future<void> end(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 7));
  }

  group('your message, as it reaches them', () {
    testWidgets('Sent, then Delivered, then Seen — without reopening',
        (t) async {
      _server(messages: [_mine('m1', 'up for a battle?')]);
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      expect(find.text('Sent'), findsOneWidget);

      socket.debugReceive({
        'type': 'chat_delivered',
        'receiverId': 'u2',
        'messageIds': ['m1'],
      });
      await _settle(t, 4);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);

      socket.debugReceive({
        'type': 'chat_read',
        'readerId': 'u2',
        'readerUsername': 'alice',
      });
      await _settle(t, 4);
      expect(find.text('Seen'), findsOneWidget);
      expect(find.text('Delivered'), findsNothing);
      await end(t);
    });

    testWidgets('somebody else reading their own chat changes nothing here',
        (t) async {
      _server(messages: [_mine('m1', 'hi')]);
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      socket.debugReceive({'type': 'chat_read', 'readerId': 'u3'});
      socket.debugReceive({
        'type': 'chat_delivered',
        'receiverId': 'u3',
        'messageIds': ['m1'],
      });
      await _settle(t, 4);
      expect(find.text('Sent'), findsOneWidget);
      await end(t);
    });

    testWidgets('"Delivered" that beats the server\'s reply still lands',
        (t) async {
      // The server tells the other phone, and then this one "Delivered",
      // sometimes before its answer to the send has arrived here.
      final reply = Completer<http.Response>();
      _onSend = (_) => reply.future;
      _server();
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      await t.tap(find.text('👋 Hey!'));
      await _settle(t, 3);
      socket.debugReceive({
        'type': 'chat_delivered',
        'receiverId': 'u2',
        'messageIds': ['99'],
      });
      await _settle(t, 2);
      expect(find.text('Sent'), findsOneWidget);
      reply.complete(http.Response(json.encode({'id': 99}), 200));
      await _settle(t, 4);
      expect(find.text('Delivered'), findsOneWidget);
      await end(t);
    });

    testWidgets('a message that could not be sent says so, and a tap resends',
        (t) async {
      var fail = true;
      var tries = 0;
      _onSend = (_) async {
        tries++;
        return fail
            ? http.Response('down', 500)
            : http.Response(json.encode({'id': '99'}), 200);
      };
      _server();
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      await t.tap(find.text('👋 Hey!'));
      await _settle(t, 4);
      expect(find.text('Not sent · Tap to retry'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);

      fail = false;
      await t.tap(find.text('Not sent · Tap to retry'));
      await _settle(t, 4);
      expect(tries, 2);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Not sent · Tap to retry'), findsNothing);
      await end(t);
    });
  });

  group('typing', () {
    testWidgets('their typing shows in the header and as dots, and goes',
        (t) async {
      _server(messages: [_mine('m1', 'hi', status: 'read', read: true)]);
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      expect(find.text('typing…'), findsNothing);
      expect(find.byKey(const ValueKey('typing_bubble')), findsNothing);

      socket.debugReceive({'type': 'typing', 'from': 'u2', 'typing': true});
      await _settle(t, 4);
      expect(find.text('typing…'), findsOneWidget);
      expect(find.byKey(const ValueKey('typing_bubble')), findsOneWidget);

      socket.debugReceive({'type': 'typing', 'from': 'u2', 'typing': false});
      await _settle(t, 4);
      expect(find.text('typing…'), findsNothing);
      expect(find.byKey(const ValueKey('typing_bubble')), findsNothing);
      await end(t);
    });

    testWidgets('a lost "stopped" does not leave typing… up for ever',
        (t) async {
      _server(messages: [_mine('m1', 'hi')]);
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      socket.debugReceive({'type': 'typing', 'from': 'u2', 'typing': true});
      await _settle(t, 2);
      expect(find.text('typing…'), findsOneWidget);
      await t.pump(const Duration(seconds: 7));
      await _settle(t, 4);
      expect(find.text('typing…'), findsNothing);
      await end(t);
    });

    testWidgets('your typing is sent to them, every few seconds, then stopped',
        (t) async {
      _server(messages: [_mine('m1', 'hi')]);
      await t.pumpWidget(_app(_thread, socket, calls));
      await _settle(t);
      await t.enterText(find.byType(TextField), 'h');
      await t.pump();
      await t.enterText(find.byType(TextField), 'he');
      await t.pump();
      expect(socket.sentOf('typing'), [
        {'type': 'typing', 'to': 'u2', 'typing': true},
      ], reason: 'one signal for two keys pressed together');

      await t.enterText(find.byType(TextField), '');
      await t.pump();
      expect(socket.sentOf('typing').last['typing'], false);
      await end(t);
    });
  });

  group('the chat list', () {
    testWidgets('your last message turns to Seen, and typing shows, live',
        (t) async {
      _server(conversations: [
        {
          'userId': 'u2',
          'username': 'alice',
          'lastMessage': 'see you there',
          'lastFromMe': true,
          'lastStatus': 'delivered',
          'unreadCount': 0,
          'lastTime': _ago(5),
        },
      ]);
      await t.pumpWidget(_app(const ChatListPage(), socket, calls));
      await _settle(t);
      expect(find.text('You: see you there'), findsOneWidget);
      expect(find.text('Seen'), findsNothing);

      socket.debugReceive({'type': 'chat_read', 'readerId': 'u2'});
      await _settle(t, 3);
      expect(find.text('Seen'), findsOneWidget);

      socket.debugReceive({'type': 'typing', 'from': 'u2', 'typing': true});
      await _settle(t, 3);
      expect(find.text('typing…'), findsOneWidget);
      expect(find.text('You: see you there'), findsNothing);
      await end(t);
    });
  });

  group('calls', () {
    testWidgets('the video button rings them and the call screen comes up',
        (t) async {
      final sounds = SilentSounds();
      _server(messages: [_mine('m1', 'hi')]);
      await t.pumpWidget(_app(_thread, socket, calls, sounds: sounds));
      await _settle(t);
      await t.tap(find.byTooltip('Video call'));
      await _settle(t, 6);

      final offer = socket.sentOf('call_offer').single;
      expect(offer['to'], 'u2');
      expect(offer['video'], true);
      expect(find.byType(CallPage), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      // Your own camera fills the screen while it rings.
      expect(find.byKey(const ValueKey('fake_local_view')), findsOneWidget);

      socket.debugReceive(
          {'type': 'call_ringing', 'callId': offer['callId'], 'from': 'u2'});
      await _settle(t, 3);
      expect(find.text('Ringing…'), findsOneWidget);
      expect(sounds.played.last, 'ringback');

      socket.debugReceive({
        'type': 'call_answer',
        'callId': offer['callId'],
        'from': 'u2',
        'sdp': 'A',
      });
      await _settle(t, 3);
      made.single.onLink!(CallLink.up);
      made.single.theirPictureArrives();
      await _settle(t, 3);
      expect(find.byKey(const ValueKey('fake_remote_view')), findsOneWidget);
      expect(find.byKey(const ValueKey('my_window')), findsOneWidget);
      expect(sounds.played.last, 'stop');

      await t.tap(find.byTooltip('End'));
      await _settle(t, 3);
      expect(socket.sentOf('call_end').single['reason'], 'hangup');
      expect(find.textContaining('Call ended'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      await _settle(t, 6);
      expect(find.byType(CallPage), findsNothing, reason: 'it closes itself');
      expect(find.byType(ChatConversationPage), findsOneWidget);
      await end(t);
    });

    testWidgets('a call rings wherever you are, and Decline turns it down',
        (t) async {
      final sounds = SilentSounds();
      await t.pumpWidget(_app(
        const Scaffold(body: Text('somewhere else in the app')),
        socket,
        calls,
        sounds: sounds,
      ));
      await _settle(t, 2);
      socket.debugReceive({
        'type': 'call_offer',
        'callId': 'c9',
        'from': 'u2',
        'fromUsername': 'alice',
        'video': false,
        'sdp': 'O',
      });
      await _settle(t, 6);
      expect(find.byType(CallPage), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('Incoming call'), findsOneWidget);
      expect(sounds.played, contains('ring'));

      await t.tap(find.byTooltip('Decline'));
      await _settle(t, 3);
      expect(socket.sentOf('call_decline').single['callId'], 'c9');
      await t.pump(const Duration(seconds: 3));
      await _settle(t, 6);
      expect(find.byType(CallPage), findsNothing);
      expect(find.text('somewhere else in the app'), findsOneWidget);
      expect(sounds.played.last, 'stop');
      await end(t);
    });

    testWidgets('Accept picks up', (t) async {
      await t.pumpWidget(_app(const SizedBox(), socket, calls));
      await _settle(t, 2);
      socket.debugReceive({
        'type': 'call_offer',
        'callId': 'c9',
        'from': 'u2',
        'fromUsername': 'alice',
        'video': true,
        'sdp': 'O',
      });
      await _settle(t, 6);
      expect(find.text('Incoming video call'), findsOneWidget);
      await t.tap(find.byTooltip('Accept'));
      await _settle(t, 4);
      expect(socket.sentOf('call_answer').single['callId'], 'c9');
      expect(find.text('Connecting…'), findsOneWidget);
      calls.hangUp();
      await end(t);
    });
  });

  testWidgets('a missed call in the notifications opens the chat, to ring '
      'back', (t) async {
    _server(notifications: [
      {
        'id': '8',
        'type': 'missed_call',
        'text': 'tried to video call you.',
        'message': 'alice tried to video call you.',
        'timestamp': _ago(3),
        'read': false,
        'actorId': 'u2',
        'actorUsername': 'alice',
      },
    ]);
    await t.pumpWidget(_app(const NotificationsPage(), socket, calls));
    await _settle(t);
    expect(find.byIcon(Icons.phone_missed_rounded), findsOneWidget);
    await t.tap(find.textContaining('tried to video call you', findRichText: true));
    await _settle(t);
    final chat = t.widget<ChatConversationPage>(find.byType(ChatConversationPage));
    expect(chat.otherUserId, 'u2');
    expect(chat.otherUsername, 'alice');
    expect(find.byTooltip('Video call'), findsOneWidget);
    await end(t);
  });

  group('the live signals stay out of the notifications list', () {
    test('only real notifications reach it', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final got = <NotificationModel>[];
      final sub = socket.notificationStream.listen(got.add);
      final events = <Map<String, dynamic>>[];
      final sub2 = socket.events.listen(events.add);
      for (final type in WebSocketService.liveSignals) {
        socket.debugReceive({'type': type});
      }
      socket.debugReceive({
        'type': 'missed_call',
        'text': 'tried to call you.',
        'actorUsername': 'alice',
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.length, WebSocketService.liveSignals.length + 1);
      expect(got.map((n) => n.type), ['missed_call']);

      final dp = DataProvider();
      for (final type in WebSocketService.liveSignals) {
        dp.addNotification(
            NotificationModel(type: type, message: '', timestamp: DateTime.now()));
      }
      expect(dp.notifications, isEmpty);
      dp.addNotification(got.single);
      expect(dp.notifications.single.type, 'missed_call');
      sub.cancel();
      sub2.cancel();
    });
  });
}
