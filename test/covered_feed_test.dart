// The video stops when another page opens on top of it.
//
// The bell's notifications page opened over Home and the reel underneath
// carried on playing, with sound. Stopping it was left to each button that
// opens a page, and the bell's did not — nor did several others. Now the
// feed hears from the app's navigator that a page has opened on top of it,
// whatever opened it.
//
// These go through the real app shell, the real bell and the real back
// arrow, with only the server and the video player faked. The navigator
// reports to the same observer main.dart gives it (checked at the bottom).
// Each test checks the reel WAS playing first, so a reel that never started
// cannot pass.

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
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/screens/main_shell.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_cover_observer.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/feed_action_bar.dart' show ChallengeCommentSheet;
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

  /// Every video told to play, in order — even one stopped again a moment
  /// later, which [sounding] cannot show.
  final List<String> played = [];

  @override
  Future<void> play(int playerId) async {
    played.add(uriOf[playerId]!);
    playing.add(playerId);
  }

  /// How long a pause takes. A slow one holds the next video back while it
  /// waits (see VideoPlayerService.pauseSettleTimeout).
  Duration pauseTakes = Duration.zero;

  @override
  Future<void> pause(int playerId) async {
    if (pauseTakes > Duration.zero) await Future<void>.delayed(pauseTakes);
    playing.remove(playerId);
  }

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

const _video = 'https://x/c7.mp4';

Map<String, dynamic> _challenge({String id = '7'}) => {
  'id': id,
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': 'https://x/c$id.mp4',
  'prefix': 'Who can',
  'subject': 'juggle five',
  'status': 'open',
  'visibility': 'arena',
  'likes': 3,
  'views': 0,
  'createdAt': '2026-09-20T10:00:00Z',
};

/// maya's challenge 8 and leo's answer to it, with maya ahead, so it opens
/// on her side.
Map<String, dynamic> _battle() => {
  ..._challenge(id: '8'),
  'status': 'active',
  'responseCount': 1,
  'topResponseId': '78',
  'topResponseUsername': 'leo',
  'topResponseVideoUrl': 'https://x/r8.mp4',
  'leader': 'creator',
};

/// Holds Home's first page back until a test lets it through.
Completer<void>? _feedHeld;

/// What Home's feed serves.
List<Map<String, dynamic>> _feed = [];

