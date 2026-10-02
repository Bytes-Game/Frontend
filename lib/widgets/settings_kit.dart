import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';

/// The pieces every settings page is built from, so they all look the same:
/// rounded groups on a soft background, each row with its icon on a small
/// coloured square, the way iPhone and Instagram settings look.

/// The page background behind the groups.
Color settingsBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppTheme.bgDark
        : AppTheme.surfaceLightHigh;

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
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 60),
          child: Divider(
            height: 0.5,
            thickness: 0.5,
            color: dark ? AppTheme.borderDark : AppTheme.borderLight,
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
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: muted,
                ),
              ),
            ),
          Material(
            color: dark ? AppTheme.surfaceDark : cs.surface,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            clipBehavior: Clip.antiAlias,
            child: Column(children: rows),
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

/// The small coloured square an icon sits on.
class SettingsIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  const SettingsIcon(this.icon, this.color, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: Colors.white),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
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
                        fontWeight: FontWeight.w500,
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
        activeTrackColor: AppTheme.success,
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

  const SettingsChoiceTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    return InkWell(
      onTap: onTap,
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
                      style: TextStyle(fontSize: 16, color: cs.onSurface)),
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
