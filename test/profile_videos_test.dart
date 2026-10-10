// A profile's tabs are videos, drawn like Search, and a tap plays that
// tab's videos — only them, in order. Never the recommendations.
//
// Each test goes through the real tap on the real profile page, and counts
// the feed requests, so a tap quietly routed back to the explore feed goes
// red here even when a video still appears.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/pages/liked_videos_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/video_player_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

const words = {
  '11': 'eleven',
  '12': 'twelve',
  '13': 'thirteen',
  '21': 'twenty-one',
  '31': 'thirty-one',
  '32': 'thirty-two',
  '33': 'thirty-three',
};

Map<String, dynamic> video(String id, {String by = 'maya', bool vs = false}) =>
    {
      'id': id,
      'creatorId': by == 'maya' ? '5' : '8',
      'creatorUsername': by,
      'creatorLeague': 'Silver',
      'videoUrl': 'https://x/$id.mp4',
      'prefix': 'Who can juggle',
      'subject': words[id],
      'status': vs ? 'completed' : 'open',
      'visibility': 'arena',
      'likes': 10,
      'views': 1200,
      'createdAt': '2026-09-01T10:00:00Z',
      'responseCount': vs ? 1 : 0,
      if (vs) 'topResponseId': '9$id',
      if (vs) 'topResponseUsername': 'leo',
      if (vs) 'topResponseVideoUrl': 'https://x/r$id.mp4',
    };

/// Every feed the app asked for. Must stay empty.
late List<String> feedAsks;

/// Every video file the app started fetching.
late List<String> videoAsks;

/// The owner's "Open to battles" switch: which post, and what was asked.
late List<(String, bool)> battlesFlips;

void fakeServer() {
  feedAsks = [];
  videoAsks = [];
  battlesFlips = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      Object body = {};
      if (req.method == 'PATCH' && p.endsWith('/battles')) {
        final open = (json.decode(req.body) as Map)['open'] == true;
        battlesFlips.add((p.split('/')[4], open));
        return http.Response(json.encode({'openToBattles': open}), 200);
      }
      if (p.endsWith('.mp4')) {
        videoAsks.add(req.url.toString());
        return http.Response('no', 404);
      }
      if (p.contains('/feed')) {
        feedAsks.add(p);
        body = {'items': [], 'hasMore': false};
      } else if (p.endsWith('/challenges') && p.contains('/users/')) {
        body = [video('11'), video('12'), video('13')];
      } else if (p.endsWith('/battles')) {
        final tab = req.url.queryParameters['tab'];
        body = {
          'summary': {
            'rating': 1080,
            'league': 'Silver',
            'wins': 1,
            'counts': {'won': 1},
          },
          'tab': tab,
          'battles': [
            if (tab == 'won')
              {
                'challengeId': '21',
                'title': 'Who can juggle twenty-one',
                'role': 'creator',
                'status': 'completed',
                'outcome': 'won',
                'myVotes': 5,
                'theirVotes': 2,
                'opponent': 'leo',
                'video': video('21', vs: true),
              },
          ],
        };
      } else if (p.contains('/saved/')) {
        body = [
          video('31', by: 'zara'),
          video('32', by: 'zara'),
          video('33', by: 'zara'),
        ];
      } else if (p.endsWith('/likes')) {
        body = {
          'items': [video('32', by: 'zara'), video('33', by: 'zara')],
          'hasMore': false,
          'nextCursor': '',
        };
      }
      return http.Response.bytes(
        utf8.encode(json.encode(body)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
}

UserModel person(String id, String name) => UserModel(
  id: id,
  username: name,
  wins: 1,
  losses: 0,
  followersCount: 3,
  followingCount: 2,
);

Future<void> open(WidgetTester t, Widget home, {String me = '1'}) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  fakeServer();
  final dp = DataProvider()..setUser(person(me, me == '5' ? 'maya' : 'me'));
  EventTracker.instance.dispose();
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: MaterialApp(home: home),
    ),
  );
  await settle(t);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox()));
  await t.pump(const Duration(seconds: 5));
  ReelDiagnostics.instance.debugReset();
  EventTracker.instance.dispose();
}

