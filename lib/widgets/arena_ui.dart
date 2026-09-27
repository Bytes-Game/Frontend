import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';

/// The small set of parts every screen is built from, so the whole app
/// looks like one thing: the same search bar, the same avatars, the same
/// round icon buttons, the same section titles and empty states.
///
/// The look is deliberately quiet, in the way Apple's own apps are: black
/// and white, grey for anything secondary, and ONE accent colour — blue —
/// for the thing on a screen you are meant to press. No gradients, no
/// glows. Colour that is everywhere stops meaning anything; kept to one
/// place, it tells you where to look.
///
/// Everything takes its colours from the theme, so it works in both light
/// and dark.

/// The one accent colour: buttons, links, your own chat bubbles.
const Color kAccent = AppTheme.primary;

/// Grey for things that sit on the page without being the point of it:
/// the fill of a search bar, an icon button, a chip.
Color quietFill(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);

/// Grey for secondary words: handles, times, captions.
Color quietText(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

/// A press you can feel: while held, the thing sinks slightly and leans
/// towards the finger in 3D — press a corner and that corner goes down,
/// like a real card — then springs back when let go.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// How far it shrinks while held. 0.97 is just enough to notice.
  final double pressedScale;

  /// How far it leans towards the finger, in radians. Small on purpose:
  /// enough to feel, not enough to read as a wobble.
  final double maxTilt;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
    this.maxTilt = 0.12,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  /// Where it leans while held: x about the horizontal axis, y about the
  /// vertical one.
  Offset _lean = Offset.zero;

  void _press(Offset local) {
    final size = context.size;
    var lean = Offset.zero;
    if (size != null && size.width > 0 && size.height > 0) {
      // -1..1 across each side, from the middle.
      final fx = (local.dx / size.width) * 2 - 1;
      final fy = (local.dy / size.height) * 2 - 1;
      // Wide things (a row) lean less sideways than tall things do, or a
      // full-width row would swing like a door.
      final aspect = (size.height / size.width).clamp(0.25, 1.0);
      lean = Offset(-fy * widget.maxTilt, fx * widget.maxTilt * aspect);
    }
    setState(() {
      _down = true;
      _lean = lean;
    });
  }

  void _release() {
    if (_down) setState(() => _down = false);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (d) => _press(d.localPosition) : null,
      onTapUp: enabled ? (_) => _release() : null,
      onTapCancel: enabled ? _release : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _release();
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: TweenAnimationBuilder<Offset>(
        tween: Tween(end: _down ? _lean : Offset.zero),
        duration: Duration(milliseconds: _down ? 90 : 260),
        curve: _down ? Curves.easeOut : Curves.easeOutBack,
        builder: (context, lean, child) => Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateX(lean.dx)
            ..rotateY(lean.dy),
          child: child,
        ),
        child: AnimatedScale(
          scale: _down ? widget.pressedScale : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A person's picture: their initial on a soft grey disc, the way a
/// contact without a photo looks on an iPhone.
///
/// [ring] draws a thin ring in one colour when it says something: their
/// league in search, something unread from them in messages. A green dot
/// means they are online.
class ArenaAvatar extends StatelessWidget {
  final String name;
  final double size;
  final Color? ring;
  final bool online;

  const ArenaAvatar({
    super.key,
    required this.name,
    this.size = 44,
    this.ring,
    this.online = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final ringWidth = size >= 48 ? 2.0 : 1.5;

    final face = Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFA5ABB8), Color(0xFF858994)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.42,
          height: 1,
        ),
      ),
    );

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: ring == null
                ? face
                : Container(
                    padding: EdgeInsets.all(ringWidth),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ring,
                    ),
                    // A gap in the page's own colour, so the ring reads as a
                    // ring and not as a fatter picture.
                    child: Container(
                      padding: EdgeInsets.all(ringWidth),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: bg,
                      ),
                      child: face,
                    ),
                  ),
          ),
          if (online)
            Positioned(
              right: size * 0.02,
              bottom: size * 0.02,
              child: Container(
                width: size * 0.26,
                height: size * 0.26,
                decoration: BoxDecoration(
                  color: AppTheme.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: bg, width: size * 0.045 + 1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A round icon button. Quiet grey by default; filled with the accent when
/// [filled] — kept for the one action on a screen that matters most.
class IconBubble extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool filled;

  /// For use over a picture or a dark header, where the page's own greys
  /// would disappear.
  final bool onImage;

  const IconBubble({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 40,
    this.filled = false,
    this.onImage = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color fg = filled || onImage ? Colors.white : cs.onSurface;
    final Color bg = filled
        ? kAccent
        : onImage
        ? Colors.black.withValues(alpha: 0.35)
        : quietFill(context);
    final bubble = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.48, color: fg),
    );
    final button = Pressable(onTap: onTap, child: bubble);
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// The app's search bar, shaped like the one in Apple's apps: a rounded
/// grey field, a magnifier, and a clear button only when there is
/// something to clear.
class ArenaSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Called after the text has been cleared with the clear button.
  final VoidCallback? onCleared;

  const ArenaSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint = 'Search',
    this.onChanged,
    this.onSubmitted,
    this.onCleared,
  });

  @override
  State<ArenaSearchField> createState() => _ArenaSearchFieldState();
}

