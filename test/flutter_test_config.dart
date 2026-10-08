// Runs around every test file.
//
// The chats kept for an instant Messages tab live in one place for the whole
// app (ChatCache). Without a reset, one test's chats would still be "kept"
// when the next test opens Messages, and the two tests would depend on the
// order they ran in.
//
// The same goes for the queue of saves of the unsent posts
// (UploadJobManager): a save left over from one test never finishes, since
// that test's clock has stopped, and every save and post after it would
// wait for it for ever.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/upload_job_manager.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(ChatCache.instance.debugReset);
  setUp(UploadJobManager.instance.debugResetSaving);
  await testMain();
}
