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

  test('the iPhone app may play videos from its own server on the phone, '
      'and nothing else is allowed over plain http', () {
    final plist = withoutXmlComments(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    // The video player is handed an http address on the phone itself
    // (LocalMediaServer). Without this an iPhone may refuse to load it.
    expect(
      RegExp(
        r'<key>NSAppTransportSecurity</key>\s*<dict>\s*'
        r'<key>NSAllowsLocalNetworking</key>\s*<true/>\s*</dict>',
      ).hasMatch(plist),
      isTrue,
    );
    // The switch that would allow plain http to anywhere stays off.
    expect(plist.contains('NSAllowsArbitraryLoads'), isFalse);
    // And the app does run that server on every kind of phone: if it were
    // Android-only one day, this setting could go.
    final cache = File(
      'lib/services/video_cache_service.dart',
    ).readAsStringSync();
    expect(cache.contains('LocalMediaServer.instance.start()'), isTrue);
  });

  test('the iPhone app asks for push notifications, and may be woken by '
      'one', () {
    final entitlements = withoutXmlComments(
      File('ios/Runner/Runner.entitlements').readAsStringSync(),
    );
    expect(
      RegExp(
        r'<key>aps-environment</key>\s*<string>(development|production)</string>',
      ).hasMatch(entitlements),
      isTrue,
    );
    // Sign in with Apple stays beside it.
    expect(entitlements, contains('com.apple.developer.applesignin'));
    final plist = withoutXmlComments(
      File('ios/Runner/Info.plist').readAsStringSync(),
    );
    expect(
      RegExp(
        r'<key>UIBackgroundModes</key>\s*<array>[^\]]*?<string>remote-notification</string>',
        dotAll: true,
      ).hasMatch(plist),
      isTrue,
    );
    // Every build setting that signs the app points at that file.
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
          .allMatches(project)
          .length,
      3,
      reason: 'Debug, Release and Profile',
    );
  });
}
