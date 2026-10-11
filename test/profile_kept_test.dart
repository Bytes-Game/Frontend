// Your profile opens on its videos and their pictures right after the app
// starts, before the server answers.
//
// The profile already kept its videos between visits, but only in memory:
// the app filled it a few seconds after opening, then waited for the
// server. Opening your profile in that time showed empty boxes. Now your
// own videos are written down on the phone, and a new run of the app reads
// them before the first frame.
//
// Each test is one run of the app writing, then a "new run" (memory
// forgotten, the phone's copy read the way main() reads it) opening the
// page through the real ProfilePage.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/profile_cache.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

Map<String, dynamic> video(String id) => {
      'id': id,
      'creatorId': '5',
      'creatorUsername': 'maya',
      'videoUrl': 'https://x/$id.mp4',
      'thumbnailUrl': 'https://x/$id.jpg',
      'prefix': 'who dances',
      'subject': 'better',
      'status': 'open',
      'visibility': 'arena',
      'createdAt': '2026-09-01T10:00:00Z',
    };

List<String> mine = ['71', '72'];

/// When set, the server holds every answer until this completes — a slow
/// server on a fresh start.
Completer<void>? hold;

void fakeServer() {
  mine = ['71', '72'];
  hold = null;
  ApiService.useClient(MockClient((req) async {
    final h = hold;
    if (h != null) await h.future;
    final p = req.url.path;
    if (p.endsWith('/users/5/challenges')) {
      return http.Response(json.encode([for (final id in mine) video(id)]), 200);
    }
    if (p.endsWith('/battles')) {
      return http.Response(
          json.encode({
            'summary': {'rating': 1000, 'league': 'Bronze', 'counts': {}},
            'battles': [],
          }),
          200);
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
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );

Future<void> openOwnProfile(WidgetTester t) async {
  final dp = DataProvider()..setUser(maya());
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(ChangeNotifierProvider.value(
    value: dp,
    child: MaterialApp(home: ProfilePage(user: maya(), isEmbedded: false)),
  ));
}

/// The app closing and opening again: memory gone, the phone's copy read.
Future<void> newRun(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  ProfileCache.instance.debugReset();
  ExploreGridCache.instance.debugReset();
  await t.runAsync(() => ProfileCache.instance.restore());
}

/// Real file writes finish on the real clock, and their callbacks run on
/// the test's: so a little of each, in turn, until the write is done.
Future<void> waitForSave(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  final save = ProfileCache.instance.debugLastSave;
  expect(save, isNotNull, reason: 'something was written down');
  var done = false;
  save!.whenComplete(() => done = true).ignore();
  for (var i = 0; i < 300 && !done; i++) {
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump();
  }
  expect(done, isTrue, reason: 'the write to the phone finished');
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('profile_kept');
    ProfileCache.directory = () async => dir;
    ProfileCache.download = (url) async => Uint8List.fromList([1, 2, 3]);
    ProfileCache.instance.debugReset();
    ExploreGridCache.instance.debugReset();
    fakeServer();
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('right after the app opens, your profile shows last time\'s '
      'videos with their pictures, while the server is still thinking',
      (t) async {
    // Last run: the profile opened and the server answered.
    await openOwnProfile(t);
    await t.pump(const Duration(milliseconds: 500));
    await waitForSave(t);

    await newRun(t);
    hold = Completer<void>();
    await openOwnProfile(t);
    await t.pump();
    expect(find.byKey(const ValueKey('short_tile_71')), findsOneWidget);
    expect(find.byKey(const ValueKey('short_tile_72')), findsOneWidget);
    expect(find.byType(VideoGridPlaceholder), findsNothing);
    // The picture comes off the phone, not the network.
    final pic = ExploreGridCache.posterImage('https://x/71.jpg');
    expect(pic, isA<ResizeImage>());
    expect((pic as ResizeImage).imageProvider, isA<FileImage>());

    hold!.complete();
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('a video you delete does not come back from the phone\'s copy',
      (t) async {
    await openOwnProfile(t);
    await t.pump(const Duration(milliseconds: 500));
    await waitForSave(t);

    // Deleting takes it off the page; the page hands the new list over.
    ProfileCache.instance.replaceShorts('5', [
      for (final c in ProfileCache.instance.shorts('5')!)
        if (c.id != '72') c,
    ]);
    await waitForSave(t);

    await newRun(t);
    hold = Completer<void>();
    await openOwnProfile(t);
    await t.pump();
    expect(find.byKey(const ValueKey('short_tile_71')), findsOneWidget);
    expect(find.byKey(const ValueKey('short_tile_72')), findsNothing);
    hold!.complete();
    await t.pump(const Duration(seconds: 1));
  });

  testWidgets('somebody else\'s profile is never written down, and signing '
      'out forgets yours', (t) async {
    await openOwnProfile(t);
    await t.pump(const Duration(milliseconds: 500));
    await waitForSave(t);
    expect(File('${dir.path}/own_profile.json').existsSync(), isTrue,
        reason: 'yours is written down');

    ProfileCache.instance.clear();
    for (var i = 0;
        i < 100 && File('${dir.path}/own_profile.json').existsSync();
        i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump();
    }
    expect(File('${dir.path}/own_profile.json').existsSync(), isFalse);

    await newRun(t);
    expect(ProfileCache.instance.shorts('5'), isNull);
  });

  testWidgets('the videos sit edge to edge, with only a hairline between',
      (t) async {
    mine = ['71', '72', '73'];
    await openOwnProfile(t);
    await t.pump(const Duration(milliseconds: 500));
    final a = t.getRect(find.byKey(const ValueKey('short_tile_71')));
    final b = t.getRect(find.byKey(const ValueKey('short_tile_72')));
    expect(a.left, 0, reason: 'from the very edge of the screen');
    expect(b.left - a.right, closeTo(1, 0.01), reason: 'a hairline apart');
    await waitForSave(t);
  });

  // The page only opens instantly if the app reads the copy before Home
  // draws. Comment lines are taken out first, so a mention in a comment
  // does not count.
  test('the app reads your profile from the phone when it starts', () {
    final code = File('lib/main.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    expect(code, contains('ProfileCache.instance.restore()'));
  });
}
