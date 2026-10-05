// Photo challenges: "who looks better", "which is the better meme".
//
// A challenge can be a photo now, answered with a photo. These go through
// the real screens — the feed, the + button's page, the editors, the
// posting page, the battle page, Search — with only the server, the phone's
// video player, video tools, camera and gallery faked, and check two things
// everywhere a post appears:
//
//   * the photo is SHOWN — the picture is on screen;
//   * nothing treats it as a video — no player is opened for it, so no
//     decoder is spent and no JPEG is fed to a video player.
//
// Every "nothing opened" check sits next to one showing that a video in
// the same place DOES open a player, or the check would prove nothing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/create_page.dart';
import 'package:myapp/pages/photo_editor_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/pages/video_editor_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/create_flow.dart';
import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/media_upload_service.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/widgets/match_warning.dart';
import 'package:myapp/widgets/photo_face.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

import 'fake_gallery.dart';
import 'fake_music.dart';
import 'fake_video_engine.dart';

/// A phone video player that records what it was asked to open.
class _Platform extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events = {};
  final List<String> opened = [];
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
    opened.add(options.dataSource.uri ?? '');
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

class _Photos implements PhotoSource {
  File? next;
  bool? askedCamera;
  @override
  Future<File?> pick({required bool camera}) async {
    askedCamera = camera;
    return next;
  }
}

/// The phone's file picker: hands back [next].
class _Picker extends FilePicker {
  String? next;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final path = next;
    if (path == null) return null;
    return FilePickerResult([
      PlatformFile(
        path: path,
        name: path.split('/').last,
        size: File(path).lengthSync(),
      ),
    ]);
  }
}

const photoUrl = 'https://cdn/u/9/a/photo.jpg';
const answerPhotoUrl = 'https://cdn/u/8/b/photo.jpg';

/// maya's photo challenge, and leo's photo answering it.
Map<String, dynamic> photoBattle() => {
  'id': '1',
  'creatorId': '9',
  'creatorUsername': 'maya',
  'mediaType': 'photo',
  'videoUrl': photoUrl,
  'thumbnailUrl': photoUrl,
  'prefix': 'Who looks',
  'subject': 'better in red',
  'status': 'active',
  'createdAt': '2026-09-20T10:00:00Z',
  'responseCount': 1,
  'topResponseId': '77',
  'topResponseUsername': 'leo',
  'topResponseVideoUrl': answerPhotoUrl,
  'topResponseThumbnailUrl': answerPhotoUrl,
};

/// A photo challenge nobody has answered yet.
Map<String, dynamic> photoShort() => {
  'id': '3',
  'creatorId': '9',
  'creatorUsername': 'maya',
  'mediaType': 'photo',
  'videoUrl': photoUrl,
  'thumbnailUrl': photoUrl,
  'prefix': 'Which is',
  'subject': 'the better meme',
  'status': 'open',
  'createdAt': '2026-09-20T10:00:00Z',
};

/// An ordinary video challenge.
Map<String, dynamic> videoShort() => {
  'id': '2',
  'creatorId': '8',
  'creatorUsername': 'zara',
  'videoUrl': 'https://x/2.mp4',
  'prefix': 'Who can',
  'subject': 'cook pasta in 5 minutes',
  'status': 'open',
  'createdAt': '2026-09-20T10:00:00Z',
};

/// Every request the app made: method, path, body.
late List<(String, String, String)> asked;

/// The challenge the server sends for the feed and the battle page.
late Map<String, dynamic> serving;

/// When true, creating a challenge fails once.
bool createFailsOnce = false;

/// When true, sending an answer fails once.
bool acceptFailsOnce = false;

