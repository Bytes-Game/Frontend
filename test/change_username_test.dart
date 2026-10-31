// Changing your username, once every 30 days, the way TikTok allows it.
//
// Through the real pages against a stand-in server: Edit profile opens it;
// a name is checked as it is typed; saving asks first, then keeps the fresh
// sign-in the server hands back and the account under its new name; the
// refusals say why; and while the 30 days run, the page says from when.
// And the live connection: it moves to the new name by itself, keeping
// everything that listens to it.
//
// Each test checks something that IS there — the request sent, the words
// shown, the name the connection opened with — not only what is gone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/dates.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/change_username_page.dart';
import 'package:myapp/pages/edit_profile_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/services/websocket_service.dart';

/// What the stand-in server says, and what the app asked it.
String? nextChangeAt; // the status: null means "may change now"
bool statusDown = false;
String change = 'ok'; // ok | taken | tooSoon | down
final taken = {'taken_name'};
List<String> checked = [];
List<Map<String, dynamic>> changes = [];

/// A sign-in as the server makes one, for the parts the app reads.
String signIn(String username) {
  String part(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': '1', 'username': username})}.sig';
}

void fakeServer() {
  nextChangeAt = null;
  statusDown = false;
  change = 'ok';
  checked = [];
  changes = [];
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/users/1/username') && req.method == 'GET') {
      if (statusDown) return http.Response('down', 500);
      return http.Response(
          json.encode({'username': 'maya', 'nextChangeAt': nextChangeAt}), 200);
    }
    if (path.endsWith('/users/1/username') && req.method == 'PUT') {
      final body = json.decode(req.body) as Map<String, dynamic>;
      changes.add(body);
      switch (change) {
        case 'taken':
          return http.Response(
              json.encode({'field': 'username', 'error': 'That username is taken.'}),
              409);
        case 'tooSoon':
          return http.Response(
              json.encode({
                'field': 'username',
                'error': 'You can change your username again on 20 November 2026.',
                'nextChangeAt': '2026-11-20T09:00:00Z',
                'tooSoon': true,
              }),
              409);
        case 'down':
          throw const SocketException('no network');
      }
      return http.Response(
          json.encode({
            'user': {
              'id': '1',
              'username': body['username'],
              'fullName': 'Maya K',
              'wins': 0,
              'losses': 0,
            },
            'token': signIn('${body['username']}'),
            'nextChangeAt': '2026-12-01T09:00:00Z',
          }),
          200);
    }
    if (path.endsWith('/signup/available')) {
      final name = req.url.queryParameters['username'] ?? '';
      checked.add(name);
      final free = !taken.contains(name);
      return http.Response(
          json.encode({
            'valid': true,
            'available': free,
            'reason': free ? '' : 'That username is taken.',
          }),
          200);
    }
    return http.Response('{}', 200);
  }));
}

UserModel maya() => UserModel(
      id: '1',
      username: 'maya',
      fullName: 'Maya K',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );

/// Edit profile, as the app opens it, with Maya signed in.
Future<DataProvider> pumpEditProfile(WidgetTester t) async {
  final dp = DataProvider()..setUser(maya());
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(420, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: dp),
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: const MaterialApp(home: EditProfilePage()),
  ));
  await t.pump();
  return dp;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// From Edit profile to the Change username page, loaded.
Future<DataProvider> openChangeUsername(WidgetTester t) async {
  final dp = await pumpEditProfile(t);
  await t.tap(find.byKey(const ValueKey('edit_username_change')));
  await settle(t);
  return dp;
}

Future<void> type(WidgetTester t, String name) async {
  await t.enterText(find.byKey(const ValueKey('change_username_box')), name);
  await settle(t); // past the half-second wait before asking the server
}

bool saveEnabled(WidgetTester t) =>
    t.widget<TextButton>(find.byKey(const ValueKey('change_username_save'))).onPressed !=
    null;

