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

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

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
}
