// The profile opens on its videos at once, the way Search does: what it
// showed last time is kept (ProfileCache), your own is filled in the
// background after the app opens, and fresh answers replace it.
//
// Every test looks for tiles that ARE on screen, so a page broken into
// showing nothing cannot pass by having nothing to find.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/profile_cache.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

Map<String, dynamic> video(String id) => {
      'id': id,
      'creatorId': '5',
      'creatorUsername': 'maya',
      'creatorLeague': 'Silver',
      'videoUrl': 'https://x/$id.mp4',
      'prefix': 'who dances',
      'subject': 'better',
      'status': 'open',
      'visibility': 'arena',
      'likes': 3,
      'views': 40,
      'responseCount': 0,
      'createdAt': '2026-09-01T10:00:00Z',
    };

/// How long the server takes, and what it answers for maya's videos.
Duration slow = Duration.zero;
List<String> mayasVideos = ['71', '72'];
List<String> asked = [];

void fakeServer() {
  asked = [];
  slow = Duration.zero;
  mayasVideos = ['71', '72'];
  ApiService.useClient(MockClient((req) async {
    final p = req.url.path;
    asked.add(p);
    if (slow > Duration.zero) await Future<void>.delayed(slow);
    if (p.endsWith('/users/5/challenges')) {
      return http.Response(
          json.encode([for (final id in mayasVideos) video(id)]), 200);
    }
    if (p.endsWith('/battles')) {
      final tab = req.url.queryParameters['tab'];
      return http.Response(
        json.encode({
          'summary': {'rating': 1080, 'league': 'Silver', 'counts': {}},
          'tab': tab,
          'battles': [
            if (tab == 'won')
              {
                'challengeId': '90',
                'title': 'who sings',
                'role': 'creator',
                'status': 'completed',
                'outcome': 'won',
                'myVotes': 5,
                'theirVotes': 2,
                'opponent': 'leo',
                'createdAt': '2026-09-01T10:00:00Z',
                'video': video('90'),
              },
          ],
        }),
        200,
      );
    }
    if (p.contains('/saved/')) return http.Response('[]', 200);
    if (p.endsWith('/likes')) {
      return http.Response('{"items":[],"hasMore":false}', 200);
    }
    return http.Response('{}', 200);
  }));
}

UserModel maya() => UserModel(
      id: '5',
      username: 'maya',
      wins: 3,
      losses: 1,
      followersCount: 12,
      followingCount: 4,
    );

Future<void> openProfile(WidgetTester t) async {
  final dp = DataProvider()
    ..setUser(UserModel(
      id: '1',
      username: 'me',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    ));
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ChangeNotifierProvider.value(
    value: dp,
    child: MaterialApp(home: ProfilePage(user: maya(), isEmbedded: false)),
  ));
}

void main() {
  setUp(() {
    fakeServer();
    ProfileCache.instance.clear();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('kept from last time: the videos are there at once, before '
      'the server answers', (t) async {
    ProfileCache.instance.keepShorts(
        '5', [ChallengeModel.fromJson(video('71'))]);
    slow = const Duration(seconds: 3);
    await openProfile(t);
    await t.pump();
    expect(find.byKey(const ValueKey('short_tile_71')), findsOneWidget);
    expect(find.byType(VideoGridPlaceholder), findsNothing);
    // The fresh answer replaces it.
    await t.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('short_tile_72')), findsOneWidget);
    expect(ProfileCache.instance.shorts('5')!.map((c) => c.id), ['71', '72']);
  });

  testWidgets('nothing kept: placeholders, then the videos, which are then '
      'kept', (t) async {
    slow = const Duration(seconds: 1);
    await openProfile(t);
    await t.pump();
    expect(find.byType(VideoGridPlaceholder), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.byKey(const ValueKey('short_tile_71')), findsOneWidget);
    expect(ProfileCache.instance.shorts('5'), hasLength(2));
  });

  testWidgets('a failed answer does not wipe the kept videos', (t) async {
    ProfileCache.instance.keepShorts(
        '5', [ChallengeModel.fromJson(video('71'))]);
    mayasVideos = [];
    await openProfile(t);
    await t.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('short_tile_71')), findsOneWidget);
    expect(find.text('No posts'), findsNothing);
  });

  testWidgets('filled in the background: a battle tab is there at once',
      (t) async {
    await t.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
        onPressed: () => ProfileCache.instance.prefetch(context, '5'),
        child: const Text('go'),
      );
    })));
    await t.tap(find.text('go'));
    await t.pump(const Duration(seconds: 1));
    expect(ProfileCache.instance.shorts('5'), hasLength(2));
    expect(ProfileCache.instance.battles('5', 'won'), hasLength(1));
    expect(ProfileCache.instance.record('5')?.rating, 1080);

    slow = const Duration(seconds: 3);
    await openProfile(t);
    await t.pump();
    final wonTab = find.descendant(
        of: find.byType(TabBar), matching: find.text('Won'));
    await t.ensureVisible(wonTab);
    await t.pump();
    await t.tap(wonTab);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('battle_tile_90')), findsOneWidget,
        reason: 'from what was kept, while the server is still thinking');
    await t.pump(const Duration(seconds: 4));
  });

  // Nothing above goes through the app's own start: this does. The shell
  // has to start the profile prefetch, or the first visit waits after all.
  // Comment lines are taken out first, so a mention in a comment does not
  // count.
  test('the app starts filling your profile in the background', () {
    final code = File('lib/screens/main_shell.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code, contains('ProfileCache.instance.prefetch(context, '));
  });

  test('signing out empties it', () {
    ProfileCache.instance
      ..keepShorts('5', [ChallengeModel.fromJson(video('71'))])
      ..keepSaved('5', [ChallengeModel.fromJson(video('72'))])
      ..clear();
    expect(ProfileCache.instance.shorts('5'), isNull);
    expect(ProfileCache.instance.saved('5'), isNull);
  });
}
