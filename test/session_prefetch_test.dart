// The app used to freeze for 223ms at startup reading the saved login.
//
// The first time anything touches the phone's secure storage, Android has to
// unlock the key it encrypted the data with — a trip to the security chip.
// It happens once per launch. On a real device it measured 223ms.
//
// It was happening at the worst possible moment: in the splash screen's
// callback, AFTER the first frame, with nothing else running and the
// login-or-feed decision stuck behind it.
//
// The fix does not make the work faster. It starts it at the top of main()
// so it runs alongside the rest of startup, and hands the answer to whoever
// asks later. These tests hold both halves of that in place:
//
//   * main() actually starts it (delete that one line and this file goes red)
//   * asking for it later does NOT read a second time

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/session_store.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Every line of a Dart file that is not a comment.
///
/// A test that reads source has to do this. Two tests in this repo once
/// searched for the words in the comment explaining a trap instead of the
/// code that avoids it, and passed against code with the trap wide open.
String codeOnly(String source) => source
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('///') && !t.startsWith('*');
    })
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Answers the secure-storage channel with [stored] and counts how many
  /// times it was actually asked to read.
  ///
  /// The counter is the whole point: "it still works" would pass even if
  /// every caller went back to the keystore separately, which is the bug.
  int reads = 0;
  String? stored;

  setUp(() {
    reads = 0;
    stored = null;
    SessionStore.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'read':
          reads++;
          return stored;
        case 'write':
          stored = (call.arguments as Map)['value'] as String?;
          return null;
        case 'delete':
          stored = null;
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    SessionStore.resetForTest();
  });

  /// A session blob shaped exactly like the one save() writes.
  String blob({String token = 'tok-abc'}) => json.encode({
        'token': token,
        'user': {'id': '7', 'username': 'player2'},
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
      });

  group('main() starts the read', () {
    test('the call is there, and it is above runApp', () {
      final source = codeOnly(File('lib/main.dart').readAsStringSync());

      final started = source.indexOf('SessionStore.prefetch()');
      expect(started, isNot(-1),
          reason: 'main() must start the secure-storage read itself. '
              'Without this line the 223ms lands back in the splash screen, '
              'after the first frame, with nothing else running.');

      final firstRunApp = source.indexOf('runApp(');
      expect(firstRunApp, isNot(-1));
      expect(started, lessThan(firstRunApp),
          reason: 'Starting the read after runApp puts it back on the '
              'critical path — there is nothing left to overlap with.');
    });

    test('and it is not awaited', () {
      final source = codeOnly(File('lib/main.dart').readAsStringSync());
      expect(source.contains('await SessionStore.prefetch'), isFalse,
          reason: 'Awaiting it moves the 223ms in FRONT of the first frame '
              'instead of beside it. That is the same stall, just somewhere '
              'the user cannot see it coming.');
    });
  });

  group('asking later does not read again', () {
    test('prefetch then load costs one keystore read, not two', () async {
      stored = blob();

      SessionStore.prefetch();
      final session = await SessionStore.load();

      expect(reads, 1,
          reason: 'load() must pick up what prefetch() already read. '
              'Two reads means the startup read was wasted and the splash '
              'still waits for a fresh one.');
      // Checking for PRESENCE, not just the count. A load() that always
      // returned null would also score one read.
      expect(session, isNotNull);
      expect(session!.token, 'tok-abc');
      expect(session.userJson['username'], 'player2');
    });

    test('prefetch twice is still one read', () async {
      stored = blob();
      SessionStore.prefetch();
      SessionStore.prefetch();
      await SessionStore.load();
      expect(reads, 1);
    });

    test('two loads in a row are still one read', () async {
      stored = blob();
      final a = await SessionStore.load();
      final b = await SessionStore.load();
      expect(reads, 1);
      expect(a!.token, b!.token);
    });
  });

  group('load() on its own still works', () {
    // Nothing may DEPEND on prefetch having run. Tests skip main(), and so
    // does any future code path that reaches the store before startup does.
    test('reads the keystore when nobody prefetched', () async {
      stored = blob(token: 'tok-solo');
      final session = await SessionStore.load();
      expect(reads, 1);
      expect(session!.token, 'tok-solo');
    });

    test('returns null when there is nothing saved', () async {
      expect(await SessionStore.load(), isNull);
      expect(reads, 1);
    });
  });

  group('what we remembered gets dropped when it stops being true', () {
    test('after save(), load() sees the NEW session', () async {
      stored = blob(token: 'tok-old');
      SessionStore.prefetch();
      expect((await SessionStore.load())!.token, 'tok-old');

      await SessionStore.save('tok-new', {'id': '7', 'username': 'player2'});

      final after = await SessionStore.load();
      expect(after!.token, 'tok-new',
          reason: 'Handing back the boot-time read after a save means the '
              'app carries on with the token it just replaced.');
    });

    test('after clear(), load() sees no session', () async {
      stored = blob();
      SessionStore.prefetch();
      expect(await SessionStore.load(), isNotNull);

      await SessionStore.clear();

      expect(await SessionStore.load(), isNull,
          reason: 'Handing back the boot-time read after a logout means the '
              'next launch restores the session the user just ended.');
    });
  });

  group('a keystore that refuses is not the same as no session', () {
    test('load() survives a platform failure and says so', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        throw PlatformException(code: 'keyset', message: 'corrupted');
      });

      final printed = <String>[];
      final realDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };
      try {
        expect(await SessionStore.load(), isNull);
      } finally {
        debugPrint = realDebugPrint;
      }

      expect(printed.join('\n'), contains('Could not read the saved session'),
          reason: 'A keystore failure and a logged-out user look identical '
              'from the outside — both land on the login screen. Without a '
              'line in the log there is nothing to tell them apart.');
    });
  });
}
