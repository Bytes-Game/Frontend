// The page the + button opens: the phone's photos and videos, and the
// camera, the way Instagram and TikTok do it.
//
// Nobody is asked "photo or video?". These check that the app works it out
// from what was picked — a photo goes straight to the details page as a
// photo, a video goes to the trim screen — through the real pages, with
// only the phone faked: its gallery (FakeGallery), its camera, its video
// player and its permission prompt.

import 'dart:async';
import 'dart:io';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/pages/create_page.dart';
import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/create_flow.dart';
import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/event_tracker.dart';

import 'fake_gallery.dart';

/// A video player that opens anything, for the trim screen's preview.
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

/// A camera that hands back real files, and records what it was asked.
class _Camera extends CameraPlatform {
  late Directory dir;
  final List<String> asked = [];
  final _initialized = StreamController<CameraInitializedEvent>.broadcast();

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
    CameraDescription(
      name: 'back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings? mediaSettings,
  ) async => 1;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    scheduleMicrotask(
      () => _initialized.add(
        const CameraInitializedEvent(
          1,
          720,
          1280,
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      ),
    );
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _initialized.stream;

  // Open, and silent: the controller waits on the first error, and a
  // stream that ends at once is itself an error.
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<XFile> takePicture(int cameraId) async {
    asked.add('photo');
    final f = File('${dir.path}/camera_shot.jpg')
      ..writeAsBytesSync(tinyPicture);
    return XFile(f.path);
  }

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async =>
      asked.add('record');

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    asked.add('stop');
    final f = File('${dir.path}/camera_clip.mp4')
      ..writeAsBytesSync(List.filled(2048, 1));
    return XFile(f.path);
  }

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.grey);

  @override
  Future<void> dispose(int cameraId) async {}
}

