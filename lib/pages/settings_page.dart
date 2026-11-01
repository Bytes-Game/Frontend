import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/config/dates.dart';
import 'package:myapp/pages/change_password_page.dart';
import 'package:myapp/pages/free_up_space_page.dart';
import 'package:myapp/pages/notification_settings_page.dart';
import 'package:myapp/pages/preferences_pages.dart';
import 'package:myapp/pages/privacy_page.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/pages/two_factor_setup_page.dart';
import 'package:myapp/pages/watch_history_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/save_to_phone.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/flex_logo.dart';
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

  /// "Save your posts to your phone": on until switched off.
  bool _savePosts = true;

  @override
  void initState() {
    super.initState();
    SaveToPhone.instance.isOn().then((on) {
      if (mounted) setState(() => _savePosts = on);
    });
  }

  Future<void> _setSavePosts(bool on) async {
    setState(() => _savePosts = on);
    await SaveToPhone.instance.setOn(on);
  }

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

  /// Make another account: say that this one is signed out first, then
  /// the sign-in screen opens straight on to sign-up.
  Future<void> _newAccount() async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create a new account?'),
        content: Text("You'll be logged out of @${user?.username ?? ''} "
            'first. You can sign back in to it any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('new_account_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    EventTracker.instance.trackTap(target: 'new_account', pageName: pageName);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    Navigator.of(context).popUntil((r) => r.isFirst);
    // ignore: use_build_context_synchronously
    auth.startNewAccount(context);
  }

  /// Delete the account, for good. App stores require it to be possible
  /// from inside the app. Asks twice — the second time by typing the
  /// username — because there is no getting it back.
  Future<void> _deleteAccount() async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    if (user == null) return;
    EventTracker.instance.trackTap(
      target: 'delete_account_open',
      pageName: pageName,
    );
    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteAccountDialog(username: user.username),
    );
    if (sure != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('Deleting your account…'),
    ));
    final result = await ApiService.deleteAccount(user.id);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    if (!result.done) {
      messenger.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't delete your account. Check your connection "
            'and try again.'),
      ));
      return;
    }
    EventTracker.instance.trackTap(
      target: 'delete_account_done',
      pageName: pageName,
    );
    final auth = Provider.of<AuthProvider>(context, listen: false);
    Navigator.of(context).popUntil((r) => r.isFirst);
    // ignore: use_build_context_synchronously
    auth.logout(context);
    final on = result.deleteOn;
    messenger.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 8),
      content: Text(on == null
          ? 'Your account has been deleted.'
          : 'Your account will be deleted on '
              '${dateInWords(on.toLocal())}. Sign in before then to keep it.'),
    ));
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
    final name = (user?.fullName.isNotEmpty ?? false)
        ? user!.fullName
        : (user?.username ?? '');
    const blue = AppTheme.primary;

    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Settings and privacy'),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTheme.space40),
        children: [
          _AccountCard(
            name: name,
            username: user?.username ?? '',
            onEdit: widget.onEditProfile,
            onShare: widget.onShareProfile,
          ),
          SettingsGroup(
            title: 'Account',
            children: [
              SettingsTile(
                key: const ValueKey('settings_privacy'),
                icon: Icons.lock_rounded,
                color: blue,
                title: 'Privacy',
                value: privacySummary(user),
                onTap: () => _open(const PrivacyPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_2fa'),
                icon: Icons.verified_user_rounded,
                color: blue,
                title: 'Two-step verification',
                value: user?.twoFactorEnabled == true ? 'On' : 'Off',
                onTap: () => _open(const TwoFactorSetupPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_password'),
                icon: Icons.key_rounded,
                color: blue,
                title: 'Change password',
                onTap: () => _open(const ChangePasswordPage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Content and activity',
            children: [
              SettingsTile(
                key: const ValueKey('settings_saved'),
                icon: Icons.bookmark_rounded,
                color: blue,
                title: 'Saved',
                onTap: widget.onSaved,
              ),
              SettingsTile(
                key: const ValueKey('settings_liked'),
                icon: Icons.favorite_rounded,
                color: blue,
                title: 'Liked',
                onTap: widget.onLiked,
              ),
              SettingsTile(
                key: const ValueKey('settings_history'),
                icon: Icons.history_rounded,
                color: blue,
                title: 'Watch history',
                onTap: () => _open(const WatchHistoryPage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Content and display',
            children: [
              SettingsTile(
                key: const ValueKey('settings_notifications'),
                icon: Icons.notifications_rounded,
                color: blue,
                title: 'Notifications',
                onTap: () => _open(const NotificationSettingsPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_appearance'),
                icon: Icons.dark_mode_rounded,
                color: blue,
                title: 'Appearance',
                value: _themeLabel(user?.settings ?? const {}),
                onTap: () => _open(const AppearancePage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_save_posts'),
                icon: Icons.download_rounded,
                color: blue,
                title: 'Save your posts to your phone',
                subtitle: 'A copy of what you make or edit here goes to '
                    'your gallery',
                trailing: Switch.adaptive(
                  key: const ValueKey('settings_save_posts_switch'),
                  value: _savePosts,
                  activeTrackColor: blue,
                  onChanged: _setSavePosts,
                ),
                onTap: () => _setSavePosts(!_savePosts),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Cache and storage',
            children: [
              SettingsTile(
                key: const ValueKey('settings_space'),
                icon: Icons.cleaning_services_rounded,
                color: blue,
                title: 'Free up space',
                onTap: () => _open(const FreeUpSpacePage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Support and about',
            children: [
              SettingsTile(
                key: const ValueKey('settings_bug'),
                icon: Icons.flag_rounded,
                color: blue,
                title: 'Report a problem',
                onTap: () => _open(const BugReportPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_help'),
                icon: Icons.support_agent_rounded,
                color: blue,
                title: 'Help Center',
                onTap: () => _open(const HelpCenterPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_policies'),
                icon: Icons.gavel_rounded,
                color: blue,
                title: 'Terms and policies',
                onTap: () => _open(const TermsAndPoliciesPage()),
              ),
              SettingsTile(
                key: const ValueKey('settings_about'),
                icon: Icons.info_rounded,
                color: blue,
                title: 'About ${AppConstants.appName}',
                onTap: () => _open(const AboutPage()),
              ),
            ],
          ),
          SettingsGroup(
            title: 'Login',
            children: [
              SettingsTile(
                key: const ValueKey('settings_new_account'),
                icon: Icons.person_add_alt_1_rounded,
                color: blue,
                title: 'Create a new account',
                onTap: _newAccount,
              ),
              SettingsTile(
                key: const ValueKey('settings_logout'),
                icon: Icons.logout_rounded,
                color: AppTheme.error,
                title: 'Log out',
                destructive: true,
                onTap: _logout,
              ),
              SettingsTile(
                key: const ValueKey('settings_delete_account'),
                icon: Icons.person_remove_rounded,
                color: AppTheme.error,
                title: 'Delete account',
                destructive: true,
                onTap: _deleteAccount,
              ),
            ],
          ),
          const SizedBox(height: 20),
          const _VersionFoot(),
        ],
      ),
    );
  }
}

/// You, at the top of Settings, on the app's blue: tap to edit your
/// profile, or share it.
class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.name,
    required this.username,
    required this.onEdit,
    required this.onShare,
  });

  final String name;
  final String username;
  final VoidCallback onEdit;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, AppTheme.space8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: FlexMark.tileColors,
            stops: [0, 0.5, 1],
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primary.withValues(alpha: 0.28),
              blurRadius: 28,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('settings_account'),
            onTap: onEdit,
            splashColor: Colors.white.withValues(alpha: 0.12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 10, 16),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(2.5),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: ArenaAvatar(
                        name: username.isEmpty ? '?' : username, size: 56),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.82),
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.3),
                              width: 0.8,
                            ),
                          ),
                          child: const Text(
                            'Edit profile',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('settings_share'),
                    tooltip: 'Share profile',
                    onPressed: onShare,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.18),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.qr_code_2_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The logo and the version, quietly, at the foot of Settings.
class _VersionFoot extends StatelessWidget {
  const _VersionFoot();

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return Column(
      children: [
        const FlexLogo(size: 30, glow: false),
        const SizedBox(height: 8),
        Text(
          '${AppConstants.appName} ${AppConstants.appVersion}',
          key: const ValueKey('settings_version'),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
      ],
    );
  }
}

/// "Delete your account?", with the username to type before Delete works.
/// Its own widget so the typing box lives exactly as long as the dialog,
/// closing animation included.
class _DeleteAccountDialog extends StatefulWidget {
  final String username;
  const _DeleteAccountDialog({required this.username});

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.username;
    final matches = _typed.text.trim().toLowerCase() == name.toLowerCase();
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@$name will be hidden from everyone straight away and signed '
            'out on every phone. Battles you are in now end with no result.'
            '\n\n'
            'After 30 days it is deleted for good: your profile, your posts '
            'and battles, your comments, likes, votes and followers. Sign in '
            'before then to keep it.',
          ),
          const SizedBox(height: 14),
          Text('Type $name to confirm.'),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('delete_account_username'),
            controller: _typed,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(hintText: name),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('delete_account_confirm'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Delete account'),
        ),
      ],
    );
  }
}
