// The number on the Messages button: how many PEOPLE have sent you messages
// you have not read, through the real app shell, with only the server and
// the video player faked.
//
// Every test checks a number that IS there as well as one that is not, so
// a button broken into never showing anything cannot pass.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/screens/main_shell.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_badge.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// No phone, no videos: nothing here plays one.
class _NoVideos extends VideoPlayerPlatform {
  @override
  Future<void> init() async {}
}

/// What the server answers for the number.
int unreadAnswer = 0;

/// How many times the number was asked for.
int unreadAsks = 0;

/// When set, the server holds its answer for the number until this
/// completes.
Completer<void>? holdUnread;

/// The chats the server lists.
List<Map<String, dynamic>> chats = [];

Map<String, dynamic> chat(
  String id,
  String name, {
  int unread = 0,
  bool muted = false,
}) => {
  'userId': id,
  'username': name,
  'lastMessage': 'hello',
  'lastTime': DateTime.now().toUtc().toIso8601String(),
  'unreadCount': unread,
  'muted': muted,
};

void main() {
  late Directory dir;
  late WebSocketService ws;

  setUpAll(() => VideoPlayerPlatform.instance = _NoVideos());

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    dir = Directory.systemTemp.createTempSync('messages_badge');
    VideoCacheService.instance.debugSetDirectory(dir);
    ExploreGridCache.directory = () async => dir;
    ExploreGridCache.instance.debugReset();
    ChatCache.directory = () async => dir;
    ChatCache.instance.debugReset();
    ChatBadge.instance.clear();
    unreadAnswer = 0;
    unreadAsks = 0;
    holdUnread = null;
    chats = [];
    ApiService.useClient(
      MockClient((req) async {
        final path = req.url.path;
        if (path.endsWith('/api/v1/chat/unread')) {
          unreadAsks++;
          await holdUnread?.future;
          return http.Response(json.encode({'people': unreadAnswer}), 200);
        }
        if (path.contains('/chat/conversations/')) {
          return http.Response(json.encode(chats), 200);
        }
        if (path.contains('/chat/online/')) {
          return http.Response('{"online": false}', 200);
        }
        if (path.endsWith('/chat/read')) {
          return http.Response('{"ok":true}', 200);
        }
        if (path.contains('/feed')) {
          return http.Response(
            json.encode({'items': [], 'hasMore': false}),
            200,
          );
        }
        return http.Response('[]', 200);
      }),
    );
  });

  tearDown(() {
    ApiService.useClient(http.Client());
    ChatBadge.instance.clear();
    ChatCache.instance.debugReset();
    ExploreGridCache.instance.debugReset();
    ReelDiagnostics.instance.debugReset();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> frames(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// The real shell, signed in as u1.
  Future<void> openShell(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
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
    ws = WebSocketService('', '');
    EventTracker.instance.dispose();
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DataProvider>.value(value: dp),
          Provider<WebSocketService>.value(value: ws),
        ],
        child: const MaterialApp(home: MainShell()),
      ),
    );
    await frames(t);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    EventTracker.instance.dispose();
  }

  /// What the Messages button's number says, or null with none on it.
  /// Read even while a page covers the bar.
  String? badge(WidgetTester t) {
    final label = find.byKey(
      const ValueKey('messages_badge'),
      skipOffstage: false,
    );
    if (label.evaluate().isEmpty) return null;
    final on = t.widget<Badge>(
      find
          .ancestor(
            of: label,
            matching: find.byType(Badge, skipOffstage: false),
          )
          .first,
    );
    return on.isLabelVisible ? t.widget<Text>(label).data : null;
  }

  testWidgets('opening the app: the number from the server, at once', (
    t,
  ) async {
    unreadAnswer = 3;
    await openShell(t);
    expect(unreadAsks, 1);
    expect(badge(t), '3');
    // It sits on the Messages button.
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('messages_badge')),
        matching: find.byType(NavigationDestination),
      ),
      findsWidgets,
    );
    await close(t);
  });

  testWidgets('none: nothing on the button; past 99 it says 99+', (t) async {
    await openShell(t);
    expect(badge(t), isNull);
    ChatBadge.instance.people.value = 140;
    await t.pump();
    expect(badge(t), '99+');
    await close(t);
  });

  testWidgets('a message arriving live: asked again a moment later, once for '
      'a burst; not for a muted chat, nor for your own', (t) async {
    unreadAnswer = 1;
    await openShell(t);
    expect(badge(t), '1');
    unreadAnswer = 2;
    for (var i = 0; i < 4; i++) {
      ws.debugReceive({
        'type': 'chat',
        'senderId': 'u9',
        'receiverId': 'u1',
        'message': 'hi $i',
      });
    }
    await t.pump(const Duration(milliseconds: 200));
    expect(unreadAsks, 1, reason: 'not straight away');
    await frames(t, 6);
    expect(unreadAsks, 2, reason: 'one ask for four messages');
    expect(badge(t), '2');

    ws.debugReceive({
      'type': 'chat',
      'senderId': 'u8',
      'receiverId': 'u1',
      'message': 'shh',
      'muted': true,
    });
    ws.debugReceive({
      'type': 'chat',
      'senderId': 'u1',
      'receiverId': 'u9',
      'message': 'mine, from my other phone',
    });
    await frames(t, 10);
    expect(unreadAsks, 2, reason: 'a muted chat and your own change nothing');
    await close(t);
  });

  testWidgets('coming back to the app asks again', (t) async {
    unreadAnswer = 1;
    await openShell(t);
    unreadAnswer = 4;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(t);
    expect(unreadAsks, 2);
    expect(badge(t), '4');
    await close(t);
  });

  testWidgets('Messages: the list sets the number, muted chats left out; '
      'opening a chat takes it off at once', (t) async {
    chats = [
      chat('u2', 'alice', unread: 2),
      chat('u3', 'bob', unread: 5, muted: true),
      chat('u4', 'carl'),
      chat('u5', 'dina', unread: 1),
    ];
    // The server's number when the app opened was from earlier; the list
    // that then loads is newer, and the number follows it.
    unreadAnswer = 5;
    await openShell(t);
    expect(badge(t), '5');
    await t.tap(find.text('Messages'));
    await frames(t);
    expect(find.text('alice'), findsOneWidget);
    expect(badge(t), '2', reason: 'alice and dina; bob is muted');

    // Opening alice's chat: one person left at once, while the server is
    // still being asked. (It answers 7 here, so its answer shows apart.)
    unreadAnswer = 7;
    holdUnread = Completer<void>();
    final asked = unreadAsks;
    await t.tap(find.text('alice'));
    await frames(t, 4);
    expect(find.byType(ChatConversationPage), findsOneWidget);
    expect(badge(t), '1', reason: 'off at once, by the app');
    expect(
      unreadAsks,
      greaterThan(asked),
      reason: 'and the server asked, once the chat was marked read',
    );
    holdUnread!.complete();
    await frames(t);
    expect(badge(t), '7', reason: "then the server's number");
    await close(t);
  });
}