void fakeServer() {
  asked = [];
  createFailsOnce = false;
  acceptFailsOnce = false;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      // A photo's bytes are not text: read them leniently.
      asked.add((
        req.method,
        req.url.toString(),
        utf8.decode(req.bodyBytes, allowMalformed: true),
      ));
      if (p.endsWith('/media/presign')) {
        final items = (json.decode(req.body)['items'] as List).cast<Map>();
        return http.Response(
          json.encode({
            'uploadId': 'up1',
            'items': [
              for (final i in items)
                {
                  ...i,
                  'uploadUrl': 'https://storage/put/${i['kind']}',
                  'publicUrl': 'https://cdn/u/1/up1/photo.jpg',
                },
            ],
          }),
          200,
        );
      }
      if (req.url.host == 'storage') return http.Response('', 200);
      if (p == '/api/v1/challenges' && req.method == 'POST') {
        if (createFailsOnce) {
          createFailsOnce = false;
          return http.Response('down', 503);
        }
        return http.Response(
          json.encode({
            ...photoShort(),
            'id': '41',
            'creatorId': '1',
            'creatorUsername': 'me',
          }),
          201,
        );
      }
      if (p.endsWith('/challenges/accept')) {
        if (acceptFailsOnce) {
          acceptFailsOnce = false;
          return http.Response('down', 503);
        }
        return http.Response(
          json.encode({
            'id': '88',
            'challengeId': serving['id'],
            'responderId': '1',
            'responderUsername': 'me',
            'videoUrl': 'https://cdn/u/1/up1/photo.jpg',
            'mediaType': 'photo',
          }),
          201,
        );
      }
      if (p.endsWith('/challenges/${serving['id']}')) {
        return http.Response.bytes(
          utf8.encode(
            json.encode({
              'challenge': serving,
              'responses': [
                if (serving['topResponseId'] != null)
                  {
                    'id': serving['topResponseId'],
                    'challengeId': serving['id'],
                    'responderId': '8',
                    'responderUsername': serving['topResponseUsername'],
                    'videoUrl': serving['topResponseVideoUrl'],
                  },
              ],
              'votes': [],
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (p.contains('/feed')) {
        return http.Response.bytes(
          utf8.encode(
            json.encode({
              'items': [
                {'type': 'challenge', 'challenge': serving},
              ],
              'hasMore': false,
            }),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      if (p.endsWith('/watch')) {
        return http.Response('{"message":"ok"}', 201);
      }
      return http.Response('{}', 200);
    }),
  );
}

/// The bodies sent to [path] with [method].
List<Map<String, dynamic>> sentTo(String method, String path) => [
  for (final (m, url, body) in asked)
    if (m == method && Uri.parse(url).path == path)
      json.decode(body) as Map<String, dynamic>,
];

DataProvider signedIn() => DataProvider()
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

Future<void> frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Lets real file reading and the upload finish. Reading a file goes back
/// and forth between the real world and the test's clock, so it takes
/// turns.
Future<void> letItUpload(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  await frames(t, 4);
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SizedBox()));
  // Past the three seconds a finished upload stays on screen.
  await t.pump(const Duration(seconds: 5));
  ReelDiagnostics.instance.debugReset();
  EventTracker.instance.dispose();
}

/// The feed, opening on whatever [serving] is.
Future<void> openFeed(WidgetTester t) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  EventTracker.instance.dispose();
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: signedIn(),
      child: const MaterialApp(
        localizationsDelegates: editorLocalizations,
        home: Scaffold(body: SmartReelsFeed(userId: '1')),
      ),
    ),
  );
  await frames(t, 6);
}

/// The picture of each photo on screen.
List<String> photosShown(WidgetTester t) => [
  for (final f in t.widgetList<PhotoFace>(find.byType(PhotoFace)))
    if (f.url.isNotEmpty) f.url,
];