void main() {
  final platform = _Platform();
  late Directory cacheDir;

  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    _feedHeld = null;
    _feed = [_challenge()];
    platform.pauseTakes = Duration.zero;
    cacheDir = Directory.systemTemp.createTempSync('covered_feed');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    ApiService.useClient(
      MockClient((req) async {
        if (req.url.path.contains('/feed')) {
          await _feedHeld?.future;
          return http.Response(
            json.encode({
              'items': [
                for (final c in _feed) {'type': 'challenge', 'challenge': c},
              ],
              'hasMore': false,
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/people')) {
          return http.Response(
            json.encode({
              'sides': [
                {
                  'username': 'maya',
                  'role': 'creator',
                  'people': [
                    {'userId': '9', 'username': 'zoe'},
                  ],
                },
              ],
            }),
            200,
          );
        }
        if (req.url.path.endsWith('/notifications')) {
          return http.Response(json.encode({'items': []}), 200);
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

  late GlobalKey<NavigatorState> navigator;

  /// The real shell, opened on Home. Its reel is playing, unless the test
  /// holds the first page back with [_feedHeld].
  Future<void> openHome(WidgetTester t) async {
    // Shutdowns queued, not run: see VideoPlayerService.deferRelease.
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
      )
      ..setAllUsers([
        UserModel(
          id: '9',
          username: 'zoe',
          wins: 0,
          losses: 0,
          followersCount: 0,
          followingCount: 0,
        ),
      ]);
    EventTracker.instance.dispose();
    navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>.value(
        value: dp,
        child: MaterialApp(
          navigatorKey: navigator,
          // As main.dart has it.
          navigatorObservers: [PageCoverObserver.instance],
          home: const MainShell(),
        ),
      ),
    );
    await frames(t, 20);
    if (_feedHeld == null) {
      final first = _feed.first['videoUrl'] as String;
      expect(platform.sounding, {first}, reason: 'the reel never started');
    }
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  }

  Future<void> openBell(WidgetTester t) async {
    await t.tap(find.byTooltip('Notifications'));
    await frames(t, 8);
    expect(
      find.byType(NotificationsPage),
      findsOneWidget,
      reason: 'the bell did not open the notifications page',
    );
  }

  Future<void> back(WidgetTester t) async {
    await t.pageBack();
    await frames(t, 8);
    expect(find.byType(NotificationsPage), findsNothing);
  }

  testWidgets('the bell: the video stops under the notifications page, and '
      'plays again on the way back', (t) async {
    await openHome(t);
    await openBell(t);
    expect(
      platform.sounding,
      isEmpty,
      reason: 'the reel plays on under the notifications page',
    );
    expect(VideoPlayerService.instance.activeIsPlaying, isFalse);
    await back(t);
    expect(platform.sounding, {_video}, reason: 'back on Home, still stopped');
    await close(t);
  });

  testWidgets('any page opened on top stops it — one a phone notification '
      'opens, say, which no button on Home knows about', (t) async {
    await openHome(t);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a page on top')),
        ),
      ),
    );
    await frames(t, 8);
    expect(find.text('a page on top'), findsOneWidget);
    expect(platform.sounding, isEmpty);
    navigator.currentState!.pop();
    await frames(t, 8);
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('a sheet over the reel is not a page: the comments open and '
      'it keeps playing, as it always has', (t) async {
    await openHome(t);
    await t.tap(find.byKey(const ValueKey('reel_caption')));
    await frames(t, 8);
    expect(
      find.byType(ChallengeCommentSheet),
      findsOneWidget,
      reason: 'the comments did not open',
    );
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets(
    'a name tapped in the who-liked list: the profile opens on top '
    'of the list, not of the reel, and the reel stops under it all the same',
    (t) async {
      await openHome(t);
      await t.tap(find.byKey(const ValueKey('count_likes')));
      await frames(t, 8);
      expect(
        find.byKey(const ValueKey('person_9')),
        findsOneWidget,
        reason: 'the who-liked list did not open',
      );
      expect(platform.sounding, {_video}, reason: 'a sheet is not a page');
      await t.tap(find.byKey(const ValueKey('person_9')));
      await frames(t, 8);
      expect(
        find.byType(ProfilePage),
        findsOneWidget,
        reason: "zoe's profile did not open",
      );
      expect(
        platform.sounding,
        isEmpty,
        reason: 'the reel plays on under the profile',
      );
      navigator.currentState!.pop();
      await frames(t, 8);
      expect(find.byType(ProfilePage), findsNothing);
      expect(
        find.byKey(const ValueKey('person_9')),
        findsOneWidget,
        reason: 'back on the list',
      );
      expect(platform.sounding, {
        _video,
      }, reason: 'back on the list over the reel, it plays again');
      await close(t);
    },
  );

  testWidgets('a video the person had stopped stays stopped after the page '
      'closes', (t) async {
    await openHome(t);
    // Tap the reel to pause it.
    await t.tapAt(const Offset(200, 400));
    await frames(t, 4);
    expect(platform.sounding, isEmpty, reason: 'tapping did not pause it');
    await openBell(t);
    await back(t);
    expect(platform.sounding, isEmpty, reason: 'it started on its own');
    await close(t);
  });

  testWidgets('back in the app with the notifications still open: the video '
      'waits for the page to close', (t) async {
    await openHome(t);
    await openBell(t);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await frames(t, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(t, 4);
    expect(find.byType(NotificationsPage), findsOneWidget);
    expect(
      platform.sounding,
      isEmpty,
      reason: 'coming back to the app started it behind the page',
    );
    await back(t);
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('the first video arriving after the bell was opened waits for '
      'the page to close', (t) async {
    _feedHeld = Completer<void>();
    await openHome(t);
    expect(platform.sounding, isEmpty, reason: 'nothing to play yet');
    await openBell(t);
    final before = platform.played.length;
    _feedHeld!.complete();
    await frames(t, 12);
    expect(
      platform.played.skip(before),
      isEmpty,
      reason:
          'the first video started behind the notifications page, '
          'even if only for a moment',
    );
    await back(t);
    expect(platform.sounding, {
      _video,
    }, reason: 'it never started once the page closed');
    await close(t);
  });

  testWidgets('a battle turned to the answer: coming back to the app with '
      'the notifications open leaves it stopped, and closing them plays the '
      'answer, not the challenger', (t) async {
    _feed = [_battle()];
    await openHome(t);
    await t.tap(find.byKey(const ValueKey('matchup_opponent')));
    await frames(t, 8);
    expect(platform.sounding, {
      'https://x/r8.mp4',
    }, reason: 'it did not turn to the answer');
    await openBell(t);
    expect(platform.sounding, isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await frames(t, 2);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frames(t, 4);
    expect(
      platform.sounding,
      isEmpty,
      reason: 'coming back to the app started the answer behind the page',
    );
    await back(t);
    expect(platform.sounding, {'https://x/r8.mp4'});
    await close(t);
  });

  testWidgets('a page opened while the next video is still starting: it '
      'does not start behind the page', (t) async {
    _feed = [_challenge(), _challenge(id: '8')];
    await openHome(t);
    // Stopping the video being left takes a while, so the next one waits
    // to start — and the page opens in that moment.
    platform.pauseTakes = const Duration(seconds: 1);
    await t.dragFrom(const Offset(200, 600), const Offset(0, -500));
    for (
      var i = 0;
      i < 60 &&
          VideoPlayerService.instance.debugActiveUrl != 'https://x/c8.mp4';
      i++
    ) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(
      VideoPlayerService.instance.debugActiveUrl,
      'https://x/c8.mp4',
      reason: 'the swipe did not reach the next video',
    );
    expect(
      platform.sounding,
      isNot(contains('https://x/c8.mp4')),
      reason: 'it started before the page could open',
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a page on top')),
        ),
      ),
    );
    await frames(t, 30);
    expect(
      platform.sounding,
      isEmpty,
      reason: 'the next video started behind the page',
    );
    platform.pauseTakes = Duration.zero;
    navigator.currentState!.pop();
    await frames(t, 8);
    expect(platform.sounding, {'https://x/c8.mp4'});
    await close(t);
  });

  MaterialPageRoute<void> page(String words) =>
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(words)));

  testWidgets('a page swapped for another — the trim page for the post '
      'details, on the way to posting — and then closed: the video plays '
      'again', (t) async {
    await openHome(t);
    unawaited(navigator.currentState!.push(page('trim')));
    await frames(t, 8);
    expect(platform.sounding, isEmpty);
    unawaited(navigator.currentState!.pushReplacement(page('details')));
    await frames(t, 8);
    expect(find.text('details'), findsOneWidget);
    expect(platform.sounding, isEmpty);
    navigator.currentState!.pop();
    await frames(t, 8);
    expect(find.text('details'), findsNothing);
    expect(platform.sounding, {
      _video,
    }, reason: 'the feed still thinks the swapped-out page is on top');
    await close(t);
  });

  testWidgets('a page taken out from under another — a call that ends while '
      'something is open on top of it — and then the last one closed: the '
      'video plays again', (t) async {
    await openHome(t);
    final call = page('call');
    unawaited(navigator.currentState!.push(call));
    await frames(t, 8);
    unawaited(navigator.currentState!.push(page('on top of the call')));
    await frames(t, 8);
    navigator.currentState!.removeRoute(call);
    await frames(t, 8);
    expect(platform.sounding, isEmpty, reason: 'a page is still on top');
    navigator.currentState!.pop();
    await frames(t, 8);
    expect(find.text('on top of the call'), findsNothing);
    expect(platform.sounding, {
      _video,
    }, reason: 'the feed still thinks the call is on top');
    await close(t);
  });

  testWidgets('two feeds alive on one page — Home has one per tab — and '
      'only the video being watched stops, and the same one plays after', (
    t,
  ) async {
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
    navigator = GlobalKey<NavigatorState>();
    SmartReelsFeed feed(String id) => SmartReelsFeed(
      userId: '1',
      playlist: [ChallengeModel.fromJson(_challenge(id: id))],
    );
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>.value(
        value: dp,
        child: MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [PageCoverObserver.instance],
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: feed('21')),
                Expanded(child: feed('22')),
              ],
            ),
          ),
        ),
      ),
    );
    await frames(t, 20);
    // The second feed started last, so its video is the one on screen.
    expect(platform.sounding, {'https://x/c22.mp4'});
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('a page on top')),
        ),
      ),
    );
    await frames(t, 8);
    expect(platform.sounding, isEmpty);
    navigator.currentState!.pop();
    await frames(t, 8);
    expect(platform.sounding, {
      'https://x/c22.mp4',
    }, reason: 'the other feed took the screen back on the way out');
    await close(t);
  });

  test('main.dart gives the navigator the observer the feed listens to', () {
    final main = File(
      'lib/main.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(
      main,
      matches(
        RegExp(r'navigatorObservers:\s*\[[^\]]*PageCoverObserver\.instance'),
      ),
      reason: 'the navigator does not tell the feed when a page covers it',
    );
  });
}
