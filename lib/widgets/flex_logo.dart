import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Flex logo: a bold white F whose middle arm is a play button, on the
/// app's blue.
///
/// The F is the name. The play button is what the app is: videos. It points
/// forward, the way a battle goes.
///
/// One drawing makes every copy of the logo. The app icons on Android,
/// iPhone, the web and desktop are made from this same painter by
/// `tool/make_app_icons_test.dart`, so the logo inside the app and the one
/// on the home screen can never drift apart. Change it here, run that, and
/// every icon follows.
///
/// Everything is measured on a 100 × 100 tile, then scaled.
class FlexMark {
  FlexMark._();

  /// The F's left edge, and its top.
  static const left = 32.0;
  static const top = 25.0;

  /// How thick the F's strokes are.
  static const stroke = 13.0;

  /// Where the top arm ends (its round tip), and the stem (its round foot).
  static const armEnd = 72.0;
  static const foot = 78.0;

  /// The big rounded bend at the top-left, and the small one under the arm.
  static const bend = 15.0;
  static const innerBend = 3.0;

  /// The play button that is the F's middle arm. Its back edge sits inside
  /// the stem, so it grows out of it.
  static const play = [Offset(38, 42), Offset(67, 57), Offset(38, 72)];

  /// How round the play button's corners are.
  static const playRadius = 3.5;

  /// How big the F is drawn on its tile: a little bigger than measured, so
  /// it holds its own at the size of a home-screen icon.
  static const presence = 1.1;

  /// The blues, from the top-left corner of the tile to the bottom-right.
  /// The middle one is the app's own blue (AppTheme.primary), the one on the
  /// QR code's corners.
  static const tileColors = [
    Color(0xFF3DA5FF),
    Color(0xFF0A84FF),
    Color(0xFF0050D0),
  ];

  /// The play button's light blue, at its tip. The app's soft blue
  /// (AppTheme.accentCyan), lightened so it stays bright on the tile.
  static const playTip = Color(0xFFA5E3FF);

  /// The deep blue under the mark, for its shadow.
  static const shadow = Color(0xFF00337F);

  /// The F without its middle arm: the stem and the top arm, as one stroke
  /// with a smooth bend.
  static Path frame() => (_PathPen().._frame()).path;

  /// The play button.
  static Path playButton() => (_PathPen().._play()).path;

  /// The whole F as one shape.
  static Path path() => Path()
    ..addPath(frame(), Offset.zero)
    ..addPath(playButton(), Offset.zero);

  /// The same shapes written out for an Android vector file (its
  /// `pathData`), on a canvas where the tile's 100 units are [scale] long
  /// and its top-left corner is at ([dx], [dy]).
  static String pathData({
    required double scale,
    double dx = 0,
    double dy = 0,
    bool frame = true,
    bool play = true,
  }) {
    final pen = _TextPen(scale, dx, dy);
    if (frame) pen._frame();
    if (play) pen._play();
    return pen.text.toString().trim();
  }
}

/// Something the logo can be drawn with: a Flutter path, or the text of an
/// Android vector file. One set of drawing steps for both, so the two are
/// the same shape by construction.
abstract class _Pen {
  void moveTo(double x, double y);
  void lineTo(double x, double y);

  /// A circular arc of radius [r] to ([x], [y]), turning clockwise on
  /// screen unless told otherwise.
  void arcTo(double x, double y, double r, {bool clockwise = true});
  void close();

  void _frame() {
    const left = FlexMark.left, top = FlexMark.top, bend = FlexMark.bend;
    const r = FlexMark.stroke / 2;
    const right = left + FlexMark.stroke;
    const under = top + FlexMark.stroke;
    const inner = FlexMark.innerBend;
    // Each round tip is two quarter turns, not one half turn: written out
    // as text, a half turn's centre moves a long way for a tiny rounding of
    // its numbers, and the tip comes out flat.
    moveTo(left + bend, top);
    lineTo(FlexMark.armEnd - r, top);
    arcTo(FlexMark.armEnd, top + r, r);
    arcTo(FlexMark.armEnd - r, under, r);
    lineTo(right + inner, under);
    arcTo(right, under + inner, inner, clockwise: false);
    lineTo(right, FlexMark.foot - r);
    arcTo(left + r, FlexMark.foot, r);
    arcTo(left, FlexMark.foot - r, r);
    lineTo(left, top + bend);
    arcTo(left + bend, top, bend);
    close();
  }

  /// The play button: a triangle with each corner rounded.
  void _play() {
    const points = FlexMark.play;
    const radius = FlexMark.playRadius;
    final n = points.length;
    for (var i = 0; i < n; i++) {
      final prev = points[(i - 1 + n) % n];
      final at = points[i];
      final next = points[(i + 1) % n];
      final toPrev = prev - at;
      final toNext = next - at;
      final a = toPrev / toPrev.distance;
      final b = toNext / toNext.distance;
      // The corner's angle, and how far from it the curve starts.
      final angle = math.acos((a.dx * b.dx + a.dy * b.dy).clamp(-1.0, 1.0));
      final cut = radius / math.tan(angle / 2);
      final start = at + a * cut;
      final end = at + b * cut;
      if (i == 0) {
        moveTo(start.dx, start.dy);
      } else {
        lineTo(start.dx, start.dy);
      }
      // Going back along [a] then on along [b]: clockwise on screen when
      // their cross product is negative (the y axis points down).
      arcTo(end.dx, end.dy, radius,
          clockwise: (a.dx * b.dy - a.dy * b.dx) < 0);
    }
    close();
  }
}

