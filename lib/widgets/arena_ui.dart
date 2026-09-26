import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';

/// The small set of parts every screen is built from, so the whole app
/// looks like one thing: the same search bar, the same avatars, the same
/// round icon buttons, the same section titles and empty states.
///
/// Everything takes its colours from the theme, so it works in both light
/// and dark, and from AppTheme's purple-to-pink brand gradient for the
/// parts that should stand out.

/// The brand gradient's two colours, for anything painted with it.
const List<Color> kBrandColors = [AppTheme.primary, AppTheme.accentPink];

/// A slightly shrinking press, so a tap is felt before anything opens.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// How far it shrinks while held. 0.96 is just enough to notice.
  final double pressedScale;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// An icon painted with a gradient instead of one flat colour.
class GradientIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final List<Color> colors;

  const GradientIcon(
    this.icon, {
    super.key,
    this.size = 22,
    this.colors = kBrandColors,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ).createShader(rect),
      child: Icon(icon, size: size, color: Colors.white),
    );
  }
}

/// A person's picture: their initial on a gradient, inside a ring.
///
/// The ring says something rather than decorating: the brand gradient when
/// there is something new from them, their league's colours on a profile or
/// in search, a plain hairline otherwise. A green dot means they are online.
class ArenaAvatar extends StatelessWidget {
  final String name;
  final double size;

  /// Colours for the ring. Null draws a thin neutral ring.
  final List<Color>? ring;
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
    final cs = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final ringWidth = size >= 48 ? 2.5 : 2.0;
    final fill = _fillFor(name);

    final face = Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: fill,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.4,
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
            child: Container(
              padding: EdgeInsets.all(ringWidth),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ring == null
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: ring!,
                      ),
                border: ring == null
                    ? Border.all(
                        color: cs.onSurface.withValues(alpha: 0.12),
                        width: 1,
                      )
                    : null,
              ),
              // A gap between ring and face, in the page's own colour, so
              // the ring reads as a ring and not as a fatter avatar.
              child: Container(
                padding: EdgeInsets.all(ring == null ? 0 : ringWidth * 0.8),
                decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
                child: face,
              ),
            ),
          ),
          if (online)
            Positioned(
              right: size * 0.02,
              bottom: size * 0.02,
              child: Container(
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  color: AppTheme.success,
                  shape: BoxShape.circle,
                  border: Border.all(color: bg, width: size * 0.05 + 1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Each name gets one of a few fills, so a list of people is not a
  /// column of identical purple circles, and the same person always gets
  /// the same colour.
  static List<Color> _fillFor(String name) {
    const fills = [
      [Color(0xFF8B5CF6), Color(0xFFEC4899)],
      [Color(0xFF06B6D4), Color(0xFF8B5CF6)],
      [Color(0xFFF59E0B), Color(0xFFEC4899)],
      [Color(0xFF10B981), Color(0xFF06B6D4)],
      [Color(0xFF3B82F6), Color(0xFF8B5CF6)],
      [Color(0xFFEF4444), Color(0xFFF59E0B)],
    ];
    var h = 0;
    for (final c in name.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return fills[h % fills.length];
  }
}

/// A round icon button. Soft and see-through by default; filled with the
/// brand gradient when [filled] — kept for the one action on a screen that
/// matters most.
class IconBubble extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final bool filled;

  /// For use over a picture or a coloured header, where the theme's own
  /// surface colours would disappear.
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
    final bubble = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: kBrandColors,
              )
            : null,
        color: filled
            ? null
            : onImage
            ? Colors.black.withValues(alpha: 0.28)
            : cs.onSurface.withValues(alpha: 0.07),
        border: filled
            ? null
            : Border.all(
                color: onImage
                    ? Colors.white.withValues(alpha: 0.18)
                    : cs.onSurface.withValues(alpha: 0.06),
              ),
        boxShadow: filled ? AppTheme.glowPrimary(intensity: 0.3) : null,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: fg),
    );
    final button = Pressable(onTap: onTap, child: bubble);
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// The app's search bar: a rounded pill that lights up in the brand colours
/// while you are typing in it, with a clear button that appears only when
/// there is something to clear.
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
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_rebuild);
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    _focus.removeListener(_rebuild);
    widget.controller.removeListener(_rebuild);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final focused = _focus.hasFocus;
    final hasText = widget.controller.text.isNotEmpty;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 48,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        // The border is the gradient: a padded box painted with it, and the
        // field on top in the surface colour.
        gradient: LinearGradient(
          colors: focused
              ? kBrandColors
              : [
                  cs.onSurface.withValues(alpha: 0.08),
                  cs.onSurface.withValues(alpha: 0.08),
                ],
        ),
        boxShadow: focused ? AppTheme.glowPrimary(intensity: 0.22) : null,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            cs.onSurface.withValues(alpha: 0.05),
            Theme.of(context).scaffoldBackgroundColor,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        ),
        child: Row(
          children: [
            const SizedBox(width: 14),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: focused
                  ? const GradientIcon(
                      Icons.search_rounded,
                      key: ValueKey('on'),
                      size: 22,
                    )
                  : Icon(
                      Icons.search_rounded,
                      key: const ValueKey('off'),
                      size: 22,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                textInputAction: TextInputAction.search,
                cursorColor: AppTheme.primary,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(
                    fontSize: 15,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: hasText
                  ? IconButton(
                      key: const ValueKey('clear'),
                      tooltip: 'Clear',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.cancel_rounded,
                        size: 20,
                        color: cs.onSurface.withValues(alpha: 0.45),
                      ),
                      onPressed: () {
                        widget.controller.clear();
                        widget.onChanged?.call('');
                        widget.onCleared?.call();
                      },
                    )
                  : const SizedBox(width: 14, key: ValueKey('none')),
            ),
          ],
        ),
      ),
    );
  }
}

