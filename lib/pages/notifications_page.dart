import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

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
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none,
                      size: 64,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(height: 16),
                  Text('No notifications yet',
                      style: TextStyle(
                          fontSize: 18,
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Text('Interactions will appear here',
                      style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant)),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: list.length,
              separatorBuilder: (ctx, i) =>
                  const Divider(height: 1, indent: 72),
              itemBuilder: (_, i) {
                final n = list[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _color(n.type).withValues(alpha: 0.15),
                    child: Icon(_icon(n.type), color: _color(n.type)),
                  ),
                  title: Text(n.message),
                  subtitle: Text(_timeAgo(n.timestamp)),
                  onTap: () {
                    EventTracker.instance.trackNotificationTap(
                      notificationId: n.messageId ??
                          '${n.type}_${n.timestamp.millisecondsSinceEpoch}',
                      notificationType: n.type,
                      position: i,
                    );
                  },
                );
              },
            ),
    );
  }

  IconData _icon(String type) {
    switch (type) {
      case 'follow':
        return Icons.person_add;
      case 'like':
        return Icons.favorite;
      case 'comment':
        return Icons.chat_bubble;
      case 'challenge':
        return Icons.sports_kabaddi;
      case 'challenge_accepted':
        return Icons.emoji_events;
      case 'vote':
        return Icons.how_to_vote;
      default:
        return Icons.notifications;
    }
  }

  Color _color(String type) {
    switch (type) {
      case 'follow':
        return Colors.blue;
      case 'like':
        return Colors.red;
      case 'comment':
        return Colors.teal;
      case 'challenge':
        return Colors.orange;
      case 'challenge_accepted':
        return Colors.amber;
      case 'vote':
        return Colors.purple;
      default:
        return Colors.grey;
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
