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
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppTheme.space32),
        children: [
          const _PrivacyIntro(),
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
                color: AppTheme.primary,
                title: 'Private account',
                value: _private,
                onChanged: (v) {
                  final was = _private;
                  final wasMessages = _messages;
                  _save(
                    // Going private turns "Everyone" off, on screen and in
                    // what is saved, so the two never disagree. Going public
                    // leaves "Only people you follow" chosen; "Everyone" can
                    // be picked again.
                    apply: () {
                      _private = v;
                      if (v) _messages = 'following';
                    },
                    undo: () {
                      _private = was;
                      _messages = wasMessages;
                    },
                    visibility: v ? 'friends' : 'public',
                    settings: v ? {'messages': 'following'} : null,
                  );
                },
              ),
            ],
          ),
          SettingsGroup(
            title: 'Messages and calls',
            footer: _private
                ? 'Your account is private, so only people you follow can '
                    'message and call you.'
                : 'Who can send you messages and call you. People you '
                    'follow can always reach you.',
            children: [
              for (final (value, label) in const [
                ('everyone', 'Everyone'),
                ('following', 'Only people you follow'),
              ])
                SettingsChoiceTile(
                  key: ValueKey('privacy_messages_$value'),
                  title: label,
                  // A private account takes messages only from people it
                  // follows (the server holds it to that too), so
                  // "Everyone" does not apply.
                  enabled: !(_private && value == 'everyone'),
                  subtitle: _private && value == 'everyone'
                      ? 'Off while your account is private'
                      : null,
                  // Private: "Only people you follow", even for an account
                  // that picked "Everyone" before going private.
                  selected: _private
                      ? value == 'following'
                      : _messages == value,
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
                icon: Icons.visibility_rounded,
                color: AppTheme.primary,
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
                color: AppTheme.primary,
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

/// The top of the Privacy page: what it is for, in one line.
class _PrivacyIntro extends StatelessWidget {
  const _PrivacyIntro();

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, AppTheme.space8),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: settingsCard(context),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF3DA5FF), Color(0xFF0050D0)],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.28),
                    blurRadius: 14,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.shield_rounded,
                  color: Colors.white, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'You choose who sees you',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Who sees your videos, who can reach you, and when '
                    "you're shown as active. The server keeps every choice, "
                    'not just the app.',
                    style:
                        TextStyle(fontSize: 13, height: 1.35, color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How the Privacy row in Settings sums up the choices.
String privacySummary(UserModel? user) =>
    user?.visibility == 'friends' ? 'Private' : 'Public';