const _permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  final videos = _Videos();
  final camera = _Camera();
  late FakeGallery gallery;
  late Directory dir;

  setUpAll(() {
    VideoPlayerPlatform.instance = videos;
    CameraPlatform.instance = camera;
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('create_page');
    camera.dir = dir;
    camera.asked.clear();
    gallery = FakeGallery();
    DeviceGallery.instance = gallery;
  });

  tearDown(() {
    DeviceGallery.instance = PhoneGallery();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> frames(WidgetTester t, [int n = 8]) async {
    for (var i = 0; i < n; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets real file copying finish (the camera's file is copied to the
  /// app's own name). It goes back and forth between the real world and
  /// the test's clock, so it takes turns.
  Future<void> letFilesMove(WidgetTester t) async {
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
    await frames(t, 4);
  }

  /// The create page, opened the way the + button opens it, over a page
  /// that stands for wherever + was pressed.
  Future<void> openCreate(WidgetTester t) async {
    t.view.physicalSize = const Size(400, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    EventTracker.instance.dispose();
    await t.pumpWidget(
      ChangeNotifierProvider<DataProvider>(
        // Nobody signed in: the details page then uploads nothing in the
        // background, and nothing here is about the upload.
        create: (_) => DataProvider(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => CreateFlow.open(context),
                  child: const Text('launcher'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('launcher'));
    await frames(t, 8);
    expect(find.byType(CreatePage), findsOneWidget);
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    EventTracker.instance.dispose();
  }

  void allowCamera(WidgetTester t) {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_permissions, (
      call,
    ) async {
      final asked = (call.arguments as List).cast<int>();
      return {for (final p in asked) p: 1}; // granted
    });
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(_pathProvider, (
      call,
    ) async {
      return dir.path;
    });
    addTearDown(() {
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _permissions,
        null,
      );
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _pathProvider,
        null,
      );
    });
  }

  group('the grid', () {
    testWidgets('the camera first, then the phone\'s photos and videos, '
        'newest first, and the newest ready to go', (t) async {
      gallery
        ..addVideo(dir, 'v1', const Duration(seconds: 42))
        ..addPhoto(dir, 'p1')
        ..addPhoto(dir, 'p2');
      await openCreate(t);
      final cam = t.getTopLeft(find.byKey(const ValueKey('create_camera')));
      final v1 = t.getTopLeft(find.byKey(const ValueKey('create_item_v1')));
      final p1 = t.getTopLeft(find.byKey(const ValueKey('create_item_p1')));
      final p2 = t.getTopLeft(find.byKey(const ValueKey('create_item_p2')));
      expect(cam.dy, v1.dy, reason: 'one row: the camera, then the newest');
      expect(cam.dx, lessThan(v1.dx));
      expect(v1.dx, lessThan(p1.dx));
      expect(p1.dx, lessThan(p2.dx));
      // A video says how long it is.
      expect(find.text('0:42'), findsWidgets);
      // The newest is picked and shown big, so Next works at once.
      expect(find.byKey(const ValueKey('create_preview_v1')), findsOneWidget);
      expect(
        t
            .widget<TextButton>(find.byKey(const ValueKey('create_next')))
            .onPressed,
        isNotNull,
      );
      // No "photo or video?" anywhere.
      expect(find.text('Photo'), findsNothing);
      expect(find.text('Upload'), findsNothing);
      await close(t);
    });

    testWidgets('tapping one shows it big', (t) async {
      gallery
        ..addVideo(dir, 'v1', const Duration(seconds: 9))
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_item_p1')));
      await frames(t, 2);
      expect(find.byKey(const ValueKey('create_preview_p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('create_preview_v1')), findsNothing);
      await close(t);
    });

    testWidgets('scrolling down reads the next photos and videos', (t) async {
      for (var i = 0; i < 150; i++) {
        gallery.addPhoto(dir, 'p$i');
      }
      await openCreate(t);
      expect(gallery.pagesAsked, [0]);
      await t.drag(find.byType(GridView), const Offset(0, -1500));
      await frames(t, 4);
      expect(gallery.pagesAsked, contains(1));
      await close(t);
    });

    testWidgets('a gallery that could not be read says so', (t) async {
      gallery.broken = true;
      await openCreate(t);
      expect(
        find.text("Couldn't read your photos and videos."),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('create_camera')), findsOneWidget);
      await close(t);
    });
  });

  group('the app tells a photo from a video by itself', () {
    testWidgets('a photo goes straight to the details, as a photo', (t) async {
      gallery
        ..addVideo(dir, 'v1', const Duration(seconds: 9))
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_item_p1')));
      await frames(t, 2);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await frames(t, 8);
      expect(gallery.filesAsked, ['p1']);
      final details = t.widget<ChallengeMetadataPage>(
        find.byType(ChallengeMetadataPage),
      );
      expect(details.photo, isTrue);
      expect(details.processedSourcePath, gallery.files['p1']!.path);
      expect(find.byType(VideoTrimPage), findsNothing);
      expect(find.text('New photo challenge'), findsOneWidget);
      await close(t);
    });

    testWidgets('a video goes to the trim screen', (t) async {
      gallery
        ..addVideo(dir, 'v1', const Duration(seconds: 9))
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await frames(t, 8);
      expect(gallery.filesAsked, ['v1']);
      final trim = t.widget<VideoTrimPage>(find.byType(VideoTrimPage));
      expect(trim.sourcePath, gallery.files['v1']!.path);
      expect(find.byType(ChallengeMetadataPage), findsNothing);
      await close(t);
    });

    testWidgets('one that could not be opened says so and stays', (t) async {
      gallery.items.add(const GalleryItem(id: 'gone', isVideo: false));
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await frames(t, 4);
      expect(find.text("Couldn't open that one. Try another."), findsOneWidget);
      expect(find.byType(CreatePage), findsOneWidget);
      await close(t);
    });

    testWidgets('back from the details lands on the grid, still open', (
      t,
    ) async {
      gallery.addPhoto(dir, 'p1');
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await frames(t, 8);
      expect(find.byType(ChallengeMetadataPage), findsOneWidget);
      await t.pageBack();
      await frames(t, 8);
      expect(find.byType(CreatePage), findsOneWidget);
      expect(find.byKey(const ValueKey('create_preview_p1')), findsOneWidget);
      await close(t);
    });
  });

  group('without access to the gallery', () {
    testWidgets('it says so; the camera and the phone\'s own picker still '
        'work', (t) async {
      gallery
        ..access = GalleryAccess.denied
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      expect(find.byKey(const ValueKey('create_no_access')), findsOneWidget);
      expect(find.byKey(const ValueKey('create_camera')), findsOneWidget);
      expect(find.byKey(const ValueKey('create_item_p1')), findsNothing);
      expect(find.byKey(const ValueKey('create_next')), findsNothing);

      gallery.phonePick = PickedMedia(gallery.files['p1']!, isVideo: false);
      await t.tap(find.byKey(const ValueKey('create_phone_picker')));
      await frames(t, 8);
      expect(gallery.phonePickerOpened, 1);
      final details = t.widget<ChallengeMetadataPage>(
        find.byType(ChallengeMetadataPage),
      );
      expect(details.photo, isTrue, reason: 'the picker said it is a photo');
      await close(t);
    });

    testWidgets('a video from the phone\'s picker goes to the trim screen', (
      t,
    ) async {
      gallery
        ..access = GalleryAccess.denied
        ..addVideo(dir, 'v1', const Duration(seconds: 5));
      gallery.phonePick = PickedMedia(gallery.files['v1']!, isVideo: true);
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_phone_picker')));
      await frames(t, 8);
      expect(find.byType(VideoTrimPage), findsOneWidget);
      await close(t);
    });

    testWidgets('Allow access asks again; refused for good, it opens the '
        'settings, and coming back from them shows the gallery', (t) async {
      gallery
        ..access = GalleryAccess.denied
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      expect(gallery.accessAsked, 1);
      await t.tap(find.byKey(const ValueKey('create_allow')));
      await frames(t, 4);
      expect(gallery.accessAsked, 2);
      expect(gallery.settingsOpened, 1);

      // Allowed in the settings, then back to the app.
      gallery.access = GalleryAccess.all;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frames(t, 6);
      expect(find.byKey(const ValueKey('create_item_p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('create_no_access')), findsNothing);
      await close(t);
    });

    testWidgets('only some photos shared: Choose more, then the grid again', (
      t,
    ) async {
      gallery
        ..access = GalleryAccess.limited
        ..addPhoto(dir, 'p1');
      await openCreate(t);
      expect(find.byKey(const ValueKey('create_item_p1')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('create_choose_more')));
      await frames(t, 4);
      expect(gallery.choseMore, 1);
      expect(gallery.pagesAsked, [0, 0], reason: 'read again after choosing');
      await close(t);
    });
  });

  group('the camera', () {
    testWidgets('opens with Photo and Video; a photo taken goes to the '
        'details as a photo', (t) async {
      allowCamera(t);
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_camera')));
      await frames(t, 10);
      final page = t.widget<RecordVideoPage>(find.byType(RecordVideoPage));
      expect(page.allowPhoto, isTrue);
      expect(find.byKey(const ValueKey('camera_mode_photo')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera_mode_video')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('camera_mode_photo')));
      await frames(t, 2);
      await t.tap(find.byKey(const ValueKey('camera_shutter')));
      await letFilesMove(t);
      expect(camera.asked, ['photo']);
      final details = t.widget<ChallengeMetadataPage>(
        find.byType(ChallengeMetadataPage),
      );
      expect(details.photo, isTrue);
      expect(details.processedSourcePath, endsWith('.jpg'));
      expect(File(details.processedSourcePath).existsSync(), isTrue);
      await close(t);
    });

    testWidgets('in Video it records, as before, and the clip goes to the '
        'trim screen', (t) async {
      allowCamera(t);
      await openCreate(t);
      await t.tap(find.byKey(const ValueKey('create_camera')));
      await frames(t, 10);
      await t.tap(find.byKey(const ValueKey('camera_shutter')));
      await frames(t, 4);
      expect(camera.asked, ['record']);
      // While recording there is no switching to Photo.
      expect(find.byKey(const ValueKey('camera_mode_photo')), findsNothing);
      await t.tap(find.byKey(const ValueKey('camera_shutter')));
      await letFilesMove(t);
      expect(camera.asked, ['record', 'stop']);
      final trim = t.widget<VideoTrimPage>(find.byType(VideoTrimPage));
      expect(trim.sourcePath, endsWith('.mp4'));
      await close(t);
    });

    testWidgets('answering a video challenge, the camera offers no Photo', (
      t,
    ) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(const MaterialApp(home: RecordVideoPage()));
      await frames(t, 10);
      expect(find.byKey(const ValueKey('camera_shutter')), findsOneWidget);
      expect(find.byKey(const ValueKey('camera_mode_photo')), findsNothing);
      await close(t);
    });

    test(
      'a photo and a video are told apart by the file they come back as',
      () {
        expect(RecordVideoPage.isPhotoPath('/tmp/devf_photo_1.jpg'), isTrue);
        expect(RecordVideoPage.isPhotoPath('/tmp/IMG_2.HEIC'), isTrue);
        expect(RecordVideoPage.isPhotoPath('/tmp/devf_record_1.mp4'), isFalse);
        expect(RecordVideoPage.isPhotoPath('/tmp/clip.mov'), isFalse);
      },
    );
  });
}
