// Your own videos, kept on the phone after you post them, so they open at
// once from your profile instead of being downloaded again.
//
// Three wires, each tested through its real caller:
//   * the store keeps, finds, trims and empties the copies,
//   * a reel of one of your videos plays the copy, with the server's as the
//     retry,
//   * the player opens that copy as a file, not over the network.
// And the one that cannot be driven in a test — an upload finishing — is
// checked in the code, with the comments taken out first.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/own_uploads.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

ChallengeModel video(String id, {String answer = ''}) => ChallengeModel(
  id: id,
  creatorId: '1',
  creatorUsername: 'me',
  creatorLeague: 'Bronze',
  videoUrl: 'https://cdn/$id.mp4',
  prefix: 'Who can',
  subject: 'juggle',
  visibility: 'arena',
  status: answer.isEmpty ? 'open' : 'active',
  likes: 0,
  views: 0,
  createdAt: '',
  responseCount: answer.isEmpty ? 0 : 1,
  topResponseId: answer,
  topResponseVideoUrl: answer.isEmpty ? '' : 'https://cdn/r$answer.mp4',
);

/// A platform that records what each player was opened on.
class _Platform extends VideoPlayerPlatform {
  final List<String> opened = [];
  int _id = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    opened.add(options.dataSource.uri ?? '');
    return _id++;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      StreamController<VideoEvent>().stream;

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> pause(int playerId) async {}
}

void main() {
  late Directory tmp;
  final store = OwnUploads.instance;

  File posted(String name, {int bytes = 1000}) {
    final f = File('${tmp.path}/$name')
      ..writeAsBytesSync(List.filled(bytes, 7));
    return f;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('own_uploads_test');
    store.folder = () async => Directory('${tmp.path}/kept');
    store.debugForget();
  });

  tearDown(() async {
    await store.clear();
    store.debugForget();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the store', () {
    test('keeps a copy under the video id, and finds it again after a '
        'restart', () async {
      await store.keep('challenge:12', posted('devf_trim_1.mp4').path);
      final kept = store.pathFor('challenge:12');
      expect(kept, isNotNull);
      expect(File(kept!).lengthSync(), 1000);
      expect(isLocalVideo(kept), isTrue);

      // The posted file goes away, as posting's leftovers do: the copy stays.
      File('${tmp.path}/devf_trim_1.mp4').deleteSync();
      store.debugForget();
      expect(store.pathFor('challenge:12'), isNull, reason: 'not read yet');
      await store.init();
      expect(store.pathFor('challenge:12'), kept);
    });

    test('keeps only the newest twelve', () async {
      for (var i = 0; i < OwnUploads.maxFiles + 1; i++) {
        await store.keep('challenge:$i', posted('v$i.mp4').path);
      }
      expect(store.pathFor('challenge:0'), isNull, reason: 'oldest out');
      expect(store.pathFor('challenge:1'), isNotNull);
      expect(store.pathFor('challenge:${OwnUploads.maxFiles}'), isNotNull);
      expect(
        Directory(
          '${tmp.path}/kept',
        ).listSync().where((f) => f.path.endsWith('.mp4')).length,
        OwnUploads.maxFiles,
        reason: 'the file itself is deleted, not just forgotten',
      );
    });

    test('does not copy a huge one, or one already gone', () async {
      final huge = File('${tmp.path}/huge.mp4');
      final raf = huge.openSync(mode: FileMode.write)
        ..truncateSync(OwnUploads.maxOneFile + 1);
      raf.closeSync();
      await store.keep('challenge:1', huge.path);
      await store.keep('challenge:2', '${tmp.path}/nothing.mp4');
      expect(store.pathFor('challenge:1'), isNull);
      expect(store.pathFor('challenge:2'), isNull);
    });

    test(
      'empties on sign-out and from Free up space, saying how much',
      () async {
        await store.keep('challenge:5', posted('a.mp4', bytes: 3000).path);
        expect(await store.bytesOnDisk(), greaterThanOrEqualTo(3000));
        final freed = await store.clear();
        expect(freed, greaterThanOrEqualTo(3000));
        expect(store.pathFor('challenge:5'), isNull);
        expect(await store.bytesOnDisk(), 0);
      },
    );
  });

  group('a reel of your own video', () {
    test('plays the copy on the phone, with the server\'s as the retry, and '
        'the same for an answer you posted', () async {
      await store.keep('challenge:30', posted('c.mp4').path);
      await store.keep('response:40', posted('r.mp4').path);
      final plays = SmartReelsFeed.debugPlaysFor(video('30', answer: '40'))!;
      expect(plays.video, store.pathFor('challenge:30'));
      expect(plays.fallback, 'https://cdn/30.mp4');
      expect(plays.answer, store.pathFor('response:40'));
    });

    test('the same when it comes round in a feed', () async {
      await store.keep('challenge:32', posted('f.mp4').path);
      await store.keep('response:42', posted('g.mp4').path);
      final plays = SmartReelsFeed.debugPlaysForEntry({
        'type': 'challenge',
        'challenge': {
          'id': '32',
          'videoUrl': 'https://cdn/32.mp4',
          'topResponseId': '42',
          'topResponseVideoUrl': 'https://cdn/r42.mp4',
        },
      })!;
      expect(plays.video, store.pathFor('challenge:32'));
      expect(plays.fallback, 'https://cdn/32.mp4');
      expect(plays.answer, store.pathFor('response:42'));
    });

    test('anyone else\'s plays from the server as before', () {
      final plays = SmartReelsFeed.debugPlaysFor(video('31', answer: '41'))!;
      expect(plays.video, 'https://cdn/31.mp4');
      expect(plays.answer, 'https://cdn/r41.mp4');
    });
  });

  test('the player opens the copy as a file, never over the network', () async {
    WidgetsFlutterBinding.ensureInitialized();
    final platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    await store.keep('challenge:50', posted('p.mp4').path);
    final path = store.pathFor('challenge:50')!;
    VideoPlayerService.instance.getController(path);
    await pumpEventQueue();
    expect(platform.opened, ['file://$path']);
    await VideoPlayerService.instance.disposeAll();
    ReelDiagnostics.instance.debugReset();
  });

  test('every finished upload keeps its video: two challenge paths and the '
      'answer path', () {
    // Comments out first: a test that finds the words in a comment checks
    // nothing.
    final code = File(
      'lib/services/upload_job_manager.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    final keeps = RegExp(
      r"OwnUploads\.instance\s*\.keep\(\s*'(challenge|response):\$\{(challenge|response)\.id\}',\s*job\.sourcePath\)",
    ).allMatches(code).map((m) => m.group(1)).toList();
    expect(keeps, ['challenge', 'challenge', 'response']);
    // And each sits where the post is marked as done — every such place
    // but the photo one. A photo is not played from the phone, so there is
    // nothing of it to keep.
    final photo = RegExp(
      r'Future<void> _runPhoto\([\s\S]*?\n  }\n',
    ).firstMatch(code)!.group(0)!;
    expect(photo, contains("message: 'Posted'"));
    expect(photo, isNot(contains('OwnUploads')));
    final posted = RegExp(r"message: 'Posted'").allMatches(code).length;
    expect(posted, keeps.length + 1);
  });

  test('the app reads what it kept when it starts, or a copy from before '
      'a restart is never found', () {
    final code = File(
      'lib/main.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(code, contains('OwnUploads.instance.init()'));
  });
}
