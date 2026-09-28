import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// Your notifications: who followed you, who challenged you, who accepted.
///
/// The list lives on the server now, so it has everything — not only what
/// arrived while the app happened to be open, which is all it used to show.
/// What you have not seen yet is under "New", tinted, with a dot.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with PageTracker<NotificationsPage> {
  @override
  String get pageName => 'notifications_page';

  bool _loading = true;

  /// What was unseen when the page opened. It stays "New" for as long as
  /// the page is up, even though opening it marks everything seen.
  final Set<String> _newIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    EventTracker.instance.trackNotificationPanelOpen(
      unreadCount: dp.unreadNotifications,
    );
    await dp.loadNotifications();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _newIds.addAll([
        for (final n in dp.notifications)
          if (!n.read) _key(n),
      ]);
    });
    dp.clearUnreadNotifications();
  }

  Future<void> _refresh() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    await dp.loadNotifications();
    if (!mounted) return;
    setState(() {
      _newIds.addAll([
        for (final n in dp.notifications)
          if (!n.read) _key(n),
      ]);
    });
    dp.clearUnreadNotifications();
  }

  static String _key(NotificationModel n) => n.id.isNotEmpty
      ? n.id
      : '${n.type}_${n.timestamp.millisecondsSinceEpoch}';

  Future<void> _open(NotificationModel n, int position) async {
    EventTracker.instance.trackNotificationTap(
      notificationId: _key(n),
      notificationType: n.type,
      position: position,
    );
    if (n.challengeId.isNotEmpty) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChallengeDetailPage(challengeId: n.challengeId),
        ),
      );
      return;
    }
    if (n.actorUsername.isNotEmpty) {
      final user = await ApiService.getUserByUsername(n.actorUsername);
      if (!mounted || user == null) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ProfilePage(user: user, isEmbedded: false),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    final all = dp.notifications;
    final fresh = [
      for (final n in all)
        if (_newIds.contains(_key(n))) n,
    ];
    final earlier = [
      for (final n in all)
        if (!_newIds.contains(_key(n))) n,
    ];

    Widget body;
    if (_loading && all.isEmpty) {
      body = const Center(child: CircularProgressIndicator(strokeWidth: 2));
    } else if (all.isEmpty) {
      body = ListView(
        children: const [
          SizedBox(height: 80),
          ArenaEmptyState(
            icon: Icons.notifications_none_rounded,
            title: 'Nothing yet',
            subtitle:
                'When someone follows you, challenges you or accepts '
                'your challenge, you will see it here.',
          ),
        ],
      );
    } else {
      var position = 0;
      body = ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (fresh.isNotEmpty) ...[
            const _Heading('New'),
            for (final n in fresh)
              _NoteRow(
                key: ValueKey('note_${_key(n)}'),
                note: n,
                isNew: true,
                onTap: () => _open(n, position++),
              ),
          ],
          if (earlier.isNotEmpty) ...[
            _Heading(fresh.isEmpty ? 'All' : 'Earlier'),
            for (final n in earlier)
              _NoteRow(
                key: ValueKey('note_${_key(n)}'),
                note: n,
                isNew: false,
                onTap: () => _open(n, position++),
              ),
          ],
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications'), centerTitle: true),
      body: RefreshIndicator(onRefresh: _refresh, child: body),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;

  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
      child: Text(
        text,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// How each kind looks: the badge on the avatar.
({IconData icon, Color color}) _look(String type) {
  switch (type) {
    case 'follow':
      return (
        icon: Icons.person_add_alt_1_rounded,
        color: const Color(0xFF0A84FF),
      );
    case 'friend_challenge':
      return (icon: Icons.bolt_rounded, color: const Color(0xFFFF375F));
    case 'challenge_accepted':
      return (
        icon: Icons.local_fire_department_rounded,
        color: const Color(0xFFFF9F0A),
      );
    case 'battle_started':
      return (icon: Icons.emoji_events_rounded, color: const Color(0xFFE0A800));
    case 'like':
      return (icon: Icons.favorite_rounded, color: const Color(0xFFFF375F));
    case 'comment':
      return (icon: Icons.chat_bubble_rounded, color: const Color(0xFF30D158));
    default:
      return (
        icon: Icons.notifications_rounded,
        color: const Color(0xFF8E8E93),
      );
  }
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${(d.inDays / 7).floor()}w';
}

class _NoteRow extends StatelessWidget {
  final NotificationModel note;
  final bool isNew;
  final VoidCallback onTap;

  const _NoteRow({
    super.key,
    required this.note,
    required this.isNew,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final look = _look(note.type);
    final actor = note.actorUsername;
    final text = note.text.isNotEmpty ? note.text : note.message;
    return Material(
      color: isNew ? cs.primary.withValues(alpha: 0.07) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            children: [
              // Who, with what kind of news as a badge on their picture.
              SizedBox(
                width: 50,
                height: 50,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (actor.isNotEmpty)
                      ArenaAvatar(name: actor, size: 48)
                    else
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: look.color.withValues(alpha: 0.15),
                        ),
                        child: Icon(look.icon, color: look.color, size: 22),
                      ),
                    if (actor.isNotEmpty)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          key: const ValueKey('note_badge'),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: look.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Theme.of(context).scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: Icon(look.icon, size: 12, color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          if (actor.isNotEmpty)
                            TextSpan(
                              text: '$actor ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          TextSpan(text: text),
                        ],
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        height: 1.3,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      timeAgo(note.timestamp),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: quietText(context),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _Trailing(note: note),
              if (isNew) ...[
                const SizedBox(width: 8),
                Container(
                  key: const ValueKey('note_new_dot'),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: cs.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// On the right: the video it is about, or a way to follow back.
class _Trailing extends StatelessWidget {
  final NotificationModel note;

  const _Trailing({required this.note});

  @override
  Widget build(BuildContext context) {
    if (note.thumbnailUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          note.thumbnailUrl,
          width: 42,
          height: 56,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _blank(context),
        ),
      );
    }
    if (note.challengeId.isNotEmpty) return _blank(context);
    if (note.type == 'follow' && note.actorId.isNotEmpty) {
      return _FollowBack(note: note);
    }
    return const SizedBox.shrink();
  }

  Widget _blank(BuildContext context) => Container(
    width: 42,
    height: 56,
    decoration: BoxDecoration(
      color: quietFill(context),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(Icons.play_arrow_rounded, color: quietText(context)),
  );
}

class _FollowBack extends StatelessWidget {
  final NotificationModel note;

  const _FollowBack({required this.note});

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    final following = dp.following.contains(note.actorId);
    final target = UserModel(
      id: note.actorId,
      username: note.actorUsername,
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );
    return SizedBox(
      height: 32,
      child: following
          ? OutlinedButton(
              key: const ValueKey('note_following'),
              onPressed: () => dp.unfollowUser(target),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: const Text(
                'Following',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            )
          : FilledButton(
              key: const ValueKey('note_follow_back'),
              onPressed: () => dp.followUser(target),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
              ),
              child: const Text(
                'Follow back',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
    );
  }
}
