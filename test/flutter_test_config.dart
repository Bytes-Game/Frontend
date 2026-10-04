// Runs around every test file.
//
// The chats kept for an instant Messages tab live in one place for the whole
// app (ChatCache). Without a reset, one test's chats would still be "kept"
// when the next test opens Messages, and the two tests would depend on the
// order they ran in.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/chat_cache.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(ChatCache.instance.debugReset);
  await testMain();
}
