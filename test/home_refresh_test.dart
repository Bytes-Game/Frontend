// Refreshing Home: tap Home again, or pull down anywhere on the first video.
//
// A pull used to have to start in the top 120 pixels — under the feed's own
// tab strip — and tapping Home while on Home did nothing. These go through
// the real app shell, the real Home tab button and real finger drags, with
// only the server and the video player faked.

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
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/screens/main_shell.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// A platform whose players open and play without a phone.
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

Map<String, dynamic> _challenge(String id, {bool battle = false}) => {
  'id': id,
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': 'https://x/c$id.mp4',
  'prefix': 'Who can',
  'subject': 'juggle five',
  'status': battle ? 'active' : 'open',
  'visibility': 'arena',
  'likes': 0,
  'views': 0,
  'createdAt': '2026-09-20T10:00:00Z',
  if (battle) ...{
    'responseCount': 1,
    'topResponseId': '7$id',
    'topResponseUsername': 'leo',
    'topResponseVideoUrl': 'https://x/r$id.mp4',
  },
};

/// Every For You page asked for, in order.
late List<Uri> forYouAsks;

/// Every Search grid asked for, in order.
late List<Uri> exploreAsks;

/// Whether the server's Search grid comes back empty.
bool exploreEmpty = false;

/// Whether it comes back long enough to scroll.
bool exploreLong = false;

/// When set, the server holds the next For You page until this completes.
Completer<void>? holdFeed;

/// Whether the first video is a battle (so a sideways drag turns it).
bool firstIsBattle = false;

bool isRefresh(Uri u) => u.queryParameters['refresh'] == 'true';

