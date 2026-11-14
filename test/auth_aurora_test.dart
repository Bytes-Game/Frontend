// The light behind the sign-in screens.
//
// The sign-in, sign-up, forgot-password, two-step and "ask a parent"
// screens have soft blue glows behind them. They used to stand still. Now
// they drift slowly, like an aurora: the first thing a new person sees is
// a screen that is alive.
//
// What must stay true, and is checked here: only light moves; it is never
// brighter than before, so the words stay easy to read; it loops with no
// jump; a phone set to reduce motion gets it standing still; and what is
// on top of it still takes taps.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/social_auth.dart';
import 'package:myapp/widgets/auth_widgets.dart';

int taps = 0;

/// A phone and build that offer "Continue with Google".
class _GoogleOffered implements SocialAuth {
  @override
  bool offers(SocialProvider provider) => provider == SocialProvider.google;

  @override
  Future<SocialCredential?> signIn(SocialProvider provider) async => null;
}

Future<void> show(WidgetTester t, {bool reduceMotion = false}) async {
  taps = 0;
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: AuthBackdrop(
              child: Center(
                child: FilledButton(
                  key: const ValueKey('on_top'),
                  onPressed: () => taps++,
                  child: const Text('Sign in'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

AuroraPainter painterOf(WidgetTester t) =>
    t.widget<CustomPaint>(find.byKey(const ValueKey('auth_aurora'))).painter!
        as AuroraPainter;

/// How much light the glows add at one spot of a page, 0 to 1: each glow
/// is strongest at its middle and fades evenly to nothing at its edge.
double lightAt(Offset spot, Size page, double t, {required bool dark}) {
  var dim = 1.0;
  for (final g in AuroraPainter.glowsAt(t)) {
    final reach = g.radius * page.shortestSide;
    final far = (spot - g.at.alongSize(page)).distance;
    if (far >= reach) continue;
    dim *= 1 - AuroraPainter.peak(dark) * g.strength * (1 - far / reach);
  }
  return 1 - dim;
}

void main() {
  testWidgets('the light moves: a few seconds later every glow is somewhere '
      'else, and the page keeps drawing by itself', (t) async {
    await show(t);
    final before = painterOf(t).drift.value;
    await t.pump(const Duration(seconds: 3));
    final after = painterOf(t).drift.value;

    expect(after, greaterThan(before));
    // Three seconds of a 24-second round.
    expect(after - before, closeTo(3 / 24, 0.01));
    expect(t.binding.hasScheduledFrame, isTrue, reason: 'still moving');

    final was = AuroraPainter.glowsAt(before);
    final now = AuroraPainter.glowsAt(after);
    expect(now, hasLength(3));
    for (var i = 0; i < now.length; i++) {
      expect(
        (now[i].at.x - was[i].at.x).abs() + (now[i].at.y - was[i].at.y).abs(),
        greaterThan(0.02),
        reason: 'glow $i has not moved',
      );
    }
  });

  test('once round, every glow is back where it began, and it never '
      'jumps on the way', () {
    final start = AuroraPainter.glowsAt(0);
    final end = AuroraPainter.glowsAt(1);
    for (var i = 0; i < start.length; i++) {
      expect(end[i].at.x, closeTo(start[i].at.x, 1e-9));
      expect(end[i].at.y, closeTo(start[i].at.y, 1e-9));
      expect(end[i].radius, start[i].radius);
      expect(end[i].strength, start[i].strength);
    }
    // A tenth of a second at a time, all the way round: no glow moves
    // more than a sliver of the page between two looks.
    const steps = 240;
    for (var s = 0; s < steps; s++) {
      final a = AuroraPainter.glowsAt(s / steps);
      final b = AuroraPainter.glowsAt((s + 1) / steps);
      for (var i = 0; i < a.length; i++) {
        final moved = math.sqrt(
          math.pow(a[i].at.x - b[i].at.x, 2) +
              math.pow(a[i].at.y - b[i].at.y, 2),
        );
        expect(moved, lessThan(0.02), reason: 'glow $i jumped at step $s');
      }
    }
  });

  test('only light: nowhere on the page, at any moment, is it brighter '
      'than the one still glow it took the place of', () {
    const page = Size(400, 860);
    for (final dark in [true, false]) {
      // The still glow added this much at its brightest.
      final allowed = dark ? 0.16 : 0.18;
      var brightest = 0.0;
      for (var s = 0; s <= 48; s++) {
        for (var x = 0.0; x <= page.width; x += 20) {
          for (var y = 0.0; y <= page.height; y += 20) {
            brightest = math.max(
              brightest,
              lightAt(Offset(x, y), page, s / 48, dark: dark),
            );
          }
        }
      }
      expect(brightest, greaterThan(0.05), reason: 'there is light to see');
      expect(
        brightest,
        lessThanOrEqualTo(allowed + 0.001),
        reason: 'brighter than before would dim the words over it',
      );
    }
  });

  testWidgets('a phone set to reduce motion gets the same glows, standing '
      'still', (t) async {
    await show(t, reduceMotion: true);
    expect(find.byKey(const ValueKey('auth_aurora')), findsOneWidget);
    final before = painterOf(t).drift.value;
    await t.pump(const Duration(seconds: 5));
    expect(painterOf(t).drift.value, before);
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'nothing is moving');
  });

  testWidgets('what is on top of the light still takes taps, and shows', (
    t,
  ) async {
    await show(t);
    expect(find.text('Sign in'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('on_top')));
    await t.pump(const Duration(milliseconds: 100));
    expect(taps, 1);
  });

  testWidgets('when the screen goes, the light stops with it', (t) async {
    await show(t);
    await t.pump(const Duration(seconds: 1));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 1));
    expect(t.binding.hasScheduledFrame, isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('the big buttons on the sign-in screen are written in the '
      "app's own lettering, like every other word on it", (t) async {
    // A phone and build that offer Google, so its button is there too.
    final real = SocialAuth.instance;
    SocialAuth.instance = _GoogleOffered();
    addTearDown(() => SocialAuth.instance = real);
    FlutterSecureStorage.setMockInitialValues({});
    EventTracker.instance.dispose();
    ApiService.useClient(MockClient((_) async => http.Response('{}', 200)));
    addTearDown(() => ApiService.useClient(http.Client()));
    await t.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => DataProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: const LoginScreen(),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));

    /// The font a piece of text on screen is drawn in.
    String? fontOf(String words) {
      final text = find.text(words);
      expect(text, findsOneWidget, reason: '"\$words" is not on the screen');
      final widget = t.widget<Text>(text);
      return widget.style?.fontFamily ??
          DefaultTextStyle.of(t.element(text)).style.fontFamily;
    }

    // What the rest of the page is written in.
    final pageFont = fontOf('Welcome back');
    expect(pageFont, isNotNull);
    expect(pageFont, startsWith('Inter'));
    // A button's label used to have no font named at all, so the phone
    // drew it in its own default one.
    for (final label in [
      'Sign in',
      'Create new account',
      'Continue with Google',
    ]) {
      expect(
        fontOf(label),
        startsWith('Inter'),
        reason: 'the "\$label" button is not in the app\'s lettering',
      );
    }
  });

  testWidgets('the real sign-in screen has it, moving', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    EventTracker.instance.dispose();
    ApiService.useClient(MockClient((_) async => http.Response('{}', 200)));
    addTearDown(() => ApiService.useClient(http.Client()));
    await t.binding.setSurfaceSize(const Size(400, 860));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => DataProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('auth_aurora')), findsOneWidget);
    final before = painterOf(t).drift.value;
    await t.pump(const Duration(seconds: 2));
    expect(painterOf(t).drift.value, greaterThan(before));
    // The form is still there on top of it.
    expect(find.byType(TextField), findsWidgets);
  });
}
