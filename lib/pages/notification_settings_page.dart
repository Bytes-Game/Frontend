import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/settings_kit.dart';

/// Which notifications buzz your phone.
///
/// Every switch here is one the server actually reads before it sends
/// anything (NotificationPrefs in notifications.go). This page used to show
/// switches named "likes", "comments", "mentions" and so on, which the
/// server had never heard of: they did nothing, and — because the server
/// saved whatever it did not recognise as "off" — touching any of them
/// turned every battle notification off. Now the names match, and a save
/// changes only the switch that was flipped.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

/// One switch: the server's name for it, and how it reads on screen.
class _Pref {
  final String key;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  const _Pref(this.key, this.title, this.subtitle, this.icon, this.color);
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage>
    with PageTracker<NotificationSettingsPage> {
  @override
  String get pageName => 'notification_settings_page';

  static const _messages = [
    _Pref('messages', 'Messages and calls',
        'A new message or a missed call', Icons.chat_bubble_rounded,
        AppTheme.primary),
  ];
  static const _battles = [
    _Pref('friendResponse', "Friends' battles",
        'When people you follow post or answer a challenge',
        Icons.group_rounded, Color(0xFF5E5CE6)),
    _Pref('endingSoon', 'Battle updates',
        'Ending soon, results, and when you win', Icons.emoji_events_rounded,
        Color(0xFFFF9F0A)),
  ];
  static const _more = [
    _Pref('youWillLove', 'Videos picked for you',
        "Now and then, a battle we think you'll like",
        Icons.auto_awesome_rounded, Color(0xFFFF375F)),
    _Pref('inactiveWinback', 'Reminders',
        "A nudge when you haven't been around for a while",
        Icons.schedule_rounded, Color(0xFF8E8E93)),
  ];

  /// The server's settings, as last read or saved. Null until read.
  Map<String, dynamic>? _prefs;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _userId =>
      Provider.of<DataProvider>(context, listen: false).user?.id ?? '';

  Future<void> _load() async {
    setState(() => _failed = false);
    final remote = await ApiService.getNotificationPrefs(_userId);
    if (!mounted) return;
    setState(() {
      _prefs = remote;
      _failed = remote == null;
    });
  }

  bool _on(String key) => _prefs?[key] != false;

  /// Night pause is on when quiet hours are set (start differs from end).
  bool get _quiet =>
      (_prefs?['quietHoursStart'] ?? 22) != (_prefs?['quietHoursEnd'] ?? 8);

  /// Save [changes] — only these; the server keeps the rest as they are.
  Future<void> _save(Map<String, dynamic> changes) async {
    final before = Map<String, dynamic>.of(_prefs ?? const {});
    EventTracker.instance.trackTap(
      target: 'notification_pref_toggle',
      pageName: pageName,
      params: changes,
    );
    setState(() => _prefs = {...before, ...changes});
    final ok = await ApiService.setNotificationPrefs(changes);
    if (!mounted) return;
    if (!ok) {
      setState(() => _prefs = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save that. Try again."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _switch(_Pref p) => SettingsSwitchTile(
        key: ValueKey('notif_${p.key}'),
        icon: p.icon,
        color: p.color,
        title: p.title,
        subtitle: p.subtitle,
        value: _on(p.key),
        onChanged: (v) => _save({p.key: v}),
      );

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: settingsBackground(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: prefs == null
          ? Center(
              child: _failed
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text("Couldn't load your notification settings"),
                        const SizedBox(height: 8),
                        TextButton(onPressed: _load, child: const Text('Retry')),
                      ],
                    )
                  : const CircularProgressIndicator(strokeWidth: 2),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: AppTheme.space32),
              children: [
                SettingsGroup(
                  title: 'Messages',
                  footer: 'Messages and calls always reach you, even at night.',
                  children: [for (final p in _messages) _switch(p)],
                ),
                SettingsGroup(
                  title: 'Battles',
                  children: [for (final p in _battles) _switch(p)],
                ),
                SettingsGroup(
                  title: 'From Battle Arena',
                  children: [for (final p in _more) _switch(p)],
                ),
                SettingsGroup(
                  title: 'Night',
                  footer: _quiet
                      ? "Battle and app notifications wait until 8 AM. "
                          "They're not lost — they arrive in the morning."
                      : 'Notifications arrive at any hour.',
                  children: [
                    SettingsSwitchTile(
                      key: const ValueKey('notif_quiet'),
                      icon: Icons.bedtime_rounded,
                      color: const Color(0xFF5856D6),
                      title: 'Pause at night',
                      subtitle: '10 PM to 8 AM',
                      value: _quiet,
                      onChanged: (v) => _save(v
                          ? {'quietHoursStart': 22, 'quietHoursEnd': 8}
                          : {'quietHoursStart': 0, 'quietHoursEnd': 0}),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
