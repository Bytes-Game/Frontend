// Opening the app at once, the way TikTok and Instagram open.
//
//   * The saved login opens the app straight away; the server renews it
//     behind. It used to be waited for — up to six seconds, with a spinner.
//   * The next videos on Home, and their pictures, are kept on the phone so
//     the next open starts on one with nothing to download first.
//
// Each test checks what IS there (signed in, the videos, the picture's
// bytes) as well as what is not.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/next_up_store.dart';
import 'package:myapp/services/profile_cache.dart';
import 'package:myapp/models/battle_model.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';
import 'package:myapp/services/session_store.dart';

String jwtWithExp(DateTime exp) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256'})}.'
      '${seg({'sub': '1', 'username': 'me', 'exp': exp.millisecondsSinceEpoch ~/ 1000})}'
      '.sig';
}

Map<String, dynamic> entry(String id) => {
      'type': 'challenge',
      'challenge': {
        'id': id,
        'prefix': 'Who can',
        'subject': 'video $id',
        'videoUrl': 'https://x/$id.mp4',
        'thumbnailUrl': 'https://x/$id.jpg',
      },
    };

void main() {
  group('the saved login opens the app at once', () {
    late Completer<http.Response> renew;
    late String token;

    setUp(() {
      token = jwtWithExp(DateTime.now().add(const Duration(days: 3)));
      FlutterSecureStorage.setMockInitialValues({
        'session_v1': json.encode({
          'token': token,
          'user': {'id': '1', 'username': 'me', 'followingList': <String>[]},
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      });
      SessionStore.resetForTest();
      renew = Completer<http.Response>();
      ApiService.useClient(MockClient((req) async {
        if (req.url.path.endsWith('/auth/refresh')) return renew.future;
        return http.Response('[]', 200);
      }));
    });
    tearDown(() {
      ApiService.clearAuth();
      ApiService.useClient(http.Client());
    });

    /// Let the server's answer work its way through.
    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 4; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump(const Duration(seconds: 1));
      }
    }

    Future<AuthProvider> restore(WidgetTester t) async {
      final auth = AuthProvider();
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => DataProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          home: Builder(builder: (context) {
            return Column(children: [
              TextButton(
                onPressed: () => auth.restoreSession(context),
                child: const Text('go'),
              ),
              TextButton(
                onPressed: () => auth.logout(context),
                child: const Text('out'),
              ),
            ]);
          }),
        ),
      ));
      await t.tap(find.text('go'));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 20));
      }
      EventTracker.instance.dispose();
      return auth;
    }

    testWidgets('signed in before the server has answered', (t) async {
      final auth = await restore(t);
      expect(renew.isCompleted, isFalse, reason: 'the server has not answered');
      expect(auth.restoring, isFalse);
      expect(auth.isAuthenticated, isTrue);
      expect(ApiService.authToken, token);
      renew.complete(http.Response('{"token":"fresh"}', 200));
      await settle(t);
    });

    testWidgets('the server then refuses it: sent to sign in', (t) async {
      final auth = await restore(t);
      expect(auth.isAuthenticated, isTrue);
      renew.complete(http.Response('no', 401));
      await settle(t);
      expect(auth.isAuthenticated, isFalse);
      expect(ApiService.authToken, isNull);
    });

    testWidgets('the server renews it: the new one is used', (t) async {
      final auth = await restore(t);
      renew.complete(http.Response('{"token":"fresh"}', 200));
      await settle(t);
      expect(auth.isAuthenticated, isTrue);
      expect(ApiService.authToken, 'fresh');
    });

    testWidgets('signing out forgets Home, the kept videos and profiles',
        (t) async {
      final auth = await restore(t);
      renew.complete(http.Response('{"token":"fresh"}', 200));
      await settle(t);
      ProfileCache.instance.keepShorts('1', []);
      ProfileCache.instance.keepRecord('1', BattleRecord.fromJson(const {}));
      SmartReelsFeed.debugKeepPlace(FeedKind.forYou);
      final dir = Directory.systemTemp.createTempSync('logout_next_up');
      addTearDown(() {
        NextUpStore.instance.debugReset();
        dir.deleteSync(recursive: true);
      });
      NextUpStore.directory = () async => dir;
      NextUpStore.download = (url) async => null;
      await t.runAsync(() async {
        await NextUpStore.instance.save('1', [entry('7')]);
        NextUpStore.instance.debugReset();
        await NextUpStore.instance.load();
      });
      // All there before signing out, so "gone after" means something.
      expect(ProfileCache.instance.shorts('1'), isNotNull);
      expect(SmartReelsFeed.debugHasKept, isTrue);
      expect(NextUpStore.instance.debugHasEntries, isTrue);
      await t.tap(find.text('out'));
      await settle(t);
      expect(auth.isAuthenticated, isFalse);
      expect(ProfileCache.instance.shorts('1'), isNull);
      expect(ProfileCache.instance.record('1'), isNull);
      expect(SmartReelsFeed.debugHasKept, isFalse);
      expect(NextUpStore.instance.debugHasEntries, isFalse);
    });

    testWidgets('the server cannot be reached: still signed in', (t) async {
      final auth = await restore(t);
      renew.complete(http.Response('down', 503));
      await settle(t);
      expect(auth.isAuthenticated, isTrue);
      expect(ApiService.authToken, token);
    });
  });

  group('the next videos kept between runs', () {
    late Directory dir;
    late List<String> fetched;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('next_up');
      NextUpStore.directory = () async => dir;
      fetched = [];
      NextUpStore.download = (url) async {
        fetched.add(url);
        return utf8.encode('picture of $url');
      };
      NextUpStore.instance.debugReset();
    });
    tearDown(() {
      NextUpStore.instance.debugReset();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// A new run of the app: nothing in memory, only what is on the phone.
    void newRun() => NextUpStore.instance.debugReset();

    test('kept, read back next run, for the same person, once', () async {
      await NextUpStore.instance.save('1', [entry('7'), entry('8')]);
      newRun();
      final got = await NextUpStore.instance.take('1');
      expect(got.map((e) => (e['challenge'] as Map)['id']), ['7', '8']);
      expect(await NextUpStore.instance.take('1'), isEmpty,
          reason: 'handed over once');
    });

    test('nothing for someone else signing in on this phone', () async {
      await NextUpStore.instance.save('1', [entry('7')]);
      newRun();
      expect(await NextUpStore.instance.take('2'), isEmpty);
    });

    test('their pictures are on the phone, so they show at once', () async {
      await NextUpStore.instance.save('1', [entry('7')]);
      expect(fetched, ['https://x/7.jpg']);
      newRun();
      await NextUpStore.instance.load();
      final f = NextUpStore.instance.posterFile('https://x/7.jpg');
      expect(f, isNotNull);
      expect(f!.readAsStringSync(), 'picture of https://x/7.jpg');
      expect(NextUpStore.instance.posterFile('https://x/other.jpg'), isNull);
    });

    test('a picture already kept is not fetched again; old ones go',
        () async {
      await NextUpStore.instance.save('1', [entry('7'), entry('8')]);
      await NextUpStore.instance.save('1', [entry('8'), entry('9')]);
      expect(fetched, ['https://x/7.jpg', 'https://x/8.jpg', 'https://x/9.jpg']);
      final files = Directory('${dir.path}/next_up_posters').listSync();
      expect(files, hasLength(2), reason: "7's picture is gone");
    });

    test('too old to open on: not shown', () async {
      await NextUpStore.instance.save('1', [entry('7')]);
      newRun();
      NextUpStore.instance.now =
          () => DateTime.now().add(NextUpStore.maxAge + const Duration(hours: 1));
      expect(await NextUpStore.instance.take('1'), isEmpty);
    });

    test('nothing left to keep empties it', () async {
      await NextUpStore.instance.save('1', [entry('7')]);
      await NextUpStore.instance.save('1', const []);
      newRun();
      expect(await NextUpStore.instance.take('1'), isEmpty);
    });

    test('signing out empties it, pictures too', () async {
      await NextUpStore.instance.save('1', [entry('7')]);
      await NextUpStore.instance.clear();
      newRun();
      expect(await NextUpStore.instance.take('1'), isEmpty);
      expect(Directory('${dir.path}/next_up_posters').existsSync(), isFalse);
    });

    test('a picture that cannot be fetched still keeps the video', () async {
      NextUpStore.download = (url) async => null;
      await NextUpStore.instance.save('1', [entry('7')]);
      newRun();
      expect(await NextUpStore.instance.take('1'), hasLength(1));
      expect(NextUpStore.instance.posterFile('https://x/7.jpg'), isNull);
    });
  });
}