void main() {
  final platform = _Platform();
  late Directory cacheDir;

  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    // A test that failed half way leaves its players "playing"; the next
    // test must not hear them.
    platform.playing.clear();
    cacheDir = Directory.systemTemp.createTempSync('home_refresh');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    forYouAsks = [];
    exploreAsks = [];
    exploreEmpty = false;
    exploreLong = false;
    holdFeed = null;
    ExploreGridCache.directory = () async => cacheDir;
    ExploreGridCache.instance.debugReset();
    firstIsBattle = false;
    ApiService.useClient(
      MockClient((req) async {
        if (req.url.path.endsWith('/feed/smart')) {
          forYouAsks.add(req.url);
          final hold = holdFeed;
          if (hold != null) await hold.future;
        }
        if (req.url.path.endsWith('/feed/explore')) {
          exploreAsks.add(req.url);
          if (exploreEmpty) {
            return http.Response(json.encode({'items': []}), 200);
          }
          if (exploreLong) {
            return http.Response(
              json.encode({
                'items': [
                  for (var i = 1; i <= 30; i++)
                    {'type': 'challenge', 'challenge': _challenge('$i')},
                ],
              }),
              200,
            );
          }
        }
        if (req.url.path.contains('/feed')) {
          return http.Response(
            json.encode({
              'items': [
                {
                  'type': 'challenge',
                  'challenge': _challenge('1', battle: firstIsBattle),
                },
                {'type': 'challenge', 'challenge': _challenge('2')},
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
    ExploreGridCache.instance.debugReset();
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

  /// The real shell, opened on Home with its first video playing.
  Future<void> openHome(WidgetTester t) async {
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
        child: const MaterialApp(home: MainShell()),
      ),
    );
    await frames(t, 20);
    expect(platform.sounding, {
      'https://x/c1.mp4',
    }, reason: 'the first video never started');
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  }

  int refreshes() => forYouAsks.where(isRefresh).length;

  Finder label(String text) => find.byWidgetPredicate(
    (w) =>
        w is Text &&
        w.key == const ValueKey('pull_refresh_label') &&
        w.data == text,
  );

  /// The list of videos — not Home's sideways tab swiper, also a PageView.
  final videos = find.byWidgetPredicate(
    (w) => w is PageView && w.scrollDirection == Axis.vertical,
  );

  group('tapping Search while on Search', () {
    final searchTab = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('Search'),
    );
    int gridRefreshes() => exploreAsks.where(isRefresh).length;

    testWidgets('going to Search does not count as a refresh', (t) async {
      await openHome(t);
      await t.tap(searchTab);
      await frames(t, 10);
      expect(exploreAsks, isNotEmpty, reason: 'Search asked for its grid');
      expect(gridRefreshes(), 0);
      await close(t);
    });

    testWidgets('a second tap refreshes the grid', (t) async {
      await openHome(t);
      await t.tap(searchTab);
      await frames(t, 10);
      await t.tap(searchTab);
      await frames(t, 12);
      expect(gridRefreshes(), 1);
      await close(t);
    });

    testWidgets('with nothing in the grid, it asks again', (t) async {
      exploreEmpty = true;
      await openHome(t);
      await t.tap(searchTab);
      await frames(t, 10);
      expect(find.text('Find people and battles'), findsOneWidget,
          reason: 'the empty grid, or this proves nothing');
      await t.tap(searchTab);
      await frames(t, 12);
      expect(gridRefreshes(), 1);
      await close(t);
    });

    testWidgets('from further down the grid, it goes back to the top', (
      t,
    ) async {
      exploreLong = true;
      await openHome(t);
      await t.tap(searchTab);
      await frames(t, 10);
      final grid = find.byType(CustomScrollView);
      await t.drag(grid, const Offset(0, -600));
      await frames(t, 6);
      ScrollPosition position() =>
          t.state<ScrollableState>(
            find.descendant(of: grid, matching: find.byType(Scrollable)),
          ).position;
      expect(position().pixels, greaterThan(100),
          reason: 'scrolled down, or this proves nothing');
      await t.tap(searchTab);
      await frames(t, 12);
      expect(position().pixels, 0);
      expect(gridRefreshes(), 1);
      await close(t);
    });

    testWidgets('from a search, it goes back to the videos, fresh', (t) async {
      await openHome(t);
      await t.tap(searchTab);
      await frames(t, 10);
      final field = find.byType(TextField);
      await t.enterText(field, 'dance');
      await frames(t, 4);
      await t.tap(searchTab);
      await frames(t, 12);
      expect(t.widget<TextField>(field).controller!.text, isEmpty,
          reason: 'the search is left');
      expect(gridRefreshes(), 1);
      await close(t);
    });
  });

  group('tapping Home while on Home', () {
    testWidgets('refreshes the feed on screen', (t) async {
      await openHome(t);
      final before = refreshes();
      await t.tap(find.text('Home'));
      await frames(t, 12);
      expect(refreshes(), before + 1);
      expect(platform.sounding, {
        'https://x/c1.mp4',
      }, reason: 'and plays the first video of the fresh page');
      await close(t);
    });

    testWidgets('from further down, it goes back to the first video', (
      t,
    ) async {
      await openHome(t);
      await t.drag(videos, const Offset(0, -700));
      await frames(t, 8);
      expect(platform.sounding, {'https://x/c2.mp4'});
      await t.tap(find.text('Home'));
      await frames(t, 14);
      expect(platform.sounding, {'https://x/c1.mp4'});
      await close(t);
    });

    testWidgets('coming to Home from another tab does not refresh it', (
      t,
    ) async {
      await openHome(t);
      await t.tap(find.text('Search'));
      await frames(t, 6);
      final before = refreshes();
      await t.tap(find.text('Home'));
      await frames(t, 12);
      expect(
        refreshes(),
        before,
        reason: 'back on Home it carries on where it was',
      );
      await close(t);
    });
  });

  group('pulling down on the first video', () {
    testWidgets('from the middle of the screen refreshes, and says so on the '
        'way', (t) async {
      await openHome(t);
      final before = refreshes();
      final g = await t.startGesture(const Offset(200, 420));
      await g.moveBy(const Offset(0, 20));
      await t.pump();
      await g.moveBy(const Offset(0, 20));
      await t.pump();
      expect(label('Pull to refresh'), findsOneWidget);
      await g.moveBy(const Offset(0, 90));
      await t.pump();
      expect(label('Release to refresh'), findsOneWidget);
      await g.up();
      await frames(t, 12);
      expect(refreshes(), before + 1);
      await close(t);
    });

    testWidgets('keeps saying "Refreshing" until the new videos come', (
      t,
    ) async {
      await openHome(t);
      holdFeed = Completer<void>();
      await t.dragFrom(const Offset(200, 420), const Offset(0, 200));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(label('Refreshing'), findsOneWidget);
      holdFeed!.complete();
      await frames(t, 12);
      expect(find.byKey(const ValueKey('pull_refresh_label')), findsNothing);
      await close(t);
    });

    testWidgets('a short pull lets go without refreshing', (t) async {
      await openHome(t);
      final before = refreshes();
      await t.dragFrom(const Offset(200, 420), const Offset(0, 40));
      await frames(t, 8);
      expect(refreshes(), before);
      expect(find.byKey(const ValueKey('pull_refresh_label')), findsNothing);
      await close(t);
    });

    testWidgets('a sideways drag on a battle turns it, it does not refresh', (
      t,
    ) async {
      firstIsBattle = true;
      await openHome(t);
      final before = refreshes();
      // Sideways and downhill from the very first move, the way a thumb
      // really moves — far enough down that, read as a pull, it would
      // refresh.
      final g = await t.startGesture(const Offset(320, 400));
      await g.moveBy(const Offset(-30, 12));
      await t.pump();
      await g.moveBy(const Offset(-120, 44));
      await t.pump();
      await g.moveBy(const Offset(-120, 44));
      await t.pump();
      expect(find.byKey(const ValueKey('pull_refresh_label')), findsNothing);
      await g.up();
      await frames(t, 12);
      expect(refreshes(), before);
      expect(platform.sounding, {
        'https://x/r1.mp4',
      }, reason: 'it turned to the other side');
      await close(t);
    });

    testWidgets('swiping up still goes to the next video', (t) async {
      await openHome(t);
      final before = refreshes();
      await t.drag(videos, const Offset(0, -700));
      await frames(t, 8);
      expect(refreshes(), before);
      expect(platform.sounding, {'https://x/c2.mp4'});
      await close(t);
    });
  });

  testWidgets('pulling down on the second video goes back to the first, '
      'without refreshing', (t) async {
    await openHome(t);
    await t.drag(videos, const Offset(0, -700));
    await frames(t, 8);
    final before = refreshes();
    await t.drag(videos, const Offset(0, 700));
    await frames(t, 8);
    expect(refreshes(), before);
    expect(platform.sounding, {'https://x/c1.mp4'});
    await close(t);
  });
}
