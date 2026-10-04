// Going back from a video stops it.
//
// A video opened from a profile kept playing, with sound, after pressing
// back. The page closing handed its players back, but the player service
// never touches the video on screen when handing back, so that one video
// played on with nothing on screen.
//
// These go through the real way in — a tap that opens the video the way a
// profile does — and the real way out, the back arrow. Each also checks the
// video WAS playing first, so a video that never started cannot pass.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/search_reels_viewer_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

/// A platform that knows which players are playing.
class _Platform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, String> uriOf = {};
  final Set<int> playing = {};
  int _id = 0;

  /// The addresses of the players playing right now.
  Set<String> get sounding => {for (final id in playing) uriOf[id]!};

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _id++;
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(9, 16),
          duration: const Duration(seconds: 10),
        ),
      );
    uriOf[id] = options.dataSource.uri ?? '';
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async => playing.add(playerId);

  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);

  @override
  Future<void> dispose(int playerId) async {
    playing.remove(playerId);
    _events.remove(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double v) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  /// Every video sent back to its start, by address.
  final List<String> rewound = [];

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    if (position == Duration.zero) rewound.add(uriOf[playerId] ?? '');
  }

  /// How far a playing video says it has got. Zero unless a test moves it:
  /// a video that never moves cannot show being sent back to its start.
  Duration playedFor = Duration.zero;

  @override
  Future<Duration> getPosition(int playerId) async =>
      playing.contains(playerId) ? playedFor : Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

/// A battle: maya's challenge and leo's answer.
ChallengeModel battle(String id) => ChallengeModel(
  id: id,
  creatorId: '5',
  creatorUsername: 'maya',
  creatorLeague: '',
  videoUrl: 'https://x/$id.mp4',
  prefix: 'Who can',
  subject: 'juggle five',
  visibility: 'arena',
  status: 'active',
  likes: 0,
  views: 0,
  createdAt: '',
  responseCount: 1,
  topResponseId: '7$id',
  topResponseUsername: 'leo',
  topResponseVideoUrl: 'https://x/r$id.mp4',
);

/// The live score, with [leader] ahead 14 to 9.
String score(String leader) => json.encode({
  'challengeId': '1',
  'status': 'active',
  'battleDays': 7,
  'acceptedAt': DateTime.now()
      .subtract(const Duration(days: 1))
      .toIso8601String(),
  'endsAt': DateTime.now().add(const Duration(days: 2)).toIso8601String(),
  'participants': [
    {
      'username': 'maya',
      'role': 'creator',
      'votes': leader == 'maya' ? 14 : 9,
      'leading': leader == 'maya',
    },
    {
      'username': 'leo',
      'role': 'responder',
      'responseId': '71',
      'votes': leader == 'leo' ? 14 : 9,
      'leading': leader == 'leo',
    },
  ],
});

/// Who is ahead in every battle's score.
String leader = 'maya';