void main() {
  setUp(() {
    fakeServer();
    FlutterSecureStorage.setMockInitialValues({});
    SessionStore.resetForTest();
    ApiService.authToken = signIn('maya');
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('Edit profile: the Username row opens Change username', (t) async {
    await openChangeUsername(t);
    expect(find.byType(ChangeUsernamePage), findsOneWidget);
    expect(find.byKey(const ValueKey('change_username_box')), findsOneWidget);
    expect(find.textContaining('once every 30 days'), findsOneWidget);
  });

  testWidgets(
      'a free name: checked as it is typed, asked first, then changed — the '
      'fresh sign-in and the renamed account kept', (t) async {
    final dp = await openChangeUsername(t);
    await type(t, 'Maya_New');
    expect(checked, contains('maya_new'));
    expect(find.text('@maya_new is available'), findsOneWidget);
    expect(saveEnabled(t), isTrue);

    await t.tap(find.byKey(const ValueKey('change_username_save')));
    await settle(t);
    expect(find.byKey(const ValueKey('change_username_confirm')), findsOneWidget);
    expect(find.textContaining("won't be able to change it again for 30 days"),
        findsOneWidget);
    expect(changes, isEmpty, reason: 'nothing is sent before saying yes');

    await t.tap(find.byKey(const ValueKey('change_username_yes')));
    await settle(t);
    expect(changes, [
      {'username': 'maya_new'}
    ]);
    // This phone's sign-in is the fresh one, carrying the new name, and so
    // is the saved session the app restores from.
    expect(jwtUsername(ApiService.authToken!), 'maya_new');
    final saved = await SessionStore.loadFresh();
    expect(jwtUsername(saved!.token), 'maya_new');
    expect(saved.userJson['username'], 'maya_new');
    // The account is renamed everywhere the app shows it: back on Edit
    // profile, under its new name.
    expect(dp.user?.username, 'maya_new');
    expect(find.byType(ChangeUsernamePage), findsNothing);
    expect(find.text('@maya_new'), findsOneWidget);
    expect(find.textContaining('Your username is now @maya_new'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // the message's own timer
    // Keeping the account restarts the usage tracker, as any saved profile
    // does; stop it again, as the setup above does.
    EventTracker.instance.dispose();
  });

  testWidgets('a taken name says so, and cannot be saved', (t) async {
    await openChangeUsername(t);
    await type(t, 'taken_name');
    expect(find.text('That username is taken.'), findsOneWidget);
    expect(saveEnabled(t), isFalse);
  });

  testWidgets('a name that is not allowed is said at once, without asking',
      (t) async {
    await openChangeUsername(t);
    await type(t, 'ab');
    expect(find.textContaining('Use 3 to 20 characters'), findsOneWidget);
    expect(checked, isEmpty);
    expect(saveEnabled(t), isFalse);
    // Your own name is nothing to save either.
    await type(t, 'maya');
    expect(saveEnabled(t), isFalse);
  });

  testWidgets('changed less than 30 days ago: says from when, nothing to type',
      (t) async {
    final when = DateTime.now().add(const Duration(days: 12));
    nextChangeAt = when.toUtc().toIso8601String();
    await openChangeUsername(t);
    expect(find.byKey(const ValueKey('change_username_locked')), findsOneWidget);
    expect(find.textContaining(dateInWords(when)), findsOneWidget);
    expect(find.byKey(const ValueKey('change_username_box')), findsNothing);
    expect(find.byKey(const ValueKey('change_username_save')), findsNothing);
  });

  testWidgets('the server says it is too soon at Save: says from when',
      (t) async {
    change = 'tooSoon';
    final dp = await openChangeUsername(t);
    await type(t, 'maya_new');
    await t.tap(find.byKey(const ValueKey('change_username_save')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('change_username_yes')));
    await settle(t);
    expect(find.byKey(const ValueKey('change_username_locked')), findsOneWidget);
    expect(find.textContaining(dateInWords(DateTime.parse('2026-11-20T09:00:00Z').toLocal())),
        findsOneWidget);
    expect(dp.user?.username, 'maya');
  });

  testWidgets('taken at Save, a moment after the check: says so', (t) async {
    change = 'taken';
    final dp = await openChangeUsername(t);
    await type(t, 'maya_new');
    await t.tap(find.byKey(const ValueKey('change_username_save')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('change_username_yes')));
    await settle(t);
    expect(find.text('That username is taken.'), findsOneWidget);
    expect(dp.user?.username, 'maya');
    expect(jwtUsername(ApiService.authToken!), 'maya');
  });

  testWidgets('Cancel sends nothing', (t) async {
    final dp = await openChangeUsername(t);
    await type(t, 'maya_new');
    await t.tap(find.byKey(const ValueKey('change_username_save')));
    await settle(t);
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(changes, isEmpty);
    expect(dp.user?.username, 'maya');
    expect(find.byType(ChangeUsernamePage), findsOneWidget);
  });

  testWidgets('no connection at Save: says so, and nothing changes', (t) async {
    change = 'down';
    final dp = await openChangeUsername(t);
    await type(t, 'maya_new');
    await t.tap(find.byKey(const ValueKey('change_username_save')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('change_username_yes')));
    await settle(t);
    expect(find.byKey(const ValueKey('change_username_error')), findsOneWidget);
    expect(find.textContaining("Couldn't reach the server"), findsOneWidget);
    expect(dp.user?.username, 'maya');
    expect(jwtUsername(ApiService.authToken!), 'maya');
  });

  testWidgets("couldn't load: says so, with a retry that works", (t) async {
    statusDown = true;
    await openChangeUsername(t);
    expect(find.text("Couldn't load your username."), findsOneWidget);
    statusDown = false;
    await t.tap(find.byKey(const ValueKey('change_username_retry')));
    await settle(t);
    expect(find.byKey(const ValueKey('change_username_box')), findsOneWidget);
  });

  group('the live connection', () {
    late HttpServer server;
    late List<String> opened;
    late List<WebSocket> sockets;

    setUp(() async {
      opened = [];
      sockets = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        opened.add(req.uri.path);
        final socket = await WebSocketTransformer.upgrade(req);
        sockets.add(socket);
        socket.listen((_) {});
      });
    });
    tearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      await server.close(force: true);
    });

    Future<void> until(bool Function() done) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!done()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('waited 3 seconds; connections opened: $opened');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('moves to the new name by itself, keeping everything that listens',
        () async {
      final dp = DataProvider()..setUser(maya());
      final ws = WebSocketService('ws://127.0.0.1:${server.port}', 'maya');
      final follow = followUsername(ws, dp, () => dp.user?.username);
      addTearDown(() {
        dp.removeListener(follow);
        ws.dispose();
      });
      final heard = <Map<String, dynamic>>[];
      final listening = ws.events.listen(heard.add);
      addTearDown(listening.cancel);

      ws.connect();
      await until(() => opened.length == 1);
      expect(opened, ['/ws/maya']);

      // The change: the fresh sign-in, then the account under its new name.
      ApiService.authToken = signIn('maya_new');
      dp.setUser(UserModel.fromJson({
        'id': '1',
        'username': 'maya_new',
        'fullName': 'Maya K',
        'wins': 0,
        'losses': 0,
      }));
      await until(() => opened.length == 2 && ws.isConnected);
      expect(opened, ['/ws/maya', '/ws/maya_new']);

      // What arrives on the new connection reaches the same listener.
      sockets.last.add(json.encode({'type': 'typing', 'from': 'leo'}));
      await until(() => heard.isNotEmpty);
      expect(heard.single['from'], 'leo');

      // And the old one ending changes nothing: the new one stays up, and
      // no second connection opens, under either name.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(opened, ['/ws/maya', '/ws/maya_new']);
      expect(ws.isConnected, isTrue,
          reason: 'the old connection ending must not take the new one down');
      expect(ws.debugReconnectPending, isFalse,
          reason: 'a reconnect waiting would open a second connection');
      expect(ws.send({'type': 'typing', 'to': 'leo'}), isTrue);
    });

    test('a change while the first connection is still opening: one '
        'connection, under the new name', () async {
      final dp = DataProvider()..setUser(maya());
      final ws = WebSocketService('ws://127.0.0.1:${server.port}', 'maya');
      final follow = followUsername(ws, dp, () => dp.user?.username);
      addTearDown(() {
        dp.removeListener(follow);
        ws.dispose();
      });
      final heard = <Map<String, dynamic>>[];
      final listening = ws.events.listen(heard.add);
      addTearDown(listening.cancel);

      ws.connect(); // still opening when the change lands
      ApiService.authToken = signIn('maya_new');
      dp.setUser(UserModel.fromJson({
        'id': '1',
        'username': 'maya_new',
        'fullName': 'Maya K',
        'wins': 0,
        'losses': 0,
      }));
      await until(() => opened.contains('/ws/maya_new') && ws.isConnected);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(ws.isConnected, isTrue);
      expect(ws.debugReconnectPending, isFalse);
      expect(opened.where((p) => p == '/ws/maya_new'), hasLength(1));
      sockets.last.add(json.encode({'type': 'typing', 'from': 'leo'}));
      await until(() => heard.isNotEmpty);
      expect(heard.single['from'], 'leo');
    });

    test('the app keeps its connection following the name (main.dart)', () {
      final code = File('lib/main.dart')
          .readAsStringSync()
          .replaceAll(RegExp(r'^\s*//.*$', multiLine: true), '');
      expect(code, contains('followUsername(_ws, dp, () => dp.user?.username)'));
      expect(code, contains('_dp.removeListener(_followingUsername)'));
    });
  });
}
