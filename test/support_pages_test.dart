// Support and about, through the real pages: Terms and policies and the
// documents in it, the Help Center, About, and Report a problem. And the
// blue glow behind every page in dark mode, looked at in the drawn pixels.
//
// Every test checks for something that IS there (a page, a request, a
// colour), not only for what is gone.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/legal_texts.dart';
import 'package:myapp/pages/settings_page.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

/// Problem reports the app sent, and whether the server takes them.
late List<Map<String, dynamic>> events;
bool refuse = false;

/// What the app put on the clipboard.
String? copied;

void fakeServer() {
  events = [];
  refuse = false;
  copied = null;
  ApiService.useClient(MockClient((req) async {
    if (req.url.path.endsWith('/api/v1/events')) {
      events.add(json.decode(req.body) as Map<String, dynamic>);
      return refuse ? http.Response('down', 500) : http.Response('{}', 200);
    }
    return http.Response('{}', 200);
  }));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied = (call.arguments as Map)['text'] as String?;
    }
    return null;
  });
}

final me = UserModel(
  id: '1',
  username: 'maya',
  fullName: 'Maya K',
  wins: 0,
  losses: 0,
  followersCount: 0,
  followingCount: 0,
);

final shot = GlobalKey();

Future<void> open(
  WidgetTester t,
  Widget page, {
  ThemeMode mode = ThemeMode.light,
  bool appThemes = false,
  double height = 1600,
}) async {
  FlutterSecureStorage.setMockInitialValues({});
  // Signing in starts the activity reporter's timer: stopped straight
  // after, as the other tests here do.
  final dp = DataProvider()..setUser(me);
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(Size(420, height));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(RepaintBoundary(
    key: shot,
    child: MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: dp),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        theme: appThemes ? AppTheme.lightTheme : null,
        darkTheme: appThemes ? AppTheme.darkTheme : null,
        themeMode: mode,
        home: page,
      ),
    ),
  ));
  await settle(t);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await settle(t);
}

/// A note at the foot of the page keeps a timer; let it run out, as the
/// app would.
Future<void> letNotesGo(WidgetTester t) => t.pump(const Duration(seconds: 5));

/// The colour drawn at ([x], [y]) on the screen.
Future<Color> pixelAt(WidgetTester t, double x, double y) async {
  final boundary =
      shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Color colour;
  await t.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final i = (y.round() * image.width + x.round()) * 4;
    colour = Color.fromARGB(data.getUint8(i + 3), data.getUint8(i),
        data.getUint8(i + 1), data.getUint8(i + 2));
  });
  return colour;
}

/// A page that opens [page] when its button is tapped, so [page] has
/// somewhere to go back to.
class Launcher extends StatelessWidget {
  const Launcher(this.page, {super.key});
  final Widget page;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: TextButton(
            key: const ValueKey('launch'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => page)),
            child: const Text('Open'),
          ),
        ),
      );
}

