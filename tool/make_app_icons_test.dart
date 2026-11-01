// Makes every app icon from the logo's one drawing (lib/widgets/flex_logo.dart).
//
// Run it after changing the logo:
//
//     flutter test tool/make_app_icons_test.dart
//
// It writes the icons straight into android/, ios/, web/, macos/ and
// windows/. It sits in tool/, not test/, so the normal test run never
// rewrites them. test/app_icon_test.dart checks the icons in the repo still
// match the logo, so a logo changed without running this goes red.
//
// It needs ImageMagick's `convert` for two last steps: taking the
// see-through layer out of the iPhone icons (the App Store refuses icons
// that have one) and putting the Windows icon together. Without it, it
// says what to run.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/widgets/flex_logo.dart';

Future<void> _png(String path, int px, FlexLogoPainter painter) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size.square(px.toDouble()));
  final image = await recorder.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
}

void _text(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

const _res = 'android/app/src/main/res';
const _made = '<!-- Made by tool/make_app_icons_test.dart from the logo in\n'
    '     lib/widgets/flex_logo.dart. Change the logo there and run that;\n'
    '     do not edit this by hand. -->';

void main() {
  test('make the app icons', () async {
    // ── Android 8 and later: the phone's own icon shape ────────────────
    // Three layers on a 108 × 108 canvas, of which the middle 72 × 72 shows.
    // The tile's 100 units are that 72; the F is drawn bigger by its
    // presence, about the middle.
    const shown = 72.0, edge = (108 - shown) / 2;
    const fScale = shown * FlexMark.presence;
    const fOffset = edge + shown / 2 - fScale / 2;
    final play = FlexMark.playButton().getBounds();
    double at(double u) => fOffset + u * fScale / 100;

    _text('$_res/drawable/ic_launcher_background.xml', '''
<?xml version="1.0" encoding="utf-8"?>
$_made
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="$edge"
                android:startY="$edge"
                android:endX="${edge + shown}"
                android:endY="${edge + shown}">
                <item android:offset="0" android:color="${_hex(FlexMark.tileColors[0])}" />
                <item android:offset="0.48" android:color="${_hex(FlexMark.tileColors[1])}" />
                <item android:offset="1" android:color="${_hex(FlexMark.tileColors[2])}" />
            </gradient>
        </aapt:attr>
    </path>
    <!-- Light from the top-left, so the tile has depth. -->
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="radial"
                android:centerX="${(edge + shown * 0.125).toStringAsFixed(1)}"
                android:centerY="${(edge + shown * 0.025).toStringAsFixed(1)}"
                android:gradientRadius="${(shown * 1.1).toStringAsFixed(1)}">
                <item android:offset="0" android:color="#38FFFFFF" />
                <item android:offset="1" android:color="#00FFFFFF" />
            </gradient>
        </aapt:attr>
    </path>
</vector>
''');

    _text('$_res/drawable/ic_launcher_foreground.xml', '''
<?xml version="1.0" encoding="utf-8"?>
$_made
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- The play button: white, fading to light blue at its tip. -->
    <path android:pathData="${FlexMark.pathData(scale: fScale, dx: fOffset, dy: fOffset, frame: false)}">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="${at(play.left).toStringAsFixed(3)}"
                android:startY="${at(play.center.dy).toStringAsFixed(3)}"
                android:endX="${at(play.right).toStringAsFixed(3)}"
                android:endY="${at(play.center.dy).toStringAsFixed(3)}">
                <item android:offset="0" android:color="#FFFFFFFF" />
                <item android:offset="1" android:color="${_hex(FlexMark.playTip)}" />
            </gradient>
        </aapt:attr>
    </path>
    <!-- The stem and top arm of the F. -->
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="${FlexMark.pathData(scale: fScale, dx: fOffset, dy: fOffset, play: false)}" />
</vector>
''');

    // Android 13's themed icons: the F alone, which the phone colours.
    _text('$_res/drawable/ic_launcher_monochrome.xml', '''
<?xml version="1.0" encoding="utf-8"?>
$_made
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="${FlexMark.pathData(scale: fScale, dx: fOffset, dy: fOffset)}" />
</vector>
''');

    _text('$_res/mipmap-anydpi-v26/ic_launcher.xml', '''
<?xml version="1.0" encoding="utf-8"?>
$_made
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''');

    // The small mark at the top of every notification: the F alone, 20 of
    // its 24 units tall. Android shows it white, or tinted the app's blue.
    final bounds = FlexMark.path().getBounds();
    final nScale = 20 / bounds.height * 100;
    final nx = 12 - bounds.center.dx * nScale / 100;
    final ny = 12 - bounds.center.dy * nScale / 100;
    _text('$_res/drawable/ic_notification.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<!-- The small mark at the top of every notification from the app: the
     Flex F, with its play button. Android shows it white (or tinted with
     the app's blue), so only its shape matters. -->
$_made
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="${FlexMark.pathData(scale: nScale, dx: nx, dy: ny)}" />
</vector>
''');

    // ── Android before 8: a rounded square, as the launcher shows it ────
    const android = {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    };
    for (final e in android.entries) {
      await _png('$_res/mipmap-${e.key}/ic_launcher.png', e.value,
          const FlexLogoPainter(tileRadius: 0.22));
    }

    // ── iPhone and iPad: plain squares. iOS rounds the corners itself ───
    const iosDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
    const ios = {
      'Icon-App-20x20@1x.png': 20,
      'Icon-App-20x20@2x.png': 40,
      'Icon-App-20x20@3x.png': 60,
      'Icon-App-29x29@1x.png': 29,
      'Icon-App-29x29@2x.png': 58,
      'Icon-App-29x29@3x.png': 87,
      'Icon-App-40x40@1x.png': 40,
      'Icon-App-40x40@2x.png': 80,
      'Icon-App-40x40@3x.png': 120,
      'Icon-App-60x60@2x.png': 120,
      'Icon-App-60x60@3x.png': 180,
      'Icon-App-76x76@1x.png': 76,
      'Icon-App-76x76@2x.png': 152,
      'Icon-App-83.5x83.5@2x.png': 167,
      'Icon-App-1024x1024@1x.png': 1024,
    };
    for (final e in ios.entries) {
      await _png('$iosDir/${e.key}', e.value,
          const FlexLogoPainter(tileRadius: 0));
    }

    // ── The web ──────────────────────────────────────────────────────────
    // Rounded for browsers. "Maskable" ones are cropped by the phone to its
    // own shape, so the F is smaller inside a full square.
    await _png('web/icons/Icon-192.png', 192, const FlexLogoPainter());
    await _png('web/icons/Icon-512.png', 512, const FlexLogoPainter());
    await _png('web/icons/Icon-maskable-192.png', 192,
        const FlexLogoPainter(tileRadius: 0, markScale: 0.8));
    await _png('web/icons/Icon-maskable-512.png', 512,
        const FlexLogoPainter(tileRadius: 0, markScale: 0.8));
    await _png('web/favicon.png', 32, const FlexLogoPainter(shadow: false));

    // ── Mac ──────────────────────────────────────────────────────────────
    for (final px in [16, 32, 64, 128, 256, 512, 1024]) {
      await _png(
          'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$px.png',
          px,
          FlexLogoPainter(shadow: px >= 64));
    }

    // ── Windows: the sizes its .ico holds ────────────────────────────────
    final winSizes = [16, 24, 32, 48, 64, 128, 256];
    final winPngs = <String>[];
    for (final px in winSizes) {
      final path = 'build/icons/win_$px.png';
      await _png(path, px, FlexLogoPainter(shadow: px >= 64));
      winPngs.add(path);
    }

    // ── The last steps, with ImageMagick ─────────────────────────────────
    final steps = <List<String>>[
      for (final name in ios.keys)
        [
          '$iosDir/$name',
          '-background',
          _hex(FlexMark.tileColors[1]).replaceFirst('#FF', '#'),
          '-alpha',
          'remove',
          '-alpha',
          'off',
          '$iosDir/$name',
        ],
      [...winPngs, 'windows/runner/resources/app_icon.ico'],
    ];
    try {
      for (final args in steps) {
        final run = await Process.run('convert', args);
        if (run.exitCode != 0) throw ProcessException('convert', args, '${run.stderr}');
      }
    } on ProcessException catch (e) {
      // ignore: avoid_print
      print('ImageMagick did not run ($e). Run these yourself:\n'
          '${steps.map((a) => 'convert ${a.join(' ')}').join('\n')}');
    }
  });
}
