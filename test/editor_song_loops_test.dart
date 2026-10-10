// The song under a video in the editor keeps playing as the video loops.
//
// It used to play once. At the end of the video the editor jumped back to
// the start, asked the player whether it was playing, and stopped the song
// when it said no — but a phone's player always says no for a moment while
// it jumps, and carries on by itself straight after. A device log showed it
// at every loop: the song paused 7ms after the jump, and the video playing
// again 90ms later without it.
//
// The phone here behaves the way that log shows: "not playing" for a moment
// during every jump, and, asked to loop, going back to the start by itself
// at its very end. Everything else — the editor, the picker, the song
// player's instructions — is the real thing.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/pages/music_picker_page.dart';
import 'package:myapp/pages/video_editor_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/video_edit_engine.dart';

import 'fake_music.dart';
import 'fake_video_engine.dart';

/// A phone's video player, as far as looping goes.
class _Phone extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _id = 0;

  /// The player the editor opened last.
  int id = -1;

  /// How long the video really is, to the player.
  Duration length = const Duration(seconds: 10);

  bool looping = false;
  bool playing = false;
  Duration at = Duration.zero;
  final List<String> calls = [];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    id = _id++;
    looping = false;
    playing = false;
    at = Duration.zero;
    calls.clear();
    _events[id] = StreamController<VideoEvent>()
      ..add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(9, 16),
          duration: length,
        ),
      );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
    playing = true;
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
    playing = false;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek ${position.inMilliseconds}');
    at = position;
    if (!playing) return;
    // Getting the new spot ready: not playing for a moment, then playing
    // again by itself.
    _events[playerId]?.add(
      VideoEvent(eventType: VideoEventType.isPlayingStateUpdate, isPlaying: false),
    );
    Timer(const Duration(milliseconds: 90), () {
      if (playing) {
        _events[playerId]?.add(
          VideoEvent(
            eventType: VideoEventType.isPlayingStateUpdate,
            isPlaying: true,
          ),
        );
      }
    });
  }

  /// The video plays on to [to]. At its very end the phone goes back to the
  /// start by itself if it was asked to loop, and stops there if not.
  void playTo(Duration to) {
    if (to < length) {
      at = to;
    } else if (looping) {
      at = to - length;
    } else {
      at = length;
      playing = false;
      _events[id]?.add(VideoEvent(eventType: VideoEventType.completed));
    }
  }

  @override
  Future<void> dispose(int playerId) async => _events.remove(playerId);
  @override
  Future<void> setVolume(int playerId, double v) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      this.looping = looping;
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => at;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory dir;
  late FakeMusicLibrary library;
  late FakeVideoEngine engine;
  late File video;
  final phone = _Phone();

  setUpAll(() => VideoPlayerPlatform.instance = phone);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('loops');
    library = FakeMusicLibrary(dir)..all = [song('a', title: 'Alpha')];
    MusicLibrary.instance = library;
    FakeMusicPlayer.made.clear();
    MusicPlayer.create = FakeMusicPlayer.new;
    engine = FakeVideoEngine(dir);
    VideoEditEngine.instance = engine;
    phone.length = const Duration(seconds: 10);
    video = File('${dir.path}/picked.mp4')
      ..writeAsBytesSync(List.filled(2048, 1));
  });

  tearDown(() {
    MusicLibrary.instance = ServerMusicLibrary();
    MusicPlayer.create = DeviceMusicPlayer.new;
    VideoEditEngine.instance = PhoneVideoEditEngine();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openEditor(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _pathProvider,
      (call) async => dir.path,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pathProvider,
        null,
      ),
    );
    EventTracker.instance.dispose();
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: editorLocalizations,
        home: VideoEditorPage(
          sourcePath: video.path,
          onDone: (context, path, music) async => true,
        ),
      ),
    );
    await settle(t);
  }

  Future<void> addSong(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('editor_add_music')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('music_use_a')));
    await settle(t);
    expect(find.byType(MusicPickerPage), findsNothing);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    EventTracker.instance.dispose();
  }

  /// What the song player was told to do, after the first [from] calls.
  List<String> songSince(int from) {
    final calls = FakeMusicPlayer.made.last.calls;
    return [
      for (final c in calls.skip(from))
        if (c.startsWith('play') || c == 'pause' || c == 'stop')
          c.split(' loop').first.replaceFirst('${dir.path}/', ''),
    ];
  }

  testWidgets('the video plays as the editor opens', (t) async {
    await openEditor(t);
    expect(phone.calls, contains('play'));
    expect(phone.playing, isTrue);
    expect(phone.looping, isTrue, reason: 'the phone loops it at its end');
    await close(t);
  });

  testWidgets('back to the start at the end of the video: the song starts '
      'again with it', (t) async {
    // The player goes a little past the length the editor was told, so
    // the editor's own jump back to the start is what loops it.
    phone.length = const Duration(milliseconds: 10300);
    await openEditor(t);
    await addSong(t);
    expect(songSince(0), contains('play music_a.mp3 from 0'));

    phone.playTo(const Duration(seconds: 4));
    await settle(t, 3);
    final before = FakeMusicPlayer.made.last.calls.length;

    phone.playTo(const Duration(milliseconds: 10100));
    await settle(t, 4);
    expect(phone.calls, contains('seek 0'), reason: 'the video went back');
    expect(phone.playing, isTrue);
    expect(
      songSince(before),
      ['play music_a.mp3 from 0'],
      reason: 'the song starts again from where the video does, and is '
          'not stopped by the moment the phone says "not playing"',
    );

    // And again on the next loop.
    final second = FakeMusicPlayer.made.last.calls.length;
    phone.playTo(const Duration(milliseconds: 10100));
    await settle(t, 4);
    expect(songSince(second), ['play music_a.mp3 from 0']);
    await close(t);
  });

  testWidgets('a video the phone loops by itself: the song goes back with '
      'it', (t) async {
    // The editor was told the video is longer than the player plays it,
    // so its own jump never comes and the phone's loop is all there is.
    engine.source = const VideoFacts(
      duration: Duration(milliseconds: 10300),
      resolution: Size(1080, 1920),
      bitrate: 12000000,
      hasSound: true,
    );
    await openEditor(t);
    await addSong(t);
    phone.playTo(const Duration(seconds: 9));
    await settle(t, 3);
    final before = FakeMusicPlayer.made.last.calls.length;

    phone.playTo(const Duration(milliseconds: 10200));
    await settle(t, 4);
    expect(phone.playing, isTrue, reason: 'the video carries on');
    expect(songSince(before), ['play music_a.mp3 from 200']);
    await close(t);
  });

  testWidgets('paused, the song stays paused', (t) async {
    await openEditor(t);
    await addSong(t);
    final state = t.state<VideoEditorPageState>(find.byType(VideoEditorPage));
    final before = FakeMusicPlayer.made.last.calls.length;
    state.controller!.pause();
    await settle(t, 4);
    expect(songSince(before), ['pause']);
    expect(phone.playing, isFalse);

    state.controller!.play();
    await settle(t, 4);
    expect(songSince(before), ['pause', 'play music_a.mp3 from 0']);
    await close(t);
  });
}
