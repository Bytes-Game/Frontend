// Search's grid stops while another page is on top of it.
//
// A device log: a video tapped in Search, and in that same moment ten grid
// previews opened behind it, one after another. Each one went on pulling
// video off the internet until it had started, so the video that had been
// tapped — and every one after it — waited for the same connection. Every
// swipe went to the network cold, and the picture stuck for a moment on
// each.
//
// These go through the real page, with only the server and the phone's
// video player faked, and count the players the phone is asked to open.
// Whether a preview is showing is read from the screen: the fake player
// only finishes closing when a test ends.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/reel_diagnostics.dart';

class _Platform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  int created = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = created++;
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(9, 16),
          duration: const Duration(seconds: 60),
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> dispose(int playerId) async => _events.remove(playerId);

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

/// No picture, so nothing tries to fetch one.
Map<String, dynamic> video(int id) => {
  'id': '$id',
  'creatorId': '9',
  'creatorUsername': 'leo',
  'videoUrl': 'https://x/$id.mp4',
  'thumbnailUrl': '',
  'prefix': 'Who can',
  'subject': 'dance better',
  'status': 'open',
  'createdAt': '2026-09-20T10:00:00Z',
};

void fakeServer() {
  ApiService.useClient(
    MockClient((req) async {
      if (req.url.path.contains('/feed/explore')) {
        return http.Response(
          json.encode({
            'items': [
              for (var id = 1; id <= 12; id++)
                {'type': 'challenge', 'challenge': video(id)},
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }),
  );
}

void main() {
  final platform = _Platform();
  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ExploreGridCache.instance.debugReset();
    ReelDiagnostics.instance.debugReset();
    fakeServer();
  });

  tearDown(() {
    ApiService.useClient(http.Client());
    ExploreGridCache.instance.debugReset();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  /// A preview on screen in the grid — behind a page on top too.
  final preview = find.byType(VideoPlayer, skipOffstage: false);

  Future<void> frames(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// Search with its grid up and its first preview playing. [wrap] puts
  /// something around the page.
  Future<void> openSearch(
    WidgetTester t, {
    Widget Function(Widget page)? wrap,
  }) async {
    await t.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
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
    const page = SearchPage();
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>.value(
        value: dp,
        child: MaterialApp(home: wrap == null ? page : wrap(page)),
      ),
    );
    await frames(t);
    expect(
      preview,
      findsOneWidget,
      reason:
          'the grid never started a preview, so nothing below means '
          'anything',
    );
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    EventTracker.instance.dispose();
  }

  NavigatorState navigator(WidgetTester t) =>
      Navigator.of(t.element(find.byType(SearchPage, skipOffstage: false)));

  void openOnTop(WidgetTester t) {
    unawaited(
      navigator(t).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('on top')),
        ),
      ),
    );
  }

  group('a page opened over Search', () {
    testWidgets('stops the preview, and opens none behind it', (t) async {
      await openSearch(t);
      final before = platform.created;
      openOnTop(t);
      // At once, while the page is still sliding in: the video that was
      // tapped needs the decoder and the connection now, not once the grid
      // has noticed it is out of sight.
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(preview, findsNothing, reason: 'stopped the moment it opened');

      await frames(t, 10);
      expect(find.text('on top'), findsOneWidget);
      expect(preview, findsNothing, reason: 'nothing plays behind it');
      expect(platform.created, before, reason: 'and nothing new opens');

      // The grid gives each preview 25 seconds and then moves on to the
      // next tile. That must not happen behind the page either: the log has
      // two previews opening under a video opened from Search.
      await t.pump(const Duration(seconds: 30));
      await frames(t, 4);
      expect(platform.created, before);
      expect(preview, findsNothing);
      await close(t);
    });

    testWidgets('the burst from the device log: tiles that go out of sight '
        'together open nothing', (t) async {
      // The real phone tells the grid about its tiles in batches, half a
      // second apart. A batch that lands after the page on top has finished
      // opening says every tile is gone — and that is the batch that opened
      // ten players, one per tile.
      VisibilityDetectorController.instance.updateInterval = const Duration(
        milliseconds: 500,
      );
      await openSearch(t);
      final before = platform.created;
      openOnTop(t);
      await frames(t, 20);
      expect(platform.created, before);
      await close(t);
    });

    testWidgets('previews start again once it has gone', (t) async {
      await openSearch(t);
      openOnTop(t);
      await frames(t, 10);
      expect(preview, findsNothing);

      navigator(t).pop();
      await frames(t, 10);
      expect(find.text('on top'), findsNothing);
      expect(
        preview,
        findsOneWidget,
        reason: 'Search is showing again, so the grid plays again',
      );
      await close(t);
    });

    testWidgets('but not while it is still sliding away', (t) async {
      await openSearch(t);
      openOnTop(t);
      await frames(t, 10);
      final before = platform.created;

      navigator(t).pop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(
        find.text('on top'),
        findsOneWidget,
        reason: 'still on its way out, or this proves nothing',
      );
      expect(
        platform.created,
        before,
        reason:
            'tiles half-seen behind a moving page report numbers '
            'that change every frame; acting on them opens players '
            'for nothing',
      );

      await frames(t, 10);
      expect(platform.created, before + 1);
      await close(t);
    });
  });

  testWidgets('a whole grid going out of sight at once opens nothing, on '
      'the same page too', (t) async {
    // No page on top this time: the grid is simply hidden in place. Each
    // tile used to say "gone" one at a time, and each time the turn passed
    // to a tile that had not said so yet and still looked visible — which
    // opened a player for it.
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
    final hidden = ValueNotifier(false);
    addTearDown(hidden.dispose);
    final tapped = ValueNotifier(0);
    addTearDown(tapped.dispose);
    await openSearch(
      t,
      // A new page widget on every build, so hiding it also rebuilds every
      // tile — and a rebuilt tile asks for a fresh report of how much of it
      // can be seen.
      wrap: (_) => ValueListenableBuilder<bool>(
        valueListenable: hidden,
        builder: (_, h, _) => Offstage(
          offstage: h,
          child: SearchPage(tappedAgain: tapped),
        ),
      ),
    );
    final before = platform.created;
    // Nothing waiting to be reported...
    VisibilityDetectorController.instance.notifyNow();
    // ...then hide the grid, and let the reports land: every tile says it
    // is gone, in one batch, the way they did on the phone.
    hidden.value = true;
    await t.pump();
    VisibilityDetectorController.instance.notifyNow();
    await frames(t, 8);
    expect(platform.created, before);
    expect(preview, findsNothing, reason: 'and the one playing stops');
    await close(t);
  });

  testWidgets('the grid feeds that counter: let go, then really closed', (
    t,
  ) async {
    final d = ReelDiagnostics.instance;
    await openSearch(t);
    expect(d.debugPreviewClosingPeak, 0);
    openOnTop(t);
    await t.pump();
    expect(d.debugPreviewClosingPeak, 1, reason: 'the preview was let go');
    await close(t);
    // Out of the test's fake time, so the fake phone can finish closing.
    await t.runAsync(() => Future<void>.delayed(Duration.zero));
    await t.pump();
    expect(d.debugPreviewClosing, 0, reason: 'and the phone closed it');
  });

  test('the counter says how many the phone is still closing', () {
    final d = ReelDiagnostics.instance..debugReset();
    d.recordProxiedStart();
    for (var i = 0; i < 10; i++) {
      d.recordPreviewOpened();
      d.recordPreviewReleased();
      d.recordPreviewClosing();
    }
    expect(
      d.summary(),
      contains('previews live=0 peak=1'),
      reason: 'what the old count said about the burst',
    );
    expect(
      d.summary(),
      contains('closing now=10 peak=10'),
      reason: 'what the phone was really holding',
    );
    for (var i = 0; i < 10; i++) {
      d.recordPreviewClosed();
    }
    expect(d.summary(), contains('closing now=0 peak=10'));
    d.debugReset();
  });
}
