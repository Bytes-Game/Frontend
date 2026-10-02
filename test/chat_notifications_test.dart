// Message notifications the app draws itself: a conversation with the
// sender's last few messages, and Reply and Mark as read that work without
// opening the app.
//
// Only the phone's notification shade is faked (FakeNotifier records what
// would be drawn) and the server (a MockClient that records requests). The
// real ChatNotifications does the rest — through the same two entry points
// Android calls.

import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_notifications.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/services/websocket_service.dart';

import 'support/dart_source.dart';

class FakeNotifier implements PhoneNotifier {
  final shown = <ChatNote>[];
  final removed = <String>[];
  int removedAll = 0;
  bool startsOk = true;
  String? launched;
  void Function(String? payload)? onTap;

  @override
  Future<bool> start({required void Function(String? payload) onTap}) async {
    this.onTap = onTap;
    return startsOk;
  }

  @override
  Future<String?> launchedFrom() async => launched;

  @override
  Future<void> show(ChatNote note) async => shown.add(note);

  @override
  Future<void> remove(int id, String tag) async => removed.add('$id/$tag');

  @override
  Future<void> removeAll() async => removedAll++;
}

late List<http.Request> requests;
var sendWorks = true;

void server() {
  requests = [];
  sendWorks = true;
  ApiService.useClient(MockClient((req) async {
    requests.add(req);
    if (req.url.path == '/api/v1/chat/send') {
      return sendWorks
          ? http.Response('{"id":"m1","message":"x"}', 200)
          : http.Response('down', 503);
    }
    if (req.url.path.contains('/chat/messages/')) {
      return http.Response('[]', 200);
    }
    return http.Response('{"ok":true}', 200);
  }));
}

List<Map<String, dynamic>> sentTo(String path) => [
      for (final r in requests)
        if (r.url.path == path) json.decode(r.body) as Map<String, dynamic>,
    ];

Map<String, dynamic> chatPush(String body, {String id = ''}) => {
      'type': 'chat',
      'senderId': '9',
      'senderUsername': 'leo',
      'messageId': id,
      'title': 'leo',
      'body': body,
      'tag': 'chat_9',
    };

