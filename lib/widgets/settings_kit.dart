import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';

/// The pieces every settings page is built from, so they all look the same:
/// rounded groups on the page, each row with its icon on a small blue
/// tile like the app's own icon.
///
/// In dark mode the groups are deep-blue glass over the blue glow behind
/// every page (PageBackdrop). In light mode they are white cards on a soft
/// blue-grey.

/// The page background behind the groups: clear in dark mode, so the glow
/// shows; a soft blue-grey in light mode.
Color settingsBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.transparent
        : const Color(0xFFF2F4F8);

/// The top bar's colour on a settings page: the theme's in dark mode (clear
/// over the glow, deep blue once the page scrolls under it), the page's
/// blue-grey in light mode.
Color? settingsBarColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? null
        : settingsBackground(context);

/// The look of a settings card, light or dark: its fill, its edge and its
/// shadow. Shared, so a page's own cards match the groups.
BoxDecoration settingsCard(BuildContext context, {double radius = 18}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return BoxDecoration(
    color: dark ? const Color(0xB80B1A2E) : Colors.white,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: dark ? const Color(0x2664D2FF) : const Color(0xFFE5EAF2),
      width: 0.8,
    ),
    boxShadow: dark
        ? null
        : const [
            BoxShadow(
              color: Color(0x0F0A84FF),
              blurRadius: 18,
              offset: Offset(0, 6),
            ),
          ],
  );
}

/// The muted colour for headings and notes: a blue-grey in dark mode.
Color settingsMuted(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF8DA2BD)
        : AppTheme.textMutedLight;

/// A rounded group of rows, with an optional heading above and a note below.
class SettingsGroup extends StatelessWidget {
  final String? title;
  final String? footer;
  final List<Widget> children;

  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = settingsMuted(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 64),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: dark ? const Color(0x1FFFFFFF) : AppTheme.borderLight,
          ),
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, AppTheme.space8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.space12, AppTheme.space8, AppTheme.space12, 6),
              child: Text(
                title!.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9,
                  color: muted,
                ),
              ),
            ),
          DecoratedBox(
            decoration: settingsCard(context),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(18),
              clipBehavior: Clip.antiAlias,
              child: Column(children: rows),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.space12, 6, AppTheme.space12, 0),
              child: Text(
                footer!,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// The small tile an icon sits on: [color] shading to a little lighter at
/// the top, like the app's own icon.
class SettingsIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const SettingsIcon(this.icon, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(color, Colors.white, 0.22)!, color],
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.26),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 19, color: Colors.white),
    );
  }
}

/// One row: icon, title, an optional line under it or value on the right,
/// and a chevron when it leads somewhere.
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Red, for leaving or deleting.
  final bool destructive;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = settingsMuted(context);
    return InkWell(
      onTap: onTap,
      splashColor: AppTheme.primary.withValues(alpha: 0.12),
      highlightColor: AppTheme.primary.withValues(alpha: 0.06),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space16, vertical: 10),
          child: Row(
            children: [
              SettingsIcon(icon, destructive ? AppTheme.error : color),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                        color: destructive ? AppTheme.error : cs.onSurface,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
                    ],
                  ],
                ),
              ),
              if (value != null) ...[
                const SizedBox(width: 8),
                Text(value!, style: TextStyle(fontSize: 15, color: muted)),
              ],
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (onTap != null && !destructive) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 22, color: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A row with a switch on the right. The whole row flips it.
class SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final change = onChanged;
    return SettingsTile(
      icon: icon,
      color: color,
      title: title,
      subtitle: subtitle,
      onTap: change == null ? null : () => change(!value),
      trailing: Switch.adaptive(
        value: value,
        activeTrackColor: AppTheme.primary,
        onChanged: change,
      ),
    );
  }
}

/// A choice among a few options: a tick on the one picked.
class SettingsChoiceTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  /// Greyed out and not tappable: a choice that does not apply right now
  /// (say why in [subtitle]).
  final bool enabled;

  const SettingsChoiceTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.selected,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = settingsMuted(context);
    return InkWell(
      onTap: enabled ? onTap : null,
      splashColor: AppTheme.primary.withValues(alpha: 0.12),
      highlightColor: AppTheme.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space16, vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 16,
                          color: enabled ? cs.onSurface : muted)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: TextStyle(fontSize: 13, color: muted)),
                  ],
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: selected ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: const Icon(Icons.check_rounded,
                  color: AppTheme.primary, size: 22),
            ),
          ],
        ),
      ),
    );
  }
}
