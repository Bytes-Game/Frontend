import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/pages/free_up_space_page.dart';
import 'package:myapp/pages/notification_settings_page.dart';
import 'package:myapp/pages/preferences_pages.dart';
import 'package:myapp/pages/privacy_page.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/pages/two_factor_setup_page.dart';
import 'package:myapp/pages/watch_history_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/settings_kit.dart';

/// Settings and privacy, as a page of its own.
///
/// It used to be a long sheet that slid up over the profile, with two rows
/// that did nothing but say "coming soon" and a Language row with one
/// language in it. Every row here works: each one opens a page that does
/// what it says, or does it on the spot.
class SettingsPage extends StatefulWidget {
  final VoidCallback onEditProfile;
  final VoidCallback onShareProfile;

  /// Back to the profile, on its Saved tab / Liked tab.
  final VoidCallback onSaved;
  final VoidCallback onLiked;

  const SettingsPage({
    super.key,
    required this.onEditProfile,
    required this.onShareProfile,
    required this.onSaved,
    required this.onLiked,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with PageTracker<SettingsPage> {
  @override
  String get pageName => 'settings_page';

  void _open(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _logout() async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Log out of @${user?.username ?? ''}?'),
        content: const Text(
            "You'll need your username and password to sign back in."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('logout_confirm'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    EventTracker.instance.trackTap(target: 'logout', pageName: pageName);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    Navigator.of(context).popUntil((r) => r.isFirst);
    // ignore: use_build_context_synchronously
    auth.logout(context);
  }

  static String _themeLabel(Map<String, dynamic> settings) {
    switch (settings['theme']) {
      case 'light':
        return 'Light';
      case 'dark':
        return 'Dark';
      default:
        return 'Automatic';
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<DataProvider>(context).user;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    final name = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
        : (user?.username ?? '');

    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Settings and privacy'),
        backgroundColor: settingsBackground(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTheme.space40),
        children: [
          // You, at the top: tap to edit your profile.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.space16, AppTheme.space8, AppTheme.space16, 0),
            child: Material(
              color: dark ? AppTheme.surfaceDark : cs.surface,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('settings_account'),
                onTap: widget.onEditProfile,
                child: Padding(
                  padding: const EdgeInsets.all(AppTheme.space16),
                  child: Row(
                    children: [
                      ArenaAvatar(name: user?.username ?? '?', size: 56),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text('@${user?.username ?? ''} · Edit profile',
                                style: TextStyle(fontSize: 13.5, color: muted)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: muted),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SettingsGroup(
            title: 'Your activity',
            children: [
              SettingsTile(
                key: const ValueKey('settings_saved'),
                icon: Icons.bookmark_rounded,
                color: const Color(0xFFFF9F0A),
                title: 'Saved',
                onTap: widget.onSaved,
              ),
              SettingsTile(
                key: const ValueKey('settings_liked'),
                icon: Icons.favorite_rounded,
                color: const Color(0xFFFF375F),
                title: 'Liked',
                onTap: widget.onLiked,
              ),
              SettingsTile(
                key: const ValueKey('settings_history'),
                icon: Icons.history_rounded,
                color: const Color(0xFF64D2FF),
                title: 'Watch history',
                onTap: () => _open(const WatchHistoryPage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Privacy and safety',
            children: [
              SettingsTile(
                key: const ValueKey('settings_privacy'),
                icon: Icons.lock_rounded,
                color: const Color(0xFF5E5CE6),
                title: 'Privacy',
                value: privacySummary(user),
                onTap: () => _open(const PrivacyPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_2fa'),
                icon: Icons.shield_rounded,
                color: AppTheme.success,
                title: 'Two-step verification',
                value: user?.twoFactorEnabled == true ? 'On' : 'Off',
                onTap: () => _open(const TwoFactorSetupPage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Preferences',
            children: [
              SettingsTile(
                key: const ValueKey('settings_notifications'),
                icon: Icons.notifications_rounded,
                color: AppTheme.error,
                title: 'Notifications',
                onTap: () => _open(const NotificationSettingsPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_appearance'),
                icon: Icons.dark_mode_rounded,
                color: const Color(0xFF3A3A3C),
                title: 'Appearance',
                value: _themeLabel(user?.settings ?? const {}),
                onTap: () => _open(const AppearancePage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_space'),
                icon: Icons.cleaning_services_rounded,
                color: const Color(0xFF8E8E93),
                title: 'Free up space',
                onTap: () => _open(const FreeUpSpacePage()),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                key: const ValueKey('settings_share'),
                icon: Icons.ios_share_rounded,
                color: AppTheme.primary,
                title: 'Share profile',
                onTap: widget.onShareProfile,
              ),
            ],
          ),
          SettingsGroup(
            title: 'Support and about',
            children: [
              SettingsTile(
                key: const ValueKey('settings_help'),
                icon: Icons.help_rounded,
                color: AppTheme.primary,
                title: 'Help center',
                onTap: () => _open(const HelpCenterPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_bug'),
                icon: Icons.flag_rounded,
                color: const Color(0xFFFF9F0A),
                title: 'Report a problem',
                onTap: () => _open(const BugReportPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_terms'),
                icon: Icons.description_rounded,
                color: const Color(0xFF8E8E93),
                title: 'Terms of service',
                onTap: () => _open(const TermsOfServicePage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_policy'),
                icon: Icons.privacy_tip_rounded,
                color: const Color(0xFF8E8E93),
                title: 'Privacy policy',
                onTap: () => _open(const PrivacyPolicyPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_about'),
                icon: Icons.info_rounded,
                color: const Color(0xFF8E8E93),
                title: 'About',
                onTap: () => _open(const AboutPage()),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                key: const ValueKey('settings_logout'),
                icon: Icons.logout_rounded,
                color: AppTheme.error,
                title: 'Log out',
                destructive: true,
                onTap: _logout,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