class _ArenaSearchFieldState extends State<ArenaSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasText = widget.controller.text.isNotEmpty;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: quietFill(context),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.search_rounded, size: 20, color: quietText(context)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              onChanged: widget.onChanged,
              onSubmitted: widget.onSubmitted,
              textInputAction: TextInputAction.search,
              cursorColor: kAccent,
              style: TextStyle(fontSize: 16, color: cs.onSurface),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(fontSize: 16, color: quietText(context)),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
                // Zero, explicitly. The app's theme gives every text box 20
                // pixels of padding at the side and 16 above and below, and a
                // collapsed field still takes it — which pushed the words
                // right and off-centre inside this slim bar.
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (hasText)
            IconButton(
              tooltip: 'Clear',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                Icons.cancel_rounded,
                size: 18,
                color: quietText(context),
              ),
              onPressed: () {
                widget.controller.clear();
                widget.onChanged?.call('');
                widget.onCleared?.call();
              },
            )
          else
            const SizedBox(width: 10),
        ],
      ),
    );
  }
}

/// A section's title, with an optional action on the right ("See all") in
/// the accent colour, the way a link looks.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const SectionTitle({
    super.key,
    required this.title,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(16, 20, 8, 8),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          if (action != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: kAccent,
                visualDensity: VisualDensity.compact,
              ),
              // Size and weight on the Text, not the button: a button's
              // own text style replaces the app's font rather than adding
              // to it.
              child: Text(
                action!,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The main button on a screen: solid accent, white words.
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;

  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    required this.onPressed,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onPressed,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: kAccent,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a screen shows when there is nothing in it yet: a large grey
/// icon, one line saying what is missing, one saying what to do.
class ArenaEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  const ArenaEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 52,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: quietText(context),
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              PrimaryButton(
                label: actionLabel!,
                icon: actionIcon,
                onPressed: onAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tabs drawn as a segmented control, like the one in Apple's apps: a grey
/// track, and the chosen tab raised on a lighter piece that slides.
///
/// [scrollable] for a row that may not fit the screen (a profile with seven
/// tabs); otherwise the tabs share the width equally.
class ArenaPillTabs extends StatelessWidget {
  final TabController controller;

  /// Each tab's words, and an optional icon before them.
  final List<({IconData? icon, String label})> tabs;
  final bool scrollable;

  const ArenaPillTabs({
    super.key,
    required this.controller,
    required this.tabs,
    this.scrollable = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: quietFill(context),
        borderRadius: BorderRadius.circular(9),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: scrollable,
        tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.zero,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        indicator: BoxDecoration(
          color: dark ? const Color(0xFF636366) : Colors.white,
          borderRadius: BorderRadius.circular(7),
          boxShadow: dark
              ? null
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
        ),
        labelColor: cs.onSurface,
        unselectedLabelColor: cs.onSurface.withValues(alpha: 0.75),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        tabs: [
          for (final t in tabs)
            Tab(
              height: 32,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: scrollable ? 14 : 6),
                // Scales down rather than overflowing on a narrow phone.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (t.icon != null) ...[
                        Icon(t.icon, size: 15),
                        const SizedBox(width: 5),
                      ],
                      Text(t.label),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small rounded label — a league, a record, a status. Grey unless it is
/// given a [color] that means something.
class InfoChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;

  const InfoChip({super.key, required this.label, this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color;
    // Bright colours (gold, silver) vanish on a light page, so the words
    // take a darker shade of the same colour there.
    final Color ink = c == null
        ? quietText(context)
        : Theme.of(context).brightness == Brightness.light
        ? Color.lerp(c, Colors.black, 0.4)!
        : c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c == null ? quietFill(context) : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: ink),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// A card you can tilt.
///
/// Drag across it and it leans in 3D, following the finger, with a sheen
/// sliding over it like light on glass; let go and it springs back flat
/// with a little wobble. A tap is passed on. Used for the clip on the trim
/// screen and the challenge preview on the details screen.
class TiltCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double radius;

  /// The colour of the soft shadow under it.
  final Color glow;

  const TiltCard({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 22,
    this.glow = AppTheme.primary,
  });

  @override
  State<TiltCard> createState() => _TiltCardState();
}

class _TiltCardState extends State<TiltCard>
    with SingleTickerProviderStateMixin {
  Offset _tilt = Offset.zero;
  late final AnimationController _back =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 520),
      )..addListener(() {
        final t = Curves.elasticOut.transform(_back.value);
        setState(() => _tilt = Offset.lerp(_from, Offset.zero, t)!);
      });
  Offset _from = Offset.zero;

  /// The furthest it leans, in radians — enough to read as 3D, not so much
  /// the video is hard to see.
  static const double _max = 0.32;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _onPan(DragUpdateDetails d, Size size) {
    _back.stop();
    setState(() {
      _tilt = Offset(
        (_tilt.dx - d.delta.dy / size.height * 1.4).clamp(-_max, _max),
        (_tilt.dy + d.delta.dx / size.width * 1.4).clamp(-_max, _max),
      );
    });
  }

  void _release() {
    _from = _tilt;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        final sheen = Alignment(-_tilt.dy * 4, -_tilt.dx * 4);
        return GestureDetector(
          onTap: widget.onTap,
          onPanUpdate: (d) => _onPan(d, size),
          onPanEnd: (_) => _release(),
          onPanCancel: _release,
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0016)
              ..rotateX(_tilt.dx)
              ..rotateY(_tilt.dy),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.radius),
                boxShadow: [
                  BoxShadow(
                    color: widget.glow.withValues(alpha: 0.22),
                    blurRadius: 40,
                    offset: Offset(-_tilt.dy * 40, 18 + _tilt.dx * 40),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(widget.radius),
                child: Stack(
                  children: [
                    widget.child,
                    // Light on glass, sliding as it leans.
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: RadialGradient(
                              center: sheen,
                              radius: 0.9,
                              colors: [
                                Colors.white.withValues(
                                  alpha: 0.18 * (_tilt.distance / _max),
                                ),
                                Colors.white.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
