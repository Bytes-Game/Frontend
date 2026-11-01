// The app is called Flex, and its icons are the Flex logo, made from the
// logo's one drawing (lib/widgets/flex_logo.dart).
//
// The icons themselves are checked, not the code that makes them: the files
// a phone actually shows are read back and compared with the logo. A logo
// changed without remaking the icons (tool/make_app_icons_test.dart) fails
// here.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/flex_logo.dart';

const res = 'android/app/src/main/res';

/// Reads back the path text the logo writes for Android's vector files
/// (FlexMark.pathData: M, L, A and Z only).
Path readPathData(String d) {
  final path = Path();
  for (final m in RegExp(r'([MLAZ])([^MLAZ]*)').allMatches(d)) {
    final n = RegExp(r'-?\d+(?:\.\d+)?')
        .allMatches(m.group(2)!)
        .map((x) => double.parse(x.group(0)!))
        .toList();
    switch (m.group(1)) {
      case 'M':
        path.moveTo(n[0], n[1]);
      case 'L':
        path.lineTo(n[0], n[1]);
      case 'A':
        path.arcToPoint(Offset(n[5], n[6]),
            radius: Radius.elliptical(n[0], n[1]),
            rotation: n[2],
            largeArc: n[3] == 1,
            clockwise: n[4] == 1);
      case 'Z':
        path.close();
    }
  }
  return path;
}

/// Every pathData in an Android vector file, joined into one shape.
Path shapeIn(String file) {
  final xml = File(file).readAsStringSync();
  final shape = Path();
  for (final m in RegExp(r'android:pathData="([^"]+)"').allMatches(xml)) {
    if (m.group(1)!.startsWith('M0,0h108')) continue; // a background fill
    shape.addPath(readPathData(m.group(1)!), Offset.zero);
  }
  return shape;
}

/// How many points of a fine grid over a [side] × [side] canvas the two
/// shapes disagree about, and how many are inside [expected] at all.
(int, int) compare(Path actual, Path expected, double side) {
  var differ = 0, inside = 0;
  for (var y = 0.25; y < side; y += side / 200) {
    for (var x = 0.25; x < side; x += side / 200) {
      final p = Offset(x, y);
      final want = expected.contains(p);
      if (want) inside++;
      if (actual.contains(p) != want) differ++;
    }
  }
  return (differ, inside);
}

/// The logo's F, placed the way an icon of [scale] units per tile, starting
/// at [offset], places it.
Path logoAt(double scale, double offset) => FlexMark.path().transform(
    (Matrix4.identity()
          ..translateByDouble(offset, offset, 0, 1)
          ..scaleByDouble(scale / 100, scale / 100, 1, 1))
        .storage);