ChallengeModel short(String id) => ChallengeModel(
  id: id,
  creatorId: '5',
  creatorUsername: 'maya',
  creatorLeague: '',
  videoUrl: 'https://x/$id.mp4',
  prefix: 'Who can',
  subject: 'juggle five',
  visibility: 'arena',
  status: 'open',
  likes: 0,
  views: 0,
  createdAt: '',
  responseCount: 0,
);

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // One platform for the whole file. The player pool outlives each test —
  // a widget test cannot shut its players down, see deferRelease — so a
  // later test can meet an earlier test's player, and it must be one this
  // platform knows.
  final platform = _Platform();
  late Directory cacheDir;

  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    cacheDir = Directory.systemTemp.createTempSync('leave_video');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    leader = 'maya';
    ApiService.useClient(
      MockClient(
        (req) async => req.url.path.endsWith('/standings')
            ? http.Response(score(leader), 200)
            : http.Response('{}', 200),
      ),
    );
  });

  tearDown(() async {
    ApiService.useClient(http.Client());
    VideoCacheService.instance.warm(const []);
    ReelDiagnostics.instance.debugReset();
    try {
      cacheDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A page with the videos on it, the way a profile opens them.
  Future<void> openFromPage(
    WidgetTester t, {
    List<ChallengeModel>? videos,
  }) async {
    t.view.physicalSize = const Size(400, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
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
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>.value(
        value: dp,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  key: const ValueKey('open_video'),
                  onPressed: () => openVideoPlaylist(
                    context,
                    videos ?? [short('11'), short('12')],
                    0,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open_video')));
    await settle(t);
  }

  test('a page closing leaves alone a video another page has claimed '
      'since', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final service = VideoPlayerService.instance;
    final closing = Object();
    final other = Object();
    service.getController('https://x/1.mp4');
    service.getController('https://x/2.mp4');
    await pumpEventQueue();
    await service.showAndPlay('https://x/1.mp4', owner: closing);
    await service.showAndPlay('https://x/2.mp4', owner: other);
    expect(platform.sounding, {'https://x/2.mp4'});

    service.leaveScreen(closing);
    await pumpEventQueue();
    expect(platform.sounding, {'https://x/2.mp4'}, reason: 'not its video');
    expect(service.debugActiveUrl, 'https://x/2.mp4');

    service.leaveScreen(other);
    await pumpEventQueue();
    expect(platform.sounding, isEmpty);
    expect(service.debugActiveUrl, isNull);
    await service.disposeAll();
  });

  test('a page that plays a video directly is nobody\'s: another page '
      'closing does not stop it', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final service = VideoPlayerService.instance;
    final feed = Object();
    service.getController('https://x/1.mp4');
    await pumpEventQueue();
    await service.showAndPlay('https://x/1.mp4', owner: feed);
    // A full-screen player page takes the screen without a feed.
    await service.pauseAllExcept('https://x/1.mp4');
    expect(service.debugActiveOwner, isNull);
    service.leaveScreen(feed);
    expect(service.debugActiveUrl, 'https://x/1.mp4');
    await service.disposeAll();
  });

  testWidgets('back from a video opened on a profile stops its sound', (
    t,
  ) async {
    // Shutdowns queued, not run: see VideoPlayerService.deferRelease.
    final queued = <VoidCallback>[];
    final before = VideoPlayerService.deferRelease;
    VideoPlayerService.deferRelease = queued.add;
    addTearDown(() => VideoPlayerService.deferRelease = before);

    await openFromPage(t);
    // It did play: a video that never started would pass the rest.
    expect(platform.sounding, {'https://x/11.mp4'});
    expect(VideoPlayerService.instance.debugActiveUrl, 'https://x/11.mp4');

    await t.tap(find.byKey(const ValueKey('reel_back')));
    await settle(t);

    expect(find.byKey(const ValueKey('open_video')), findsOneWidget);
    expect(platform.sounding, isEmpty, reason: 'nothing on screen, no sound');
    expect(VideoPlayerService.instance.debugActiveUrl, isNull);
    expect(
      VideoPlayerService.instance.hasController('https://x/11.mp4'),
      isFalse,
      reason: 'the player is handed back too, not left holding a decoder',
    );
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  });

  group('a battle starts playing whoever is ahead', () {
    Future<void> check(
      WidgetTester t,
      String id,
      String ahead,
      String plays,
    ) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      leader = ahead;
      await openFromPage(t, videos: [battle(id)]);
      await settle(t);
      expect(platform.sounding, {plays});
      expect(VideoPlayerService.instance.debugActiveUrl, plays);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      ReelDiagnostics.instance.debugReset();
      EventTracker.instance.dispose();
    }

    testWidgets('the answer ahead: the answer plays, the challenger does '
        'not', (t) => check(t, '1', 'leo', 'https://x/r1.mp4'));

    testWidgets('the challenger ahead: the challenger plays', (t) =>
        check(t, '2', 'maya', 'https://x/2.mp4'));
  });

  // Whoever is ahead is the FIRST side: named first at the top, and the
  // other is a swipe LEFT away. It used to open on the leader but keep the
  // challenger first, so with the answer ahead the other side was a swipe
  // right — backwards.
  group('the side ahead comes first', () {
    Future<void> swipe(WidgetTester t, double dx) async {
      await t.dragFrom(Offset(dx < 0 ? 320 : 80, 430), Offset(dx, 0));
      await settle(t);
    }

    double leftOf(WidgetTester t, String key) =>
        t.getTopLeft(find.byKey(ValueKey(key))).dx;

    Future<void> run(
      WidgetTester t, {
      required String id,
      required String ahead,
      required String first,
      required String second,
      required String firstKey,
      required String secondKey,
    }) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      leader = ahead;
      await openFromPage(t, videos: [battle(id)]);
      await settle(t);
      expect(platform.sounding, {first}, reason: 'opens on the side ahead');
      expect(leftOf(t, firstKey), lessThan(leftOf(t, secondKey)),
          reason: 'the side ahead is named first');

      // Right from the first side: there is nothing before it.
      await swipe(t, 280);
      expect(platform.sounding, {first});

      // Left: the other side.
      await swipe(t, -280);
      expect(platform.sounding, {second});
      expect(VideoPlayerService.instance.debugActiveUrl, second);

      // And right again: back to the first.
      await swipe(t, 280);
      expect(platform.sounding, {first});

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      ReelDiagnostics.instance.debugReset();
      EventTracker.instance.dispose();
    }

    testWidgets('the answer ahead: the answer first, the challenger a swipe '
        'left away', (t) => run(
          t,
          id: '6',
          ahead: 'leo',
          first: 'https://x/r6.mp4',
          second: 'https://x/6.mp4',
          firstKey: 'matchup_opponent',
          secondKey: 'matchup_challenger',
        ));

    testWidgets('the challenger ahead: the challenger first, the answer a '
        'swipe left away', (t) => run(
          t,
          id: '7',
          ahead: 'maya',
          first: 'https://x/7.mp4',
          second: 'https://x/r7.mp4',
          firstKey: 'matchup_challenger',
          secondKey: 'matchup_opponent',
        ));
  });

  // Pulling down the notifications pauses the app; letting them go resumes
  // it. On a battle's other side that used to start the challenger — its
  // sound behind the answer's still picture.
  group('back from the notifications on a battle', () {
    Future<void> shade(WidgetTester t) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await settle(t);
      expect(platform.sounding, isEmpty, reason: 'the shade pauses it');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(t);
    }

    Future<void> done(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      ReelDiagnostics.instance.debugReset();
      EventTracker.instance.dispose();
    }

    testWidgets('turned to the answer: the answer plays again, not the '
        'challenger', (t) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      leader = 'maya';
      await openFromPage(t, videos: [battle('3')]);
      await settle(t);
      expect(platform.sounding, {'https://x/3.mp4'});
      // Swipe left to the answer.
      await t.dragFrom(const Offset(320, 430), const Offset(-280, 0));
      await settle(t);
      expect(platform.sounding, {'https://x/r3.mp4'},
          reason: 'on the answer before the shade');

      await shade(t);
      expect(platform.sounding, {'https://x/r3.mp4'},
          reason: 'the side on screen plays again');
      expect(VideoPlayerService.instance.debugActiveUrl, 'https://x/r3.mp4');
      await done(t);
    });

    testWidgets('opened on the answer because it is ahead: the answer plays '
        'again', (t) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      leader = 'leo';
      await openFromPage(t, videos: [battle('4')]);
      await settle(t);
      expect(platform.sounding, {'https://x/r4.mp4'});
      await shade(t);
      expect(platform.sounding, {'https://x/r4.mp4'});
      await done(t);
    });

    testWidgets('on the challenger: the challenger plays again', (t) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      leader = 'maya';
      await openFromPage(t, videos: [battle('5')]);
      await settle(t);
      expect(platform.sounding, {'https://x/5.mp4'});
      await shade(t);
      expect(platform.sounding, {'https://x/5.mp4'});
      await done(t);
    });
  });

  // A video tapped in Search starts once the videos that come after it have
  // arrived, the way it always did. For a while it started before them;
  // two device logs after that show every video after the tap starving, and
  // the owner asked for it back as it was.
  group('a video opened from Search', () {
    /// Opens [seed] the way Search does, with the server holding back the
    /// rest of the list until [rest] completes.
    Future<void> open(
      WidgetTester t,
      ChallengeModel seed,
      Completer<void> rest,
    ) async {
      final queued = <VoidCallback>[];
      final before = VideoPlayerService.deferRelease;
      VideoPlayerService.deferRelease = queued.add;
      addTearDown(() => VideoPlayerService.deferRelease = before);
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      ApiService.useClient(
        MockClient((req) async {
          if (req.url.path.endsWith('/standings')) {
            return http.Response(score(leader), 200);
          }
          if (req.url.path.contains('/feed/explore')) {
            await rest.future;
            return http.Response(
              json.encode({
                'items': [
                  {
                    'type': 'challenge',
                    'challenge': {
                      'id': '59',
                      'creatorId': '5',
                      'creatorUsername': 'maya',
                      'videoUrl': 'https://x/59.mp4',
                      'status': 'open',
                    },
                  },
                ],
                'hasMore': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
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
      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>.value(
          value: dp,
          child: MaterialApp(home: SearchReelsViewerPage(seedChallenge: seed)),
        ),
      );
      await settle(t);
    }

    Future<void> done(WidgetTester t) async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      ReelDiagnostics.instance.debugReset();
      EventTracker.instance.dispose();
    }

    testWidgets('plays once the rest of the list has come, with one player',
        (t) async {
      final rest = Completer<void>();
      await open(t, short('51'), rest);
      expect(platform.sounding, isEmpty,
          reason: 'it waits for the list, as it did before');

      rest.complete();
      await settle(t);
      expect(platform.sounding, {'https://x/51.mp4'});
      expect(platform.uriOf.values.where((u) => u == 'https://x/51.mp4'),
          hasLength(1),
          reason: 'one player for it, not a second one');
      await done(t);
    });

    testWidgets('a battle with the answer ahead plays the answer', (t) async {
      leader = 'leo';
      final rest = Completer<void>();
      await open(t, battle('52'), rest);
      rest.complete();
      await settle(t);
      expect(platform.sounding, {'https://x/r52.mp4'});
      await done(t);
    });

    testWidgets('the rest of the list does come, behind it', (t) async {
      final rest = Completer<void>();
      await open(t, short('53'), rest);
      rest.complete();
      await settle(t);
      await t.drag(find.byType(PageView), const Offset(0, -700));
      await settle(t);
      expect(platform.sounding, {'https://x/59.mp4'});
      await done(t);
    });
  });
}
