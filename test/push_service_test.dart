// Notifications on the phone: registering this phone with the server, and
// a tapped notification opening the right screen.
//
// Only Google's push service is faked (a stand-in PushPlatform) and the
// server (a MockClient that records every request). The real PushService
// does the rest, through the real pages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_notifications.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/push_service.dart';
import 'package:myapp/services/websocket_service.dart';

import 'support/dart_source.dart';
import 'chat_notifications_test.dart' show FakeNotifier;

class FakePush implements PushPlatform {
  bool setUp = true;
  bool allowed = true;
  String? address = 'phone-1';
  Map<String, dynamic>? launched;
  int asked = 0;
  final refresh = StreamController<String>.broadcast();
  final taps = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Future<bool> start() async => setUp;

  @override
  Future<bool> askPermission() async {
    asked++;
    return allowed;
  }

  @override
  Future<String?> token() async => address;

  @override
  Stream<String> get tokenRefresh => refresh.stream;

  @override
  Future<Map<String, dynamic>?> launchedFrom() async => launched;

  @override
  Stream<Map<String, dynamic>> get opened => taps.stream;
}

late List<http.Request> requests;

void server() {
  requests = [];
  ApiService.useClient(MockClient((req) async {
    requests.add(req);
    if (req.url.path.contains('/chat/messages/')) {
      return http.Response('[]', 200);
    }
    if (req.url.path.contains('/challenges/')) {
      return http.Response('{}', 404);
    }
    return http.Response('{"status":"ok"}', 200);
  }));
}

List<Map<String, dynamic>> sentTo(String path) => [
      for (final r in requests)
        if (r.url.path == path) json.decode(r.body) as Map<String, dynamic>,
    ];

final nav = GlobalKey<NavigatorState>();

Widget app() {
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
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<DataProvider>.value(value: dp),
      Provider<WebSocketService>.value(value: WebSocketService('', '')),
    ],
    child: MaterialApp(
      navigatorKey: nav,
      home: const Scaffold(body: Text('home')),
    ),
  );
}

