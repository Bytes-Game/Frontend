import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';

/// What the person picked from the burst.
enum CreateChoice { record, upload }

/// The + button's pop-out: Record and Upload rise out of the button in 3D.
///
/// They start lying flat and small at the button, then swing upright as
/// they fly out along an arc, while the screen behind blurs and dims. It can
/// be used two ways, and both feel like one gesture:
///
///   * Tap +, then tap a choice.
///   * Hold +, slide the finger onto a choice — it swells and leans towards
///     the finger — and let go to pick it. No second tap.
///
/// Letting go anywhere else leaves the burst open, so a hold that was only
/// a hold does not throw the choice away. Tapping the dimmed background or
/// the × closes it.
class CreateBurst {
  CreateBurst._();

  /// Opens the burst at [anchor], the centre of the + button in global
  /// coordinates. [onChoose] runs after the burst has closed.
  static CreateBurstHandle show(
    BuildContext context, {
    required Offset anchor,
    required bool fromHold,
    required void Function(CreateChoice) onChoose,
  }) {
    final handle = CreateBurstHandle._();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BurstOverlay(
        anchor: anchor,
        fromHold: fromHold,
        handle: handle,
        onDone: (choice) {
          entry.remove();
          handle._closed = true;
          if (choice != null) onChoose(choice);
        },
      ),
    );
    Overlay.of(context).insert(entry);
    return handle;
  }
}

/// Lets the + button keep steering the burst while the finger that opened
/// it is still down: the button's own gesture reports where the finger
/// goes, and where it is let go.
class CreateBurstHandle extends ChangeNotifier {
  CreateBurstHandle._();

  Offset? _pointer;
  Offset? _released;
  bool _closed = false;

  /// Where the finger is now, in global coordinates.
  Offset? get pointer => _pointer;

  /// Where the finger was let go, once it has been.
  Offset? get released => _released;

  bool get isClosed => _closed;

  void pointerMoved(Offset global) {
    if (_closed) return;
    _pointer = global;
    notifyListeners();
  }

  void pointerReleased(Offset global) {
    if (_closed) return;
    _pointer = global;
    _released = global;
    notifyListeners();
  }
}

class _Choice {
  final CreateChoice value;
  final IconData icon;
  final String label;

  /// Direction from the + button, in degrees; -90 is straight up.
  final double angle;
  final Color color;

  const _Choice(this.value, this.icon, this.label, this.angle, this.color);
}

const _choices = [
  _Choice(
    CreateChoice.record,
    Icons.videocam_rounded,
    'Record',
    -128,
    Color(0xFFFF453A),
  ),
  _Choice(
    CreateChoice.upload,
    Icons.photo_library_rounded,
    'Upload',
    -52,
    AppTheme.primary,
  ),
];

class _BurstOverlay extends StatefulWidget {
  final Offset anchor;
  final bool fromHold;
  final CreateBurstHandle handle;
  final void Function(CreateChoice?) onDone;

  const _BurstOverlay({
    required this.anchor,
    required this.fromHold,
    required this.handle,
    required this.onDone,
  });

  @override
  State<_BurstOverlay> createState() => _BurstOverlayState();
}

class _BurstOverlayState extends State<_BurstOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
    reverseDuration: const Duration(milliseconds: 220),
  )..forward();

  /// How far from the + button each choice lands.
  static const double _reach = 118;

  /// How close the finger must be to a choice to be "on" it.
  static const double _hitRadius = 50;

  int? _hovered;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.handle.addListener(_onPointer);
  }

  @override
  void dispose() {
    widget.handle.removeListener(_onPointer);
    _open.dispose();
    super.dispose();
  }

  Offset _centreOf(int i, double t) {
    final a = _choices[i].angle * math.pi / 180;
    return widget.anchor + Offset(math.cos(a), math.sin(a)) * (_reach * t);
  }

  int? _choiceAt(Offset p) {
    for (var i = 0; i < _choices.length; i++) {
      if ((p - _centreOf(i, 1)).distance <= _hitRadius) return i;
    }
    return null;
  }

  void _onPointer() {
    final p = widget.handle.pointer;
    final hovered = p == null ? null : _choiceAt(p);
    if (hovered != _hovered) {
      if (hovered != null) HapticFeedback.selectionClick();
      setState(() => _hovered = hovered);
    }
    final released = widget.handle.released;
    if (released != null) {
      final picked = _choiceAt(released);
      // Let go on a choice: that's the pick. Anywhere else: stay open, so
      // a hold that was only a hold can still be finished with a tap.
      if (picked != null) _finish(_choices[picked].value);
    }
  }

  Future<void> _finish(CreateChoice? choice) async {
    if (_closing) return;
    _closing = true;
    if (choice != null) HapticFeedback.mediumImpact();
    await _open.reverse();
    widget.onDone(choice);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _open,
      builder: (context, _) {
        final t = _open.value;
        final fly = Curves.easeOutBack.transform(t);
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              // The screen behind blurs and dims; tapping it closes.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _finish(null),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10 * t, sigmaY: 10 * t),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.45 * t),
                    ),
                  ),
                ),
              ),
              // What to do, above the arc.
              Positioned(
                left: 0,
                right: 0,
                top: widget.anchor.dy - _reach - 104,
                child: Opacity(
                  opacity: t,
                  child: Text(
                    widget.fromHold ? 'Slide to choose' : 'Create a challenge',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < _choices.length; i++) _buildChoice(i, fly),
              // The + turns into a × that closes.
              Positioned(
                left: widget.anchor.dx - 22,
                top: widget.anchor.dy - 15,
                child: GestureDetector(
                  onTap: () => _finish(null),
                  child: Transform.rotate(
                    angle: t * math.pi / 4,
                    child: Container(
                      width: 44,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.add_rounded,
                        color: Colors.black,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChoice(int i, double fly) {
    final c = _choices[i];
    final centre = _centreOf(i, fly);
    final hovered = _hovered == i;
    final p = widget.handle.pointer;

    // Lying flat at the start, upright once out. While the finger is on
    // it, it leans towards the finger, like a card pressed at one corner.
    double leanX = 0, leanY = 0;
    if (hovered && p != null) {
      final d = p - centre;
      leanX = (-d.dy / _hitRadius).clamp(-1.0, 1.0) * 0.35;
      leanY = (d.dx / _hitRadius).clamp(-1.0, 1.0) * 0.35;
    }
    final t = fly.clamp(0.0, 1.0);
    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.0022)
      ..rotateX((1 - t) * 1.35 + leanX)
      ..rotateY(leanY)
      ..scaleByDouble(
        (0.35 + 0.65 * t) * (hovered ? 1.18 : 1),
        (0.35 + 0.65 * t) * (hovered ? 1.18 : 1),
        1,
        1,
      );

    const size = 66.0;
    return Positioned(
      left: centre.dx - 50,
      top: centre.dy - size / 2,
      width: 100,
      child: Opacity(
        opacity: t,
        child: Transform(
          alignment: Alignment.center,
          transform: transform,
          child: GestureDetector(
            onTap: () => _finish(c.value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered ? c.color : Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    c.icon,
                    size: 30,
                    color: hovered ? Colors.white : c.color,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  c.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
