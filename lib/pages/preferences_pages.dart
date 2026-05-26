import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// Appearance settings — theme picker. Persists the choice into the
/// user's `settings.theme` field on the backend so it syncs across
/// devices. App-level theming wiring (reading this value in
/// MaterialApp.themeMode) is intentionally a separate task because
/// we don't want to ship a half-applied theme toggle that updates
/// the user record but doesn't actually repaint until a re-launch.
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage>
    with PageTracker<AppearancePage> {
  @override
  String get pageName => 'appearance_page';

  String _selected = 'system';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings =
        Provider.of<DataProvider>(context, listen: false).user?.settings ??
            const {};
    _selected = (settings['theme'] as String?) ?? 'system';
  }

  Future<void> _save(String value) async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    if (user == null) return;
    setState(() {
      _selected = value;
      _saving = true;
    });
    EventTracker.instance.trackTap(
      target: 'appearance_set',
      pageName: pageName,
      params: {'theme': value},
    );
    // Apply locally first so the user sees the theme flip immediately
    // — even if the server save fails the UX is responsive. We sync
    // to the server right after; on failure we keep the local state
    // and surface a toast so the user knows to retry.
    final tp = Provider.of<ThemeProvider>(context, listen: false);
    tp.setThemeMode(_themeModeFor(value));

    final newSettings = {...user.settings, 'theme': value};
    final result = await ApiService.updateUserProfile(
      userId: user.id,
      settings: newSettings,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    // result.success is the authoritative signal — result.user may be
    // null even on success (server returned 200 with no-op response).
    // The theme was already applied locally above, so a missing fresh
    // user here doesn't undo the visible change; we only refuse to
    // merge if the server signaled failure.
    if (result.success) {
      if (result.user != null) {
        Provider.of<DataProvider>(context, listen: false)
            .setUser(result.user!);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved locally — could not sync to server.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// Map the wire-format string ("system"/"light"/"dark") to the
  /// Flutter ThemeMode enum. Anything unrecognized falls back to
  /// `system` so a forward-compat blob never breaks rendering.
  static ThemeMode _themeModeFor(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Appearance'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          children: [
            _option(
              value: 'system',
              label: 'Match system',
              subtitle: 'Follow your device\'s light/dark setting',
              icon: Icons.brightness_auto,
            ),
            _option(
              value: 'light',
              label: 'Light',
              subtitle: 'Always show in light mode',
              icon: Icons.light_mode_outlined,
            ),
            _option(
              value: 'dark',
              label: 'Dark',
              subtitle: 'Always show in dark mode',
              icon: Icons.dark_mode_outlined,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(AppTheme.space16),
              child: Text(
                'Synced to your account so it persists across devices.',
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _option({
    required String value,
    required String label,
    required String subtitle,
    required IconData icon,
  }) {
    // RadioListTile's groupValue/onChanged got deprecated post-3.32 in
    // favor of a RadioGroup<T> ancestor pattern, but the old API still
    // works and the new one isn't worth the extra widget tree for two
    // single-pick lists. Suppressing the deprecation so analyze stays
    // green; revisit once RadioGroup<T> is stable across our targeted
    // Flutter range.
    return RadioListTile<String>(
      value: value,
      // ignore: deprecated_member_use
      groupValue: _selected,
      // ignore: deprecated_member_use
      onChanged: (v) {
        if (v != null) _save(v);
      },
      title: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(left: 32),
        child: Text(subtitle),
      ),
    );
  }
}

/// Language picker. Single option today (English) — the i18n string
/// extraction is itself a separate task. We surface the toggle so
/// users can see it's planned and the selection persists into their
/// settings JSON for future use.
class LanguagePage extends StatefulWidget {
  const LanguagePage({super.key});

  @override
  State<LanguagePage> createState() => _LanguagePageState();
}

class _LanguagePageState extends State<LanguagePage>
    with PageTracker<LanguagePage> {
  @override
  String get pageName => 'language_page';

  String _selected = 'en';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings =
        Provider.of<DataProvider>(context, listen: false).user?.settings ??
            const {};
    _selected = (settings['language'] as String?) ?? 'en';
  }

  Future<void> _save(String value) async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    if (user == null) return;
    setState(() {
      _selected = value;
      _saving = true;
    });
    final newSettings = {...user.settings, 'language': value};
    final result = await ApiService.updateUserProfile(
      userId: user.id,
      settings: newSettings,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    // result.user may be null even on success (no-op 200). Only merge
    // when the server actually returned a fresh user object.
    if (result.success && result.user != null) {
      Provider.of<DataProvider>(context, listen: false).setUser(result.user!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Language')),
      body: SafeArea(
        child: ListView(
          children: [
            RadioListTile<String>(
              value: 'en',
              // ignore: deprecated_member_use
              groupValue: _selected,
              // ignore: deprecated_member_use
              onChanged: _saving ? null : (v) => v == null ? null : _save(v),
              title: const Text('English'),
              subtitle: const Text('Currently the only fully translated language'),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(AppTheme.space16),
              child: Text(
                'Other languages are coming. Your preference here is '
                'saved to your account so it auto-applies once each '
                'language ships.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
