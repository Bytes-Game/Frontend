import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The bar between the two sides of a battle.
///
/// One side's colour comes in from the left, the other's from the right,
/// and they meet where the votes put them: six votes against three, and
/// the seam sits two thirds of the way across. The side that is ahead
/// glows. When the score moves, the seam slides to its new place and the
/// glow flares once, then rests.
///
/// Nothing here moves for ever. It moves when the score does, and stops:
/// a bar that never rests keeps the phone drawing for as long as the page
/// is open. A phone set to "reduce motion" gets the bar in its new place
/// at once, with no slide and no flare.
///
/// The seam is where the VOTES are. The glow is on whoever the server
/// says is ahead, which is not always the side with more votes on show:
/// some votes do not count, and level votes are settled on likes.
class VersusBar extends StatefulWidget {
  const VersusBar({
    super.key,
    required this.left,
    required this.right,
    required this.leader,
    required this.leftColor,
    required this.rightColor,
    this.leftName = '',
    this.rightName = '',
  });

  /// Each side's votes, as shown on the page.
  final double left;
  final double right;

  /// Who is ahead: -1 the left side, 1 the right, 0 nobody (level, or no
  /// votes yet).
  final int leader;

  final Color leftColor;
  final Color rightColor;

  /// For people who have the screen read to them.
  final String leftName;
  final String rightName;

  /// How long the seam takes to slide to a new place.
  static const Duration slide = Duration(milliseconds: 420);

  /// How long the glow flares after the score has moved.
  static const Duration flare = Duration(milliseconds: 900);

  /// The left side's share of the bar, 0 to 1. Half each while nobody has
  /// voted.
  static double shareOf(double left, double right) {
    final total = left + right;
    if (total <= 0) return 0.5;
    return (left / total).clamp(0.0, 1.0);
  }

  @override
  State<VersusBar> createState() => _VersusBarState();
}

class _VersusBarState extends State<VersusBar> with TickerProviderStateMixin {
  /// Where the seam is on screen. It follows the votes.
  late final AnimationController _seam = AnimationController(
    vsync: this,
    duration: VersusBar.slide,
    value: VersusBar.shareOf(widget.left, widget.right),
  );

  /// 1 while the glow is at its brightest, 0 at rest.
  late final AnimationController _flare = AnimationController(
    vsync: this,
    duration: VersusBar.flare,
  );

