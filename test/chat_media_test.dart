// Photo and voice messages, through the real chat screen.
//
// Faked: the phone's photo picker, microphone and speaker (stand-ins that
// record what was asked of them), and the network (a MockClient that
// answers the server and storage, and records every request). Everything
// else is the real page.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/chat_media_widgets.dart';

/// A 4 x 3 red picture.
final tinyPng = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGP4z8AARww4OQD1MQv1NXv7ggAAAABJRU5ErkJggg==',
);

class FakePhotos implements PhotoSource {
  File? next;
  bool? askedCamera;
  @override
  Future<File?> pick({required bool camera}) async {
    askedCamera = camera;
    return next;
  }
}

class FakeRecorder implements VoiceRecorder {
  static bool allow = true;
  static final made = <FakeRecorder>[];
  final levelsCtrl = StreamController<double>.broadcast();
  String? path;
  bool cancelled = false;
  bool stopped = false;
  bool disposed = false;
  FakeRecorder() {
    made.add(this);
  }

  @override
  Future<bool> allowed() async => allow;
  @override
  Future<void> start(String path) async {
    this.path = path;
    File(path).writeAsBytesSync(List.filled(2048, 7));
  }

  @override
  Stream<double> levels() => levelsCtrl.stream;
  @override
  Future<String?> stop() async {
    stopped = true;
    return path;
  }

  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Future<void> dispose() async => disposed = true;
}

class FakePlayer implements VoicePlayer {
  static final made = <FakePlayer>[];
  final positionCtrl = StreamController<Duration>.broadcast();
  final finishedCtrl = StreamController<void>.broadcast();
  String? playing;
  double speed = 1;
  bool disposed = false;
  FakePlayer() {
    made.add(this);
  }

  @override
  Future<void> play(String url) async => playing = url;
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> seek(Duration to) async {}
  @override
  Future<void> setSpeed(double speed) async => this.speed = speed;
  @override
  Stream<Duration> get position => positionCtrl.stream;
  @override
  Stream<void> get finished => finishedCtrl.stream;
  @override
  Future<void> dispose() async => disposed = true;
}

late List<http.BaseRequest> requests;
final bodies = <http.BaseRequest, String>{};

/// How many bytes each upload carried.
final uploaded = <int>[];

/// When set, storage holds every upload until it is completed.
Completer<void>? storageGate;
var storageWorks = true;
List<Map<String, dynamic>> history = [];
var conversationsDelay = Duration.zero;

void fakeNetwork() {
  requests = [];
  bodies.clear();
  uploaded.clear();
  storageGate = null;
  storageWorks = true;
  history = [];
  conversationsDelay = Duration.zero;
  ApiService.useClient(
    MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (req.url.host == 'storage.test') {
        // The file itself: bytes, not words.
        uploaded.add(req.bodyBytes.length);
        await storageGate?.future;
        return http.Response('', storageWorks ? 200 : 500);
      }
      bodies[req] = req.body;
      if (path == '/api/v1/chat/media') {
        final kind = json.decode(req.body)['kind'];
        final file = kind == 'photo' ? 'photo.jpg' : 'voice.m4a';
        return http.Response(
          json.encode({
            'uploadUrl': 'https://storage.test/put/$file?X-Amz-Signature=x',
            'publicUrl': 'https://cdn.test/chat/u1/abc/$file',
            'contentType': kind == 'photo' ? 'image/jpeg' : 'audio/mp4',
          }),
          200,
        );
      }
      if (path == '/api/v1/chat/send') {
        return http.Response(json.encode({'id': '77'}), 200);
      }
      if (path.contains('/chat/messages/')) {
        return http.Response(json.encode(history), 200);
      }
      if (path.contains('/chat/conversations/')) {
        await Future<void>.delayed(conversationsDelay);
        return http.Response('[]', 200);
      }
      return http.Response('{}', 200);
    }),
  );
}

List<http.BaseRequest> to(String pathOrHost) => [
  for (final r in requests)
    if (r.url.path == pathOrHost || r.url.host == pathOrHost) r,
];

Map<String, dynamic> sent() =>
    json.decode(bodies[to('/api/v1/chat/send').single]!)
        as Map<String, dynamic>;

