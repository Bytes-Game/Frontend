import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Things that build themselves as you scroll to them, the way the best
/// websites do.
///
/// The sibling of ScrollReveal (the profile page's), which follows the
/// finger exactly. This one plays once, on its own clock, when an item first
/// appears — better for long lists, where a row half-revealed at rest would
/// look unfinished.
///
/// The first time [child] comes into view it folds up into place in 3D:
/// tilted back and a little low, it swings upright, rises and fades in.
/// Items on screen when a page opens do it one after another ([order]), so
/// the page assembles itself instead of just appearing.
///
/// With [depth], it also moves with the scroll: as it slides off the top of
/// the list it leans back and fades a little, as if travelling away.
///
/// Taps land where the item is drawn, mid-move or not. Anybody who has
/// asked their phone for less motion gets none of it.
class FoldIn extends StatefulWidget {
  final Widget child;

  /// Which of a row of items this is, for the one-after-another start.
  final int order;

  /// Lean back and fade while leaving the top of the list.
  final bool depth;

  const FoldIn({
    super.key,
    required this.child,
    this.order = 0,
    this.depth = false,
  });

  /// How long one item takes to fold into place.
  static const duration = Duration(milliseconds: 520);

  /// The gap between one item starting and the next.
  static const stagger = Duration(milliseconds: 55);

  @override
  State<FoldIn> createState() => _FoldInState();
}

class _FoldInState extends State<FoldIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in;
  late final Animation<double> _shown;
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    // The wait for its turn is part of the animation rather than a timer,
    // so nothing is left pending when the item goes away early.
    final wait = FoldIn.stagger * widget.order.clamp(0, 8);
    final total = wait + FoldIn.duration;
    _in = AnimationController(vsync: this, duration: total);
    _shown = CurvedAnimation(
      parent: _in,
      curve: Interval(
        wait.inMicroseconds / total.inMicroseconds,
        1,
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _onSeen() {
    if (_seen || !mounted) return;
    _seen = true;
    _in.forward();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) return widget.child;
    return _Reveal(
      shown: _shown,
      position: Scrollable.maybeOf(context)?.position,
      depth: widget.depth,
      onSeen: _onSeen,
      child: widget.child,
    );
  }
}

class _Reveal extends SingleChildRenderObjectWidget {
  final Animation<double> shown;
  final ScrollPosition? position;
  final bool depth;
  final VoidCallback onSeen;

  const _Reveal({
    required this.shown,
    required this.position,
    required this.depth,
    required this.onSeen,
    required super.child,
  });

  @override
  _RenderReveal createRenderObject(BuildContext context) => _RenderReveal(
        shown: shown,
        position: position,
        depth: depth,
        onSeen: onSeen,
      );

  @override
  void updateRenderObject(BuildContext context, _RenderReveal r) {
    r
      ..shown = shown
      ..position = position
      ..depth = depth
      ..onSeen = onSeen;
  }
}

/// Draws its child moved, tilted and faded by how far it has come in and
/// how far it has gone off the top. Worked out while painting, when where
/// everything sits is already known, so a scroll costs a repaint and never
/// a rebuild.
class _RenderReveal extends RenderProxyBox {
  _RenderReveal({
    required Animation<double> shown,
    required ScrollPosition? position,
    required bool depth,
    required this.onSeen,
  })  : _shown = shown,
        _position = position,
        _depth = depth;

  VoidCallback onSeen;
  bool _toldSeen = false;

  /// What was drawn last, for taps. Null when drawn as it is.
  Matrix4? _drawn;
  final _fade = LayerHandle<OpacityLayer>();

  Animation<double> _shown;
  set shown(Animation<double> v) {
    if (v == _shown) return;
    if (attached) _shown.removeListener(markNeedsPaint);
    _shown = v;
    if (attached) _shown.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  ScrollPosition? _position;
  set position(ScrollPosition? v) {
    if (v == _position) return;
    if (attached) _position?.removeListener(_scrolled);
    _position = v;
    if (attached) _position?.addListener(_scrolled);
  }

  bool _depth;
  set depth(bool v) {
    if (v == _depth) return;
    _depth = v;
    markNeedsPaint();
  }

  void _scrolled() {
    if (_depth) markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _shown.addListener(markNeedsPaint);
    _position?.addListener(_scrolled);
  }

  @override
  void detach() {
    _shown.removeListener(markNeedsPaint);
    _position?.removeListener(_scrolled);
    super.detach();
  }

  @override
  void dispose() {
    _fade.layer = null;
    super.dispose();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  /// 0 while fully in the list; up to 1 as it slides off the top.
  double _leaving() {
    if (!_depth || !hasSize || size.height <= 0) return 0;
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport is! RenderViewportBase || viewport.axis != Axis.vertical) {
      return 0;
    }
    final top = getTransformTo(viewport).getTranslation().y;
    if (top >= 0) return 0;
    return (-top / size.height).clamp(0.0, 1.0);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // Being painted means being on screen: that is the moment to come in.
    if (!_toldSeen) {
      _toldSeen = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => onSeen());
    }
    final t = _shown.value;
    final d = _leaving();
    if (t >= 1 && d <= 0) {
      _drawn = null;
      layer = null;
      _fade.layer = null;
      context.paintChild(child, offset);
      return;
    }
    final alpha = (255 * t * (1 - 0.55 * d)).round().clamp(0, 255);
    final cx = size.width / 2, cy = size.height / 2;
    final m = Matrix4.translationValues(cx, cy + (1 - t) * 34, 0)
      ..multiply(Matrix4.identity()..setEntry(3, 2, 0.0012))
      ..multiply(Matrix4.rotationX((1 - t) * 0.6 - d * 0.42))
      ..multiply(Matrix4.diagonal3Values(
        (0.93 + 0.07 * t) * (1 - 0.07 * d),
        (0.93 + 0.07 * t) * (1 - 0.07 * d),
        1,
      ))
      ..multiply(Matrix4.translationValues(-cx, -cy, 0));
    _drawn = m;
    layer = context.pushTransform(
      needsCompositing,
      offset,
      m,
      (inner, at) {
        _fade.layer = inner.pushOpacity(
          at,
          alpha,
          (c, o) => c.paintChild(child, o),
          oldLayer: _fade.layer,
        );
      },
      oldLayer: layer is TransformLayer ? layer as TransformLayer : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final m = _drawn;
    if (m == null) return super.hitTestChildren(result, position: position);
    return result.addWithPaintTransform(
      transform: m,
      position: position,
      hitTest: (r, p) => super.hitTestChildren(r, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final m = _drawn;
    if (m != null) transform.multiply(m);
  }
}