void main() {
  late FakePush push;
  late FakeNotifier drawn;

  setUp(() {
    server();
    push = FakePush();
    PushService.instance.platform = push;
    drawn = FakeNotifier();
    ChatNotifications.instance
      ..notifier = drawn
      ..supported = true
      // Nothing kept on disk: the lines are not what these tests are about.
      ..directory = () async => throw const FileSystemException('none');
  });

  tearDown(() async {
    await PushService.instance.debugReset();
    ChatNotifications.instance.debugReset();
    ApiService.useClient(http.Client());
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> end(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  }

  testWidgets('after sign-in, this phone is given to the server', (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    expect(push.asked, 1);
    final got = sentTo('/api/v1/notifications/register');
    expect(got, hasLength(1));
    expect(got.single['token'], 'phone-1');
    expect(got.single['platform'], 'fcm');
    expect(PushService.instance.token, 'phone-1');

    // A second call (the app's socket reconnecting) does not ask again.
    await PushService.instance.signedIn(navigator: nav);
    expect(push.asked, 1);

    // A new address from the phone goes to the server too.
    push.refresh.add('phone-2');
    await t.pump();
    expect(sentTo('/api/v1/notifications/register').last['token'], 'phone-2');
    await end(t);
  });

  testWidgets('this phone tells the server it draws messages itself, with '
      'Reply', (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    expect(sentTo('/api/v1/notifications/register').single['drawsOwn'], isTrue);
    await end(t);
  });

  testWidgets("a phone that can't draw its own says so, and keeps plain "
      'notifications', (t) async {
    drawn.startsOk = false;
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    final got = sentTo('/api/v1/notifications/register');
    expect(got.single['token'], 'phone-1');
    expect(got.single['drawsOwn'], isFalse);
    await end(t);
  });

  testWidgets('tapping a message notification the app drew opens that chat',
      (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    drawn.onTap!(json.encode(
        {'type': 'chat', 'senderId': 'u7', 'senderUsername': 'maya'}));
    await settle(t);
    final chat = t.widget<ChatConversationPage>(find.byType(ChatConversationPage));
    expect(chat.otherUserId, 'u7');
    await end(t);
  });

  testWidgets('a drawn message notification that started the app opens its '
      'chat', (t) async {
    drawn.launched = json.encode(
        {'type': 'chat', 'senderId': 'u7', 'senderUsername': 'maya'});
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await settle(t);
    expect(find.byType(ChatConversationPage), findsOneWidget);
    await end(t);
  });

  testWidgets('notifications not allowed: nothing is registered', (t) async {
    push.allowed = false;
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    expect(push.asked, 1);
    expect(sentTo('/api/v1/notifications/register'), isEmpty);
    await end(t);
  });

  testWidgets('Firebase not set up: the app carries on, nothing asked',
      (t) async {
    push.setUp = false;
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    expect(push.asked, 0);
    expect(requests, isEmpty);
    expect(find.text('home'), findsOneWidget);
    await end(t);
  });

  testWidgets('tapping a message notification opens that chat', (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    push.taps.add({
      'type': 'chat',
      'senderId': 'u7',
      'senderUsername': 'maya',
      'outboxId': '0',
    });
    await settle(t);
    final chat = t.widget<ChatConversationPage>(find.byType(ChatConversationPage));
    expect(chat.otherUserId, 'u7');
    expect(chat.otherUsername, 'maya');
    // A chat push is not one of the queued ones: no click is recorded.
    expect(sentTo('/api/v1/notifications/clicked'), isEmpty);
    await end(t);
  });

  testWidgets('a missed call notification opens the chat too', (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    push.taps.add({'type': 'missed_call', 'senderId': 'u7', 'senderUsername': 'maya'});
    await settle(t);
    expect(find.byType(ChatConversationPage), findsOneWidget);
    await end(t);
  });

  testWidgets('a notification that started the app opens its chat once '
      'the app is up', (t) async {
    push.launched = {'type': 'chat', 'senderId': 'u7', 'senderUsername': 'maya'};
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await settle(t);
    expect(find.byType(ChatConversationPage), findsOneWidget);
    await end(t);
  });

  testWidgets('a battle notification opens the battle, and the tap is '
      'counted', (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    push.taps.add({'deeplink': 'devf://challenge/42', 'outboxId': '17'});
    await settle(t);
    final page = t.widget<ChallengeDetailPage>(find.byType(ChallengeDetailPage));
    expect(page.challengeId, '42');
    expect(sentTo('/api/v1/notifications/clicked').single['id'], '17');
    await end(t);
  });

  testWidgets('signing out stops this phone getting their messages',
      (t) async {
    await t.pumpWidget(app());
    await PushService.instance.signedIn(navigator: nav);
    await t.pump();
    await PushService.instance.signingOut();
    expect(sentTo('/api/v1/notifications/unregister').single['token'], 'phone-1');
    expect(PushService.instance.token, isNull);
    expect(drawn.removedAll, 1,
        reason: "the old account's messages stay on the phone");
    // And taps no longer do anything for the old session.
    push.taps.add({'type': 'chat', 'senderId': 'u7', 'senderUsername': 'maya'});
    await settle(t);
    expect(find.byType(ChatConversationPage), findsNothing);
    await end(t);
  });

  // Every build has the Firebase project built in, and its values must
  // all come from one project: an app id from another project would start
  // Firebase fine and then never get a push address.
  test('this build is set up for Firebase, all from one project', () {
    expect(FirebasePushPlatform.configured, isTrue);
    final v = FirebasePushPlatform.debugValues;
    expect(v.apiKey, startsWith('AIza'));
    expect(v.appId, startsWith('1:${v.senderId}:android:'),
        reason: 'the app id is not from project ${v.senderId}');
    expect(v.projectId, isNotEmpty);
  });

  // The screen tests build their own app, so none of them goes through
  // main.dart or the real sign-out. These read the source, comments
  // stripped, so a comment describing the wiring cannot stand in for it.
  test('main.dart registers the phone; sign-out unregisters it first', () {
    String code(String path) => File(path)
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final wrapper = bodyOf(code('lib/main.dart'), 'class _WebSocketWrapperState');
    expect(wrapper,
        contains('PushService.instance.signedIn(navigator: MyApp.navigatorKey)'));
    final logout = bodyOf(code('lib/providers/auth_provider.dart'),
        'void logout(BuildContext context)');
    final out = logout.indexOf('PushService.instance.signingOut()');
    expect(out, greaterThan(-1), reason: 'sign-out no longer unregisters');
    expect(out, lessThan(logout.indexOf('ApiService.clearAuth()')),
        reason: 'unregistering must happen while still signed in');
  });
}
