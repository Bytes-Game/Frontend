// The photo editor and the video editor, through the real editor screens
// (pro_image_editor), with only the phone faked: its video player and its
// video tools (FakeVideoEngine).
//
// What these hold the editors to is the quality promise:
//
//   * nothing changed: the very same file goes on — not a copy;
//   * a video only cut shorter: cut, not remade;
//   * anything else: remade at the original's own size and data rate;
//   * a remake that lost the sound is caught, and the person is offered
//     the video without the edit, with its sound.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/pages/photo_editor_page.dart';
import 'package:myapp/pages/video_editor_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_edit_engine.dart';

import 'fake_gallery.dart';
import 'fake_video_engine.dart';

/// A video player that opens anything, for the editor's preview.
class _Videos extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  int _id = 0;

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

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  late Directory dir;
  late FakeVideoEngine engine;

  setUpAll(() => VideoPlayerPlatform.instance = _Videos());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('editors');
    engine = FakeVideoEngine(dir);
    VideoEditEngine.instance = engine;
  });

  tearDown(() {
    VideoEditEngine.instance = PhoneVideoEditEngine();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// The editors decode and encode for real, off the test's clock: this
  /// lets that work finish, in turns.
  Future<void> settle(WidgetTester t, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// What the next step (the posting page) was handed, and what it
  /// answered.
  final handed = <String>[];
  final handedMusic = <MusicTrack?>[];
  var postAnswers = <bool>[];

  Future<bool> next(
    BuildContext context,
    String path,
    MusicTrack? music,
  ) async {
    handed.add(path);
    handedMusic.add(music);
    return postAnswers.isNotEmpty ? postAnswers.removeAt(0) : true;
  }

  /// [page], opened from a page that stands for the one before it. Answers
  /// a way to read what the editor closed with.
  Future<bool? Function()> open(WidgetTester t, Widget page) async {
    handed.clear();
    handedMusic.clear();
    postAnswers = [];
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
    bool? closedWith;
    await t.pumpWidget(
      MaterialApp(
        localizationsDelegates: editorLocalizations,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  closedWith = await Navigator.of(
                    context,
                  ).push<bool>(MaterialPageRoute(builder: (_) => page));
                },
                child: const Text('before'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('before'));
    await settle(t);
    return () => closedWith;
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    EventTracker.instance.dispose();
  }

  Future<void> done(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
    await settle(t, 14);
  }

  /// Text typed on top of the picture: an edit, made the way a person
  /// makes it.
  Future<void> addText(WidgetTester t, String words) async {
    await t.tap(find.text('Text'));
    await settle(t);
    await t.enterText(find.byType(EditableText).first, words);
    await t.pump();
    await t.tap(find.byKey(const ValueKey('TextEditorDoneButton')));
    await settle(t);
  }

  group('the editors\' words', () {
    testWidgets('an app without them cannot even draw an editor', (t) async {
      final photo = File('${dir.path}/picked.jpg')..writeAsBytesSync(tinyJpeg);
      await t.pumpWidget(
        MaterialApp(
          home: PhotoEditorPage(sourcePath: photo.path, onDone: next),
        ),
      );
      await settle(t, 3);
      expect(
        '${t.takeException()}',
        contains('MaterialLocalizations'),
        reason: 'if this ever draws, the words below are not needed',
      );
      await close(t);
    });

    test('the app has them', () {
      // Comment lines out first: a comment saying they are added is not
      // them being added.
      final src = File('lib/main.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final at = src.indexOf('return MaterialApp(');
      expect(at, greaterThan(-1));
      var depth = 0;
      var end = at;
      for (var i = src.indexOf('(', at); i < src.length; i++) {
        if (src[i] == '(') depth++;
        if (src[i] == ')' && --depth == 0) {
          end = i;
          break;
        }
      }
      expect(
        src.substring(at, end),
        contains('localizationsDelegates: editorLocalizations'),
      );
    });
  });

  group('the photo editor', () {
    late File photo;

    setUp(() {
      photo = File('${dir.path}/picked.jpg')..writeAsBytesSync(tinyJpeg);
    });

    testWidgets('has its tools, and saves an edit at full quality: JPEG at '
        '100, up to 2000 pixels', (t) async {
      await open(t, PhotoEditorPage(sourcePath: photo.path, onDone: next));
      for (final tool in [
        'Crop/ Rotate',
        'Filter',
        'Tune',
        'Text',
        'Emoji',
        'Paint',
        'Blur',
      ]) {
        expect(find.text(tool), findsOneWidget, reason: tool);
      }
      final saving = t
          .widget<ProImageEditor>(find.byType(ProImageEditor))
          .configs
          .imageGeneration;
      expect(saving.outputFormat, OutputFormat.jpg);
      expect(saving.jpegQuality, 100);
      expect(saving.maxOutputSize, const Size(2000, 2000));
      expect(saving.enableUseOriginalBytes, isTrue);
      await close(t);
    });

    testWidgets('Done with nothing changed: the very same file goes on, '
        'not a copy', (t) async {
      final closed = await open(
        t,
        PhotoEditorPage(sourcePath: photo.path, onDone: next),
      );
      await done(t);
      expect(handed, [photo.path]);
      expect(
        dir.listSync().where((f) => f.path.contains('edited_photo')),
        isEmpty,
        reason: 'nothing was written',
      );
      expect(closed(), isTrue, reason: 'posted: the editor closes');
      expect(find.byType(PhotoEditorPage), findsNothing);
      await close(t);
    });

    testWidgets('with text on it: a new JPEG goes on, and the original is '
        'left alone', (t) async {
      await open(t, PhotoEditorPage(sourcePath: photo.path, onDone: next));
      await addText(t, 'hello');
      await done(t);
      expect(handed, hasLength(1));
      expect(handed.single, isNot(photo.path));
      expect(handed.single, contains('edited_photo'));
      final edited = File(handed.single).readAsBytesSync();
      expect(edited.take(2), [0xFF, 0xD8], reason: 'a JPEG');
      expect(edited, isNot(tinyJpeg));
      expect(photo.readAsBytesSync(), tinyJpeg, reason: 'original untouched');
      await close(t);
    });

    testWidgets('back from the posting page lands in the editor; posting '
        'then closes it', (t) async {
      final closed = await open(
        t,
        PhotoEditorPage(sourcePath: photo.path, onDone: next),
      );
      postAnswers = [false, true];
      await done(t);
      expect(handed, hasLength(1));
      expect(find.byType(PhotoEditorPage), findsOneWidget);
      expect(closed(), isNull);
      await done(t);
      expect(handed, hasLength(2));
      expect(find.byType(PhotoEditorPage), findsNothing);
      expect(closed(), isTrue);
      await close(t);
    });

    testWidgets('saving failed: it says so, and the editor stays open', (
      t,
    ) async {
      final closed = await open(
        t,
        PhotoEditorPage(sourcePath: photo.path, onDone: next),
      );
      // Nowhere to write the edited photo.
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pathProvider,
        (call) async => throw PlatformException(code: 'no_space'),
      );
      await addText(t, 'hello');
      await done(t);
      expect(handed, isEmpty);
      expect(find.text("Couldn't save your edit. Try again."), findsOneWidget);
      expect(find.byType(PhotoEditorPage), findsOneWidget);
      expect(closed(), isNull, reason: 'not closed as if cancelled');
      await close(t);
    });

    testWidgets('Cancel goes back, and nothing is posted', (t) async {
      final closed = await open(
        t,
        PhotoEditorPage(sourcePath: photo.path, onDone: next),
      );
      await t.tap(find.byTooltip('Cancel'));
      await settle(t);
      expect(handed, isEmpty);
      expect(find.byType(PhotoEditorPage), findsNothing);
      expect(closed(), isFalse);
      await close(t);
    });

    test('an unchanged photo is the original file; a changed one is a '
        'file of its own', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, (call) async => dir.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_pathProvider, null),
      );
      expect(await keepEditedPhoto(photo.path, tinyJpeg), photo.path);
      final other = await keepEditedPhoto(photo.path, tinyPicture);
      expect(other, isNot(photo.path));
      expect(File(other).readAsBytesSync(), tinyPicture);
    });
  });

  group('the video editor', () {
    late File video;

    setUp(() {
      video = File('${dir.path}/picked.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
    });

    VideoEditorPageState state(WidgetTester t) =>
        t.state<VideoEditorPageState>(find.byType(VideoEditorPage));

    testWidgets('has its tools, the trim bar and the sound button', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      for (final tool in [
        'Crop/ Rotate',
        'Filter',
        'Tune',
        'Text',
        'Emoji',
        'Paint',
        'Blur',
      ]) {
        expect(find.text(tool), findsOneWidget, reason: tool);
      }
      final c = state(t).controller!;
      expect(c.startTime, Duration.zero);
      expect(c.endTime, const Duration(seconds: 10));
      expect(c.isAudioEnabled, isTrue);
      final configs = t
          .widget<ProImageEditor>(find.byType(ProImageEditor))
          .configs
          .videoEditor;
      expect(configs.isAudioSupported, isTrue);
      expect(configs.minTrimDuration, VideoEditorPage.minLength);
      await close(t);
    });

    testWidgets('Done with nothing changed: the original file — not cut, '
        'not remade', (t) async {
      final closed = await open(
        t,
        VideoEditorPage(sourcePath: video.path, onDone: next),
      );
      await done(t);
      expect(handed, [video.path]);
      expect(engine.cuts, isEmpty);
      expect(engine.renders, isEmpty);
      expect(closed(), isTrue);
      await close(t);
    });

    testWidgets('only cut shorter: cut without remaking, at the points '
        'chosen', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      state(t).controller!.setTrimSpan(
        const TrimDurationSpan(
          start: Duration(seconds: 2),
          end: Duration(seconds: 7),
        ),
      );
      await done(t);
      expect(engine.cuts, hasLength(1));
      expect(engine.cuts.single.path, video.path);
      expect(engine.cuts.single.start, const Duration(seconds: 2));
      expect(engine.cuts.single.end, const Duration(seconds: 7));
      expect(engine.renders, isEmpty, reason: 'not remade');
      expect(handed, hasLength(1));
      expect(handed.single, contains('cut_'));
      await close(t);
    });

    testWidgets('cut on a phone that cannot cut without remaking (an '
        'iPhone): remade at the original\'s own data rate, nothing else '
        'changed', (t) async {
      engine.canCutLossless = false;
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      state(t).controller!.setTrimSpan(
        const TrimDurationSpan(
          start: Duration(seconds: 2),
          end: Duration(seconds: 7),
        ),
      );
      await done(t);
      final made = engine.renders.single;
      expect(made.startTime, const Duration(seconds: 2));
      expect(made.endTime, const Duration(seconds: 7));
      expect(made.bitrate, 12000000);
      expect(made.imageLayers, isNull);
      expect(made.colorFilters, isEmpty);
      expect(made.transform, isNull);
      expect(made.enableAudio, isTrue);
      expect(handed.single, contains('edit_'));
      await close(t);
    });

    testWidgets('sound off: remade without the sound, at the original\'s '
        'own size and data rate', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      state(t).controller!.setMuteState(true);
      await done(t);
      final made = engine.renders.single;
      expect(made.enableAudio, isFalse);
      expect(made.bitrate, 12000000);
      expect(made.transform, isNull, reason: 'same size');
      expect(handed.single, contains('edit_'));
      await close(t);
    });

    testWidgets('text on it: remade with the text in it, and checked that '
        'the sound came through', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addText(t, 'hello');
      await done(t);
      final made = engine.renders.single;
      expect(made.imageLayers, hasLength(1));
      expect(made.bitrate, 12000000);
      expect(made.enableAudio, isTrue);
      expect(
        engine.factsAsked.last,
        handed.single,
        reason: 'the remade file was asked whether it has sound',
      );
      expect(find.byKey(const ValueKey('edit_lost_sound')), findsNothing);
      await close(t);
    });

    testWidgets('a 4K video is remade no bigger than 1080p, at no more than '
        '16 Mbit/s', (t) async {
      engine.source = const VideoFacts(
        duration: Duration(seconds: 10),
        resolution: Size(2160, 3840),
        bitrate: 45000000,
        hasSound: true,
      );
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      state(t).controller!.setMuteState(true);
      await done(t);
      final made = engine.renders.single;
      expect(made.bitrate, 16000000);
      expect(made.transform?.scaleX, 0.5);
      expect(made.transform?.scaleY, 0.5);
      await close(t);
    });

    testWidgets('a remake that lost the sound says so; "Post without the '
        'edit" sends the cut, with its sound', (t) async {
      engine.remakeKeepsSound = false;
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      state(t).controller!.setTrimSpan(
        const TrimDurationSpan(
          start: Duration(seconds: 1),
          end: Duration(seconds: 6),
        ),
      );
      await addText(t, 'hello');
      await done(t);
      expect(engine.renders, hasLength(1));
      expect(find.byKey(const ValueKey('edit_lost_sound')), findsOneWidget);
      expect(find.text('Your edit lost its sound'), findsOneWidget);
      expect(handed, isEmpty, reason: 'nothing goes until they choose');

      await t.tap(find.byKey(const ValueKey('edit_lost_sound_post')));
      await settle(t);
      expect(engine.cuts.single.start, const Duration(seconds: 1));
      expect(engine.cuts.single.end, const Duration(seconds: 6));
      expect(handed, hasLength(1));
      expect(handed.single, contains('cut_'));
      await close(t);
    });

    testWidgets('lost sound, not cut: "Post without the edit" sends the '
        'original; "Go back" sends nothing', (t) async {
      engine.remakeKeepsSound = false;
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addText(t, 'hello');
      await done(t);
      await t.tap(find.byKey(const ValueKey('edit_lost_sound_back')));
      await settle(t);
      expect(handed, isEmpty);
      expect(find.byType(VideoEditorPage), findsOneWidget, reason: 'stays');

      await done(t);
      await t.tap(find.byKey(const ValueKey('edit_lost_sound_post')));
      await settle(t);
      expect(handed, [video.path]);
      await close(t);
    });

    testWidgets('longer than a post may be: the first three minutes are '
        'kept to start with, and the cut is no longer', (t) async {
      engine.source = const VideoFacts(
        duration: Duration(minutes: 4),
        resolution: Size(1080, 1920),
        bitrate: 12000000,
        hasSound: true,
      );
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      final c = state(t).controller!;
      expect(c.startTime, Duration.zero);
      expect(c.endTime, const Duration(minutes: 3));
      await done(t);
      expect(engine.cuts.single.start, Duration.zero);
      expect(engine.cuts.single.end, const Duration(minutes: 3));
      await close(t);
    });

    testWidgets('saving failed: it says so, and the editor stays open', (
      t,
    ) async {
      engine.renderFail = Exception('encoder gone');
      final closed = await open(
        t,
        VideoEditorPage(sourcePath: video.path, onDone: next),
      );
      state(t).controller!.setMuteState(true);
      await done(t);
      expect(handed, isEmpty);
      expect(find.text("Couldn't save your edit. Try again."), findsOneWidget);
      expect(find.byType(VideoEditorPage), findsOneWidget);
      expect(closed(), isNull);
      await close(t);
    });

    testWidgets('a remake shows how far it has got; Cancel stops it, and '
        'the editor stays open with nothing said', (t) async {
      engine.renderHeld = Completer<void>();
      final closed = await open(
        t,
        VideoEditorPage(sourcePath: video.path, onDone: next),
      );
      state(t).controller!.setMuteState(true);
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      await settle(t, 4);
      expect(find.byKey(const ValueKey('video_saving')), findsOneWidget);
      expect(find.text('Saving…'), findsOneWidget);
      expect(find.byKey(const ValueKey('video_saving_cancel')), findsNothing);

      engine.progressReports.add(0.42);
      await settle(t, 2);
      expect(find.text('Saving your video… 42%'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('video_saving_cancel')));
      await settle(t, 10);
      expect(engine.cancelled, [engine.renders.single.id]);
      expect(handed, isEmpty);
      expect(find.byKey(const ValueKey('video_saving')), findsNothing);
      expect(find.text("Couldn't save your edit. Try again."), findsNothing);
      expect(find.byType(VideoEditorPage), findsOneWidget);
      expect(closed(), isNull);
      await close(t);
    });

    testWidgets('a video the editor cannot open: the old trim screen takes '
        'over, so it can still be posted', (t) async {
      engine.factsFail = Exception('no decoder');
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      final trim = t.widget<VideoTrimPage>(find.byType(VideoTrimPage));
      expect(trim.sourcePath, video.path);
      expect(trim.popOnComplete, isTrue);
      await close(t);
    });
  });
}