  bool get _still => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void initState() {
    super.initState();
    // Once, as the bar arrives: the light finds the leader.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_still && widget.leader != 0) _flare.forward(from: 0);
    });
  }

  @override
  void didUpdateWidget(VersusBar old) {
    super.didUpdateWidget(old);
    final moved = old.left != widget.left || old.right != widget.right;
    if (!moved && old.leader == widget.leader) return;
    final to = VersusBar.shareOf(widget.left, widget.right);
    if (_still) {
      _seam.value = to;
      return;
    }
    if (moved) {
      // With the time said out loud. Left to itself, the time is cut down
      // to the share of the bar the seam has to cross, and a short move
      // (one vote among many) is over before anybody has seen it.
      _seam.animateTo(
        to,
        duration: VersusBar.slide,
        curve: Curves.easeOutCubic,
      );
    }
    // The light rises fast and settles slowly.
    _flare.forward(from: 0);
  }

  @override
  void dispose() {
    _seam.dispose();
    _flare.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final share = VersusBar.shareOf(widget.left, widget.right);
    final leftPercent = (share * 100).round();
    final track = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.08);
    return Semantics(
      label:
          '${widget.leftName} $leftPercent percent, '
          '${widget.rightName} ${100 - leftPercent} percent',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 22,
            width: double.infinity,
            // A layer of its own: when the bar moves, only the bar is drawn
            // again.
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('versus_bar'),
                painter: VersusBarPainter(
                  seam: _seam,
                  flare: _flare,
                  leader: widget.leader,
                  leftColor: widget.leftColor,
                  rightColor: widget.rightColor,
                  track: track,
                ),
              ),
            ),
          ),
          Row(
            children: [
              RollingCount(
                key: const ValueKey('versus_left_percent'),
                value: leftPercent.toDouble(),
                text: '$leftPercent%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: widget.leftColor,
                ),
              ),
              const Spacer(),
              RollingCount(
                key: const ValueKey('versus_right_percent'),
                value: (100 - leftPercent).toDouble(),
                text: '${100 - leftPercent}%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: widget.rightColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Draws [VersusBar]: the two sides, the seam where they meet, and the
/// glow on whoever is ahead.
class VersusBarPainter extends CustomPainter {
  VersusBarPainter({
    required this.seam,
    required this.flare,
    required this.leader,
    required this.leftColor,
    required this.rightColor,
    required this.track,
  }) : super(repaint: Listenable.merge([seam, flare]));

  /// The left side's share of the bar as drawn right now, 0 to 1.
  final Animation<double> seam;

  /// 0 at rest, up to 1 just after the score has moved.
  final Animation<double> flare;
  final int leader;
  final Color leftColor;
  final Color rightColor;
  final Color track;

  /// How thick the bar is, and how much room it has for its glow.
  static const double thickness = 10;

  /// How strong the leader's glow is at rest, and at the top of a flare.
  static const double restGlow = 0.45;
  static const double peakGlow = 0.95;

  /// The glow's strength now, 0 to 1. Nobody ahead: no glow at all.
  double get glow {
    if (leader == 0) return 0;
    // Up quickly, down slowly: a flash that settles.
    final t = flare.value;
    final lift = t <= 0 || t >= 1
        ? 0.0
        : (t < 0.25 ? t / 0.25 : 1 - (t - 0.25) / 0.75);
    return restGlow + (peakGlow - restGlow) * Curves.easeOut.transform(lift);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final top = (size.height - thickness) / 2;
    final bar = Rect.fromLTWH(0, top, size.width, thickness);
    const round = Radius.circular(thickness / 2);
    final shape = RRect.fromRectAndRadius(bar, round);
    final at = size.width * seam.value.clamp(0.0, 1.0);
    final leftPart = Rect.fromLTRB(0, top, at, top + thickness);
    final rightPart = Rect.fromLTRB(at, top, size.width, top + thickness);

    // The glow first, under the bar, on the leader's part only. Blurred
    // paint, not a blur of what is behind it: cheap, and it never touches
    // a video.
    final strength = glow;
    if (strength > 0) {
      final part = leader < 0 ? leftPart : rightPart;
      final colour = leader < 0 ? leftColor : rightColor;
      if (part.width > 0) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(part.inflate(1), round),
          Paint()
            ..color = colour.withValues(alpha: strength)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 + 4 * strength),
        );
      }
    }

    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(bar, Paint()..color = track);
    // The side behind is drawn a little dimmer, so "ahead" reads even
    // where the glow is faint.
    double weight(int side) => leader == 0 || leader == side ? 1.0 : 0.6;
    canvas.drawRect(
      leftPart,
      Paint()..color = leftColor.withValues(alpha: weight(-1)),
    );
    canvas.drawRect(
      rightPart,
      Paint()..color = rightColor.withValues(alpha: weight(1)),
    );
    canvas.restore();

    // The seam: a sliver of light where the two sides meet. Not drawn when
    // one side has the whole bar.
    if (at > 2 && at < size.width - 2) {
      final spark = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(at, size.height / 2),
          width: 3,
          height: math.min(size.height, thickness + 8),
        ),
        const Radius.circular(1.5),
      );
      if (strength > 0) {
        canvas.drawRRect(
          spark.inflate(1.5),
          Paint()
            ..color = Colors.white.withValues(alpha: 0.55 * strength)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
        );
      }
      canvas.drawRRect(spark, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(VersusBarPainter old) =>
      old.leader != leader ||
      old.leftColor != leftColor ||
      old.rightColor != rightColor ||
      old.track != track ||
      old.seam != seam ||
      old.flare != flare;
}

/// A number that rolls to its new value, the way the digits of a counter
/// do: the old one slides out and the new one slides in after it, upward
/// when the number has grown and downward when it has dropped.
///
/// The new number is there from the first frame. A phone set to "reduce
/// motion" gets it with no roll.
class RollingCount extends StatefulWidget {
  const RollingCount({
    super.key,
    required this.value,
    required this.text,
    this.style,
  });

  /// The number itself: decides which way it rolls.
  final double value;

  /// The number as it is written: "6", "4.5", "67%".
  final String text;
  final TextStyle? style;

  /// How long one roll takes.
  static const Duration roll = Duration(milliseconds: 280);

  @override
  State<RollingCount> createState() => _RollingCountState();
}

class _RollingCountState extends State<RollingCount> {
  /// Whether the last change was upward.
  bool _up = true;

  @override
  void didUpdateWidget(RollingCount old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) _up = widget.value > old.value;
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final now = ValueKey<String>(widget.text);
    return ClipRect(
      child: AnimatedSwitcher(
        duration: still ? Duration.zero : RollingCount.roll,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerRight,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) {
          // The one coming in starts below (when the number grew) and
          // rises into place; the one going out carries on up and away.
          final coming = child.key == now;
          final from = coming
              ? Offset(0, _up ? 0.7 : -0.7)
              : Offset(0, _up ? -0.7 : 0.7);
          return SlideTransition(
            position: Tween(begin: from, end: Offset.zero).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: Text(widget.text, key: now, style: widget.style),
      ),
    );
  }
}
