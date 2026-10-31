import 'package:flutter/material.dart';

/// How far a finger has to come down to refresh — Home's pull and every
/// list that pulls the same way. Home settled on this; Search's old pull
/// (Flutter's own) wanted about a sixth of the screen, 120 points and more
/// on a tall phone, which is why it felt like having to pull harder.
const double pullRefreshTriggerPx = 80;

/// How far a finger moves before its direction is read.
const double pullRefreshDecidePx = 10;

/// How much steeper than sideways a move has to be to count as a pull.
const double pullRefreshSteepness = 1.2;

/// What a pull looks like, TikTok style: a ring that fills as the finger
/// comes down, and a word saying what letting go will do. Then the ring
/// spins while the new videos come.
///
///   * pulling, not far enough — "Pull to refresh", the ring part filled
///   * far enough — "Release to refresh", the ring full
///   * refreshing — "Refreshing", the ring spinning
///
/// Hand-rolled rather than Material's RefreshProgressIndicator: that one is
/// driven by a RefreshIndicator and a scrollable, and these pulls are read
/// from the raw finger.
///
/// White with a shadow over a video (Home); [color] and no shadow over the
/// page's own background (Search's grid).
class PullRefreshBadge extends StatelessWidget {
  final double distance;
  final double triggerPx;
  final bool isRefreshing;
  final Color color;
  final bool overVideo;

  const PullRefreshBadge({
    super.key,
    required this.distance,
    required this.triggerPx,
    required this.isRefreshing,
    this.color = Colors.white,
    this.overVideo = true,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (distance / triggerPx).clamp(0.0, 1.0);
    final ready = progress >= 1.0;
    final label = isRefreshing
        ? 'Refreshing'
        : ready
        ? 'Release to refresh'
        : 'Pull to refresh';
    final shadow = overVideo
        ? const [Shadow(color: Color(0x99000000), blurRadius: 8)]
        : const <Shadow>[];
    return Opacity(
      // Fades in with the pull rather than popping up at the first pixel.
      opacity: isRefreshing ? 1 : (0.25 + 0.75 * progress).clamp(0.0, 1.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              key: const ValueKey('pull_refresh_ring'),
              // Filling with the pull; spinning once it is refreshing.
              value: isRefreshing ? null : progress,
              strokeWidth: 2.6,
              strokeCap: StrokeCap.round,
              color: color,
              backgroundColor: color.withValues(alpha: 0.22),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            key: const ValueKey('pull_refresh_label'),
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              shadows: shadow,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pull a list down from its top to refresh it — the same pull as Home's.
///
/// It is read from the finger itself rather than from the list going past
/// its end, so it starts with the first movement, fires at
/// [pullRefreshTriggerPx], and the list follows the finger down, with the
/// same words as Home. Flutter's RefreshIndicator, which Search used, only
/// counts what the list reports past its end and fires after about a sixth
/// of the screen.
///
/// [child] is the list: a scroll view, at the top of which a pull begins.
class PullToRefresh extends StatefulWidget {
  final Future<void> Function() onRefresh;
  final Widget child;

  /// The words and the ring. The page's text colour when not given.
  final Color? color;

  const PullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color,
  });

  @override
  State<PullToRefresh> createState() => PullToRefreshState();
}

class PullToRefreshState extends State<PullToRefresh> {
  /// Whether the list is at its top, as it last said.
  bool _atTop = true;

  int? _pointer;
  double? _startY;
  double? _startX;
  bool _decided = false;
  double _distance = 0;
  bool _refreshing = false;

  /// Refresh the way a pull does, with the words showing while it runs —
  /// for Search tapped again in the bottom bar.
  Future<void> show() => _refresh();

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _distance = pullRefreshTriggerPx;
    });
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          _distance = 0;
        });
      }
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _atTop = n.metrics.pixels <= n.metrics.minScrollExtent + 1;
    }
    return false;
  }

  void _down(PointerDownEvent e) {
    if (_refreshing) return;
    // One finger. A second one landing (a pinch, a palm) is not a pull.
    if (_pointer != null) {
      _reset();
      return;
    }
    _pointer = e.pointer;
    _startY = e.localPosition.dy;
    _startX = e.localPosition.dx;
    _decided = false;
    _distance = 0;
  }

  void _move(PointerMoveEvent e) {
    if (_startY == null || e.pointer != _pointer) return;
    final dy = e.localPosition.dy - _startY!;
    if (!_decided) {
      final dx = e.localPosition.dx - _startX!;
      if (dy.abs() < pullRefreshDecidePx && dx.abs() < pullRefreshDecidePx) {
        return;
      }
      // Sideways, up (scrolling the list), or down while the list is not
      // at its top (scrolling back up to it): not a pull.
      if (dy <= 0 || dy < dx.abs() * pullRefreshSteepness || !_atTop) {
        _reset();
        return;
      }
      _decided = true;
    }
    if (dy <= 0) {
      if (_distance != 0) setState(() => _distance = 0);
      return;
    }
    // Light damping past the trigger, as on Home, so a big flick does not
    // drag the list half way down the screen.
    final damped = dy <= pullRefreshTriggerPx
        ? dy
        : pullRefreshTriggerPx + (dy - pullRefreshTriggerPx) * 0.4;
    setState(() => _distance = damped);
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    final fired = _decided && _distance >= pullRefreshTriggerPx;
    _pointer = null;
    _startY = null;
    _decided = false;
    if (fired) {
      _refresh();
    } else if (_distance != 0) {
      setState(() => _distance = 0);
    }
  }

  void _reset() {
    // Forget the finger too: it is not a pull, whatever it does next.
    _pointer = null;
    _startY = null;
    _decided = false;
    if (_distance != 0) setState(() => _distance = 0);
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.onSurface;
    final pulling = _pointer != null && _decided;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: NotificationListener<OverscrollIndicatorNotification>(
            // The list's own glow or stretch at the top would fight the
            // pull: the pull is the feedback there.
            onNotification: (n) {
              if (n.leading) n.disallowIndicator();
              return false;
            },
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              child: TweenAnimationBuilder<double>(
                // Further than Home's video goes (half), so the words fit in
                // the gap above the list rather than over its first row.
                tween: Tween(end: _distance * 0.8),
                // With the finger while it pulls; easing back when it lets
                // go and when the new list is in.
                duration: pulling
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                builder: (context, offset, child) => Transform.translate(
                  offset: Offset(0, offset),
                  child: child,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
        if (_distance > 0 || _refreshing)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: PullRefreshBadge(
                  distance: _distance,
                  triggerPx: pullRefreshTriggerPx,
                  isRefreshing: _refreshing,
                  color: color,
                  overVideo: false,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
