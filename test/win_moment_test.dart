// The moment a battle is won: a burst of light, and a trophy that flips
// over in 3D and lands facing you.
//
// What must stay true, and is checked here: it really turns in 3D and
// ends facing front; the light reaches out and then fades; it takes
// itself away; it never takes a tap from the page under it; a battle is
// celebrated once; and a phone set to reduce motion gets the trophy and
// the words standing still.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/celebrated_wins.dart';
import 'package:myapp/widgets/win_moment.dart';

int taps = 0;
bool? played;

/// A page with one button in the middle of it. [celebrate] plays the
/// moment over it.
///
/// [reduceMotion] is the phone's own setting, set the way a phone sets
/// it: for the whole app. The moment is drawn above the page, so a
/// setting given to the page alone would not reach it.
Future<void> show(WidgetTester t, {bool reduceMotion = false}) async {
  taps = 0;
  played = null;
  if (reduceMotion) {
    t.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('under'),
            onPressed: () => taps++,
            child: const Text('Vote'),
          ),
        ),
      ),
    ),
  );
}

Future<void> celebrate(WidgetTester t, {String battle = '7'}) async {
  played = await WinMoment.celebrate(
    t.element(find.byKey(const ValueKey('under'))),
    battleId: battle,
    detail: 'Against leo, 6 votes to 3.',
  );
}

/// How the trophy is turned right now.
Matrix4 trophy(WidgetTester t) =>
    t.widget<Transform>(find.byKey(const ValueKey('win_trophy'))).transform;

WinBurstPainter burst(WidgetTester t) =>
    t.widget<CustomPaint>(find.byKey(const ValueKey('win_burst'))).painter!
        as WinBurstPainter;