/// A section's title: a small gradient icon, the words, and an optional
/// action on the right ("See all").
class SectionTitle extends StatelessWidget {
  final String title;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  const SectionTitle({
    super.key,
    required this.title,
    this.icon,
    this.action,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(16, 18, 8, 8),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (icon != null) ...[
            GradientIcon(icon!, size: 18),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
          if (action != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: cs.onSurface.withValues(alpha: 0.7),
                visualDensity: VisualDensity.compact,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(action!),
                  const Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A button filled with the brand gradient.
class GradientButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final double height;

  const GradientButton({
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
          gradient: const LinearGradient(colors: kBrandColors),
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          boxShadow: AppTheme.glowPrimary(intensity: 0.3),
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
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a screen shows when there is nothing in it yet: a gradient icon in
/// a soft glow, one line saying what is missing, one saying what to do.
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
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppTheme.primary.withValues(alpha: 0.22),
                    AppTheme.accentPink.withValues(alpha: 0.04),
                  ],
                ),
                border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.25),
                ),
              ),
              alignment: Alignment.center,
              child: GradientIcon(icon, size: 40),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              GradientButton(
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

/// Tabs drawn as a segmented track: the chosen one fills with the brand
/// gradient and slides between the others.
///
/// [scrollable] for a row that may not fit the screen (a profile with seven
/// tabs); otherwise the tabs share the width equally.
class ArenaPillTabs extends StatelessWidget {
  final TabController controller;
  final List<({IconData icon, String label})> tabs;
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
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: scrollable,
        tabAlignment: scrollable ? TabAlignment.start : TabAlignment.fill,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.zero,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        splashBorderRadius: BorderRadius.circular(AppTheme.radiusFull),
        indicator: BoxDecoration(
          gradient: const LinearGradient(colors: kBrandColors),
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          boxShadow: AppTheme.glowPrimary(intensity: 0.25),
        ),
        labelColor: Colors.white,
        unselectedLabelColor: cs.onSurface.withValues(alpha: 0.65),
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        tabs: [
          for (final t in tabs)
            Tab(
              height: 36,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: scrollable ? 14 : 6),
                // Scales down rather than overflowing on a narrow phone.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(t.icon, size: 16),
                      const SizedBox(width: 6),
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

/// A small rounded label with an icon — for a league, a count, a status.
class InfoChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;

  const InfoChip({
    super.key,
    required this.label,
    this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    // Bright colours (gold, silver) vanish on a light page, so the words
    // take a darker shade of the same colour there.
    final ink = Theme.of(context).brightness == Brightness.light
        ? Color.lerp(color, Colors.black, 0.4)!
        : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
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
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ],
      ),
    );
  }
}
