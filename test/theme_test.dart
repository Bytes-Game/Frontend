// The app's look: dark until the person picks otherwise, and one
// blue everywhere, in both modes.
//
// Through the real app root, the real sign-in and the real Appearance page;
// the colour checks read the real themes and the real files the phones use.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/main.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/preferences_pages.dart';
import 'package:myapp/pages/settings_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/widgets/flexete_logo.dart';

/// What the stand-in server answers /login with: an account whose
/// settings are [settings].
void serverSigningIn(Map<String, dynamic> settings) {
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/login')) {
      return http.Response(
          json.encode({
            'token': 'tok',
            'user': {
              'id': '7',
              'username': 'maya',
              'followingList': <String>[],
              'settings': settings,
            },
          }),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path.endsWith('/api/v1/users')) return http.Response('[]', 200);
    return http.Response('{}', 200,
        headers: {'content-type': 'application/json'});
  }));
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Signs in as maya through the real sign-in screen, with [theme] showing
/// beforehand (the last person on this phone's pick).
Future<ThemeProvider> signInAfter(WidgetTester t, ThemeMode theme) async {
  FlutterSecureStorage.setMockInitialValues({});
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(430, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final tp = ThemeProvider()..setThemeMode(theme);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => DataProvider()),
      ChangeNotifierProvider.value(value: tp),
    ],
    child: const MaterialApp(home: LoginScreen()),
  ));
  await settle(t);
  await t.enterText(find.byKey(const ValueKey('login_username')), 'maya');
  await t.enterText(find.byKey(const ValueKey('login_password')), 'sunset42');
  await t.tap(find.byKey(const ValueKey('login_submit')));
  await settle(t);
  EventTracker.instance.dispose();
  return tp;
}

/// Opens Settings → Appearance for an account whose settings are
/// [settings].
Future<ThemeProvider> openAppearance(
    WidgetTester t, Map<String, dynamic> settings) async {
  FlutterSecureStorage.setMockInitialValues({});
  ApiService.useClient(MockClient((req) async => http.Response(
      json.encode({'id': '7', 'username': 'maya', 'settings': settings}), 200,
      headers: {'content-type': 'application/json'})));
  final dp = DataProvider()
    ..setUser(UserModel.fromJson(
        {'id': '7', 'username': 'maya', 'settings': settings}));
  EventTracker.instance.dispose();
  final tp = ThemeProvider();
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: dp),
      ChangeNotifierProvider.value(value: tp),
    ],
    child: const MaterialApp(home: AppearancePage()),
  ));
  await settle(t);
  return tp;
}

/// Which option Appearance shows ticked.
String ticked(WidgetTester t) => t
    .widgetList<RadioListTile<String>>(find.byType(RadioListTile<String>))
    // ignore: deprecated_member_use
    .where((r) => r.value == r.groupValue)
    .single
    .value;

double _channel(double c) => c <= 0.04045
    ? c / 12.92
    : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

/// The WCAG contrast between two colours: 4.5 is what small text needs.
double contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

String hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// A source file without its comment lines, so a test reads the code and
/// never the words explaining it.
String codeOf(File f) => f
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  tearDown(() => ApiService.useClient(http.Client()));

  group('dark until the person picks otherwise', () {
    testWidgets('a new install opens dark, through the real app', (t) async {
      FlutterSecureStorage.setMockInitialValues({});
      await t.pumpWidget(const MyApp());
      await settle(t);
      expect(find.byType(LoginScreen), findsOneWidget,
          reason: 'nobody signed in on a new install');
      final context = t.element(find.byType(LoginScreen));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(Provider.of<ThemeProvider>(context, listen: false).themeMode,
          ThemeMode.dark);
    });

    test('nothing stored, or something unknown, is dark', () {
      expect(ThemeProvider().themeMode, ThemeMode.dark);
      expect(ThemeProvider.modeFor(null), ThemeMode.dark);
      expect(ThemeProvider.modeFor('sepia'), ThemeMode.dark);
      expect(ThemeProvider.modeFor('light'), ThemeMode.light);
      expect(ThemeProvider.modeFor('system'), ThemeMode.system);
      expect(ThemeProvider.modeFor('dark'), ThemeMode.dark);
    });

    testWidgets(
        'an account that never picked signs in dark, even after somebody '
        'who picked light', (t) async {
      serverSigningIn(const {});
      final tp = await signInAfter(t, ThemeMode.light);
      expect(tp.themeMode, ThemeMode.dark);
    });

    testWidgets("an account that picked light keeps light at every sign-in",
        (t) async {
      serverSigningIn(const {'theme': 'light'});
      final tp = await signInAfter(t, ThemeMode.dark);
      expect(tp.themeMode, ThemeMode.light);
    });

    testWidgets(
        'a pick comes back every time the app opens with a saved login, '
        'before the server has answered', (t) async {
      // The everyday way in: already signed in, the app opens on the login
      // kept on the phone. Light was picked on an earlier day.
      FlutterSecureStorage.setMockInitialValues({
        'session_v1': json.encode({
          'token': 'kept-token',
          'user': {
            'id': '7',
            'username': 'maya',
            'followingList': <String>[],
            'settings': {'theme': 'light'},
          },
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      });
      SessionStore.resetForTest();
      final renew = Completer<http.Response>();
      ApiService.useClient(MockClient((req) async =>
          req.url.path.endsWith('/auth/refresh')
              ? renew.future
              : http.Response('', 503)));
      final auth = AuthProvider();
      final tp = ThemeProvider();
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider(create: (_) => DataProvider()),
          ChangeNotifierProvider.value(value: tp),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => auth.restoreSession(context),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      expect(tp.themeMode, ThemeMode.dark, reason: 'before it is read');

      await t.tap(find.text('open'));
      await settle(t);
      EventTracker.instance.dispose();
      expect(auth.isAuthenticated, isTrue);
      expect(renew.isCompleted, isFalse, reason: 'the server has not answered');
      expect(tp.themeMode, ThemeMode.light);

      renew.complete(http.Response(json.encode({'token': 'fresh'}), 200));
      await settle(t);
      ApiService.clearAuth();
    });

    testWidgets('Settings says what the app shows next to Appearance',
        (t) async {
      await t.binding.setSurfaceSize(const Size(430, 2200));
      addTearDown(() => t.binding.setSurfaceSize(null));
      FlutterSecureStorage.setMockInitialValues({});
      ApiService.useClient(MockClient((req) async => http.Response('{}', 200,
          headers: {'content-type': 'application/json'})));
      const said = <String, (Map<String, dynamic>, String)>{
        'nothing picked': ({}, 'Dark'),
        'Match system': ({'theme': 'system'}, 'Automatic'),
        'Light': ({'theme': 'light'}, 'Light'),
      };
      for (final MapEntry(key: why, value: (settings, label)) in said.entries) {
        final dp = DataProvider()
          ..setUser(UserModel.fromJson(
              {'id': '7', 'username': 'maya', 'settings': settings}));
        EventTracker.instance.dispose();
        await t.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider.value(value: dp),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ],
          child: MaterialApp(
            home: SettingsPage(
              onEditProfile: () {},
              onShareProfile: () {},
              onSaved: () {},
              onLiked: () {},
            ),
          ),
        ));
        await settle(t);
        expect(
            find.descendant(
                of: find.byKey(const ValueKey('settings_appearance')),
                matching: find.text(label)),
            findsOneWidget,
            reason: why);
      }
      EventTracker.instance.dispose();
    });

    testWidgets('Appearance ticks Dark when nothing was picked', (t) async {
      await openAppearance(t, const {});
      expect(ticked(t), 'dark');
    });

    testWidgets('Appearance ticks what was picked, and a new pick shows at '
        'once', (t) async {
      final tp = await openAppearance(t, const {'theme': 'system'});
      expect(ticked(t), 'system');
      await t.tap(find.text('Light'));
      await settle(t);
      expect(ticked(t), 'light');
      expect(tp.themeMode, ThemeMode.light);
    });
  });

  group('one blue everywhere', () {
    test('the same colour leads both themes', () {
      expect(AppTheme.primary, const Color(0xFF2F6AFF));
      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        expect(theme.colorScheme.primary, AppTheme.primary);
        expect(
            theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
            AppTheme.primary);
        expect(theme.textButtonTheme.style!.foregroundColor!.resolve({}),
            AppTheme.primary);
        expect(theme.progressIndicatorTheme.color, AppTheme.primary);
      }
    });

    test('it reads on white, on black, and under white letters', () {
      const white = Color(0xFFFFFFFF), black = Color(0xFF000000);
      expect(contrast(white, AppTheme.primary), greaterThanOrEqualTo(4.5),
          reason: 'white words on a button');
      expect(contrast(AppTheme.primary, black), greaterThanOrEqualTo(4.5),
          reason: 'a link in dark mode');
      // The first blue, for comparison: under 4.5.
      expect(contrast(white, const Color(0xFF0A84FF)), lessThan(4.5));
    });

    test('it is blue with a touch of violet: not the first blue, not violet',
        () {
      // The shade on the colour wheel, in degrees: the first blue sat at
      // 210, the violet at 238. This one is a little way from the blue
      // towards violet, and well short of it.
      double shade(Color c) => HSVColor.fromColor(c).hue;
      expect(shade(AppTheme.primary), inInclusiveRange(218, 228));
      expect(shade(const Color(0xFF0A84FF)), lessThan(218),
          reason: 'the first blue');
      expect(shade(const Color(0xFF6064F0)), greaterThan(228),
          reason: 'the violet');
    });

    test('neither old colour is left in the app: the first blue or the '
        'violet', () {
      // The old shades, written out, anywhere in the app's code: the first
      // blue's family, then the violet's.
      final old = RegExp(
          r'0A84FF|64D2FF|0071E3|0B3D73|051425|0B1A2E|061322|3DA5FF|0050D0|'
          r'A5E3FF|8DA2BD|E5EAF2|F2F4F8|00337F|Colors\.(blue|lightBlue|cyan|'
          r'indigo)\b|'
          r'6064F0|3A3FDF|9C9DFC|2B2E82|0B0C2D|101030|8E8EBE|1B1E80|DEDFFF|'
          r'F0F0FF|E4E4F4|7478FB|2F34C6|C2C4FF',
          caseSensitive: false);
      final found = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final code = codeOf(f);
        for (final m in old.allMatches(code)) {
          found.add('${f.path}: ${m.group(0)}');
        }
      }
      expect(found, isEmpty);
    });

    test("the phones' own colours are the same blue", () {
      final want = hex(AppTheme.primary);
      expect(want, '#2F6AFF');
      expect(
          File('android/app/src/main/res/values/colors.xml').readAsStringSync(),
          contains('<color name="notification_accent">$want</color>'),
          reason: 'the tint on Android notifications');
      final manifest = json.decode(File('web/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(manifest['theme_color'], want);
      expect(FlexeteMark.tileColors[1], AppTheme.primary,
          reason: "the icon's middle colour is the app's");
    });

    test('an iPhone opens on black, like the app it opens into', () {
      final launch = File('ios/Runner/Base.lproj/LaunchScreen.storyboard')
          .readAsStringSync();
      expect(
          launch,
          contains('<color key="backgroundColor" red="0" green="0" blue="0" '
              'alpha="1"'));
    });
  });
}
