import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// Shows all notifications (follow, like, challenge, etc.).
///
/// When the user navigates here, unread count is cleared.
/// Notifications arrive in real-time via WebSocket and are stored
/// in [DataProvider.notifications].
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with PageTracker<NotificationsPage> {
  @override
  String get pageName => 'notifications_page';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final dp = Provider.of<DataProvider>(context, listen: false);
      EventTracker.instance.trackNotificationPanelOpen(
        unreadCount: dp.unreadNotifications,
      );
      dp.clearUnreadNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    final list = dp.notifications;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        centerTitle: true,
      ),
      body: list.isEmpty
          ? const ArenaEmptyState(
              icon: Icons.notifications_none_rounded,
              title: 'No notifications yet',
              subtitle: 'Follows, likes, votes and battle news will show '
                  'up here.',
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final n = list[i];
                final c = _color(n.type);
                return Pressable(
                  pressedScale: 0.98,
                  onTap: () {
                    EventTracker.instance.trackNotificationTap(
                      notificationId: n.messageId ??
                          '${n.type}_${n.timestamp.millisecondsSinceEpoch}',
                      notificationType: n.type,
                      position: i,
                    );
                  },
                  child: Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    ),
                    child: Row(
                      children: [
                        // What kind of news, as a tinted icon tile.
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: c.withValues(alpha: 0.15),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusMd),
                          ),
                          child: Icon(_icon(n.type), color: c, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                n.message,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _timeAgo(n.timestamp),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  IconData _icon(String type) {
    switch (type) {
      case 'follow':
        return Icons.person_add_alt_1_rounded;
      case 'like':
        return Icons.favorite_rounded;
      case 'comment':
        return Icons.chat_bubble_rounded;
      case 'challenge':
        return Icons.bolt_rounded;
      case 'challenge_accepted':
        return Icons.emoji_events_rounded;
      case 'vote':
        return Icons.how_to_vote_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Color _color(String type) {
    switch (type) {
      case 'follow':
        return AppTheme.accentBlue;
      case 'like':
        return AppTheme.accentPink;
      case 'comment':
        return AppTheme.accentCyan;
      case 'challenge':
        return AppTheme.primary;
      case 'challenge_accepted':
        return AppTheme.warning;
      case 'vote':
        return AppTheme.success;
      default:
        return AppTheme.textMutedDark;
    }
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
