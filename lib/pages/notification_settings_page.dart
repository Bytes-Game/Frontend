import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// Notification preferences — fully wired to the existing
/// `/api/v1/notifications/prefs` endpoints (get + set). Loads the
/// current prefs on init, lets the user toggle categories, and PATCHes
/// the server with each change.
///
/// Categories mirror what the dispatcher already routes on the backend
/// (see notifications.go's outbox routing); adding a new toggle here is
/// safe even if the backend ignores it — the dispatcher just drops
/// unknown keys.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage>
    with PageTracker<NotificationSettingsPage> {
  bool _loading = true;
  bool _saving = false;
  // Local mirror of the prefs map. Keys match what the backend reads
  // (see HandleSetNotificationPrefs). Unknown-keyed entries are kept
  // verbatim so we don't lose forward-compat fields when round-tripping
  // through this page.
  final Map<String, dynamic> _prefs = {
    'likes': true,
    'comments': true,
    'follows': true,
    'mentions': true,
    'newChallenges': true,
    'voteResults': true,
    'directMessages': true,
    'pushPromotional': false,
  };

  @override
  String get pageName => 'notification_settings_page';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId =
        Provider.of<DataProvider>(context, listen: false).user?.id;
    if (userId == null || userId.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final remote = await ApiService.getNotificationPrefs(userId);
    if (!mounted) return;
    if (remote != null) {
      // Merge server state over defaults. Server-authoritative for
      // anything it returns; locally-default for anything it doesn't.
      _prefs.addAll(remote);
    }
    setState(() => _loading = false);
  }

  Future<void> _toggle(String key, bool value) async {
    final userId =
        Provider.of<DataProvider>(context, listen: false).user?.id;
    if (userId == null) return;
    EventTracker.instance.trackTap(
      target: 'notification_pref_toggle',
      pageName: pageName,
      params: {'key': key, 'value': value},
    );
    // Optimistic flip — the toggle feels instant. Revert on failure.
    setState(() {
      _prefs[key] = value;
      _saving = true;
    });
    final ok = await ApiService.setNotificationPrefs({
      'userId': userId,
      ..._prefs,
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      setState(() => _prefs[key] = !value);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _section('Engagement', cs),
                _toggleTile(
                  title: 'Likes on your posts',
                  subtitle: 'When someone likes a challenge you made',
                  k: 'likes',
                ),
                _toggleTile(
                  title: 'Comments',
                  subtitle: 'Replies on your posts and threads',
                  k: 'comments',
                ),
                _toggleTile(
                  title: 'Mentions',
                  subtitle: 'When someone @-mentions you',
                  k: 'mentions',
                ),
                _section('Social', cs),
                _toggleTile(
                  title: 'New followers',
                  subtitle: 'Someone followed you',
                  k: 'follows',
                ),
                _toggleTile(
                  title: 'Direct messages',
                  subtitle: 'New chat messages',
                  k: 'directMessages',
                ),
                _section('Challenges', cs),
                _toggleTile(
                  title: 'New challenges',
                  subtitle:
                      'Friends post fresh battles for you to accept',
                  k: 'newChallenges',
                ),
                _toggleTile(
                  title: 'Vote results',
                  subtitle:
                      'When voting on a battle you participated in closes',
                  k: 'voteResults',
                ),
                _section('Promotional', cs),
                _toggleTile(
                  title: 'Tips, updates & promotions',
                  subtitle:
                      'Product news, feature launches, occasional offers',
                  k: 'pushPromotional',
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _section(String title, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space20,
          AppTheme.space20,
          AppTheme.space20,
          AppTheme.space4,
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: cs.primary,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _toggleTile({
    required String title,
    required String subtitle,
    required String k,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      value: _prefs[k] == true,
      onChanged: (v) => _toggle(k, v),
    );
  }
}