class _PathPen extends _Pen {
  final path = Path();

  @override
  void moveTo(double x, double y) => path.moveTo(x, y);
  @override
  void lineTo(double x, double y) => path.lineTo(x, y);
  @override
  void arcTo(double x, double y, double r, {bool clockwise = true}) => path
      .arcToPoint(Offset(x, y), radius: Radius.circular(r), clockwise: clockwise);
  @override
  void close() => path.close();
}

class _TextPen extends _Pen {
  _TextPen(this.scale, this.dx, this.dy);

  final double scale, dx, dy;
  final text = StringBuffer();

  String _n(double v) {
    final s = v.toStringAsFixed(3);
    // 12.500 → 12.5, 12.000 → 12
    return s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
  }

  String _at(double x, double y) =>
      '${_n(dx + x * scale / 100)},${_n(dy + y * scale / 100)}';

  @override
  void moveTo(double x, double y) => text.write('M${_at(x, y)} ');
  @override
  void lineTo(double x, double y) => text.write('L${_at(x, y)} ');
  @override
  void arcTo(double x, double y, double r, {bool clockwise = true}) {
    final rr = _n(r * scale / 100);
    // An arc's sweep flag of 1 turns clockwise on screen, as here.
    text.write('A$rr,$rr 0 0 ${clockwise ? 1 : 0} ${_at(x, y)} ');
  }

  @override
  void close() => text.write('Z ');
}

/// Paints the logo. With [tile], the blue rounded square behind the F; without
/// it, the F alone (for a notification, or an icon layer the phone puts on
/// its own background).
class FlexLogoPainter extends CustomPainter {
  const FlexLogoPainter({
    this.tile = true,
    this.tileRadius = 0.235,
    this.markColor = Colors.white,
    this.markScale = 1.0,
    this.shadow = true,
    this.tinted = true,
  });

  /// Draw the blue square.
  final bool tile;

  /// How round the square's corners are, as a share of its side. 0: a plain
  /// square, for the iPhone, which rounds the corners itself.
  final double tileRadius;

  final Color markColor;

  /// How big the F is against the tile. Below 1 for an icon layer that the
  /// phone crops (Android's adaptive icons).
  final double markScale;

  /// A soft shadow under the F, to lift it off the blue.
  final bool shadow;

  /// The play button fades to light blue at its tip. Off for a one-colour
  /// logo.
  final bool tinted;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final unit = side / 100;
    canvas.save();
    canvas.translate((size.width - side) / 2, (size.height - side) / 2);

    if (tile) {
      final rect = Rect.fromLTWH(0, 0, side, side);
      final rrect =
          RRect.fromRectAndRadius(rect, Radius.circular(side * tileRadius));
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: FlexMark.tileColors,
            stops: [0, 0.48, 1],
          ).createShader(rect),
      );
      // Light from the top-left, so the tile has depth.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.75, -0.95),
            radius: 1.1,
            colors: [
              Colors.white.withValues(alpha: 0.22),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
      canvas.restore();
    }

    // The F, scaled about the tile's middle.
    canvas.translate(side / 2, side / 2);
    canvas.scale(unit * FlexMark.presence * markScale);
    canvas.translate(-50, -50);
    if (shadow) {
      canvas.drawPath(
        FlexMark.path().shift(const Offset(0, 1.6)),
        Paint()
          ..color = FlexMark.shadow.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
      );
    }
    final play = FlexMark.playButton();
    canvas.drawPath(
      play,
      Paint()
        ..shader = tinted
            ? LinearGradient(colors: [markColor, FlexMark.playTip])
                .createShader(play.getBounds())
            : null
        ..color = markColor,
    );
    canvas.drawPath(FlexMark.frame(), Paint()..color = markColor);
    canvas.restore();
  }

  @override
  bool shouldRepaint(FlexLogoPainter old) =>
      old.tile != tile ||
      old.tileRadius != tileRadius ||
      old.markColor != markColor ||
      old.markScale != markScale ||
      old.shadow != shadow ||
      old.tinted != tinted;
}

/// The logo, [size] across, with a soft blue glow under it.
class FlexLogo extends StatelessWidget {
  const FlexLogo({super.key, this.size = 76, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Flex',
      image: true,
      child: Container(
        width: size,
        height: size,
        decoration: glow
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.235),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF0A84FF).withValues(alpha: 0.38),
                    blurRadius: size * 0.5,
                    offset: Offset(0, size * 0.06),
                  ),
                ],
              )
            : null,
        child: CustomPaint(
          key: const ValueKey('flex_logo'),
          size: Size.square(size),
          painter: const FlexLogoPainter(),
        ),
      ),
    );
  }
}
