// Sharing: a page with a QR code and the link, from a profile's Share
// button and from a video's share sheet.
//
// Through the real buttons, so a Share button that stops opening the page,
// or a code that holds the wrong address, goes red here.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/share_card_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/share_links.dart';
import 'package:myapp/widgets/feed_action_bar.dart';

UserModel maya() => UserModel(
      id: '5',
      username: 'maya',
      fullName: 'Maya Singh',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );

late List<String> copied;

void main() {
  late Directory dir;
  setUp(() {
    copied = [];
    dir = Directory.systemTemp.createTempSync('share_card');
    ApiService.useClient(MockClient((req) async => http.Response(
        req.url.path.contains('/challenges') ? '[]' : '{}', 200)));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => dir.path);
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  test('the code draws exactly the link it is given', () {
    // What the drawing package holds is private, so: the one line that
    // hands it over, read with comment lines taken out.
    final code = File('lib/pages/share_card_page.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final qr = code.substring(code.indexOf('class ShareQr'));
    expect(qr, contains('data: link,'));
  });

  test('the links point at the pages the server draws', () {
    expect(ShareLinks.profile('maya'), '${AppConstants.shareBaseUrl}/u/maya');
    expect(ShareLinks.video('42'), '${AppConstants.shareBaseUrl}/v/42');
    expect(ShareLinks.profile('maya'), isNot(contains('devf.app')),
        reason: 'a website that does not exist');
  });

  testWidgets("a profile's Share button opens the page: its code holds the "
      'profile link, and Copy copies it', (t) async {
    final dp = DataProvider()..setUser(maya());
    EventTracker.instance.dispose();
    await t.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: dp,
      child: MaterialApp(home: ProfilePage(user: maya(), isEmbedded: false)),
    ));
    await settle(t);
    await t.tap(find.byTooltip('Share profile'));
    await settle(t);

    expect(find.byType(ShareCardPage), findsOneWidget);
    final qr = t.widget<ShareQr>(find.byType(ShareQr));
    expect(qr.link, ShareLinks.profile('maya'));
    expect(find.text('@maya'), findsOneWidget);
    expect(find.text('Maya Singh'), findsOneWidget);
    expect(find.textContaining('/u/maya'), findsOneWidget,
        reason: 'the link itself is shown');

    await t.tap(find.byKey(const ValueKey('share_copy')));
    await settle(t);
    expect(copied, [ShareLinks.profile('maya')]);
    expect(find.text('Link copied'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('Save QR code puts the card in your photos, and says so',
      (t) async {
    final kept = <String>[];
    final was = ShareCardPage.keepInGallery;
    ShareCardPage.keepInGallery = (path) async {
      kept.add(path);
      return File(path).existsSync() && File(path).lengthSync() > 0;
    };
    addTearDown(() => ShareCardPage.keepInGallery = was);
    await t.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: DataProvider(),
      child: MaterialApp(
        home: ShareCardPage(
          link: ShareLinks.profile('maya'),
          title: '@maya',
          subtitle: 'Maya Singh',
          photoOf: 'maya',
          what: 'profile',
        ),
      ),
    ));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('share_save_qr')));
    for (var i = 0; i < 30 && kept.isEmpty; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(kept, hasLength(1));
    expect(kept.single, endsWith('.png'));
    expect(find.text('Saved to your photos'), findsOneWidget);
    expect(File(kept.single).existsSync(), isFalse,
        reason: 'the picture on the way to the gallery is tidied away');
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets("a video's share sheet: Copy link copies its page, not the "
      'raw file, and QR code opens the page for the video', (t) async {
    final video = ChallengeModel.fromJson({
      'id': '42',
      'creatorId': '5',
      'creatorUsername': 'maya',
      'videoUrl': 'https://storage/raw/upload.mp4',
      'prefix': 'Who dances',
      'subject': 'better',
      'status': 'open',
      'visibility': 'arena',
      'createdAt': '2026-09-01T10:00:00Z',
    });
    final dp = DataProvider()..setUser(maya());
    EventTracker.instance.dispose();
    await t.pumpWidget(ChangeNotifierProvider.value(
      value: dp,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ChallengeShareSheet(challenge: video),
              ),
              child: const Text('share'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('share'));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('share_copy_link')));
    await settle(t);
    expect(copied.single, contains(ShareLinks.video('42')));
    expect(copied.single, isNot(contains('upload.mp4')));

    await t.tap(find.text('share'));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('share_qr_code')));
    await settle(t);
    expect(find.byType(ShareCardPage), findsOneWidget);
    expect(t.widget<ShareQr>(find.byType(ShareQr)).link,
        ShareLinks.video('42'));
    expect(find.text('by @maya'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
  });
}