void main() {
  late FakeNotifier phone;
  late Directory dir;
  final chats = ChatNotifications.instance;

  setUp(() {
    server();
    phone = FakeNotifier();
    dir = Directory.systemTemp.createTempSync('chat_notes');
    chats
      ..notifier = phone
      ..directory = (() async => dir)
      ..supported = true
      ..session = (() async => StoredSession(
            token: 'tok',
            userJson: {'id': 'u1', 'username': 'me'},
            issuedAt: DateTime.now(),
          ));
  });

  tearDown(() {
    chats.debugReset();
    ApiService.useClient(http.Client());
    ApiService.authToken = null;
    dir.deleteSync(recursive: true);
  });

  test('a message is drawn as a conversation, with Reply and Mark as read',
      () async {
    await chats.fromPush(chatPush('up for a battle?', id: 'a'));
    final note = phone.shown.single;
    expect(note.kind, NoteKind.chat);
    expect(note.title, 'leo');
    expect(note.tag, 'chat_9');
    expect(note.payload['senderId'], '9');
    expect(note.lines.map((l) => l.text), ['up for a battle?']);

    final a = note.android;
    expect(a.channelId, 'messages');
    expect(a.importance, Importance.high);
    expect(a.category, AndroidNotificationCategory.message);
    expect(a.icon, 'ic_notification');
    expect(a.color, AppTheme.primary);
    expect(a.tag, 'chat_9');
    final style = a.styleInformation as MessagingStyleInformation;
    expect(style.messages!.single.text, 'up for a battle?');
    expect(style.messages!.single.person!.name, 'leo');
    expect(a.actions!.map((x) => x.title), ['Reply', 'Mark as read']);
    final reply = a.actions!.first;
    expect(reply.id, ChatNotifications.replyAction);
    expect(reply.inputs.single.label, 'Message leo');
    expect(reply.showsUserInterface, isFalse,
        reason: 'replying must not open the app');
    expect(a.actions![1].showsUserInterface, isFalse);
  });

  test('more messages stack up in the one notification; the same one twice '
      'shows once', () async {
    await chats.fromPush(chatPush('hi', id: 'a'));
    await chats.fromPush(chatPush('you there?', id: 'b'));
    await chats.fromPush(chatPush('you there?', id: 'b'));
    expect(phone.shown.last.lines.map((l) => l.text), ['hi', 'you there?']);
    for (var i = 0; i < 10; i++) {
      await chats.fromPush(chatPush('line $i', id: 'n$i'));
    }
    expect(phone.shown.last.lines, hasLength(ChatNotifications.keep));
    expect(phone.shown.last.lines.last.text, 'line 9');
    // Every one replaces the last: one notification per chat.
    expect(phone.shown.map((n) => '${n.id}/${n.tag}').toSet(), {'1/chat_9'});
  });

  test('a missed call says so, and offers to message back', () async {
    await chats.fromPush({
      'type': 'missed_call',
      'senderId': '9',
      'senderUsername': 'leo',
      'title': 'Missed video call',
      'body': 'leo tried to call you',
    });
    final note = phone.shown.single;
    expect(note.kind, NoteKind.missedCall);
    expect(note.title, 'Missed video call');
    expect(note.tag, 'call_9');
    final a = note.android;
    expect(a.category, AndroidNotificationCategory.missedCall);
    expect(a.actions!.map((x) => x.title), ['Message']);
    expect(a.styleInformation, isA<BigTextStyleInformation>());
  });

  test('anything else in a push is not drawn by the app', () async {
    await chats.fromPush({'type': 'battle_result', 'senderId': '9'});
    await chats.fromPush({'type': 'chat'});
    expect(phone.shown, isEmpty);
    // And the kind it does draw still is.
    await chats.fromPush(chatPush('hi'));
    expect(phone.shown, hasLength(1));
  });

  test('Reply sends the message, marks the chat read, and clears it',
      () async {
    await chats.fromPush(chatPush('up for a battle?', id: 'a'));
    await chats.answer(ChatNotifications.replyAction, '  yes! ',
        json.encode(phone.shown.last.payload));
    final sent = sentTo('/api/v1/chat/send').single;
    expect(sent['senderId'], 'u1');
    expect(sent['receiverId'], '9');
    expect(sent['message'], 'yes!');
    expect(sentTo('/api/v1/chat/read').single['senderId'], '9');
    expect(requests.first.headers['Authorization'], 'Bearer tok',
        reason: 'signed in from the saved session, with the app closed');
    expect(phone.removed, containsAll(['1/chat_9', '2/call_9']));
    // What was kept for the next one is gone: it starts fresh.
    await chats.fromPush(chatPush('great', id: 'c'));
    expect(phone.shown.last.lines.map((l) => l.text), ['great']);
  });

  test("a reply that doesn't send says so", () async {
    sendWorks = false;
    await chats.fromPush(chatPush('up for a battle?', id: 'a'));
    await chats.answer(ChatNotifications.replyAction, 'yes',
        json.encode(phone.shown.last.payload));
    final note = phone.shown.last;
    expect(note.kind, NoteKind.failed);
    expect(note.title, "Couldn't send your reply");
    expect(note.body, contains('yes'));
    expect(note.android.actions, isEmpty);
    expect(note.payload['senderId'], '9', reason: 'a tap opens the chat');
    expect(sentTo('/api/v1/chat/read'), isEmpty);
  });

  test('an empty reply sends nothing', () async {
    await chats.answer(ChatNotifications.replyAction, '   ',
        json.encode({'senderId': '9'}));
    expect(requests, isEmpty);
  });

  test('Mark as read marks it read and clears it', () async {
    await chats.fromPush(chatPush('hi', id: 'a'));
    await chats.answer(ChatNotifications.readAction, null,
        json.encode(phone.shown.last.payload));
    expect(sentTo('/api/v1/chat/read').single['senderId'], '9');
    expect(sentTo('/api/v1/chat/send'), isEmpty);
    expect(phone.removed, contains('1/chat_9'));
  });

  test('nobody signed in: nothing is sent', () async {
    chats.session = () async => null;
    await chats.answer(ChatNotifications.replyAction, 'yes',
        json.encode({'senderId': '9', 'senderUsername': 'leo'}));
    expect(requests, isEmpty);
  });

  test('a phone that does not draw its own draws nothing', () async {
    chats.supported = false;
    await chats.fromPush(chatPush('hi'));
    expect(phone.shown, isEmpty);
    expect(chats.drawsOwn, isFalse);
  });

  // The two functions Android calls. Called here exactly as Android calls
  // them, so they cannot drift away from the code they hand over to.
  test('the push entry point draws; the action entry point answers',
      () async {
    await chatPushArrived(RemoteMessage(data: chatPush('hey', id: 'z')));
    expect(phone.shown.single.lines.single.text, 'hey');
    chatNotificationAction(NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      actionId: ChatNotifications.replyAction,
      input: 'on my way',
      payload: json.encode(phone.shown.single.payload),
    ));
    for (var i = 0; i < 50 && sentTo('/api/v1/chat/send').isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(sentTo('/api/v1/chat/send').single['message'], 'on my way');
  });

  testWidgets('opening the chat clears its notification', (t) async {
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
      child: const MaterialApp(
        home: ChatConversationPage(otherUserId: '9', otherUsername: 'leo'),
      ),
    ));
    await t.pump();
    expect(phone.removed, containsAll(['1/chat_9', '2/call_9']));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    EventTracker.instance.dispose();
  });

  // Android's side of the wiring cannot run here. These read the source,
  // comments stripped, so a comment describing the wiring cannot stand in
  // for it.
  test('Android is told to call the two entry points', () {
    String code(String path) => File(path)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final start = bodyOf(code('lib/services/push_service.dart'),
        'Future<bool> start() async');
    expect(start, contains('FirebaseMessaging.onBackgroundMessage(chatPushArrived)'));
    final setUp = bodyOf(code('lib/services/chat_notifications.dart'),
        'Future<bool> _setUp(');
    expect(setUp,
        contains('onDidReceiveBackgroundNotificationResponse: chatNotificationAction'));
    String xml(String path) => File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    expect(xml('android/app/src/main/AndroidManifest.xml'),
        contains('com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver'));
    expect(xml('android/app/src/main/res/drawable/ic_notification.xml'),
        contains('android:pathData'),
        reason: 'the icon the notifications name');
    expect(xml('android/app/src/main/res/raw/keep.xml'),
        contains('@drawable/ic_notification'),
        reason: 'a release build would throw the icon away');
  });
}
