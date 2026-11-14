import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:myapp/services/celebrated_wins.dart';

/// The moment a battle is won.
///
/// Light bursts out from the middle of the screen, a trophy flips over in
/// 3D and lands facing you, and the words say it: "You won!". Two and a
/// half seconds, then it is gone.
///
/// It is shown ON TOP of the page and never takes a tap: everything under
/// it works while it plays. It is paint and nothing else, so it costs the
/// same whatever is underneath; nothing behind it is blurred.
///
/// Once per battle on this phone ([celebrate]). A phone set to "reduce
/// motion" gets the trophy and the words, standing still, with no flip
/// and no burst.
class WinMoment extends StatefulWidget {
  const WinMoment({super.key, required this.detail, this.onDone});

  /// The line under "You won!": who it was against, and the score.
  final String detail;

  /// Called when it has finished and can be taken away.
  final VoidCallback? onDone;

  /// From the first light to nothing.
  static const Duration length = Duration(milliseconds: 2600);

  /// The gold the app already uses for a trophy.
  static const Color gold = Color(0xFFFFD60A);

  /// How many times the trophy turns before it lands: one and a half.
  static const double turns = 1.5;

  /// Plays the moment over the page [context] is on, for the battle
  /// [battleId]. Says whether it played: a battle is celebrated once on
  /// this phone (CelebratedWins), and asking again does nothing.
  static Future<bool> celebrate(
    BuildContext context, {
    required String battleId,
    required String detail,
  }) async {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return false;
    if (!await CelebratedWins.firstTime(battleId)) return false;
    // The page may have gone while the phone was asked.
    if (!overlay.mounted) return false;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => WinMoment(
        detail: detail,
        onDone: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
    return true;
  }

  /// How far the trophy has turned at [t] (0 to 1 of the whole moment), in
  /// radians. It spins fast, slows, and is facing front by [landed].
  static double turnAt(double t) {
    if (t >= landed) return 0;
    final left = 1 - Curves.easeOutCubic.transform(t / landed);
    return left * turns * 2 * math.pi;
  }

  /// The part of the moment by which the trophy has landed.
  static const double landed = 0.5;

  /// How far the light has reached at [t], 0 to 1.
  static double reachAt(double t) =>
      Curves.easeOutCubic.transform((t / 0.45).clamp(0.0, 1.0));

  /// How strong everything is at [t], 0 to 1: in quickly, out at the end.
  static double strengthAt(double t) {
    if (t < 0.08) return t / 0.08;
    if (t > 0.82) return ((1 - t) / 0.18).clamp(0.0, 1.0);
    return 1;
  }

  @override
  State<WinMoment> createState() => _WinMomentState();
}

class _WinMomentState extends State<WinMoment>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: WinMoment.length,
    // Its full length on a phone set to "reduce motion" too. Left alone,
    // such a phone runs every timer of this kind twenty times faster, and
    // the trophy and the words were gone in a blink. Nothing moves on
    // such a phone anyway (see build): this is only how long they stay.
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((status) {
      if (status == AnimationStatus.completed) widget.onDone?.call();
    });
    _clock.forward();
    // Felt as well as seen. A phone with no buzzer ignores it.
    HapticFeedback.heavyImpact();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: 'You won! ${widget.detail}',
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final t = _clock.value;
            final strength = WinMoment.strengthAt(t);
            final turn = still ? 0.0 : WinMoment.turnAt(t);
            // It grows as it spins and lands a touch big, then settles.
            final size = still
                ? 1.0
                : 0.35 +
                      0.65 *
                          Curves.easeOutBack.transform(
                            (t / WinMoment.landed).clamp(0.0, 1.0),
                          );
            final words = Curves.easeOut.transform(
              ((t - 0.22) / 0.2).clamp(0.0, 1.0),
            );
            return Opacity(
              opacity: strength,
              child: Stack(
                fit: StackFit.expand,
                alignment: Alignment.center,
                children: [
                  // The page dims behind it, most in the middle where the
                  // words are: gold and white then read over a bright
                  // page, and over the page's own words.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.9,
                        colors: [
                          Color(0xE0000000),
                          Color(0xB3000000),
                          Color(0x40000000),
                        ],
                        stops: [0, 0.45, 1],
                      ),
                    ),
                  ),
                  if (!still)
                    RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('win_burst'),
                        painter: WinBurstPainter(
                          reach: WinMoment.reachAt(t),
                          spin: t * 0.9,
                          fade: 1 - ((t - 0.45) / 0.4).clamp(0.0, 1.0),
                        ),
                      ),
                    ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform(
                          key: const ValueKey('win_trophy'),
                          alignment: Alignment.center,
                          // The small number in the third row is what
                          // makes it 3D: the far edge looks smaller than
                          // the near one as it turns.
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0016)
                            ..rotateY(turn)
                            ..scaleByDouble(size, size, size, 1),
                          child: const Icon(
                            Icons.emoji_events_rounded,
                            size: 132,
                            color: WinMoment.gold,
                            shadows: [
                              Shadow(color: Color(0xAAFFD60A), blurRadius: 28),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Opacity(
                          opacity: still ? 1 : words,
                          child: Transform.translate(
                            offset: Offset(0, still ? 0 : 14 * (1 - words)),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // In the app's own lettering. This sits
                                // above the page, where no theme reaches,
                                // so unnamed it would be drawn in the
                                // phone's default font.
                                Text(
                                  'You won!',
                                  style: GoogleFonts.inter(
                                    textStyle: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 34,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: -0.6,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                                ),
                                if (widget.detail.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 32,
                                    ),
                                    child: Text(
                                      widget.detail,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: GoogleFonts.inter(
                                        textStyle: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w600,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The burst of light behind the trophy: rays reaching out from the
/// middle, turning slowly, with a ring that runs ahead of them.
class WinBurstPainter extends CustomPainter {
  const WinBurstPainter({
    required this.reach,
    required this.spin,
    required this.fade,
  });

  /// How far the rays have got, 0 to 1 of the way to the screen's edge.
  final double reach;

  /// How far the whole burst has turned, in radians.
  final double spin;

  /// 1 while it is bright, down to 0 as it goes.
  final double fade;

  static const int rays = 16;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || reach <= 0 || fade <= 0) return;
    final middle = size.center(Offset.zero);
    final far = size.longestSide * 0.62 * reach;

    // The glow in the middle.
    canvas.drawCircle(
      middle,
      far * 0.55,
      Paint()
        ..shader = RadialGradient(
          colors: [
            WinMoment.gold.withValues(alpha: 0.42 * fade),
            WinMoment.gold.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: middle, radius: far * 0.55)),
    );

    // The rays: thin wedges, every other one shorter.
    final wedge = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.55 * fade),
          WinMoment.gold.withValues(alpha: 0.32 * fade),
          WinMoment.gold.withValues(alpha: 0),
        ],
        stops: const [0, 0.35, 1],
      ).createShader(Rect.fromCircle(center: middle, radius: far));
    const half = math.pi / rays * 0.32;
    for (var i = 0; i < rays; i++) {
      final a = spin + i * 2 * math.pi / rays;
      final length = far * (i.isEven ? 1.0 : 0.68);
      canvas.drawPath(
        Path()
          ..moveTo(middle.dx, middle.dy)
          ..lineTo(
            middle.dx + length * math.cos(a - half),
            middle.dy + length * math.sin(a - half),
          )
          ..lineTo(
            middle.dx + length * math.cos(a + half),
            middle.dy + length * math.sin(a + half),
          )
          ..close(),
        wedge,
      );
    }

    // The ring running ahead of them.
    canvas.drawCircle(
      middle,
      far * 0.8,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(
          alpha: 0.5 * fade * (1 - reach * 0.6),
        ),
    );
  }

  @override
  bool shouldRepaint(WinBurstPainter old) =>
      old.reach != reach || old.spin != spin || old.fade != fade;
}
