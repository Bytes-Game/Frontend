// Two settings in the phone projects that the stores and real phones care
// about, read from the files the build uses. Comments are removed first, so
// a test cannot pass on the words explaining a setting.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String withoutXmlComments(String s) =>
    s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

void main() {
  test('Android keeps no backup of the app, so a restored phone never holds '
      'a sign-in it cannot read', () {
    final manifest = withoutXmlComments(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final app = RegExp(
      r'<application\b[^>]*>',
      dotAll: true,
    ).firstMatch(manifest)?.group(0);
    expect(app, isNotNull);
    expect(app, contains('android:allowBackup="false"'));
    expect(app, contains('android:fullBackupContent="false"'));
  });

  test('iPhone uploads say the app uses only standard encryption (HTTPS), '
      'so App Store Connect does not ask on every upload', () {
    final plist = withoutXmlComments(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    expect(
      RegExp(
        r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>',
      ).hasMatch(plist),
      isTrue,
    );
  });
}
