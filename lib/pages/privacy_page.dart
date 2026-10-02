import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/blocked_users_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/settings_kit.dart';

/// Privacy: who can see your videos, who can message and call you, whether
/// others see when you are active, and who you have blocked.
///
/// Every choice here is enforced by the server, not just hidden in the app:
/// a private account's videos are not sent to people who do not follow it,
/// a message or call from someone not allowed is refused, and a hidden
/// activity status is never sent to anyone. See privacy_settings.go on the
/// server.
///
/// Each switch saves at once. If the server says no, it flips back and says
/// so — it never looks saved when it is not.
class PrivacyPage extends StatefulWidget {
  const PrivacyPage({super.key});

  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<PrivacyPage>
    with PageTracker<PrivacyPage> {
  @override
  String get pageName => 'privacy_page';

  late bool _private;
  late String _messages;
  late bool _showActivity;

  @override
  void initState() {
    super.initState();
    final user = Provider.of<DataProvider>(context, listen: false).user;
    _private = user?.visibility == 'friends';
    _messages = (user?.settings['messages'] as String?) == 'following'
        ? 'following'
        : 'everyone';
    _showActivity = user?.settings['showActivity'] != false;
  }

  /// Save one change. [apply] sets it on screen at once; [undo] puts it
  /// back if the server refuses.
  Future<void> _save({
    required VoidCallback apply,
    required VoidCallback undo,
    String? visibility,
    Map<String, dynamic>? settings,
  }) async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final user = dp.user;
    if (user == null) return;
    setState(apply);
    final merged =
        settings == null ? null : <String, dynamic>{...user.settings, ...settings};
    final res = await ApiService.updateUserProfile(
      userId: user.id,
      visibility: visibility,
      settings: merged,
    );
    if (!mounted) return;
    if (!res.success) {
      setState(undo);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save that. Try again."),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    dp.setUser(res.user ??
        user.copyWith(visibility: visibility, settings: merged));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Privacy'),
        backgroundColor: settingsBackground(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTheme.space32),
        children: [
          SettingsGroup(
            title: 'Account',
            footer: _private
                ? 'Only your followers can see your videos and battles. '
                    'Anyone can still see your name and picture.'
                : 'Anyone can see your videos and battles.',
            children: [
              SettingsSwitchTile(
                key: const ValueKey('privacy_private'),
                icon: Icons.lock_rounded,
                color: const Color(0xFF5E5CE6),
                title: 'Private account',
                value: _private,
                onChanged: (v) {
                  final was = _private;
                  _save(
                    apply: () => _private = v,
                    undo: () => _private = was,
                    visibility: v ? 'friends' : 'public',
                  );
                },
              ),
            ],
          ),
          SettingsGroup(
            title: 'Messages and calls',
            footer: 'Who can send you messages and call you. People you '
                'follow can always reach you.',
            children: [
              for (final (value, label) in const [
                ('everyone', 'Everyone'),
                ('following', 'Only people you follow'),
              ])
                SettingsChoiceTile(
                  key: ValueKey('privacy_messages_$value'),
                  title: label,
                  selected: _messages == value,
                  onTap: _messages == value
                      ? null
                      : () {
                          final was = _messages;
                          _save(
                            apply: () => _messages = value,
                            undo: () => _messages = was,
                            settings: {'messages': value},
                          );
                        },
                ),
            ],
          ),
          SettingsGroup(
            title: 'Activity status',
            footer: _showActivity
                ? "People you chat with can see when you're online and when "
                    'you were last here.'
                : "Nobody sees when you're online or when you were last here.",
            children: [
              SettingsSwitchTile(
                key: const ValueKey('privacy_activity'),
                icon: Icons.circle,
                color: AppTheme.success,
                title: "Show when you're active",
                value: _showActivity,
                onChanged: (v) {
                  final was = _showActivity;
                  _save(
                    apply: () => _showActivity = v,
                    undo: () => _showActivity = was,
                    settings: {'showActivity': v},
                  );
                },
              ),
            ],
          ),
          SettingsGroup(
            title: 'Safety',
            children: [
              SettingsTile(
                key: const ValueKey('privacy_blocked'),
                icon: Icons.block_rounded,
                color: AppTheme.error,
                title: 'Blocked accounts',
                subtitle: "They can't see your profile or message you",
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BlockedUsersPage()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// How the Privacy row in Settings sums up the choices.
String privacySummary(UserModel? user) =>
    user?.visibility == 'friends' ? 'Private' : 'Public';
