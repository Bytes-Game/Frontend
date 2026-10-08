// Free music under a video: the picker, the video editor's Music button,
// and a post that carries its song's credit all the way to the server.
//
// Only the outside world is faked: the music library (FakeMusicLibrary),
// the player, the phone's video player and video tools (FakeVideoEngine),
// and the server. The editor, the picker and the posting pages are the
// real ones.

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

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/pages/music_picker_page.dart';
import 'package:myapp/pages/video_editor_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/create_flow.dart';
import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/media_upload_service.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/widgets/music_credit.dart';

import 'fake_gallery.dart';
import 'fake_music.dart';
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
  late FakeMusicLibrary library;
  late FakeVideoEngine engine;

  setUpAll(() => VideoPlayerPlatform.instance = _Videos());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('music');
    library = FakeMusicLibrary(dir);
    MusicLibrary.instance = library;
    FakeMusicPlayer.made.clear();
    MusicPlayer.create = FakeMusicPlayer.new;
    engine = FakeVideoEngine(dir);
    VideoEditEngine.instance = engine;
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

  void phone(WidgetTester t) {
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
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    EventTracker.instance.dispose();
  }

  /// [page] opened over a page that stands for the one before it; answers
  /// a way to read what it closed with.
  Future<Object? Function()> open(WidgetTester t, Widget page) async {
    phone(t);
    Object? closedWith;
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
                  ).push<Object?>(MaterialPageRoute(builder: (_) => page));
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

  group('the picker', () {
    testWidgets('opens on the songs used most here, then every free song', (
      t,
    ) async {
      library.popular = [song('pop1', title: 'Popular One')];
      library.all = [song('a', title: 'Alpha'), song('b', title: 'Beta')];
      await open(t, const MusicPickerPage());
      expect(library.searches, [('', 1)]);
      expect(find.text('Popular here'), findsOneWidget);
      expect(find.text('Popular One'), findsOneWidget);
      expect(find.text('All free songs'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      // Who made it, how long, and the licence, on every song.
      expect(find.text('Some Artist · 3:00 · CC BY 4.0'), findsWidgets);
      await close(t);
    });

    testWidgets('searches once typing stops, not on every key', (t) async {
      library.all = [song('a', title: 'Happy Days'), song('b', title: 'Sad')];
      await open(t, const MusicPickerPage());
      for (final text in ['h', 'ha', 'hap', 'happy']) {
        await t.enterText(find.byKey(const ValueKey('music_search')), text);
        await t.pump(const Duration(milliseconds: 100));
      }
      await settle(t, 8);
      expect(library.searches, [('', 1), ('happy', 1)]);
      expect(find.text('Happy Days'), findsOneWidget);
      expect(find.text('Sad'), findsNothing);
      await close(t);
    });

    testWidgets('a search with nothing found says so', (t) async {
      library.all = [song('a', title: 'Alpha')];
      await open(t, const MusicPickerPage());
      await t.enterText(find.byKey(const ValueKey('music_search')), 'zzz');
      await settle(t, 8);
      expect(
        find.text('No free songs found for "zzz". Try another word.'),
        findsOneWidget,
      );
      await close(t);
    });

    testWidgets('Play plays it; Use keeps it with the server, gets the file '
        'and hands both back', (t) async {
      library.all = [song('a', title: 'Alpha')];
      final closed = await open(t, const MusicPickerPage());
      await t.tap(find.byKey(const ValueKey('music_play_a')));
      await settle(t, 2);
      final player = FakeMusicPlayer.made.single;
      expect(player.calls, [
        'play https://files.example/a.mp3 from 0 loop false',
      ]);

      await t.tap(find.byKey(const ValueKey('music_use_a')));
      await settle(t);
      expect(library.picked.single.sourceId, 'a');
      expect(library.downloaded.single.id, library.idFor(song('a')));
      final picked = closed() as PickedMusic;
      expect(picked.track.id, library.idFor(song('a')));
      expect(picked.track.title, 'Alpha');
      expect(File(picked.path).existsSync(), isTrue);
      expect(player.calls, contains('stop'), reason: 'the preview stops');
      await close(t);
    });

    testWidgets('a song the server refuses says why, and the picker stays', (
      t,
    ) async {
      library.all = [song('a', title: 'Alpha')];
      library.refuse = 'that song is not free to use — pick another';
      final closed = await open(t, const MusicPickerPage());
      await t.tap(find.byKey(const ValueKey('music_use_a')));
      await settle(t, 4);
      expect(
        find.text('that song is not free to use — pick another'),
        findsOneWidget,
      );
      expect(library.downloaded, isEmpty);
      expect(find.byType(MusicPickerPage), findsOneWidget);
      expect(closed(), isNull);
      await close(t);
    });

    testWidgets('busy says so; unreachable offers Try again', (t) async {
      library.all = [song('a', title: 'Alpha')];
      library.busy = true;
      await open(t, const MusicPickerPage());
      expect(find.byKey(const ValueKey('music_busy')), findsOneWidget);
      expect(
        find.text('Alpha'),
        findsOneWidget,
        reason: 'still shows what it has',
      );
      await close(t);

      library
        ..busy = false
        ..unreachable = true;
      await open(t, const MusicPickerPage());
      expect(find.text("Couldn't load music."), findsOneWidget);
      library.unreachable = false;
      await t.tap(find.byKey(const ValueKey('music_retry')));
      await settle(t, 4);
      expect(find.text('Alpha'), findsOneWidget);
      await close(t);
    });

    testWidgets('scrolling down reads the next page', (t) async {
      library
        ..pageSize = 15
        ..all = [for (var i = 0; i < 40; i++) song('s$i', title: 'Song $i')];
      await open(t, const MusicPickerPage());
      expect(library.searches, [('', 1)]);
      await t.drag(find.byType(ListView), const Offset(0, -2000));
      await settle(t, 4);
      expect(library.searches, contains(('', 2)));
      await close(t);
    });
  });

  group('downloading a song', () {
    late List<String> asked;
    late Stream<List<int>> Function() body;
    int? said;
    var status = 200;
    final realFolder = ServerMusicLibrary.folder;
    final realClient = ServerMusicLibrary.client;

    setUp(() {
      asked = [];
      body = () => Stream.value(List.filled(3000, 7));
      said = null;
      status = 200;
      ServerMusicLibrary.folder = () async => dir;
      ServerMusicLibrary.client = () => MockClient.streaming((req, _) async {
        asked.add(req.url.toString());
        return http.StreamedResponse(body(), status, contentLength: said);
      });
    });

    tearDown(() {
      ServerMusicLibrary.folder = realFolder;
      ServerMusicLibrary.client = realClient;
    });

    List<String> songsFolder() => [
      for (final f in Directory('${dir.path}/devf_music').listSync())
        f.uri.pathSegments.last,
    ];

    test('it goes in the folder the app tidies, whole, and is used again '
        'rather than fetched twice', () async {
      final track = song('a');
      final path = await ServerMusicLibrary().download(track);
      expect(path, '${dir.path}/devf_music/a.mp3');
      expect(File(path).lengthSync(), 3000);
      expect(await ServerMusicLibrary().download(track), path);
      expect(asked, [track.audioUrl], reason: 'fetched once');
    });

    test('one that keeps coming past 40 MB is stopped, and nothing is '
        'left', () async {
      var sent = 0;
      body = () async* {
        while (true) {
          sent += 1024 * 1024;
          yield List.filled(1024 * 1024, 1);
        }
      };
      await expectLater(
        ServerMusicLibrary().download(song('big')),
        throwsA(isA<HttpException>()),
      );
      expect(
        sent,
        lessThanOrEqualTo(ServerMusicLibrary.maxBytes + 2 * 1024 * 1024),
        reason: 'it stopped reading, not read it all and then refused',
      );
      expect(songsFolder(), isEmpty, reason: 'no half song left behind');
    });

    test('one that says it is over 40 MB is not fetched at all', () async {
      said = ServerMusicLibrary.maxBytes + 1;
      var read = false;
      body = () async* {
        read = true;
        yield [1];
      };
      await expectLater(
        ServerMusicLibrary().download(song('big')),
        throwsA(isA<HttpException>()),
      );
      expect(read, isFalse);
      expect(songsFolder(), isEmpty);
    });

    test('a refusal or an empty answer leaves nothing', () async {
      status = 404;
      await expectLater(
        ServerMusicLibrary().download(song('gone')),
        throwsA(isA<HttpException>()),
      );
      status = 200;
      body = () => const Stream.empty();
      await expectLater(
        ServerMusicLibrary().download(song('empty')),
        throwsA(isA<HttpException>()),
      );
      expect(songsFolder(), isEmpty);
    });
  });

  group('the video editor\'s Music button', () {
    late File video;
    final handed = <String>[];
    final handedMusic = <MusicTrack?>[];

    Future<bool> next(BuildContext c, String path, MusicTrack? music) async {
      handed.add(path);
      handedMusic.add(music);
      return true;
    }

    setUp(() {
      handed.clear();
      handedMusic.clear();
      video = File('${dir.path}/picked.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      library.all = [song('a', title: 'Alpha')];
    });

    Future<void> addSong(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('editor_add_music')));
      await settle(t);
      expect(find.byType(MusicPickerPage), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('music_use_a')));
      await settle(t);
      expect(find.byType(MusicPickerPage), findsNothing);
    }

    /// Taps Done and waits until the save has an outcome — the video handed
    /// on, or the lost-sound question asked — as in editors_test.dart.
    Future<void> done(WidgetTester t) async {
      final before = handed.length;
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      for (var i = 0; i < 300; i++) {
        if (handed.length > before ||
            find
                .byKey(const ValueKey('edit_lost_sound'))
                .evaluate()
                .isNotEmpty) {
          break;
        }
        await settle(t, 1);
      }
      await settle(t, 6);
    }

    testWidgets('a song is mixed in at its volume, the video remade at its '
        'own quality, and the post told which song', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      expect(find.text('Music'), findsOneWidget);
      await addSong(t);
      expect(find.byKey(const ValueKey('editor_music')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget, reason: 'the song is named');

      await done(t);
      final made = engine.renders.single;
      expect(made.audioTracks, hasLength(1));
      final track = made.audioTracks.single;
      expect(track.path, '${dir.path}/music_a.mp3');
      expect(track.volume, 0.8);
      expect(track.loop, isTrue);
      expect(made.enableAudio, isTrue, reason: 'the video\'s own sound stays');
      expect(made.bitrate, 12000000);
      expect(handed.single, contains('edit_'));
      expect(handedMusic.single?.id, library.idFor(song('a')));
      expect(
        engine.factsAsked.last,
        handed.single,
        reason: 'checked that the sound came through',
      );
      await close(t);
    });

    testWidgets('Music is first in the bottom row, with the editor\'s own '
        'tools', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      final music = t.getCenter(find.byKey(const ValueKey('editor_add_music')));
      final screen = t.view.physicalSize / t.view.devicePixelRatio;
      expect(
        music.dy,
        greaterThan(screen.height * 0.75),
        reason: 'at the bottom',
      );
      for (final tool in [
        'open-crop-rotate-editor-btn',
        'open-filter-editor-btn',
        'open-text-editor-btn',
      ]) {
        final other = t.getCenter(find.byKey(ValueKey(tool)));
        expect(other.dy, music.dy, reason: '$tool is in the same row');
        expect(other.dx, greaterThan(music.dx), reason: 'Music comes first');
      }
      await close(t);
    });

    testWidgets('a long song name is cut short in the row', (t) async {
      library.all = [
        song('a', title: 'A song with a very long name that goes on and on'),
      ];
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addSong(t);
      final label = find.descendant(
        of: find.byKey(const ValueKey('editor_music')),
        matching: find.byType(Text),
      );
      expect(t.getSize(label).width, lessThanOrEqualTo(72));
      expect(t.takeException(), isNull, reason: 'nothing overflowed');
      await close(t);
    });

    group('going back', () {
      Future<void> back(WidgetTester t) async {
        await t.binding.handlePopRoute();
        await settle(t);
      }

      testWidgets('from the picker: back in the editor, no song', (t) async {
        await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
        await t.tap(find.byKey(const ValueKey('editor_add_music')));
        await settle(t);
        expect(find.byType(MusicPickerPage), findsOneWidget);
        await back(t);
        expect(find.byType(MusicPickerPage), findsNothing);
        expect(find.byType(VideoEditorPage), findsOneWidget);
        expect(find.byKey(const ValueKey('editor_add_music')), findsOneWidget);
        await close(t);
      });

      testWidgets('from the editor with a song: closed, and the song '
          'stopped', (t) async {
        await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
        await addSong(t);
        await back(t);
        if (find.text('OK').evaluate().isNotEmpty) {
          await t.tap(find.text('OK'));
          await settle(t);
        }
        expect(find.byType(VideoEditorPage), findsNothing);
        expect(FakeMusicPlayer.made.last.calls.last, 'dispose');
        await close(t);
      });

      testWidgets('from the Filter tool: back in the editor', (t) async {
        await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
        await t.tap(find.text('Filter'));
        await settle(t);
        await back(t);
        expect(find.byType(VideoEditorPage), findsOneWidget);
        expect(find.text('Filter'), findsOneWidget);
        await close(t);
      });
    });

    testWidgets('the song plays under the video while editing', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addSong(t);
      final state = t.state<VideoEditorPageState>(find.byType(VideoEditorPage));
      state.controller!.pause();
      await settle(t, 2);
      state.controller!.play();
      await settle(t, 2);
      final under = FakeMusicPlayer.made.last;
      expect(
        under.calls.where((c) => c.startsWith('play ${dir.path}/music_a.mp3')),
        isNotEmpty,
        reason: under.calls.join(', '),
      );
      expect(under.calls.last, 'volume 0.80');
      await close(t);
    });

    testWidgets('the song\'s volume and start are what is saved', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addSong(t);
      await t.tap(find.byKey(const ValueKey('editor_music')));
      await settle(t, 4);
      // All the way down, and the song starting halfway through.
      await t.drag(
        find.byKey(const ValueKey('music_volume')),
        const Offset(-600, 0),
      );
      final start = find.byKey(const ValueKey('music_start'));
      await t.tapAt(t.getCenter(start));
      await settle(t, 2);
      await t.tapAt(const Offset(200, 100)); // close the sheet
      await settle(t, 4);
      await done(t);
      final track = engine.renders.single.audioTracks.single;
      expect(track.volume, closeTo(0.05, 0.001));
      expect(track.audioStartTime!.inSeconds, closeTo(90, 3));
      await close(t);
    });

    testWidgets('a song removed again: saved without one, and the post has '
        'none', (t) async {
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addSong(t);
      await t.tap(find.byKey(const ValueKey('editor_music')));
      await settle(t, 4);
      await t.tap(find.byKey(const ValueKey('music_remove')));
      await settle(t, 4);
      expect(find.text('Music'), findsOneWidget);
      await done(t);
      expect(engine.renders, isEmpty, reason: 'nothing changed: not remade');
      expect(handed.single, video.path);
      expect(handedMusic.single, isNull);
      await close(t);
    });

    testWidgets('a silent video with a song is checked for sound too; lost, '
        'it is posted without the edit — and without the song', (t) async {
      engine.source = const VideoFacts(
        duration: Duration(seconds: 10),
        resolution: Size(1080, 1920),
        bitrate: 12000000,
        hasSound: false,
      );
      engine.remakeKeepsSound = false;
      await open(t, VideoEditorPage(sourcePath: video.path, onDone: next));
      await addSong(t);
      await done(t);
      expect(find.byKey(const ValueKey('edit_lost_sound')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('edit_lost_sound_post')));
      await settle(t);
      expect(handed.single, video.path);
      expect(handedMusic.single, isNull, reason: 'no song in it to credit');
      await close(t);
    });
  });

  group('the credit', () {
    test('a post says which song it has, and its answer\'s', () {
      final c = ChallengeModel.fromJson({
        'id': '1',
        'creatorId': '9',
        'creatorUsername': 'maya',
        'creatorLeague': 'Gold',
        'videoUrl': 'https://cdn/v.mp4',
        'prefix': 'Who',
        'subject': 'dances',
        'visibility': 'arena',
        'status': 'open',
        'music': {
          'id': '7',
          'title': 'Alpha',
          'artist': 'Some Artist',
          'license': 'by',
          'licenseVersion': '4.0',
        },
        'topResponseMusic': {'id': '8', 'title': 'Beta', 'license': 'cc0'},
      });
      expect(c.music?.line, 'Alpha · Some Artist');
      expect(c.music?.licenceLabel, 'CC BY 4.0');
      expect(c.topResponseMusic?.title, 'Beta');
      expect(c.topResponseMusic?.licenceLabel, 'CC0 — free to use');
      final none = ChallengeModel.fromJson({'id': '2'});
      expect(none.music, isNull);
    });

    testWidgets('tapped, it shows the whole credit and where the song is '
        'from', (t) async {
      phone(t);
      final credit = song('a', title: 'Alpha').credit;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: MusicCreditLine(credit: credit)),
          ),
        ),
      );
      expect(find.text('Alpha · Some Artist'), findsOneWidget);
      await t.tap(find.byType(MusicCreditLine));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('music_credit_sheet')), findsOneWidget);
      expect(find.text('by Some Artist'), findsOneWidget);
      expect(find.text('Free music · CC BY 4.0'), findsOneWidget);
      expect(find.text(credit.attribution), findsOneWidget);
      expect(find.text('https://www.jamendo.com/track/a'), findsOneWidget);
    });
  });

  group('posting a video with a song', () {
    late List<(String, String, String)> asked;

    setUp(() {
      asked = [];
      final server = MockClient((req) async {
        asked.add((
          req.method,
          req.url.path,
          utf8.decode(req.bodyBytes, allowMalformed: true),
        ));
        final p = req.url.path;
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
                    'publicUrl': 'https://cdn/u/1/up1/${i['kind']}',
                  },
              ],
            }),
            200,
          );
        }
        if (req.url.host == 'storage') return http.Response('', 200);
        if (p == '/api/v1/challenges' && req.method == 'POST') {
          return http.Response(
            json.encode({
              'id': '41',
              'creatorId': '1',
              'creatorUsername': 'me',
              'videoUrl': 'https://cdn/u/1/up1/video',
              'prefix': 'Who dances',
              'subject': 'best',
              'visibility': 'arena',
              'status': 'open',
            }),
            201,
          );
        }
        return http.Response('[]', 200);
      });
      ApiService.useClient(server);
      // A video goes to storage on a client of its own.
      MediaUploadService.storageClient = () => server;
    });

    tearDown(() {
      ApiService.useClient(http.Client());
      MediaUploadService.storageClient = http.Client.new;
    });

    testWidgets('from the + button: the editor\'s song is on the details '
        'page and goes to the server with the post', (t) async {
      phone(t);
      fakeVideoProcessing(t);
      final gallery = FakeGallery()
        ..addVideo(dir, 'v1', const Duration(seconds: 8));
      DeviceGallery.instance = gallery;
      addTearDown(() => DeviceGallery.instance = PhoneGallery());
      library.all = [song('a', title: 'Alpha')];

      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>(
          create: (_) => DataProvider()
            ..setUser(
              UserModel(
                id: '1',
                username: 'me',
                wins: 0,
                losses: 0,
                followersCount: 0,
                followingCount: 0,
              ),
            ),
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
      await settle(t, 6);
      await t.tap(find.byKey(const ValueKey('create_next')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('editor_add_music')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('music_use_a')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('MainEditorDoneButton')));
      // Until the details page is up: saving the edit takes real time.
      for (var i = 0; i < 300; i++) {
        if (find.byType(ChallengeMetadataPage).evaluate().isNotEmpty) break;
        await settle(t, 1);
      }
      await settle(t, 4);

      final details = t.widget<ChallengeMetadataPage>(
        find.byType(ChallengeMetadataPage),
      );
      expect(details.music?.id, library.idFor(song('a')));
      expect(find.byKey(const ValueKey('details_music')), findsOneWidget);
      expect(find.text('Alpha · Some Artist'), findsOneWidget);

      await t.enterText(find.byType(TextFormField).at(1), 'to this song');
      await t.tap(find.text('Post Challenge'));
      List<Map<String, dynamic>> sent() => [
        for (final (m, p, body) in asked)
          if (m == 'POST' && p == '/api/v1/challenges')
            json.decode(body) as Map<String, dynamic>,
      ];
      // Until it is posted: the upload goes through several steps, each
      // taking real time, and a busy machine takes longer over them.
      for (var i = 0; i < 300 && sent().isEmpty; i++) {
        await settle(t, 1);
      }
      await settle(t, 4);
      final posts = sent();
      expect(posts, hasLength(1), reason: asked.map((a) => a.$2).join(', '));
      expect(posts.single['musicTrackId'], library.idFor(song('a')));
      for (final j in [...UploadJobManager.instance.activeJobs.value]) {
        UploadJobManager.instance.dismiss(j.id);
      }
      await close(t);
    });
  });
}