void main() {
  // The phone's own storage, empty: no win has been celebrated yet.
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await CelebratedWins.resetForTest();
  });

  testWidgets('the trophy flips in 3D and lands facing front, the light '
      'bursts out and fades, and then it takes itself away', (t) async {
    await show(t);
    await celebrate(t);
    expect(played, isTrue);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(find.byType(WinMoment), findsOneWidget);
    expect(find.text('You won!'), findsOneWidget);
    expect(find.text('Against leo, 6 votes to 3.'), findsOneWidget);
    // Mid-flip. 3D: the far edge is drawn smaller than the near one,
    // which is what the number in the matrix's third row does...
    final turning = trophy(t);
    expect(turning.entry(3, 2), isNot(0));
    // ...and it is turned away from the front.
    final turned = WinMoment.turnAt(300 / WinMoment.length.inMilliseconds);
    expect(turned, greaterThan(math.pi / 2));
    expect(turning.entry(0, 0), isNot(closeTo(turning.entry(1, 1), 1e-6)));
    // The light is on its way out.
    expect(burst(t).reach, greaterThan(0.3));
    expect(burst(t).fade, 1);

    // Landed: facing front, as wide as it is tall.
    await t.pump(const Duration(milliseconds: 1100));
    final front = trophy(t);
    expect(front.entry(0, 0), closeTo(front.entry(1, 1), 1e-6));
    expect(front.entry(0, 2), closeTo(0, 1e-6));
    expect(burst(t).reach, 1);

    // The light fades before the end.
    await t.pump(const Duration(milliseconds: 900));
    expect(burst(t).fade, lessThan(0.2));

    // And then it is gone, with nothing left running.
    await t.pump(const Duration(milliseconds: 500));
    await t.pump();
    expect(find.byType(WinMoment), findsNothing);
    expect(find.text('You won!'), findsNothing);
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  testWidgets("the words are in the app's own lettering, though no theme "
      'reaches them above the page', (t) async {
    await show(t);
    await celebrate(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 900));
    for (final words in ['You won!', 'Against leo, 6 votes to 3.']) {
      final style = t.widget<Text>(find.text(words)).style;
      expect(
        style?.fontFamily,
        startsWith('Inter'),
        reason: '"$words" would be drawn in the phone\'s default font',
      );
      // And never with the yellow lines Flutter draws under text that
      // has no page around it.
      expect(style?.decoration, TextDecoration.none);
    }
    await t.pumpAndSettle();
  });

  test('the turn: one and a half times round, fast first, and not a hair '
      'past the front', () {
    expect(WinMoment.turnAt(0), closeTo(1.5 * 2 * math.pi, 1e-9));
    expect(WinMoment.turnAt(WinMoment.landed), 0);
    expect(WinMoment.turnAt(1), 0);
    // Always slowing towards the front, never turning back.
    var last = WinMoment.turnAt(0);
    var firstStep = 0.0, lastStep = 0.0;
    for (var i = 1; i <= 50; i++) {
      final now = WinMoment.turnAt(i / 100);
      expect(now, lessThanOrEqualTo(last));
      if (i == 1) firstStep = last - now;
      if (i == 50) lastStep = last - now;
      last = now;
    }
    expect(firstStep, greaterThan(lastStep * 5), reason: 'fast, then slow');
  });

  testWidgets('it never takes a tap: the page under it works while it '
      'plays', (t) async {
    await show(t);
    await celebrate(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(WinMoment), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('under')), warnIfMissed: true);
    await t.pump();
    expect(taps, 1);
    await t.pumpAndSettle();
  });

  testWidgets('a battle is celebrated once; another battle gets its own', (
    t,
  ) async {
    await show(t);
    await celebrate(t);
    expect(played, isTrue);
    await t.pumpAndSettle();
    expect(find.byType(WinMoment), findsNothing);

    await celebrate(t);
    expect(played, isFalse, reason: 'the same battle again');
    await t.pump();
    expect(find.byType(WinMoment), findsNothing);

    await celebrate(t, battle: '8');
    expect(played, isTrue);
    await t.pump();
    expect(find.byType(WinMoment), findsOneWidget);
    await t.pumpAndSettle();
  });

  testWidgets('closing the app and opening it again does not bring an old '
      'win back: the phone remembers', (t) async {
    await show(t);
    await celebrate(t);
    expect(played, isTrue);
    await t.pumpAndSettle();

    // The app is closed: what was in memory is gone, what was written
    // down is not.
    await CelebratedWins.resetForTest();
    await celebrate(t);
    expect(played, isFalse);
    await t.pump();
    expect(find.byType(WinMoment), findsNothing);
  });

  testWidgets('a phone whose storage cannot be used still celebrates, once '
      'for as long as the app is open', (t) async {
    // No storage at all: every read and write throws.
    FlutterSecureStoragePlatform.instance = _BrokenStorage();
    await CelebratedWins.resetForTest();
    await show(t);
    await celebrate(t);
    expect(played, isTrue);
    await t.pump();
    expect(find.byType(WinMoment), findsOneWidget);
    await t.pumpAndSettle();
    await celebrate(t);
    expect(played, isFalse);
  });

  test(
    'the phone remembers the last 200 wins, and lets the oldest go',
    () async {
      for (var i = 0; i < CelebratedWins.kept + 5; i++) {
        expect(await CelebratedWins.firstTime('b$i'), isTrue);
      }
      // As after closing and opening the app: read from what was written.
      await CelebratedWins.resetForTest();
      expect(await CelebratedWins.firstTime('b204'), isFalse, reason: 'newest');
      expect(await CelebratedWins.firstTime('b5'), isFalse, reason: 'kept');
      expect(await CelebratedWins.firstTime('b4'), isTrue, reason: 'let go');
      // And a battle with no id is never "a first time".
      expect(await CelebratedWins.firstTime(''), isFalse);
    },
  );

  testWidgets('a phone set to reduce motion: the trophy and the words, '
      'with no flip and no burst, and it still goes away', (t) async {
    await show(t, reduceMotion: true);
    await celebrate(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    expect(find.text('You won!'), findsOneWidget);
    expect(find.byKey(const ValueKey('win_burst')), findsNothing);
    final still = trophy(t);
    expect(still.entry(0, 0), closeTo(1, 1e-6));
    expect(still.entry(1, 1), closeTo(1, 1e-6));
    expect(still.entry(0, 2), closeTo(0, 1e-6));

    await t.pumpAndSettle();
    expect(find.byType(WinMoment), findsNothing);
  });

  testWidgets('leaving the page in the middle of it leaves nothing '
      'running', (t) async {
    await show(t);
    await celebrate(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}

/// A phone whose secure storage fails every time it is asked.
class _BrokenStorage extends FlutterSecureStoragePlatform {
  Never _fail() => throw StateError('the keystore is not there');

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _fail();

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => _fail();

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _fail();
}
