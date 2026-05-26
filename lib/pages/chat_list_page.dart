import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

/// Chat list page — shows all conversations for the current user.
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage>
    with PageTracker<ChatListPage> {
  List<Map<String, dynamic>> _conversations = [];
  bool _loading = true;
  StreamSubscription? _wsSub;
  final Map<String, bool> _onlineStatus = {};

  @override
  String get pageName => 'chat_list_page';

  @override
  void initState() {
    super.initState();
    _load();
    _listenForNewMessages();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  String get _myId =>
      Provider.of<DataProvider>(context, listen: false).user!.id;

  Future<void> _load() async {
    final convos = await ApiService.getConversations(_myId);
    if (mounted) {
      setState(() {
        _conversations = convos;
        _loading = false;
      });
      _fetchOnlineStatuses(convos);
    }
  }

  Future<void> _fetchOnlineStatuses(List<Map<String, dynamic>> convos) async {
    for (final c in convos) {
      final username = c['username'] as String? ?? '';
      if (username.isEmpty) continue;
      final status = await ApiService.getUserOnlineStatus(username);
      if (mounted) {
        setState(() {
          _onlineStatus[username] = status['online'] == true;
        });
      }
    }
  }

  void _listenForNewMessages() {
    final ws = Provider.of<WebSocketService>(context, listen: false);
    _wsSub = ws.notificationStream.listen((notif) {
      if (notif.type == 'chat') {
        _load();
      }
    });
  }

  void _openChat(String userId, String username) {
    EventTracker.instance.trackChatOpen(
      conversationId: EventTracker.makeConversationId(_myId, userId),
      otherUserId: userId,
      source: 'chat_list',
    );
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => ChatConversationPage(
              otherUserId: userId, otherUsername: username),
        ))
        .then((_) => _load());
  }

  void _showNewChatPicker() {
    EventTracker.instance.trackTap(
      target: 'chat_new_message_fab',
      pageName: 'chat_list_page',
    );
    final dp = Provider.of<DataProvider>(context, listen: false);
    final users = dp.allUsers.where((u) => u.id != _myId).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Text('New Message',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: users.length,
                itemBuilder: (_, i) {
                  final u = users[i];
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        u.username.isNotEmpty
                            ? u.username[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(u.username,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(u.league,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.5))),
                    onTap: () {
                      Navigator.pop(ctx);
                      _openChat(u.id, u.username);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        centerTitle: true,
      ),
      body: _loading
          ? const ChatListSkeleton()
          : _conversations.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chat_bubble_outline,
                          size: 56, color: cs.onSurface.withOpacity(0.3)),
                      const SizedBox(height: 16),
                      Text('No messages yet',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                  color: cs.onSurface.withOpacity(0.5))),
                      const SizedBox(height: 8),
                      Text('Start a conversation!',
                          style: TextStyle(
                              color: cs.onSurface.withOpacity(0.3),
                              fontSize: 13)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 4),
                    itemCount: _conversations.length,
                    itemBuilder: (_, i) => _ConversationTile(
                      conversation: _conversations[i],
                      isOnline: _onlineStatus[
                              _conversations[i]['username'] ?? ''] ??
                          false,
                      onTap: () => _openChat(
                        _conversations[i]['userId'] ?? '',
                        _conversations[i]['username'] ?? '',
                      ),
                    ),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewChatPicker,
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Map<String, dynamic> conversation;
  final bool isOnline;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.isOnline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final username = conversation['username'] ?? '';
    final lastMsg = conversation['lastMessage'] ?? '';
    final unread = conversation['unreadCount'] ?? 0;
    final lastTime = _formatTime(conversation['lastTime'] ?? '');

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: cs.primaryContainer,
            child: Text(
              username.isNotEmpty ? username[0].toUpperCase() : '?',
              style: TextStyle(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
          if (isOnline)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              username,
              style: TextStyle(
                fontWeight: unread > 0 ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
          Text(
            lastTime,
            style: TextStyle(
              fontSize: 12,
              color: unread > 0 ? cs.primary : cs.onSurface.withOpacity(0.4),
            ),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              lastMsg,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: unread > 0
                    ? cs.onSurface
                    : cs.onSurface.withOpacity(0.5),
                fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal,
              ),
            ),
          ),
          if (unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                unread > 9 ? '9+' : '$unread',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }

  String _formatTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    if (diff.inDays == 0) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    } else {
      return '${local.day}/${local.month}';
    }
  }
}
