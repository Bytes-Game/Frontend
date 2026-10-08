// The list of unsent posts, saved to the phone so a post that failed comes
// back, ready to retry, after the app closes.
//
// Every change to a post saves the list, and nothing waited for the save
// before. Two writes to one file at once can mix: a short list written
// over a long one leaves the end of the long one behind, the file no
// longer reads, and every unsent post is gone at the next start.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/upload_job_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const docs = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final jobs = UploadJobManager.instance;
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('unsent');
    messenger.setMockMethodCallHandler(docs, (call) async => dir.path);
    jobs.debugForgetJobsFile();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(docs, null);
    jobs.activeJobs.value = const [];
    jobs.debugForgetJobsFile();
    dir.deleteSync(recursive: true);
  });

  const meta = ChallengeSubmissionMeta(
    prefix: 'Who dances',
    subject: 'best',
    visibility: 'arena',
    category: '',
    emotionTags: [],
  );

  UploadJob unsent(int n) => UploadJob.debug(
    sourcePath: '${dir.path}/video_$n.mp4',
    stage: UploadJobStage.failed,
    postedAs: meta,
    creatorId: '1',
  );

  List<dynamic> onDisk() =>
      json.decode(File('${dir.path}/upload_jobs_v1.json').readAsStringSync())
          as List<dynamic>;

  test('a long list then a short one, the second saved while the first is '
      'still being written: the short one is on disk, whole', () async {
    final many = [for (var i = 0; i < 2000; i++) unsent(i)];
    for (var round = 0; round < 20; round++) {
      jobs.activeJobs.value = many;
      final first = jobs.debugSave();
      // Let the first save get going: it has read the list and started
      // writing by the time the list changes, as in the app.
      for (var turn = 0; turn < round; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
      jobs.activeJobs.value = [many.first];
      final second = jobs.debugSave();
      await Future.wait([first, second]);
      final List<dynamic> saved;
      try {
        saved = onDisk();
      } on FormatException catch (e) {
        fail('round $round: the saved list no longer reads: $e');
      }
      expect(saved, hasLength(1), reason: 'round $round: the last list wins');
    }
  });

  test('many saves in a row end with the last list', () async {
    final all = [for (var i = 0; i < 50; i++) unsent(i)];
    final saves = <Future<void>>[];
    for (var n = 50; n >= 0; n -= 5) {
      jobs.activeJobs.value = all.take(n).toList();
      saves.add(jobs.debugSave());
    }
    await Future.wait(saves);
    expect(onDisk(), isEmpty);
    expect(
      dir.listSync().where((f) => f.path.endsWith('.part')),
      isEmpty,
      reason: 'no half-written copies are left lying around',
    );
  });
}