late WebSocketService ws;

Future<void> openChat(WidgetTester t) async {
  final dp = DataProvider()
    ..setUser(
      UserModel(
        id: 'u1',
        username: 'me',
        wins: 0,
        losses: 0,
        followersCount: 0,
        followingCount: 0,
      ),
    );
  EventTracker.instance.dispose();
  ws = WebSocketService('', '');
  await t.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DataProvider>.value(value: dp),
        Provider<WebSocketService>.value(value: ws),
      ],
      child: const MaterialApp(
        home: ChatConversationPage(otherUserId: 'u2', otherUsername: 'maya'),
      ),
    ),
  );
  await settle(t);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Long enough for a sheet or a page to finish sliding in or out. (The
/// empty chat's greeting moves for ever, so waiting for stillness never
/// ends.)
Future<void> pumpFor(WidgetTester t) async {
  for (var i = 0; i < 15; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Lets real file reading and the upload finish, then draws. Reading a
/// file goes back and forth between the real world and the test's clock,
/// so it takes turns.
Future<void> letItUpload(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
  await settle(t);
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  EventTracker.instance.dispose();
}

void main() {
  late Directory dir;
  late FakePhotos photos;

  setUp(() {
    fakeNetwork();
    dir = Directory.systemTemp.createTempSync('chat_media');
    photos = FakePhotos();
    FakeRecorder.allow = true;
    FakeRecorder.made.clear();
    FakePlayer.made.clear();
    ChatMedia.instance
      ..photos = photos
      ..recorder = FakeRecorder.new
      ..player = FakePlayer.new
      ..directory = (() async => dir)
      ..measure = ((_) async => const ui.Size(1200, 900));
  });

  tearDown(() async {
    await VoicePlayback.instance.stop();
    ChatMedia.instance.debugReset();
    ApiService.useClient(http.Client());
    dir.deleteSync(recursive: true);
  });

  File photoFile() => File('${dir.path}/picked.jpg')..writeAsBytesSync(tinyPng);

  group('photos', () {
    testWidgets('choose one, add a caption, and it goes: uploaded to your '
        'own place, then sent with its size', (t) async {
      photos.next = photoFile();
      await openChat(t);
      await t.tap(find.byTooltip('Photo'));
      await pumpFor(t);
      await t.tap(find.byKey(const ValueKey('photo_from_gallery')));
      await pumpFor(t);
      expect(photos.askedCamera, isFalse);
      expect(find.byType(PhotoPreviewPage), findsOneWidget);
      expect(find.text('To maya'), findsOneWidget);
      await t.enterText(
        find.byKey(const ValueKey('photo_caption')),
        'look at this',
      );
      await t.tap(find.byKey(const ValueKey('photo_send')));
      await pumpFor(t);
      await letItUpload(t);

      expect(
        json.decode(bodies[to('/api/v1/chat/media').single]!)['kind'],
        'photo',
      );
      final put = to('storage.test').single;
      expect(put.method, 'PUT');
      expect(put.headers['Content-Type'], 'image/jpeg');
      expect(
        put.headers.containsKey('Authorization'),
        isFalse,
        reason: 'storage refuses a second kind of sign-in',
      );
      expect(uploaded.single, tinyPng.length, reason: 'the whole photo went');
      final body = sent();
      expect(body['kind'], 'photo');
      expect(body['mediaUrl'], 'https://cdn.test/chat/u1/abc/photo.jpg');
      expect(body['mediaWidth'], 1200);
      expect(body['mediaHeight'], 900);
      expect(body['message'], 'look at this');

      expect(find.byType(ChatPhoto), findsOneWidget);
      expect(find.text('look at this'), findsOneWidget);
      expect(find.byKey(const ValueKey('photo_uploading')), findsNothing);
      expect(find.text('Sent'), findsOneWidget);
      await close(t);
    });

    testWidgets("it isn't \"Seen\" while it is still uploading", (t) async {
      photos.next = photoFile();
      await openChat(t);
      await t.tap(find.byTooltip('Photo'));
      await pumpFor(t);
      await t.tap(find.byKey(const ValueKey('photo_from_gallery')));
      await pumpFor(t);
      // Storage holds the upload: it is still going when they open the chat.
      storageGate = Completer<void>();
      await t.tap(find.byKey(const ValueKey('photo_send')));
      await pumpFor(t);
      await letItUpload(t);
      expect(uploaded, hasLength(1), reason: 'the upload has started');
      expect(find.byKey(const ValueKey('photo_uploading')), findsOneWidget);
      ws.debugReceive({'type': 'chat_read', 'readerId': 'u2'});
      await settle(t);
      expect(find.byKey(const ValueKey('photo_uploading')), findsOneWidget);
      expect(find.text('Seen'), findsNothing);
      expect(find.text('Sending…'), findsOneWidget);
      storageGate!.complete();
      await letItUpload(t);
      expect(find.byKey(const ValueKey('photo_uploading')), findsNothing);
      expect(find.text('Sent'), findsOneWidget);
      await close(t);
    });

    testWidgets('taking one asks for the camera', (t) async {
      photos.next = photoFile();
      await openChat(t);
      await t.tap(find.byTooltip('Photo'));
      await pumpFor(t);
      await t.tap(find.byKey(const ValueKey('photo_from_camera')));
      await pumpFor(t);
      expect(photos.askedCamera, isTrue);
      expect(find.byType(PhotoPreviewPage), findsOneWidget);
      // Backing out of the preview sends nothing.
      await t.tap(find.byTooltip('Cancel'));
      await pumpFor(t);
      expect(find.byType(PhotoPreviewPage), findsNothing);
      expect(to('/api/v1/chat/media'), isEmpty);
      await close(t);
    });

    testWidgets("an upload that fails says so, and a retry uploads again", (
      t,
    ) async {
      photos.next = photoFile();
      storageWorks = false;
      await openChat(t);
      await t.tap(find.byTooltip('Photo'));
      await pumpFor(t);
      await t.tap(find.byKey(const ValueKey('photo_from_gallery')));
      await pumpFor(t);
      await t.tap(find.byKey(const ValueKey('photo_send')));
      await pumpFor(t);
      await letItUpload(t);
      expect(find.text('Not sent · Tap to retry'), findsOneWidget);
      expect(to('/api/v1/chat/send'), isEmpty);

      storageWorks = true;
      await t.tap(find.text('Not sent · Tap to retry'));
      await settle(t);
      await letItUpload(t);
      expect(to('/api/v1/chat/media'), hasLength(2));
      expect(sent()['kind'], 'photo');
      expect(find.text('Not sent · Tap to retry'), findsNothing);
      expect(find.text('Sent'), findsOneWidget);
      await close(t);
    });

    testWidgets('one arriving shows at once, and opens full screen', (t) async {
      await openChat(t);
      ws.debugReceive({
        'type': 'chat',
        'senderId': 'u2',
        'senderUsername': 'maya',
        'receiverId': 'u1',
        'messageId': '9',
        'message': '',
        'kind': 'photo',
        'mediaUrl': 'https://cdn.test/chat/u2/x/photo.jpg',
        'mediaWidth': 800,
        'mediaHeight': 600,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
      await settle(t);
      expect(find.byType(ChatPhoto), findsOneWidget);
      await t.tap(find.byType(ChatPhoto));
      await pumpFor(t);
      expect(find.byType(ChatPhotoViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(
        find.text("This photo couldn't be loaded"),
        findsOneWidget,
        reason: 'no network in tests: it says so instead of failing',
      );
      await t.tap(find.byTooltip('Close'));
      await pumpFor(t);
      expect(find.byType(ChatPhotoViewer), findsNothing);
      await close(t);
    });

    testWidgets('replying to a photo quotes "Photo"', (t) async {
      history = [
        {
          'id': '5',
          'senderId': 'u2',
          'receiverId': 'u1',
          'message': '',
          'kind': 'photo',
          'mediaUrl': 'https://cdn.test/chat/u2/x/photo.jpg',
          'mediaWidth': 800,
          'mediaHeight': 600,
          'isRead': true,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      ];
      await openChat(t);
      await t.longPress(find.byType(ChatPhoto));
      await settle(t);
      // Nothing to copy or edit in a photo without a caption.
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      await t.tap(find.text('Reply'));
      await settle(t);
      expect(find.text('📷 Photo'), findsOneWidget);
      await close(t);
    });
  });

  group('voice', () {
    testWidgets('tap the microphone, speak, send: it goes with its length '
        'and shape', (t) async {
      await openChat(t);
      await t.tap(find.byTooltip('Voice message'));
      await settle(t);
      expect(find.byType(VoiceRecordingBar), findsOneWidget);
      final rec = FakeRecorder.made.last;
      for (var i = 0; i < 25; i++) {
        rec.levelsCtrl.add(i.isEven ? -8 : -40);
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('0:03'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('voice_send')));
      await settle(t);
      await letItUpload(t);

      expect(rec.stopped, isTrue);
      expect(to('storage.test').single.headers['Content-Type'], 'audio/mp4');
      final body = sent();
      expect(body['kind'], 'voice');
      expect(body['mediaUrl'], 'https://cdn.test/chat/u1/abc/voice.m4a');
      expect(body['mediaDurationMs'], inInclusiveRange(2500, 3500));
      final wave = (body['waveform'] as List).cast<int>();
      expect(wave, hasLength(ChatMedia.waveformBars));
      expect(wave.any((v) => v > 50), isTrue, reason: 'the loud parts show');
      expect(body.containsKey('message') ? body['message'] : '', '');

      expect(find.byType(VoiceRecordingBar), findsNothing);
      expect(find.byType(ChatVoice), findsOneWidget);
      await close(t);
    });

    testWidgets('the bin throws the recording away and sends nothing', (
      t,
    ) async {
      await openChat(t);
      await t.tap(find.byTooltip('Voice message'));
      await settle(t);
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const ValueKey('voice_cancel')));
      await settle(t);
      expect(FakeRecorder.made.last.cancelled, isTrue);
      expect(find.byType(VoiceRecordingBar), findsNothing);
      expect(find.byTooltip('Voice message'), findsOneWidget);
      expect(to('/api/v1/chat/media'), isEmpty);
      await close(t);
    });

    testWidgets('without the microphone allowed it says how to allow it', (
      t,
    ) async {
      FakeRecorder.allow = false;
      await openChat(t);
      await t.tap(find.byTooltip('Voice message'));
      await settle(t);
      expect(find.byType(VoiceRecordingBar), findsNothing);
      expect(find.textContaining('Allow the microphone'), findsOneWidget);
      await close(t);
    });

    testWidgets('a voice message plays, shows its speed, and only one plays '
        'at a time', (t) async {
      final now = DateTime.now().toUtc().toIso8601String();
      history = [
        for (final n in ['a', 'b'])
          {
            'id': n,
            'senderId': 'u2',
            'receiverId': 'u1',
            'message': '',
            'kind': 'voice',
            'mediaUrl': 'https://cdn.test/chat/u2/$n/voice.m4a',
            'mediaDurationMs': 4200,
            'waveform': [10, 80, 30],
            'isRead': true,
            'createdAt': now,
          },
      ];
      await openChat(t);
      expect(find.byType(ChatVoice), findsNWidgets(2));
      expect(find.text('0:04'), findsNWidgets(2));
      // The server lists newest first, so "b" is drawn first (higher up).
      await t.tap(find.byKey(const ValueKey('voice_play')).first);
      await settle(t);
      expect(
        FakePlayer.made.single.playing,
        'https://cdn.test/chat/u2/b/voice.m4a',
      );
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.text('1×'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('voice_speed')));
      await settle(t);
      expect(find.text('1.5×'), findsOneWidget);
      expect(FakePlayer.made.single.speed, 1.5);

      await t.tap(find.byKey(const ValueKey('voice_play')).last);
      await settle(t);
      expect(
        FakePlayer.made.first.disposed,
        isTrue,
        reason: 'the first one stops when the second starts',
      );
      expect(
        FakePlayer.made.last.playing,
        'https://cdn.test/chat/u2/a/voice.m4a',
      );

      // Played to the end: back to the play button.
      FakePlayer.made.last.finishedCtrl.add(null);
      await settle(t);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      await close(t);
    });

    testWidgets('a voice message has nothing to copy or edit', (t) async {
      history = [
        {
          'id': 'v',
          'senderId': 'u1',
          'receiverId': 'u2',
          'message': '',
          'kind': 'voice',
          'mediaUrl': 'https://cdn.test/chat/u1/v/voice.m4a',
          'mediaDurationMs': 2000,
          'isRead': false,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      ];
      await openChat(t);
      await t.longPress(find.byType(ChatVoice));
      await settle(t);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('🎤 Voice message'), findsOneWidget);
      await close(t);
    });
  });

  testWidgets('the chat list shows a new voice message as words', (t) async {
    final dp = DataProvider()
      ..setUser(
        UserModel(
          id: 'u1',
          username: 'me',
          wins: 0,
          losses: 0,
          followersCount: 0,
          followingCount: 0,
        ),
      );
    EventTracker.instance.dispose();
    ws = WebSocketService('', '');
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DataProvider>.value(value: dp),
          Provider<WebSocketService>.value(value: ws),
        ],
        child: const MaterialApp(home: ChatListPage()),
      ),
    );
    await settle(t);
    // The list moves the chat to the top at once, then asks the server
    // again; the server is slow here, so what shows is the app's own line.
    conversationsDelay = const Duration(seconds: 2);
    ws.debugReceive({
      'type': 'chat',
      'senderId': 'u2',
      'senderUsername': 'maya',
      'messageId': '3',
      'message': '',
      'kind': 'voice',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });
    await t.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Voice message'), findsOneWidget);
    expect(find.text('No message content'), findsNothing);
    await t.pump(const Duration(seconds: 3));
    await close(t);
  });

  // Both used to size themselves to their top bar, about 44 pixels tall:
  // the photo showed in a strip and the caption box sat at the top.
  testWidgets('the photo preview and the full-screen photo fill the screen',
      (t) async {
    await t.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      home: PhotoPreviewPage(file: photoFile(), to: 'maya'),
    ));
    await t.pump();
    expect(t.getRect(find.byType(InteractiveViewer)).height, 900);
    expect(t.getRect(find.byKey(const ValueKey('photo_caption'))).bottom,
        greaterThan(800),
        reason: 'the caption box is at the bottom');
    expect(t.getRect(find.byTooltip('Cancel')).top, lessThan(60));

    await t.pumpWidget(MaterialApp(
      home: ChatPhotoViewer(
        message: {'localPath': photoFile().path, 'message': 'hello'},
        from: 'maya',
      ),
    ));
    await t.pump();
    expect(t.getRect(find.byType(InteractiveViewer)).height, 900);
    expect(t.getRect(find.text('hello')).bottom, greaterThan(800));
    expect(t.getRect(find.byTooltip('Close')).top, lessThan(80));
    await t.pumpWidget(const SizedBox());
  });

  group('the small parts', () {
    test('a message as one line', () {
      expect(chatPreviewText({'kind': 'photo', 'message': ''}), '📷 Photo');
      expect(chatPreviewText({'kind': 'photo', 'message': 'hi'}), '📷 hi');
      expect(
        chatPreviewText({'kind': 'voice', 'message': ''}),
        '🎤 Voice message',
      );
      expect(chatPreviewText({'message': 'hello'}), 'hello');
      expect(
        NotificationModel.fromJson({
          'type': 'chat',
          'kind': 'voice',
          'message': '',
        }).message,
        '🎤 Voice message',
      );
    });

    test('loudness, clock and shape', () {
      expect(levelFromDb(0), 100);
      expect(levelFromDb(-160), 0);
      expect(levelFromDb(-27.5), inInclusiveRange(45, 55));
      expect(voiceClock(const Duration(seconds: 7)), '0:07');
      expect(voiceClock(const Duration(seconds: 102)), '1:42');
      expect(fitWaveform([0, 100, 0, 0], 2), [100, 0]);
      expect(fitWaveform([50], 3), [50, 50, 50]);
      expect(fitWaveform([], 3), [0, 0, 0]);
    });

    test("a photo's size is read from the photo itself", () async {
      final f = File('${dir.path}/p.png')..writeAsBytesSync(tinyPng);
      final size = await photoSize(f);
      expect(size, const ui.Size(4, 3));
      final bad = File('${dir.path}/bad.jpg')..writeAsStringSync('nope');
      expect(await photoSize(bad), isNull);
    });
  });
}