void main() {
  final platform = _Platform();
  late _Photos photos;
  late Directory dir;
  setUpAll(() => VideoPlayerPlatform.instance = platform);

  setUp(() {
    SmartReelsFeed.debugForgetAppOpen();
    platform.opened.clear();
    serving = photoBattle();
    fakeServer();
    photos = _Photos();
    ChatMedia.instance.photos = photos;
    dir = Directory.systemTemp.createTempSync('photo_posts');
    final f = File('${dir.path}/picked.jpg')..writeAsBytesSync(tinyJpeg);
    photos.next = f;
    VideoEditEngine.instance = FakeVideoEngine(dir);
  });

  tearDown(() {
    VideoEditEngine.instance = PhoneVideoEditEngine();
    ApiService.useClient(http.Client());
    ChatMedia.instance.debugReset();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a challenge says whether it is a photo; anything else is a video', () {
    expect(ChallengeModel.fromJson(photoBattle()).isPhoto, isTrue);
    expect(ChallengeModel.fromJson(videoShort()).isPhoto, isFalse);
    expect(
      ChallengeModel.fromJson({...videoShort(), 'mediaType': 'gif'}).isPhoto,
      isFalse,
    );
  });

  group('a song on a reel', () {
    const alpha = {
      'id': '7',
      'title': 'Alpha',
      'artist': 'Some Artist',
      'license': 'by',
      'licenseVersion': '4.0',
      'sourceUrl': 'https://www.jamendo.com/track/a',
      'attribution': '"Alpha" by Some Artist is licensed under CC BY 4.0.',
    };
    const beta = {
      'id': '8',
      'title': 'Beta',
      'artist': 'Other',
      'license': 'cc0',
    };

    testWidgets('a video with a song credits it; tapped, the whole credit', (
      t,
    ) async {
      serving = {...videoShort(), 'music': alpha};
      await openFeed(t);
      expect(find.byKey(const ValueKey('reel_music')), findsOneWidget);
      expect(find.text('Alpha · Some Artist'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('reel_music')));
      await frames(t, 6);
      expect(find.byKey(const ValueKey('music_credit_sheet')), findsOneWidget);
      expect(find.text('Free music · CC BY 4.0'), findsOneWidget);
      expect(find.text(alpha['attribution']!), findsOneWidget);
      await close(t);
    });

    testWidgets('a video with no song says nothing about one', (t) async {
      serving = videoShort();
      await openFeed(t);
      expect(find.textContaining('cook pasta'), findsOneWidget);
      expect(find.byKey(const ValueKey('reel_music')), findsNothing);
      await close(t);
    });

    testWidgets('a battle credits the song of the side on screen', (t) async {
      serving = {
        ...videoShort(),
        'status': 'active',
        'responseCount': 1,
        'topResponseId': '77',
        'topResponseUsername': 'leo',
        'topResponseVideoUrl': 'https://x/77.mp4',
        'music': alpha,
        'topResponseMusic': beta,
      };
      await openFeed(t);
      await t.tap(find.text('leo').first);
      await frames(t, 6);
      expect(find.text('Beta · Other'), findsOneWidget);
      expect(find.text('Alpha · Some Artist'), findsNothing);
      await t.tap(find.text('zara').first);
      await frames(t, 6);
      expect(find.text('Alpha · Some Artist'), findsOneWidget);
      expect(find.text('Beta · Other'), findsNothing);
      await close(t);
    });
  });

  group('a photo in the feed', () {
    testWidgets('a video in the same feed opens a player — so the photo '
        'checks below mean something', (t) async {
      serving = videoShort();
      await openFeed(t);
      expect(platform.opened, contains('https://x/2.mp4'));
      expect(find.byType(PhotoFace), findsNothing);
      await close(t);
    });

    testWidgets('shows the photo, whole, and opens no player for it', (
      t,
    ) async {
      serving = photoShort();
      await openFeed(t);
      expect(photosShown(t), [photoUrl], reason: 'the picture is on screen');
      expect(
        t.widget<Image>(find.byKey(const ValueKey('photo_face_picture'))).fit,
        BoxFit.contain,
        reason: 'a photo is judged whole, so it is never cropped',
      );
      // Both layers — the picture and its blurred backdrop — ask for it the
      // way the feed fetches it ahead, so it is one download, ready at once.
      final layers = t.widgetList<Image>(
        find.descendant(
          of: find.byType(PhotoFace),
          matching: find.byType(Image),
        ),
      );
      expect(layers, hasLength(2));
      for (final i in layers) {
        expect(i.image, const NetworkImage(photoUrl));
      }
      expect(platform.opened, isEmpty, reason: 'nothing to play');
      expect(find.byType(VideoPlayer), findsNothing);
      // It is a post like any other: the buttons are there.
      expect(find.text('Accept challenge'), findsOneWidget);
      await close(t);
    });

    testWidgets('looking at a photo counts as a view', (t) async {
      serving = photoShort();
      await openFeed(t);
      await t.pump(const Duration(seconds: 2));
      await frames(t, 4);
      final views = sentTo('POST', '/api/v1/watch');
      expect(views, isNotEmpty);
      expect(views.first['contentId'], '3');
      await close(t);
    });

    testWidgets('a photo battle turns to the answer\'s photo, still with no '
        'player', (t) async {
      await openFeed(t);
      expect(photosShown(t), [photoUrl]);
      await t.drag(find.byType(PhotoFace).first, const Offset(-300, 0));
      await frames(t, 8);
      expect(photosShown(t), contains(answerPhotoUrl));
      expect(platform.opened, isEmpty);
      await close(t);
    });
  });

  group('reporting a photo that does not match', () {
    Future<void> openReport(WidgetTester t) async {
      await openFeed(t);
      await t.tap(find.byKey(const ValueKey('reel_more')));
      await frames(t, 5);
      await t.tap(find.byKey(const ValueKey('reel_report')));
      await frames(t, 5);
      expect(find.byKey(const ValueKey('report_dialog')), findsOneWidget);
    }

    testWidgets('says photo, and that other people decide — no check reads '
        'a photo', (t) async {
      serving = photoShort();
      await openReport(t);
      expect(find.textContaining('Report this photo only if'), findsOneWidget);
      expect(find.textContaining('our check'), findsNothing);
      expect(find.byKey(const ValueKey('report_in_battle')), findsNothing);
      await t.tap(find.text('Cancel'));
      await frames(t, 4);
      await close(t);
    });

    testWidgets('somebody in a photo battle is told their report will not '
        'count, not that it may cost them', (t) async {
      serving = {...photoBattle(), 'topResponseUsername': 'me'};
      await openReport(t);
      expect(
        find.textContaining("on a photo your report won't count"),
        findsOneWidget,
      );
      expect(find.textContaining('cost you rating points'), findsNothing);
      await t.tap(find.text('Cancel'));
      await frames(t, 4);
      await close(t);
    });
  });

  group('posting a photo challenge', () {
    /// The + button's page, with a photo on the phone, picked, Next
    /// pressed, and Done in the photo editor. Nobody said it is a photo:
    /// the page knows.
    Future<void> startFromCreatePage(WidgetTester t) async {
      t.view.physicalSize = const Size(1000, 2400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      EventTracker.instance.dispose();
      final gallery = FakeGallery()..addPhoto(dir, 'p1');
      DeviceGallery.instance = gallery;
      addTearDown(() => DeviceGallery.instance = PhoneGallery());
      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>.value(
          value: signedIn(),
          child: MaterialApp(
            localizationsDelegates: editorLocalizations,
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => CreateFlow.open(context),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await frames(t, 6);
      await t.tap(find.byKey(const ValueKey('create_item_p1')));
      await frames(t, 2);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await letItUpload(t);
      expect(find.byType(PhotoEditorPage), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      await letItUpload(t);
    }

    testWidgets('choose a photo, fill in the challenge, Post: it goes up as '
        'a photo, with nothing converted', (t) async {
      await startFromCreatePage(t);
      expect(find.text('New photo challenge'), findsOneWidget);
      expect(find.byKey(const ValueKey('photo_preview')), findsOneWidget);
      expect(find.text(matchWarningPhotoChallenge), findsOneWidget);
      expect(find.text(matchWarningChallenge), findsNothing);
      // The photo starts going up while the challenge is typed.
      await letItUpload(t);
      final presign = sentTo('POST', '/api/v1/media/presign');
      expect(presign, hasLength(1));
      expect(presign.single['items'], [
        {'kind': 'photo', 'variant': 'default', 'contentType': 'image/jpeg'},
      ]);
      expect(
        asked.where(
          (r) => r.$1 == 'PUT' && r.$2 == 'https://storage/put/photo',
        ),
        hasLength(1),
      );

      await t.enterText(find.byType(TextFormField).at(1), 'in red');
      await t.tap(find.text('Post Challenge'));
      await letItUpload(t);
      final posted = sentTo('POST', '/api/v1/challenges');
      expect(posted, hasLength(1));
      expect(posted.single['mediaType'], 'photo');
      expect(posted.single['videoUrl'], 'https://cdn/u/1/up1/photo.jpg');
      expect(posted.single['prefix'], 'Who looks better');
      expect(posted.single['subject'], 'in red');
      expect(posted.single['durationMs'], 0);
      expect(posted.single['videoVariants'], isEmpty);
      expect(platform.opened, isEmpty);
      // Posted: the create page has closed too, back to where + was.
      expect(find.byType(CreatePage), findsNothing);
      expect(find.text('go'), findsOneWidget);
      await close(t);
    });

    testWidgets('a photo challenge that failed to post is still a photo '
        'when retried', (t) async {
      final job = UploadJobManager.instance.submitChallenge(
        creatorId: '1',
        sourcePath: photos.next!.path,
        photo: true,
        meta: const ChallengeSubmissionMeta(
          prefix: 'Who looks better',
          subject: 'in red',
          visibility: 'arena',
          category: '',
          emotionTags: [],
        ),
      );
      createFailsOnce = true;
      await letItUpload(t);
      expect(job.state.value.stage, UploadJobStage.failed);
      final again = UploadJobManager.instance.retry(job)!;
      await letItUpload(t);
      expect(again.state.value.stage, UploadJobStage.done);
      final posted = sentTo('POST', '/api/v1/challenges');
      expect(posted, hasLength(2));
      expect(posted.last['mediaType'], 'photo');
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('answering', () {
    testWidgets('Accept on a video challenge offers Record and Upload, not '
        'Photo', (t) async {
      serving = videoShort();
      await openFeed(t);
      await t.tap(find.text('Accept challenge'));
      await frames(t, 6);
      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      expect(find.text('Photo'), findsNothing);
      await close(t);
    });

    testWidgets('Accept on a photo challenge goes straight to a photo, and '
        'the answer goes up as a photo', (t) async {
      serving = photoShort();
      await openFeed(t);
      await t.tap(find.text('Accept challenge'));
      await frames(t, 10);
      expect(find.text('Record'), findsNothing, reason: 'nothing to choose');
      expect(find.byKey(const ValueKey('post_photo_camera')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('post_photo_camera')));
      await letItUpload(t);
      expect(photos.askedCamera, isTrue);
      // The photo editor first, as for a new challenge.
      final editor = t.widget<PhotoEditorPage>(find.byType(PhotoEditorPage));
      expect(editor.sourcePath, photos.next!.path);
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      await letItUpload(t);
      // The last check, worded for a photo.
      expect(find.text('Does your photo answer this?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('answer_check_post')));
      await frames(t, 6);
      await letItUpload(t);
      final answers = sentTo('POST', '/api/v1/challenges/accept');
      expect(answers, hasLength(1));
      expect(answers.single['challengeId'], '3');
      expect(answers.single['mediaType'], 'photo');
      expect(answers.single['videoUrl'], 'https://cdn/u/1/up1/photo.jpg');
      expect(platform.opened, isEmpty);
      expect(find.byType(PhotoEditorPage), findsNothing, reason: 'it closed');
      await close(t);
    });

    testWidgets('Upload on a video challenge: the video editor, then the '
        'last check, then the answer goes, as a video', (t) async {
      serving = videoShort();
      final video = File('${dir.path}/answer.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      FilePicker.platform = _Picker()..next = video.path;
      await openFeed(t);
      await t.tap(find.text('Accept challenge'));
      await frames(t, 6);
      await t.tap(find.text('Upload'));
      await letItUpload(t);
      final editor = t.widget<VideoEditorPage>(find.byType(VideoEditorPage));
      expect(editor.sourcePath, video.path);

      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      await letItUpload(t);
      expect(find.text('Does your video answer this?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('answer_check_post')));
      await letItUpload(t);
      final job = UploadJobManager.instance.activeJobs.value.last;
      expect(job.sourcePath, video.path, reason: 'nothing changed: the same');
      expect(job.isPhoto, isFalse);
      expect(find.byType(VideoEditorPage), findsNothing, reason: 'it closed');
      for (final j in [...UploadJobManager.instance.activeJobs.value]) {
        UploadJobManager.instance.dismiss(j.id);
      }
      await close(t);
    });

    testWidgets('a video answer with a song from the editor goes to the '
        'server with its song', (t) async {
      serving = videoShort();
      final video = File('${dir.path}/answer.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      FilePicker.platform = _Picker()..next = video.path;
      final library = FakeMusicLibrary(dir)..all = [song('a', title: 'Alpha')];
      MusicLibrary.instance = library;
      MusicPlayer.create = FakeMusicPlayer.new;
      // The answer is processed and uploaded here as on a phone.
      fakeVideoProcessing(t);
      MediaUploadService.storageClient = () => ApiService.httpClient;
      const temp = MethodChannel('plugins.flutter.io/path_provider');
      addTearDown(() {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(temp, null);
        MusicLibrary.instance = ServerMusicLibrary();
        MusicPlayer.create = DeviceMusicPlayer.new;
        MediaUploadService.storageClient = http.Client.new;
      });

      await openFeed(t);
      // The phone's temporary folder, for processing the answer — given
      // only now, after the feed has opened: given earlier, the feed's own
      // video cache would start a server that outlives the test.
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temp,
        (call) async => dir.path,
      );
      await t.tap(find.text('Accept challenge'));
      await frames(t, 6);
      await t.tap(find.text('Upload'));
      await letItUpload(t);
      await t.tap(find.byKey(const ValueKey('editor_add_music')));
      await letItUpload(t);
      await t.tap(find.byKey(const ValueKey('music_use_a')));
      await letItUpload(t);
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      await letItUpload(t);
      await letItUpload(t);
      await t.tap(find.byKey(const ValueKey('answer_check_post')));
      await letItUpload(t);
      await letItUpload(t);

      final answers = sentTo('POST', '/api/v1/challenges/accept');
      expect(
        answers,
        hasLength(1),
        reason: [for (final a in asked) a.$2].join(', '),
      );
      expect(answers.single['musicTrackId'], library.idFor(song('a')));
      expect(answers.single.containsKey('mediaType'), isFalse, reason: 'video');
      expect(
        UploadJobManager.instance.activeJobs.value.last.musicTrackId,
        library.idFor(song('a')),
      );
      for (final j in [...UploadJobManager.instance.activeJobs.value]) {
        UploadJobManager.instance.dismiss(j.id);
      }
      await close(t);
    });
  });

  group('a post with a song that fails', () {
    testWidgets('a challenge keeps its song through the app closing and '
        'Retry', (t) async {
      final video = File('${dir.path}/mine.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      fakeVideoProcessing(t);
      MediaUploadService.storageClient = () => ApiService.httpClient;
      const temp = MethodChannel('plugins.flutter.io/path_provider');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temp,
        (call) async => dir.path,
      );
      addTearDown(() {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(temp, null);
        MediaUploadService.storageClient = http.Client.new;
      });
      final jobs = UploadJobManager.instance..debugForgetJobsFile();
      for (final j in [...jobs.activeJobs.value]) {
        jobs.dismiss(j.id);
      }
      createFailsOnce = true;
      final first = jobs.submitChallenge(
        creatorId: '1',
        sourcePath: video.path,
        meta: const ChallengeSubmissionMeta(
          prefix: 'Who dances',
          subject: 'best to this',
          visibility: 'arena',
          category: '',
          emotionTags: [],
          musicTrackId: '742',
        ),
      );
      await letItUpload(t);
      expect(first.state.value.stage, UploadJobStage.failed);

      jobs.dismiss(first.id);
      await t.runAsync(jobs.restorePersisted);
      final restored = jobs.activeJobs.value.single;
      expect(restored.postedAs?.musicTrackId, '742');

      jobs.retry(restored);
      await letItUpload(t);
      final posts = sentTo('POST', '/api/v1/challenges');
      expect(posts, hasLength(2));
      expect(posts.first['musicTrackId'], '742');
      expect(posts.last['musicTrackId'], '742');
      for (final j in [...jobs.activeJobs.value]) {
        jobs.dismiss(j.id);
      }
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('an answer with a song that fails', () {
    testWidgets('keeps its song through the app closing and Retry', (t) async {
      final video = File('${dir.path}/answer.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      fakeVideoProcessing(t);
      MediaUploadService.storageClient = () => ApiService.httpClient;
      const temp = MethodChannel('plugins.flutter.io/path_provider');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temp,
        (call) async => dir.path,
      );
      addTearDown(() {
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(temp, null);
        MediaUploadService.storageClient = http.Client.new;
      });
      final jobs = UploadJobManager.instance..debugForgetJobsFile();
      for (final j in [...jobs.activeJobs.value]) {
        jobs.dismiss(j.id);
      }
      acceptFailsOnce = true;
      final first = jobs.submitResponse(
        responderId: '1',
        challengeId: '2',
        sourcePath: video.path,
        musicTrackId: '742',
      );
      await letItUpload(t);
      expect(first.state.value.stage, UploadJobStage.failed);

      // The app is closed and opened again: the job comes back from disk.
      jobs.dismiss(first.id);
      await t.runAsync(jobs.restorePersisted);
      final restored = jobs.activeJobs.value.single;
      expect(restored.musicTrackId, '742');

      jobs.retry(restored);
      await letItUpload(t);
      final answers = sentTo('POST', '/api/v1/challenges/accept');
      expect(answers, hasLength(2));
      expect(answers.last['musicTrackId'], '742');
      for (final j in [...jobs.activeJobs.value]) {
        jobs.dismiss(j.id);
      }
      await t.pump(const Duration(seconds: 5));
    });
  });

  group('Search', () {
    setUp(() {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      ExploreGridCache.instance.debugReset();
      ReelDiagnostics.instance.debugReset();
    });
    tearDown(ExploreGridCache.instance.debugReset);

    testWidgets('a photo never takes a preview turn; the video next to it '
        'does', (t) async {
      ApiService.useClient(
        MockClient((req) async {
          if (req.url.path.contains('/feed/explore')) {
            return http.Response(
              json.encode({
                'items': [
                  {
                    'type': 'challenge',
                    'challenge': {...photoShort(), 'thumbnailUrl': ''},
                  },
                  {'type': 'challenge', 'challenge': videoShort()},
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      await t.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      EventTracker.instance.dispose();
      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>.value(
          value: signedIn(),
          child: const MaterialApp(home: SearchPage()),
        ),
      );
      await frames(t, 10);
      expect(platform.opened, contains('https://x/2.mp4'));
      expect(platform.opened, isNot(contains(photoUrl)));
      // Marked as a photo where a video has its play mark.
      expect(find.byKey(const ValueKey('grid_photo_mark')), findsOneWidget);
      expect(find.byKey(const ValueKey('grid_video_mark')), findsOneWidget);
      // Long past a video's turn: the photo is never given one.
      await t.pump(const Duration(seconds: 30));
      await frames(t, 4);
      expect(platform.opened, isNot(contains(photoUrl)));
      await close(t);
    });
  });
}
