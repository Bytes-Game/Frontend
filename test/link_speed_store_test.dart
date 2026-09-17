// One number, in a one-line file, so a launch does not start blind.
//
// The value is a hint the next run replaces within a few downloads, so
// every failure here has the same right answer: behave as if there were no
// hint. A launch must never fail because a phone could not read a file
// containing a bandwidth estimate.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/link_speed_store.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('linkspeed');
    LinkSpeedStore.directory = () async => tmp;
    LinkSpeedStore.instance.debugForgetFile();
  });

  tearDown(() {
    LinkSpeedStore.instance.debugForgetFile();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('nothing stored reads as nothing', () async {
    expect(await LinkSpeedStore.instance.read(), isNull);
  });

  test('what goes in comes back', () async {
    await LinkSpeedStore.instance.write(4200000);
    expect(await LinkSpeedStore.instance.read(), 4200000);
  });

  test('the newer reading replaces the older one', () async {
    await LinkSpeedStore.instance.write(4200000);
    await LinkSpeedStore.instance.write(900000);
    expect(await LinkSpeedStore.instance.read(), 900000,
        reason: 'a stale guess from a faster network would be believed');
  });

  group('a bad value is no value', () {
    test('gibberish', () async {
      File('${tmp.path}/link_speed_bps').writeAsStringSync('not a number');
      expect(await LinkSpeedStore.instance.read(), isNull,
          reason: 'pretending to parse it seeds the quality picker with '
              'nonsense, which then decides what people are served');
    });

    test('zero and negative', () async {
      for (final junk in ['0', '-1']) {
        File('${tmp.path}/link_speed_bps').writeAsStringSync(junk);
        expect(await LinkSpeedStore.instance.read(), isNull, reason: junk);
      }
    });

    test('empty', () async {
      File('${tmp.path}/link_speed_bps').writeAsStringSync('');
      expect(await LinkSpeedStore.instance.read(), isNull);
    });

    test('and writing one never reaches the disk', () async {
      // Checked on the FILE, not through read(). Reading it back would be
      // caught by the read guard whether this one exists or not — two
      // guards where only one can fire is one guard and some noise.
      await LinkSpeedStore.instance.write(0);
      await LinkSpeedStore.instance.write(-5);
      expect(File('${tmp.path}/link_speed_bps').existsSync(), isFalse,
          reason: 'junk was written out, and the only thing stopping the '
              'next launch believing it is a second guard somewhere else');
    });

    test('a good value still reaches the disk', () async {
      // The other half: a guard that refuses everything would pass the
      // test above and break the feature.
      await LinkSpeedStore.instance.write(3300000);
      expect(File('${tmp.path}/link_speed_bps').readAsStringSync().trim(),
          '3300000');
    });
  });

  group('a phone that cannot store it still plays video', () {
    test('no directory means no hint, not a crash', () async {
      LinkSpeedStore.directory = () async => throw const FileSystemException('no');
      LinkSpeedStore.instance.debugForgetFile();
      expect(await LinkSpeedStore.instance.read(), isNull);
      // And writing must not throw either — it is fire-and-forget from
      // main(), so an exception here would surface as an unhandled error.
      await LinkSpeedStore.instance.write(1000000);
    });

    test('a file that will not decode means no hint', () async {
      // Bytes that are not valid UTF-8. This is the case that actually
      // reaches readAsString and throws — a DIRECTORY in the file's place
      // does not, because existsSync() is false for one, so the read
      // returns before the catch can ever fire. A test using that proves
      // the early return works and nothing about the catch at all.
      File('${tmp.path}/link_speed_bps').writeAsBytesSync([0xC3, 0x28, 0xA0]);
      expect(await LinkSpeedStore.instance.read(), isNull,
          reason: 'the exception escaped and took the launch with it');
    });

    test('a directory in its place means no hint either', () async {
      Directory('${tmp.path}/link_speed_bps').createSync();
      expect(await LinkSpeedStore.instance.read(), isNull);
    });
  });
}