/// A PNG's pixels: width, height, and the colour at a point.
Future<(int, int, Color Function(double, double))> pixels(String file) async {
  final codec =
      await ui.instantiateImageCodec(File(file).readAsBytesSync());
  final image = (await codec.getNextFrame()).image;
  final data =
      (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final w = image.width, h = image.height;
  Color at(double fx, double fy) {
    final x = (fx * w).floor().clamp(0, w - 1);
    final y = (fy * h).floor().clamp(0, h - 1);
    final i = (y * w + x) * 4;
    return Color.fromARGB(data.getUint8(i + 3), data.getUint8(i),
        data.getUint8(i + 1), data.getUint8(i + 2));
  }

  return (w, h, at);
}

/// Where a point of the 100-unit tile lands on an icon, as a share of its
/// side, with the F drawn at its presence about the middle.
double onIcon(double u, {double markScale = 1}) =>
    (50 + (u - 50) * FlexMark.presence * markScale) / 100;

bool isWhite(Color c) => c.r > 0.94 && c.g > 0.94 && c.b > 0.94;
bool isBlue(Color c) => c.b > 0.75 && c.r < 0.35 && c.a > 0.99;

/// The PNG's colour type, from its header: 2 is colour without a
/// see-through layer, 6 is colour with one.
int pngColourType(String file) => File(file).readAsBytesSync()[25];

void main() {
  group('the name is Flex', () {
    test('under the icon on Android and iPhone, and on the web', () {
      expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
          contains('android:label="Flex"'));
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
          RegExp(r'<key>CFBundleDisplayName</key>\s*<string>Flex</string>')
              .hasMatch(plist),
          isTrue);
      expect(RegExp(r'<key>CFBundleName</key>\s*<string>Flex</string>')
          .hasMatch(plist), isTrue);
      final web = json.decode(File('web/manifest.json').readAsStringSync())
          as Map<String, dynamic>;
      expect(web['name'], 'Flex');
      expect(web['short_name'], 'Flex');
      expect(File('web/index.html').readAsStringSync(),
          contains('<title>Flex</title>'));
      expect(AppConstants.appName, 'Flex');
    });

    test('no screen says the old names', () {
      // Code only: comments are stripped, so a comment about the old name
      // can neither pass nor fail this.
      final said = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          if (line.startsWith('//')) continue;
          // Internal names a person never sees stay: file names (devf_…),
          // channels to the phone's own code (devf/…), links into the app
          // (devf://…), and the support addresses at devf.app.
          final visible = line
              .replaceAll(RegExp(r'devf_\w*'), '')
              .replaceAll(RegExp(r'devf/\w+'), '')
              .replaceAll(RegExp(r'devf://'), '')
              .replaceAll(RegExp(r'@devf\.app'), '')
              .replaceAll('media.devf.com', '');
          if (RegExp(r'\bdevf\b|Battle Arena|BattleArena', caseSensitive: false)
              .hasMatch(visible)) {
            said.add('${f.path}:${i + 1}: $line');
          }
        }
      }
      expect(said, isEmpty);
    });
  });

  group('the icons are the Flex logo', () {
    test("Android's own icon shape: the F, where the logo puts it", () {
      // The middle 72 of the 108 canvas shows; the tile's 100 units are
      // that 72, and the F is drawn bigger by its presence.
      const scale = 72 * FlexMark.presence;
      const offset = 54 - scale / 2;
      final want = logoAt(scale, offset);

      final (differ, inside) =
          compare(shapeIn('$res/drawable/ic_launcher_foreground.xml'), want, 108);
      expect(inside, greaterThan(2000), reason: 'the F is a real shape');
      expect(differ, lessThanOrEqualTo(3));

      final (mDiffer, _) =
          compare(shapeIn('$res/drawable/ic_launcher_monochrome.xml'), want, 108);
      expect(mDiffer, lessThanOrEqualTo(3));

      final adaptive =
          File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      for (final layer in [
        'ic_launcher_background',
        'ic_launcher_foreground',
        'ic_launcher_monochrome',
      ]) {
        expect(adaptive, contains('@drawable/$layer'));
        expect(File('$res/drawable/$layer.xml').existsSync(), isTrue);
      }
      expect(File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
          contains('android:icon="@mipmap/ic_launcher"'));
      expect(File('$res/drawable/ic_launcher_background.xml').readAsStringSync(),
          contains('#FF0A84FF'),
          reason: "the tile is the app's blue");
    });

    test('the notification mark is the F too', () {
      final bounds = FlexMark.path().getBounds();
      final scale = 20 / bounds.height * 100;
      final shape = shapeIn('$res/drawable/ic_notification.xml');
      final got = shape.getBounds();
      expect(got.height, closeTo(20, 0.05));
      expect(got.center.dx, closeTo(12, 0.05));
      expect(got.center.dy, closeTo(12, 0.05));
      final want = FlexMark.path().transform((Matrix4.identity()
            ..translateByDouble(12 - bounds.center.dx * scale / 100,
                12 - bounds.center.dy * scale / 100, 0, 1)
            ..scaleByDouble(scale / 100, scale / 100, 1, 1))
          .storage);
      final (differ, inside) = compare(shape, want, 24);
      expect(inside, greaterThan(2000));
      expect(differ, lessThanOrEqualTo(3));
    });

    test('the picture icons: a white F on the blue, every size', () async {
      final files = <String, int>{
        '$res/mipmap-mdpi/ic_launcher.png': 48,
        '$res/mipmap-xxxhdpi/ic_launcher.png': 192,
        'web/icons/Icon-512.png': 512,
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png':
            1024,
      };
      final ios = json.decode(File(
                  'ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json')
              .readAsStringSync())['images'] as List;
      for (final i in ios) {
        final side = double.parse('${i['size']}'.split('x').first) *
            int.parse('${i['scale']}'.replaceAll('x', ''));
        files['ios/Runner/Assets.xcassets/AppIcon.appiconset/${i['filename']}'] =
            side.round();
      }
      for (final e in files.entries) {
        final (w, h, at) = await pixels(e.key);
        expect((w, h), (e.value, e.value), reason: e.key);
        if (e.value < 40) continue; // too small to point into the stem
        // Inside the stem, under the top arm: white.
        expect(isWhite(at(onIcon(38.5), onIcon(60))), isTrue,
            reason: '${e.key}: the F');
        // Between the arm and the play button, right of the stem: blue.
        expect(isBlue(at(onIcon(60), onIcon(43.5))), isTrue,
            reason: '${e.key}: the tile');
      }
    });

    test('the iPhone icons have no see-through layer (the App Store refuses '
        'them)', () {
      final dir = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
      final pngs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList();
      expect(pngs.length, greaterThanOrEqualTo(15));
      for (final f in pngs) {
        expect(pngColourType(f.path), 2, reason: f.path);
      }
    });
  });

  testWidgets('the sign-in screen shows the logo and the name', (t) async {
    FlutterSecureStorage.setMockInitialValues({});
    EventTracker.instance.dispose();
    await t.binding.setSurfaceSize(const Size(430, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => DataProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('flex_logo')), findsOneWidget);
    expect(find.text('Flex'), findsOneWidget);
  });
}