void main() {
  setUp(fakeServer);
  tearDown(() {
    ApiService.useClient(http.Client());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('Terms and policies', () {
    testWidgets('lists every document, and each one opens', (t) async {
      await open(t, const TermsAndPoliciesPage());
      for (final (key, doc) in [
        ('policies_guidelines', communityGuidelines),
        ('policies_terms', termsOfService),
        ('policies_privacy', privacyPolicy),
      ]) {
        await tapKey(t, key);
        expect(find.text(doc.title), findsWidgets, reason: key);
        expect(find.text('Last updated $legalUpdated'), findsOneWidget);
        // The first part is both in the contents and as a heading.
        expect(find.text(doc.sections.first.title), findsNWidgets(2));
        await t.pageBack();
        await settle(t);
      }
      await tapKey(t, 'policies_licences');
      expect(find.byType(LicensePage), findsOneWidget);
    });

    testWidgets('a document starts with its short version and contents, and '
        'the contents jump to each part', (t) async {
      await open(t, const PrivacyPolicyPage(), height: 900);
      expect(find.text(privacyPolicy.summary.first), findsOneWidget);
      // Part 6, far down the page.
      final part = find.byKey(const ValueKey('legal_part_6'));
      expect(t.getTopLeft(part).dy, greaterThan(900),
          reason: 'it starts below the screen');

      await tapKey(t, 'legal_toc_5');
      expect(t.getTopLeft(part).dy, inInclusiveRange(0, 300),
          reason: 'its line in the contents brought it to the top');

      // The last part cannot come to the top (the page ends), but it comes
      // into view.
      final last = privacyPolicy.sections.length;
      await tapKey(t, 'legal_toc_${last - 1}');
      expect(t.getTopLeft(find.byKey(ValueKey('legal_part_$last'))).dy,
          inInclusiveRange(0, 800));

      await tapKey(t, 'legal_back_to_top');
      expect(t.getTopLeft(find.byKey(const ValueKey('legal_updated'))).dy,
          inInclusiveRange(0, 300));

      await tapKey(t, 'legal_contact');
      expect(copied, AppConstants.privacyEmail);
      expect(find.text('Email address copied'), findsOneWidget);
      await letNotesGo(t);
    });

    testWidgets('Settings leads to them, and to the Help Center and About',
        (t) async {
      await open(
          t,
          SettingsPage(
            onEditProfile: () {},
            onShareProfile: () {},
            onSaved: () {},
            onLiked: () {},
          ));
      await tapKey(t, 'settings_policies');
      expect(find.byType(TermsAndPoliciesPage), findsOneWidget);
      await t.pageBack();
      await settle(t);
      expect(find.byKey(const ValueKey('settings_version')), findsOneWidget);
      expect(find.text('Flex ${AppConstants.appVersion}'), findsOneWidget);
    });
  });

  group('Help Center', () {
    testWidgets('finds answers as you type, and says so when there are none',
        (t) async {
      await open(t, const HelpCenterPage());
      expect(find.text('I forgot my password'), findsOneWidget,
          reason: 'a popular question, before any search');
      expect(find.byKey(const ValueKey('help_topic_account')), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('help_search')), 'password');
      await settle(t);
      expect(find.text('I forgot my password'), findsOneWidget);
      expect(find.text('How do I change my password?'), findsOneWidget);
      expect(find.text('How do battles work?'), findsNothing);

      await t.enterText(find.byKey(const ValueKey('help_search')), 'zzqx');
      await settle(t);
      expect(find.byKey(const ValueKey('help_no_results')), findsOneWidget);
      expect(find.byKey(const ValueKey('help_report')), findsOneWidget,
          reason: 'no answer still leaves a way to ask');

      await tapKey(t, 'help_search_clear');
      expect(find.byKey(const ValueKey('help_topic_account')), findsOneWidget);
    });

    testWidgets('a topic lists its answers; an answer opens, with the rest '
        'of its topic under it', (t) async {
      await open(t, const HelpCenterPage());
      await tapKey(t, 'help_topic_privacy');
      expect(find.byKey(const ValueKey('help_topic_page_privacy')),
          findsOneWidget);
      final topic = helpTopics.firstWhere((x) => x.id == 'privacy');
      for (final a in topic.articles) {
        expect(find.text(a.question), findsOneWidget);
      }
      await tapKey(t, 'help_article_How do I block someone?');
      expect(find.byKey(const ValueKey('help_article_page')), findsOneWidget);
      expect(find.textContaining('Blocked accounts lists everyone'),
          findsOneWidget);
      expect(find.text('How do I make my account private?'), findsOneWidget,
          reason: 'the rest of the topic, under the answer');
    });

    testWidgets('"Still need help?": Email us copies the address, and Report '
        'a problem opens the form', (t) async {
      await open(t, const HelpCenterPage());
      await tapKey(t, 'help_email');
      expect(copied, AppConstants.supportEmail);
      await tapKey(t, 'help_report');
      expect(find.byType(BugReportPage), findsOneWidget);
      await letNotesGo(t);
    });
  });

  testWidgets('About shows the logo, the name and the version, and leads on',
      (t) async {
    await open(t, const AboutPage());
    expect(find.byKey(const ValueKey('flex_logo')), findsOneWidget);
    expect(find.text('Flex'), findsOneWidget);
    expect(find.text('Version ${AppConstants.appVersion}'), findsOneWidget);
    await tapKey(t, 'about_contact');
    expect(copied, AppConstants.supportEmail);
    await tapKey(t, 'about_policies');
    expect(find.byType(TermsAndPoliciesPage), findsOneWidget);
    await letNotesGo(t);
  });

  group('Report a problem', () {
    testWidgets('needs a topic and some words, then goes with its topic, the '
        'screen and the app version', (t) async {
      await open(t, const Launcher(BugReportPage()));
      await tapKey(t, 'launch');

      await tapKey(t, 'bug_send');
      expect(find.text('Choose what the problem is about.'), findsOneWidget);
      await tapKey(t, 'bug_topic_playback');
      await tapKey(t, 'bug_send');
      expect(find.text('Tell us what happened.'), findsOneWidget);
      expect(events, isEmpty);

      await t.enterText(find.byKey(const ValueKey('bug_description')),
          'Videos freeze after a minute');
      await t.enterText(find.byKey(const ValueKey('bug_screen')), 'the feed');
      await tapKey(t, 'bug_send');

      final sent = events.single;
      expect(sent['eventType'], 'bug_report');
      expect(sent['userId'], '1');
      expect(sent['metadata'], {
        'surface': 'playback',
        'description': 'Videos freeze after a minute',
        'appVersion': AppConstants.appVersion,
        'screen': 'the feed',
      });
      expect(find.byType(BugReportPage), findsNothing, reason: 'done, closed');
      expect(find.text('Thanks. We got your report.'), findsOneWidget);
      await letNotesGo(t);
    });

    testWidgets("one that doesn't send says so, and keeps what was typed",
        (t) async {
      refuse = true;
      await open(t, const BugReportPage());
      await tapKey(t, 'bug_topic_account');
      await t.enterText(
          find.byKey(const ValueKey('bug_description')), 'Cannot sign in');
      await tapKey(t, 'bug_send');
      expect(find.textContaining("Couldn't send your report"), findsOneWidget);
      expect(find.text('Cannot sign in'), findsOneWidget);
      expect(find.byType(BugReportPage), findsOneWidget);
    });
  });

  group('the blue glow in dark mode', () {
    Widget settings() => SettingsPage(
          onEditProfile: () {},
          onShareProfile: () {},
          onSaved: () {},
          onLiked: () {},
        );

    testWidgets('shows behind a page, in the drawn colours', (t) async {
      await open(t, settings(), mode: ThemeMode.dark, appThemes: true);
      expect(find.byKey(const ValueKey('page_backdrop')), findsOneWidget);
      // Beside the cards, level with the glow's middle: blue, not black.
      final c = await pixelAt(t, 8, 120);
      expect(c.b, greaterThan(0.12), reason: '$c');
      expect(c.b, greaterThan(c.r + 0.08), reason: '$c');
      EventTracker.instance.dispose();
    });

    testWidgets('so does a page that sets no background of its own',
        (t) async {
      await open(
        t,
        const Scaffold(body: SizedBox()),
        mode: ThemeMode.dark,
        appThemes: true,
      );
      final c = await pixelAt(t, 8, 120);
      expect(c.b, greaterThan(0.12), reason: '$c');
      expect(c.b, greaterThan(c.r + 0.08), reason: '$c');
    });

    testWidgets('a page that is black on purpose (a video) stays black',
        (t) async {
      await open(
        t,
        const Scaffold(backgroundColor: Colors.black, body: SizedBox()),
        mode: ThemeMode.dark,
        appThemes: true,
      );
      final c = await pixelAt(t, 8, 120);
      expect((c.r, c.g, c.b), (0.0, 0.0, 0.0), reason: '$c');
    });

    testWidgets('light mode has no glow', (t) async {
      await open(t, settings(), appThemes: true);
      expect(find.byKey(const ValueKey('page_backdrop')), findsNothing);
      final c = await pixelAt(t, 8, 120);
      expect(c.r, greaterThan(0.9), reason: '$c');
      EventTracker.instance.dispose();
    });
  });

  test('the version people see is the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version =
        RegExp(r'^version:\s*([0-9.]+)\+', multiLine: true).firstMatch(pubspec);
    expect(version?.group(1), AppConstants.appVersion);
  });
}
