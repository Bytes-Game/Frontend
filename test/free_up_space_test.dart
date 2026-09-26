// "Free up space", and logout emptying the saved videos.
//
// The cache's own "empty everything" existed for months and nothing in the
// app called it — only tests did, by hand. So every test here goes through
// the real caller (the logout, the screen's buttons, the settings row)
// rather than the far end. Delete any one of those calls and something in
// this file goes red.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/pages/free_up_space_page.dart';
import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/leftover_files.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/services/video_cache_service.dart';

Future<bool> eventually(
  bool Function() check, {
  Duration limit = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return check();
}

File put(Directory d, String relative, int bytes) {
  final f = File('${d.path}/$relative')..createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 7));
  return f;
}

const mb = 1024 * 1024;

void main() {
  late Directory cacheDir;
  late Directory tempDir;
  final realFolder = LeftoverFiles.folder;

  setUp(() async {
    cacheDir = Directory.systemTemp.createTempSync('reelcache');
    tempDir = Directory.systemTemp.createTempSync('apptemp');
    VideoCacheService.instance.debugSetDirectory(cacheDir);
    await VideoCacheService.instance.clear();
    LeftoverFiles.folder = () async => tempDir;
    UploadJobManager.instance.activeJobs.value = const [];
  });

  tearDown(() async {
    await VideoCacheService.instance.clear();
    UploadJobManager.instance.activeJobs.value = const [];
    LeftoverFiles.folder = realFolder;
    ApiService.useClient(http.Client());
    for (final d in [cacheDir, tempDir]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  // ── Logout ──────────────────────────────────────────────────────────

  testWidgets('logging out empties the saved videos', (tester) async {
    final whole = put(cacheDir, 'aaaa.mp4', 4096);
    final piece = put(cacheDir, 'bbbb.mp4.prefix', 2048);

    late BuildContext ctx;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => DataProvider(),
        child: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      whole.existsSync() && piece.existsSync(),
      isTrue,
      reason: 'the test has to start with something to empty',
    );

    AuthProvider().logout(ctx);
    await tester.pump();

    expect(whole.existsSync(), isFalse);
    expect(piece.existsSync(), isFalse);
  });

  // ── Clearing while a video plays ────────────────────────────────────

  group('clearing while a video is playing', () {
    const size = 4 * mb;

    setUp(() async {
      LocalMediaServer.instance.debugReset();
      await LocalMediaServer.instance.start();
      ApiService.useClient(
        MockClient.streaming((req, _) async {
          String? range;
          for (final e in req.headers.entries) {
            if (e.key.toLowerCase() == 'range') range = e.value;
          }
          final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range ?? '');
          if (m == null) {
            return http.StreamedResponse(
              Stream.value(List<int>.filled(size, 1)),
              200,
              contentLength: size,
            );
          }
          final s = int.parse(m.group(1)!);
          final asked = m.group(2)!.isEmpty ? size - 1 : int.parse(m.group(2)!);
          final e = asked < size - 1 ? asked : size - 1;
          return http.StreamedResponse(
            Stream.value(List<int>.filled(e - s + 1, 1)),
            206,
            contentLength: e - s + 1,
            headers: {'content-range': 'bytes $s-$e/$size'},
          );
        }),
      );
    });

    tearDown(() async {
      await LocalMediaServer.instance.stop();
      LocalMediaServer.instance.debugReset();
    });

    test(
      'a video playing from the saved copy carries on after a clear',
      () async {
        const url = 'https://cdn/playing.mp4';
        VideoCacheService.instance.warm([url]);
        expect(
          await eventually(() => VideoCacheService.instance.isReady(url)),
          isTrue,
        );
        expect(
          await eventually(() => VideoCacheService.instance.debugActive == 0),
          isTrue,
        );

        // The address a player opened before the clear, and still holds.
        final address = VideoCacheService.instance.playbackUrlFor(url);
        expect(address, startsWith('http://127.0.0.1:'));

        final freed = await VideoCacheService.instance.clear();
        expect(freed, greaterThan(0), reason: 'the saved opening was on disk');
        expect(cacheDir.listSync(), isEmpty);

        // The player plays on and asks for the next part, at the same address.
        // A real client: once a widget test has run in this file, Flutter's
        // test setup answers every HttpClient request with a 400 of its own.
        final client = HttpOverrides.runWithHttpOverrides(
          HttpClient.new,
          _RealSockets(),
        );
        final req = await client.getUrl(Uri.parse(address));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=1000000-1000099');
        final res = await req.close();
        final body = await res.fold<List<int>>([], (a, c) => a..addAll(c));
        client.close();

        expect(
          res.statusCode,
          HttpStatus.partialContent,
          reason: 'a "not found" here stops the video on screen dead',
        );
        expect(body.length, 100);

        expect(
          VideoCacheService.instance.isReady(url),
          isFalse,
          reason: 'its opening is gone, so it no longer starts instantly',
        );
      },
    );
  });

  // ── Leftover recordings ─────────────────────────────────────────────

  group('leftover recordings', () {
    late File recording;
    late File trimmed;
    late File uploadCopy;
    late File camera;
    late File picked;
    late List<File> notOurs;

    setUp(() {
      recording = put(tempDir, 'devf_record_1.mp4', 100);
      trimmed = put(tempDir, 'devf_trim_1.mp4', 200);
      uploadCopy = put(tempDir, 'devf_upload_1/source.mp4', 300);
      camera = put(tempDir, 'REC4417706950958238419.mp4', 400);
      picked = put(tempDir, 'file_picker/1758870000000/holiday.mp4', 500);
      notOurs = [
        put(tempDir, 'reel_cache/abcd.mp4', 1000),
        put(tempDir, 'RECORDING.mp4', 60),
        put(tempDir, 'devf_notes.txt', 70),
        put(tempDir, 'some_plugin/state.db', 80),
      ];
    });

    test(
      'finds what recording and posting leave behind, and nothing else',
      () async {
        final scan = await LeftoverFiles.instance.scan();
        expect(scan.bytes, 100 + 200 + 300 + 400 + 500);
        expect(scan.keptBytes, 0);

        final freed = await LeftoverFiles.instance.clear();
        expect(freed, 1500);
        for (final f in [recording, trimmed, uploadCopy, camera, picked]) {
          expect(f.existsSync(), isFalse, reason: '${f.path} is a leftover');
        }
        expect(
          Directory('${tempDir.path}/devf_upload_1').existsSync(),
          isFalse,
        );
        for (final f in notOurs) {
          expect(
            f.existsSync(),
            isTrue,
            reason: '${f.path} is not ours to delete',
          );
        }
      },
    );

    test('keeps the video a post waiting to retry still needs', () async {
      UploadJobManager.instance.activeJobs.value = [
        UploadJob.debug(sourcePath: trimmed.path, stage: UploadJobStage.failed),
        UploadJob.debug(sourcePath: picked.path, stage: UploadJobStage.failed),
      ];

      final scan = await LeftoverFiles.instance.scan();
      expect(scan.keptBytes, 200 + 500);
      expect(scan.freeable, 100 + 300 + 400);

      await LeftoverFiles.instance.clear();
      expect(trimmed.existsSync(), isTrue);
      expect(picked.existsSync(), isTrue);
      expect(recording.existsSync(), isFalse);
      expect(camera.existsSync(), isFalse);
    });

    test('leaves upload folders alone while an upload is running', () async {
      UploadJobManager.instance.activeJobs.value = [
        UploadJob.debug(
          sourcePath: trimmed.path,
          stage: UploadJobStage.uploading,
        ),
      ];
      await LeftoverFiles.instance.clear();
      expect(
        uploadCopy.existsSync(),
        isTrue,
        reason: 'the running upload may be reading from this folder',
      );
      expect(trimmed.existsSync(), isTrue);
      expect(recording.existsSync(), isFalse);
    });

    test("a finished post's copies are cleared", () async {
      UploadJobManager.instance.activeJobs.value = [
        UploadJob.debug(sourcePath: trimmed.path, stage: UploadJobStage.done),
      ];
      await LeftoverFiles.instance.clear();
      expect(trimmed.existsSync(), isFalse);
      expect(uploadCopy.existsSync(), isFalse);
    });
  });

  // ── Recording ───────────────────────────────────────────────────────

  test("a recording keeps one copy, not the camera's as well", () async {
    final cameraFile = put(tempDir, 'REC123.mp4', 3000);
    final ours = '${tempDir.path}/devf_record_1.mp4';

    await adoptCameraRecording(cameraFile.path, ours);

    expect(
      File(ours).lengthSync(),
      3000,
      reason: 'the recording arrived whole',
    );
    expect(
      cameraFile.existsSync(),
      isFalse,
      reason: "the camera's copy is a second full copy nobody reads",
    );
  });

  test('the recording screen hands its recording over that way', () {
    final code = File(
      'lib/pages/record_video_page.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    final stop = code.substring(code.indexOf('Future<void> _stopRecording()'));
    expect(stop, contains('await adoptCameraRecording(file.path, dest.path);'));
  });

  // ── The screen ──────────────────────────────────────────────────────

  testWidgets('the screen shows what is taking space and clears it', (
    tester,
  ) async {
    final saved = put(cacheDir, 'aaaa.mp4', 2 * mb);
    final leftover = put(tempDir, 'devf_trim_1.mp4', 1 * mb);

    await tester.pumpWidget(const MaterialApp(home: FreeUpSpacePage()));
    await tester.pumpAndSettle();

    Finder inRow(String key, Finder f) =>
        find.descendant(of: find.byKey(Key(key)), matching: f);

    expect(
      inRow('free_up_space_saved_videos', find.text('2.0 MB')),
      findsOneWidget,
    );
    expect(
      inRow('free_up_space_leftovers', find.text('1.0 MB')),
      findsOneWidget,
    );

    await tester.tap(inRow('free_up_space_saved_videos', find.text('Clear')));
    await tester.pumpAndSettle();
    expect(saved.existsSync(), isFalse);
    expect(
      leftover.existsSync(),
      isTrue,
      reason: 'each button clears only its own kind',
    );
    expect(
      inRow('free_up_space_saved_videos', find.text('0 KB')),
      findsOneWidget,
    );
    expect(find.text('Freed 2.0 MB'), findsOneWidget);

    await tester.tap(inRow('free_up_space_leftovers', find.text('Clear')));
    await tester.pumpAndSettle();
    expect(leftover.existsSync(), isFalse);
    expect(inRow('free_up_space_leftovers', find.text('0 KB')), findsOneWidget);
  });

  test('sizes read the way a person reads them', () {
    expect(formatBytes(0), '0 KB');
    expect(formatBytes(1), '1 KB');
    expect(formatBytes(740 * 1024), '740 KB');
    expect(formatBytes(12 * mb + 300 * 1024), '12.3 MB');
    expect(formatBytes(1300 * mb), '1.27 GB');
  });

  // ── The way in ──────────────────────────────────────────────────────

  test('Settings has a Free up space row, and it opens the screen', () {
    // Comment lines are dropped first, so this can only pass on code.
    final code = File(
      'lib/pages/profile_page.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

    expect(
      RegExp(
        r"_row\(\s*Icons\.\w+,\s*'Free up space',[^)]*onFreeUpSpace,",
      ).hasMatch(code),
      isTrue,
      reason: 'the settings sheet draws the row with the callback',
    );
    expect(
      RegExp(
        r'onFreeUpSpace:\s*\(\)\s*\{[^}]*FreeUpSpacePage\(\)',
      ).hasMatch(code),
      isTrue,
      reason: 'the profile page hands the sheet a callback that opens it',
    );
  });
}

class _RealSockets extends HttpOverrides {}
