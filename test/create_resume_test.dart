// The video behind the + button starts again.
//
// Pressing + paused the reel on Home so the Create pop-out could sit on top,
// and nothing ever started it again: not when the pop-out was closed, and
// not when the person came back from recording or uploading. They had to
// scroll away and back.
//
// These go through the real app shell and the real + button, with only the
// server, the video player and the permission prompt faked. Each checks the
// reel WAS playing first, so a reel that never started cannot pass.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';
import 'package:myapp/services/call_service.dart';
import 'package:myapp/widgets/call_host.dart';

import 'support/call_fakes.dart';

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

const _video = 'https://x/c7.mp4';

Map<String, dynamic> _challenge() => {
  'id': '7',
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': _video,
  'prefix': 'Who can',
  'subject': 'juggle five',
  'status': 'open',
  'visibility': 'arena',
  'likes': 0,
  'views': 0,
  'createdAt': '2026-09-20T10:00:00Z',
};

void main() {
  final platform = _Platform();
  late Directory cacheDir;
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    cacheDir = Directory.systemTemp.createTempSync('create_resume');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    ApiService.useClient(
      MockClient((req) async {
        if (req.url.path.contains('/feed')) {
          return http.Response(
            json.encode({
              'items': [
                {'type': 'challenge', 'challenge': _challenge()},
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

  /// The real shell, opened on Home with its reel playing. With [calls],
  /// built the way main.dart builds it, with the call screen host on top.
  Future<void> openHome(WidgetTester t, {CallService? calls}) async {
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
      );
    EventTracker.instance.dispose();
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>.value(
        value: dp,
        child: MaterialApp(
          navigatorKey: navigator,
          builder: calls == null
              ? null
              : (_, child) => CallHost(
                    call: calls,
                    navigator: navigator,
                    sounds: SilentSounds(),
                    child: child!,
                  ),
          home: const MainShell(),
        ),
      ),
    );
    await frames(t, 20);
    expect(platform.sounding, {_video}, reason: 'the reel never started');
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    ReelDiagnostics.instance.debugReset();
    EventTracker.instance.dispose();
  }

  Future<void> pressPlus(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.add_rounded));
    await frames(t, 6);
    expect(find.text('Record'), findsOneWidget, reason: 'the pop-out did not open');
    expect(platform.sounding, isEmpty, reason: 'the reel plays on under the pop-out');
  }

  testWidgets('closing the pop-out starts the video again', (t) async {
    await openHome(t);
    await pressPlus(t);
    // Tap the dimmed screen behind it.
    await t.tapAt(const Offset(30, 120));
    await frames(t, 8);
    expect(find.text('Record'), findsNothing);
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('coming back from Record starts the video again', (t) async {
    // The camera is refused, so Record says so and the person is back on
    // Home — the shortest real way through the record steps.
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
      call,
    ) async {
      final asked = (call.arguments as List).cast<int>();
      return {for (final p in asked) p: 0}; // denied
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        permissions,
        null,
      ),
    );
    await openHome(t);
    await pressPlus(t);
    await t.tap(find.text('Record'));
    await frames(t, 10);
    expect(
      find.text('Camera and microphone permission required.'),
      findsOneWidget,
      reason: 'the record steps did not run',
    );
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('closing a reel\'s Accept challenge menu starts it again', (
    t,
  ) async {
    await openHome(t);
    await t.tap(find.text('Accept challenge'));
    await frames(t, 6);
    expect(find.text('Record'), findsOneWidget, reason: 'the menu did not open');
    expect(platform.sounding, isEmpty);
    await t.tapAt(const Offset(30, 120));
    await frames(t, 8);
    expect(find.text('Record'), findsNothing);
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('a call stops the reel, and it plays again when the call ends', (
    t,
  ) async {
    final socket = RecordingSocket();
    final calls = fakeCalls(socket);
    addTearDown(() {
      calls.dispose();
      socket.dispose();
    });
    await openHome(t, calls: calls);
    socket.debugReceive({
      'type': 'call_offer',
      'callId': 'c1',
      'from': '5',
      'fromUsername': 'maya',
      'video': false,
      'sdp': 'O',
    });
    await frames(t, 6);
    expect(find.text('Incoming call'), findsOneWidget);
    expect(platform.sounding, isEmpty, reason: 'the reel plays over the ring');
    await t.tap(find.byTooltip('Decline'));
    await frames(t, 4);
    await t.pump(calls.endedFor);
    await frames(t, 8);
    expect(find.text('Incoming call'), findsNothing);
    expect(platform.sounding, {_video});
    await close(t);
  });

  testWidgets('a video the person had stopped stays stopped', (t) async {
    await openHome(t);
    // Tap the reel to pause it.
    await t.tapAt(const Offset(200, 400));
    await frames(t, 4);
    expect(platform.sounding, isEmpty, reason: 'tapping did not pause it');
    await pressPlus(t);
    await t.tapAt(const Offset(30, 120));
    await frames(t, 8);
    expect(platform.sounding, isEmpty, reason: 'it started on its own');
    await close(t);
  });
}