/// The reel on screen is the one about [id].
Finder playing(String id) => find.descendant(
  of: find.byKey(const ValueKey('reel_caption')),
  matching: find.textContaining(words[id]!),
);

Future<void> swipe(WidgetTester t, {bool up = true}) async {
  await t.fling(find.byType(PageView).first, Offset(0, up ? -500 : 500), 1500);
  await settle(t);
}

/// Tap a tile low down, clear of the tab bar pinned over the top of the
/// grid once the page has scrolled.
Future<void> tapTile(WidgetTester t, Finder tile) async {
  await t.tapAt(t.getBottomLeft(tile) + const Offset(30, -20));
  await settle(t);
}

Future<void> tapTab(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
  await settle(t);
}

void main() {
  // A tap that misses fails, rather than warning and carrying on.
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory cacheDir;
  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    cacheDir = Directory.systemTemp.createTempSync('profile_videos');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
  });
  tearDown(() async {
    UploadJobManager.instance.activeJobs.value = const [];
    ApiService.useClient(http.Client());
    VideoCacheService.instance.warm(const []);
    try {
      cacheDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('opening a profile fetches the start of its first videos '
      'before any tap, as TikTok does', (t) async {
    await open(t, ProfilePage(user: person('5', 'maya'), isEmbedded: false));
    expect(find.byKey(const ValueKey('short_tile_11')), findsOneWidget);
    expect(
      VideoCacheService.instance.debugWindow,
      {'https://x/11.mp4', 'https://x/12.mp4', 'https://x/13.mp4'},
      reason: 'the same addresses the reels will play',
    );
    expect(videoAsks, contains('https://x/11.mp4'), reason: 'and asked for');
    expect(feedAsks, isEmpty);

    // Another tab: the fetching moves with you.
    await tapTab(t, 'Won 1');
    expect(VideoCacheService.instance.debugWindow, {'https://x/21.mp4'});
    await close(t);
  });

  testWidgets('holding down one of your own videos: open to battles or '
      'not, and delete', (t) async {
    await open(
      t,
      ProfilePage(user: person('5', 'maya'), isEmbedded: false),
      me: '5',
    );
    final tile = find.byKey(const ValueKey('short_tile_12'));
    await t.longPress(tile);
    await settle(t);
    final sw = find.byKey(const ValueKey('battles_switch_12'));
    expect(sw, findsOneWidget);
    expect(find.text('Delete post'), findsOneWidget);
    expect(t.widget<SwitchListTile>(sw).value, isTrue);

    await t.tap(sw);
    await settle(t);
    expect(battlesFlips, [('12', false)]);
    expect(t.widget<SwitchListTile>(sw).value, isFalse);
    expect(find.text('Now a normal post. Nobody can answer it.'),
        findsOneWidget);

    // Put away and held down again: it remembers.
    await t.tapAt(const Offset(200, 60));
    await settle(t);
    await t.longPress(tile);
    await settle(t);
    expect(t.widget<SwitchListTile>(sw).value, isFalse);

    // Delete is still there, and still asks first.
    await t.tap(find.text('Delete post'));
    await settle(t);
    expect(find.text('Delete post?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await settle(t);
    await close(t);
  });

  testWidgets('somebody else\'s video held down offers nothing of the '
      'owner\'s', (t) async {
    await open(t, ProfilePage(user: person('5', 'maya'), isEmbedded: false));
    expect(find.byKey(const ValueKey('short_tile_12')), findsOneWidget);
    await t.longPress(find.byKey(const ValueKey('short_tile_12')));
    await settle(t);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byKey(const ValueKey('battles_switch_12')), findsNothing);
    expect(find.text('Delete post'), findsNothing);
    await close(t);
  });

  testWidgets('on someone else\'s profile, a tapped short plays, and the '
      'swipes go through their shorts and stop at the last', (t) async {
    await open(t, ProfilePage(user: person('5', 'maya'), isEmbedded: false));
    // Drawn the way Search draws them: who made it, the title, the views.
    final tile = find.byKey(const ValueKey('short_tile_12'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('maya')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.text('1.2K')),
      findsOneWidget,
    );

    await tapTile(t, tile);
    expect(playing('12'), findsOneWidget);
    await swipe(t);
    expect(playing('13'), findsOneWidget, reason: 'their next short');
    await swipe(t);
    expect(playing('13'), findsOneWidget, reason: 'nothing after the last');
    await swipe(t, up: false);
    await swipe(t, up: false);
    expect(playing('11'), findsOneWidget, reason: 'and back to their first');
    expect(feedAsks, isEmpty, reason: 'no recommendations mixed in');
    await close(t);
  });

  testWidgets('on your own profile the same, from the first short', (t) async {
    await open(
      t,
      ProfilePage(user: person('5', 'maya'), isEmbedded: false),
      me: '5',
    );
    await tapTile(t, find.byKey(const ValueKey('short_tile_11')));
    expect(playing('11'), findsOneWidget);
    await swipe(t);
    expect(playing('12'), findsOneWidget);
    expect(feedAsks, isEmpty);
    await close(t);
  });

  testWidgets('a battle tab is videos with the score, and a tap plays the '
      'battle, both names on it', (t) async {
    await open(t, ProfilePage(user: person('5', 'maya'), isEmbedded: false));
    await tapTab(t, 'Won 1');
    final tile = find.byKey(const ValueKey('battle_tile_21'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Won 5–2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: tile, matching: find.text('VS')),
      findsOneWidget,
    );

    await tapTile(t, tile);
    expect(playing('21'), findsOneWidget);
    expect(find.text('leo'), findsWidgets, reason: 'the opponent is named');
    expect(feedAsks, isEmpty);
    await close(t);
  });

  testWidgets('your Saved tab plays what you saved, in order', (t) async {
    await open(
      t,
      ProfilePage(user: person('5', 'maya'), isEmbedded: false),
      me: '5',
    );
    await tapTab(t, 'Saved');
    final tile = find.byKey(const ValueKey('saved_tile_32'));
    expect(tile, findsOneWidget);
    expect(VideoCacheService.instance.debugWindow, {
      'https://x/31.mp4',
      'https://x/32.mp4',
      'https://x/33.mp4',
    }, reason: 'the start of each fetched before the tap');
    expect(
      find.descendant(of: tile, matching: find.byIcon(Icons.bookmark_rounded)),
      findsOneWidget,
    );
    await tapTile(t, tile);
    expect(playing('32'), findsOneWidget);
    await swipe(t);
    expect(playing('33'), findsOneWidget);
    expect(feedAsks, isEmpty);
    await close(t);
  });

  testWidgets('Liked plays the videos you liked, not a bare player on one', (
    t,
  ) async {
    await open(t, const LikedVideosPage(), me: '5');
    final tile = find.byKey(const ValueKey('liked_tile_32'));
    expect(tile, findsOneWidget);
    expect(VideoCacheService.instance.debugWindow, {
      'https://x/32.mp4',
      'https://x/33.mp4',
    }, reason: 'the start of each fetched before the tap');
    expect(
      find.descendant(of: tile, matching: find.text('zara')),
      findsOneWidget,
    );
    await tapTile(t, tile);
    expect(playing('32'), findsOneWidget);
    await swipe(t);
    expect(playing('33'), findsOneWidget);
    expect(feedAsks, isEmpty);
    await close(t);
  });

  group('a post on its way up', () {
    late File clip;
    UploadJob posting({ChallengeSubmissionMeta? meta, double progress = 0.4}) =>
        UploadJob.debug(
          sourcePath: clip.path,
          stage: UploadJobStage.uploading,
          progress: progress,
          postedAs: meta,
        );
    const meta = ChallengeSubmissionMeta(
      prefix: 'Who can',
      subject: 'backflip off a wall',
      visibility: 'arena',
      category: 'sports',
      emotionTags: [],
    );

    setUp(() {
      clip = File('${cacheDir.path}/devf_trim_1.mp4')..writeAsBytesSync([1]);
    });

    testWidgets('shows first in your Shorts from the moment you press Post, '
        'and plays from your phone', (t) async {
      final job = posting(meta: meta);
      UploadJobManager.instance.activeJobs.value = [job];
      await open(
        t,
        ProfilePage(user: person('5', 'maya'), isEmbedded: false),
        me: '5',
      );
      final tile = find.byKey(ValueKey('posting_tile_${job.id}'));
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text('Posting…')),
        findsOneWidget,
      );
      expect(find.descendant(of: tile, matching: find.text('40%')),
          findsOneWidget);
      expect(
        find.descendant(
          of: tile,
          matching: find.text('Who can backflip off a wall'),
        ),
        findsOneWidget,
      );
      // First, ahead of what is already posted.
      final first = t.getTopLeft(tile);
      final older = t.getTopLeft(find.byKey(const ValueKey('short_tile_11')));
      expect(first.dx < older.dx || first.dy < older.dy, isTrue);

      await tapTile(t, tile);
      final player = t.widget<VideoPlayerPage>(find.byType(VideoPlayerPage));
      expect(player.videoUrl, clip.path, reason: 'the video on the phone');
      await close(t);
    });

    testWidgets('when it finishes, the real post takes its place at once',
        (t) async {
      final job = posting(meta: meta, progress: 0.9);
      UploadJobManager.instance.activeJobs.value = [job];
      await open(
        t,
        ProfilePage(user: person('5', 'maya'), isEmbedded: false),
        me: '5',
      );
      expect(find.byKey(ValueKey('posting_tile_${job.id}')), findsOneWidget);

      job.debugFinish(ChallengeModel.fromJson(video('14')));
      await settle(t);
      expect(find.byKey(ValueKey('posting_tile_${job.id}')), findsNothing);
      final posted = find.byKey(const ValueKey('short_tile_14'));
      expect(posted, findsOneWidget);
      final older = t.getTopLeft(find.byKey(const ValueKey('short_tile_11')));
      final at = t.getTopLeft(posted);
      expect(at.dx < older.dx || at.dy < older.dy, isTrue, reason: 'first');
      await close(t);
    });

    testWidgets('a video still being prepared while you type is not shown, '
        'and nobody else sees yours', (t) async {
      final typing = posting();
      final mine = posting(meta: meta);
      UploadJobManager.instance.activeJobs.value = [typing, mine];
      await open(
        t,
        ProfilePage(user: person('5', 'maya'), isEmbedded: false),
        me: '5',
      );
      expect(find.byKey(ValueKey('posting_tile_${typing.id}')), findsNothing);
      expect(find.byKey(ValueKey('posting_tile_${mine.id}')), findsOneWidget);
      await close(t);

      await open(
        t,
        ProfilePage(user: person('5', 'maya'), isEmbedded: false),
      );
      expect(find.text('Posting…'), findsNothing);
      expect(find.byKey(const ValueKey('short_tile_11')), findsOneWidget);
      await close(t);
    });
  });

  test('every upload path hands the tile its picture as soon as one is made',
      () {
    // Comments out first: a test that finds the words in a comment checks
    // nothing.
    final code = File('lib/services/upload_job_manager.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final loops = RegExp(r'await for \(final a in processed\) \{')
        .allMatches(code)
        .length;
    final pictures = RegExp(
      r'if \(a\.kind == ProcessingArtifactKind\.thumbnail\) \{\s*'
      r'job\._poster = a\.path;',
    ).allMatches(code).length;
    expect(loops, 3, reason: 'challenge, prepared challenge, answer');
    expect(pictures, loops);
  });
}
