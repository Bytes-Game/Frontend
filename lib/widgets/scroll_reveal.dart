import 'package:flutter/material.dart';

/// Brings its child into place as it scrolls into view: it starts lower,
/// tilted back and faded, and settles flat as it rises up the screen.
///
/// Driven by the scroll position itself, not by a timer, so it moves exactly
/// as far as the finger does — scroll back down and it tilts away again.
/// That is the "the picture moves, then the next part arrives" feel the
/// profile is built around.
class ScrollReveal extends StatefulWidget {
  final Widget child;

  /// How far below its resting place the child starts, in pixels.
  final double lift;

  /// How far back it is tilted at the start, in radians.
  final double tilt;

  const ScrollReveal({
    super.key,
    required this.child,
    this.lift = 48,
    this.tilt = 0.45,
  });

  /// How far through its entrance a child is, 0..1, given where its top edge
  /// is on screen. 0 while it is still at the bottom edge; 1 once it has
  /// climbed a third of the way up.
  static double progressFor({
    required double topOnScreen,
    required double viewportHeight,
  }) {
    if (viewportHeight <= 0) return 1;
    final start = viewportHeight;
    final end = viewportHeight * 0.66;
    return ((start - topOnScreen) / (start - end)).clamp(0.0, 1.0);
  }

  @override
  State<ScrollReveal> createState() => _ScrollRevealState();
}

class _ScrollRevealState extends State<ScrollReveal> {
  ScrollPosition? _position;
  double _progress = 1;

  // Where this sits in the scrolling content, and how tall the viewport is.
  // The scroll listener runs before the new frame is laid out, so asking
  // the render tree where the child is at that moment gives LAST frame's
  // answer — every entrance would lag the finger, and a single fling would
  // freeze it half way. So the place in the content is measured after
  // layout, and the place on screen is worked out from the scroll offset.
  double? _contentTop;
  double _viewportHeight = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (next != _position) {
      _position?.removeListener(_onScroll);
      _position = next;
      _position?.addListener(_onScroll);
    }
    _measureAfterLayout();
  }

  @override
  void didUpdateWidget(ScrollReveal old) {
    super.didUpdateWidget(old);
    // Something above may have changed height; measure again.
    _measureAfterLayout();
  }

  @override
  void dispose() {
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  void _measureAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final scrollable = Scrollable.maybeOf(context);
    final viewport = scrollable?.context.findRenderObject() as RenderBox?;
    final pos = _position;
    if (box == null ||
        viewport == null ||
        pos == null ||
        !box.attached ||
        !viewport.attached) {
      return;
    }
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    _contentTop = top + pos.pixels;
    _viewportHeight = viewport.size.height;
    _apply(top);
  }

  void _onScroll() {
    final pos = _position;
    final contentTop = _contentTop;
    if (pos == null || contentTop == null) {
      _measure();
      return;
    }
    _apply(contentTop - pos.pixels);
  }

  void _apply(double topOnScreen) {
    final p = ScrollReveal.progressFor(
      topOnScreen: topOnScreen,
      viewportHeight: _viewportHeight,
    );
    if ((p - _progress).abs() > 0.004) setState(() => _progress = p);
  }

  @override
  Widget build(BuildContext context) {
    final eased = Curves.easeOutCubic.transform(_progress);
    final rest = 1 - eased;
    return Opacity(
      opacity: 0.25 + 0.75 * eased,
      child: Transform(
        alignment: Alignment.topCenter,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0012) // perspective
          ..translateByDouble(0.0, widget.lift * rest, 0.0, 1.0)
          ..rotateX(widget.tilt * rest),
        child: widget.child,
      ),
    );
  }
}
