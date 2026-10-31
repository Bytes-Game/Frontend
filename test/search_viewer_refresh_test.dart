// Refreshing the videos opened from Search.
//
// Tap a video in Search, pull down on it, and the refresh used to put that
// same video back first: only the videos after it changed, and you were
// still on the one you had been watching, as if the pull had done nothing.
// A pull asks for something new from the top, as it does on Home.
//
// These open the real page the way Search does and pull with a real finger,
// with only the server and the video player faked. Each checks what is ON
// SCREEN as well as what plays: a video can play where nobody can see it.

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

/// A platform that knows which players are playing.
class _Platform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final Map<int, String> uriOf = {};
  final Set<int> playing = {};
  int _id = 0;

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

Map<String, dynamic> _challenge(String id) => {
  'id': id,
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': 'https://x/e$id.mp4',
  'prefix': 'Who can',
  'subject': 'juggle five',
  'status': 'open',
  'visibility': 'arena',
  'likes': 0,
  'views': 0,
  'createdAt': '2026-09-20T10:00:00Z',
};

/// What Search's videos are asked for, in order.
late List<Uri> asks;

/// Holds the next answer until this completes.
Completer<void>? hold;

void main() {
  final platform = _Platform();
  late Directory cacheDir;

  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    platform.playing.clear();
    cacheDir = Directory.systemTemp.createTempSync('search_viewer_refresh');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    asks = [];
    hold = null;
    ApiService.useClient(
      MockClient((req) async {
        if (req.url.path.contains('/feed')) {
          asks.add(req.url);
          await hold?.future;
          final fresh = req.url.queryParameters['refresh'] == 'true';
          // The first time, what comes after the tapped video; after a pull,
          // something new.
          final ids = fresh ? ['31', '32'] : ['21', '22'];
          return http.Response(
            json.encode({
              'items': [
                for (final id in ids)
                  {'type': 'challenge', 'challenge': _challenge(id)},
              ],
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      }),
    );
  });

  tearDown(() {
    ApiService.useClient(http.Client());
    VideoCacheService.instance.warm(const []);
    ReelDiagnostics.instance.debugReset();
    try {
      cacheDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> frames(WidgetTester t, [int n = 12]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  final videos = find.byWidgetPredicate(
    (w) => w is PageView && w.scrollDirection == Axis.vertical,
  );

  double? shown(WidgetTester t) => t.widget<PageView>(videos).controller?.page;

  /// Search, and the video tapped in it opened on top, playing.
  Future<void> openTapped(WidgetTester t) async {
    final queued = <VoidCallback>[];
    final before = VideoPlayerService.deferRelease;
    VideoPlayerService.deferRelease = queued.add;
    addTearDown(() => VideoPlayerService.deferRelease = before);
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const ValueKey('tap_video'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SearchReelsViewerPage(
                        seedChallenge: ChallengeModel.fromJson(_challenge('9')),
                      ),
                    ),
                  ),
                  child: const Text('search'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('tap_video')));
    await frames(t, 20);
    expect(platform.sounding, {
      'https://x/e9.mp4',
    }, reason: 'it opens on the video that was tapped');
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  }

  Future<void> pull(WidgetTester t) =>
      t.dragFrom(const Offset(200, 420), const Offset(0, 200));

  testWidgets('a pull brings new videos from the top: the one you were '
      'watching is not put back first', (t) async {
    await openTapped(t);
    await pull(t);
    await frames(t, 16);
    expect(
      asks.last.queryParameters['refresh'],
      'true',
      reason: 'the pull did not ask for something new',
    );
    expect(shown(t), 0.0);
    expect(platform.sounding, {
      'https://x/e31.mp4',
    }, reason: 'still on the video that was tapped, as if nothing happened');
    await close(t);
  });

  testWidgets('while the new videos come, it says so, and the back arrow is '
      'still there', (t) async {
    await openTapped(t);
    hold = Completer<void>();
    await pull(t);
    await frames(t, 4);
    expect(find.byKey(const ValueKey('pull_refresh_label')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reel_back')),
      findsOneWidget,
      reason: 'a slow server would leave no way back but the phone\'s own',
    );
    await t.tap(find.byKey(const ValueKey('reel_back')));
    await frames(t, 8);
    expect(find.byType(SearchReelsViewerPage), findsNothing);
    hold!.complete();
    await frames(t, 4);
    await close(t);
  });
}
