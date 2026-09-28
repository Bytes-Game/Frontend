// The upload bar at the bottom of the app.
//
// A challenge's video starts going up while its page is still being filled
// in. That is not a post yet, and its bar sat over the page's own fields —
// the Tags box, right where you type. The bar shows from the moment Post is
// pressed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/widgets/upload_status_overlay.dart';

const meta = ChallengeSubmissionMeta(
  prefix: 'Who can',
  subject: 'juggle',
  visibility: 'arena',
  category: 'sports',
  emotionTags: [],
);

Future<void> show(WidgetTester t, List<UploadJob> jobs) async {
  UploadJobManager.instance.activeJobs.value = jobs;
  await t.pumpWidget(
    const MaterialApp(
      home: UploadStatusOverlay(child: Scaffold(body: SizedBox.expand())),
    ),
  );
  await t.pump();
}

void main() {
  tearDown(() => UploadJobManager.instance.activeJobs.value = const []);

  testWidgets('a video still being prepared while you type shows no bar', (
    t,
  ) async {
    await show(t, [
      UploadJob.debug(
        sourcePath: '/tmp/a.mp4',
        stage: UploadJobStage.uploading,
        progress: 0.5,
      ),
    ]);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('once Post is pressed, the bar shows', (t) async {
    await show(t, [
      UploadJob.debug(
        sourcePath: '/tmp/b.mp4',
        stage: UploadJobStage.uploading,
        progress: 0.5,
        postedAs: meta,
      ),
    ]);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });
}
