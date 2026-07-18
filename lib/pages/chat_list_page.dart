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

/// Instagram's DM blue — used for the unread dot, "Requests" link and
/// primary actions so the whole messaging surface reads as one system.
const Color kDmBlue = Color(0xFF3797EF);

/// Chat inbox — Instagram Direct layout, point for point:
///   * Header: your own username (bold, chevron-down) left, compose
///     (pencil-in-square) right. No centered "Messages" AppBar.
///   * Rounded grey search field that live-filters conversations.
///   * "Messages" section title with the blue "Requests" link at right.
///   * Rows: 56px avatar (green active dot), name, "preview · 2h" second
///     line; unread rows go bold with a blue dot; a camera glyph sits at
///     the far right of every row, exactly like IG.
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
  final _searchCtrl = TextEditingController();
  String _query = '';

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
    _searchCtrl.dispose();
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

  /// Search filters the loaded conversations client-side — matches IG,
  /// which surfaces existing threads instantly as you type.
  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _conversations;
    final q = _query.toLowerCase();
    return _conversations
        .where((c) =>
            (c['username'] as String? ?? '').toLowerCase().contains(q))
        .toList();
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
            Text('New message',
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
                                .withValues(alpha: 0.5))),
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
    final myUsername =
        Provider.of<DataProvider>(context, listen: false).user?.username ??
            '';

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header: own username + chevron left, compose right ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      myUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.keyboard_arrow_down_rounded, size: 24),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.edit_square, size: 24),
                    tooltip: 'New message',
                    onPressed: _showNewChatPicker,
                  ),
                ],
              ),
            ),

            // ── Search bar — rounded grey field, magnifier + "Search" ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Icon(Icons.search,
                        size: 20, color: cs.onSurface.withValues(alpha: 0.5)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        decoration: InputDecoration(
                          hintText: 'Search',
                          hintStyle: TextStyle(
                            fontSize: 15,
                            color: cs.onSurface.withValues(alpha: 0.5),
                          ),
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    if (_query.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(Icons.cancel,
                              size: 16,
                              color: cs.onSurface.withValues(alpha: 0.4)),
                        ),
                      ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),

            // ── Section row: "Messages" + blue "Requests" ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Row(
                children: [
                  const Text('Messages',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('No message requests'),
                          duration: Duration(seconds: 1),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    child: const Text('Requests',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: kDmBlue)),
                  ),
                ],
              ),
            ),

            // ── Conversation list ──
            Expanded(
              child: _loading
                  ? const ChatListSkeleton()
                  : _conversations.isEmpty
                      ? _EmptyInbox(onCompose: _showNewChatPicker)
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: EdgeInsets.zero,
                            itemCount: _filtered.length,
                            itemBuilder: (_, i) => _ConversationTile(
                              conversation: _filtered[i],
                              isOnline: _onlineStatus[
                                      _filtered[i]['username'] ?? ''] ??
                                  false,
                              onTap: () => _openChat(
                                _filtered[i]['userId'] ?? '',
                                _filtered[i]['username'] ?? '',
                              ),
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// IG-style empty inbox: icon in a thin circle, headline, sub-line and a
/// blue "Send message" affordance that opens the people picker.
class _EmptyInbox extends StatelessWidget {
  final VoidCallback onCompose;
  const _EmptyInbox({required this.onCompose});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: cs.onSurface.withValues(alpha: 0.8), width: 2),
            ),
            child: Icon(Icons.send_outlined,
                size: 44, color: cs.onSurface.withValues(alpha: 0.8)),
          ),
          const SizedBox(height: 20),
          const Text('Message your friends',
              style:
                  TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(
            'Send private messages or share your favorite battles',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14, color: cs.onSurface.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: onCompose,
            child: const Text('Send message',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: kDmBlue)),
          ),
        ],
      ),
    );
  }
}

/// One inbox row, IG Direct layout: 56px avatar with the green activity
/// dot, name over "preview · time", blue unread dot, camera glyph.
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
    final lastMsg = (conversation['lastMessage'] ?? '') as String;
    final unread = (conversation['unreadCount'] ?? 0) as int;
    final time = _relativeTime(conversation['lastTime'] ?? '');
    final preview = time.isEmpty ? lastMsg : '$lastMsg · $time';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Avatar + activity dot.
            Stack(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    username.isNotEmpty ? username[0].toUpperCase() : '?',
                    style: TextStyle(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                    ),
                  ),
                ),
                if (isOnline)
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1CD14F),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),

            // Name + preview·time. Unread turns both bold, exactly like IG.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight:
                          unread > 0 ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          unread > 0 ? FontWeight.w600 : FontWeight.w400,
                      color: unread > 0
                          ? cs.onSurface
                          : cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),

            // Blue unread dot (IG uses a dot, not a count badge).
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 8),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: kDmBlue,
                  shape: BoxShape.circle,
                ),
              ),

            // Camera glyph at the far right of every row.
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Icon(Icons.camera_alt_outlined,
                  size: 24, color: cs.onSurface.withValues(alpha: 0.4)),
            ),
          ],
        ),
      ),
    );
  }

  /// IG's compact relative time: now / 5m / 3h / 2d / 4w.
  String _relativeTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }
}
