// Following someone you blocked.
//
// It used to just work: blocking ended the follow, and the next tap on
// Follow put it back. Now the server refuses, and the app says why and
// offers the way out — unblock, then the follow goes through.
//
// These tap the real Follow button on a real profile page, with only the
// server faked, and check what is ON screen: the sheet, the button, the
// note.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

/// Whether I have blocked maya, and whether maya has blocked me, as the
/// server keeps it.
bool iBlockedHer = false;
bool sheBlockedMe = false;

/// Unblocks and follows the server was sent, in order.
List<String> sent = [];

/// When true, the server will not unblock.
bool unblockFails = false;

void fakeServer() {
  sent = [];
  iBlockedHer = false;
  sheBlockedMe = false;
  unblockFails = false;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/users/maya')) {
        return http.Response(
          json.encode({'id': '5', 'username': 'maya', 'followers': 20}),
          200,
        );
      }
      if (p.endsWith('/follow')) {
        sent.add('follow');
        if (iBlockedHer) {
          return http.Response(
            json.encode({
              'error': "You've blocked this person. Unblock them to follow.",
              'reason': 'you_blocked',
            }),
            409,
          );
        }
        if (sheBlockedMe) {
          return http.Response(
            json.encode({
              'error': "You can't follow this account.",
              'reason': 'unavailable',
            }),
            403,
          );
        }
        return http.Response('{}', 200);
      }
      if (p.endsWith('/unblock')) {
        sent.add('unblock');
        if (unblockFails) return http.Response('down', 500);
        iBlockedHer = false;
        return http.Response('{}', 200);
      }
      if (p.endsWith('/battles')) {
        return http.Response(
          json.encode({'summary': {}, 'tab': 'live', 'battles': []}),
          200,
        );
      }
      if (p.endsWith('/challenges')) return http.Response('[]', 200);
      return http.Response('{}', 200);
    }),
  );
}

UserModel maya() => UserModel(
  id: '5',
  username: 'maya',
  wins: 0,
  losses: 0,
  followersCount: 20,
  followingCount: 0,
);

Future<DataProvider> openProfile(WidgetTester t) async {
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: '1',
        username: 'me',
        wins: 0,
        losses: 0,
        followersCount: 0,
        followingCount: 0,
      ),
    );
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ChangeNotifierProvider.value(
      value: dp,
      child: MaterialApp(home: ProfilePage(user: maya(), isEmbedded: false)),
    ),
  );
  await settle(t);
  return dp;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

final sheet = find.byKey(const ValueKey('blocked_follow_sheet'));

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('Follow on someone you blocked says so, and does not follow', (
    t,
  ) async {
    iBlockedHer = true;
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    expect(sheet, findsOneWidget);
    expect(find.text("You've blocked @maya"), findsOneWidget);
    expect(find.textContaining('unblock them first'), findsOneWidget);
    expect(dp.following, isNot(contains('5')));
    expect(
      find.byKey(const ValueKey('follow')),
      findsOneWidget,
      reason: 'the button flips back to Follow',
    );
  });

  testWidgets('"Unblock and follow" unblocks, then follows', (t) async {
    iBlockedHer = true;
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('blocked_follow_unblock')));
    await settle(t);
    expect(sent, ['follow', 'unblock', 'follow']);
    expect(dp.following, contains('5'));
    expect(find.byKey(const ValueKey('following')), findsOneWidget);
    expect(sheet, findsNothing);
    expect(find.text('Unblocked and following @maya'), findsOneWidget);
  });

  testWidgets('"Not now" leaves them blocked and not followed', (t) async {
    iBlockedHer = true;
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('blocked_follow_cancel')));
    await settle(t);
    expect(sent, ['follow'], reason: 'nothing unblocked');
    expect(dp.following, isNot(contains('5')));
    expect(find.byKey(const ValueKey('follow')), findsOneWidget);
  });

  testWidgets('an unblock that fails says so and does not follow', (t) async {
    iBlockedHer = true;
    unblockFails = true;
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('blocked_follow_unblock')));
    await settle(t);
    expect(sent, ['follow', 'unblock']);
    expect(dp.following, isNot(contains('5')));
    expect(find.text("Couldn't unblock @maya. Try again."), findsOneWidget);
  });

  testWidgets('someone who blocked you: a short note, never the word block', (
    t,
  ) async {
    sheBlockedMe = true;
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    expect(sheet, findsNothing);
    expect(find.text("You can't follow this account."), findsOneWidget);
    expect(find.textContaining('blocked'), findsNothing);
    expect(dp.following, isNot(contains('5')));
  });

  testWidgets('no block: Follow simply follows, no sheet', (t) async {
    final dp = await openProfile(t);
    await t.tap(find.byKey(const ValueKey('follow')));
    await settle(t);
    expect(sent, ['follow']);
    expect(dp.following, contains('5'));
    expect(sheet, findsNothing);
  });

  test('every Follow button in the app goes through followFromScreen', () {
    // Code only: a comment mentioning dp.followUser must not count either
    // way.
    String code(String path) => File(
      path,
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    const screens = [
      'lib/pages/profile_page.dart',
      'lib/pages/following_page.dart',
      'lib/pages/followers_page.dart',
      'lib/pages/notifications_page.dart',
      'lib/pages/search_page.dart',
      'lib/widgets/smart_reels_feed.dart',
    ];
    for (final s in screens) {
      expect(
        code(s),
        contains('followFromScreen(context,'),
        reason: '$s has a Follow button that does not offer to unblock',
      );
    }
    // And nothing else follows past it. The provider and the server call
    // are where followFromScreen itself ends up.
    final direct = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('data_provider.dart') ||
          f.path.endsWith('api_service.dart')) {
        continue;
      }
      if (code(f.path).contains('.followUser(')) direct.add(f.path);
    }
    expect(direct, isEmpty, reason: 'these follow without offering to unblock');
  });
}
