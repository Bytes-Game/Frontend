import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/league_badge.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

/// The inbox.
///
/// From the top:
///   * "Messages", and a new-message button in the brand gradient.
///   * The app's search bar, filtering your chats as you type.
///   * "Active now": the people you talk to who are online right now, as a
///     row of pictures — tap one to open the chat. Only there when someone
///     is online, so it never takes space to say nothing.
///   * Your chats. A chat with something unread gets a gradient ring round
///     the picture, a bold name and a count; the time sits top right.
///
/// Every icon here does something. The old row had a camera on every line
/// and a "Requests" link, and neither did anything but say "not yet".
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

  /// Search filters the loaded conversations as you type.
  List<Map<String, dynamic>> get _filtered {
    if (_query.isEmpty) return _conversations;
    final q = _query.toLowerCase();
    return _conversations
        .where((c) =>
            (c['username'] as String? ?? '').toLowerCase().contains(q))
        .toList();
  }

  /// The people you talk to who are online right now.
  List<Map<String, dynamic>> get _activeNow => _conversations
      .where((c) => _onlineStatus[c['username'] ?? ''] == true)
      .toList();

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
      showDragHandle: true,
      builder: (ctx) => _NewChatSheet(
        users: users,
        onPick: (u) {
          Navigator.pop(ctx);
          _openChat(u.id, u.username);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = _activeNow;
    final showActive = active.isNotEmpty && _query.isEmpty;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // ── Header: title left, new message right ──
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 16, 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Messages',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  IconBubble(
                    icon: Icons.edit_rounded,
                    tooltip: 'New message',
                    filled: true,
                    size: 42,
                    onTap: _showNewChatPicker,
                  ),
                ],
              ),
            ),

            // ── Search ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
              child: ArenaSearchField(
                controller: _searchCtrl,
                hint: 'Search chats',
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),

            // ── Conversation list ──
            Expanded(
              child: _loading
                  ? const ChatListSkeleton()
                  : _conversations.isEmpty
                      ? ArenaEmptyState(
                          icon: Icons.forum_rounded,
                          title: 'Message your friends',
                          subtitle: 'Send private messages or share your '
                              'favourite battles.',
                          actionLabel: 'Start a chat',
                          actionIcon: Icons.edit_rounded,
                          onAction: _showNewChatPicker,
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 16),
                            children: [
                              if (showActive) ...[
                                const SectionTitle(
                                  title: 'Active now',
                                  icon: Icons.bolt_rounded,
                                  padding: EdgeInsets.fromLTRB(20, 14, 16, 8),
                                ),
                                SizedBox(
                                  height: 86,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    itemCount: active.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(width: 14),
                                    itemBuilder: (_, i) {
                                      final c = active[i];
                                      final name =
                                          c['username'] as String? ?? '';
                                      return _ActivePerson(
                                        name: name,
                                        onTap: () => _openChat(
                                            c['userId'] ?? '', name),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              SectionTitle(
                                title: _query.isEmpty ? 'Chats' : 'Results',
                                icon: Icons.chat_bubble_rounded,
                                padding:
                                    const EdgeInsets.fromLTRB(20, 14, 16, 4),
                              ),
                              if (_filtered.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: Text(
                                    'No chats match "$_query"',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color:
                                          cs.onSurface.withValues(alpha: 0.5),
                                    ),
                                  ),
                                ),
                              for (final c in _filtered)
                                _ConversationTile(
                                  conversation: c,
                                  isOnline:
                                      _onlineStatus[c['username'] ?? ''] ??
                                          false,
                                  onTap: () => _openChat(
                                    c['userId'] ?? '',
                                    c['username'] ?? '',
                                  ),
                                ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One person in the "Active now" row.
class _ActivePerson extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const _ActivePerson({required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: SizedBox(
        width: 62,
        child: Column(
          children: [
            ArenaAvatar(
              name: name,
              size: 58,
              ring: kBrandColors,
              online: true,
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// One chat: picture, name and time on top, the last message and how many
/// are unread underneath.
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
    final hasUnread = unread > 0;

    return Pressable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          color: hasUnread
              ? AppTheme.primary.withValues(alpha: 0.07)
              : Colors.transparent,
        ),
        child: Row(
          children: [
            ArenaAvatar(
              name: username,
              size: 54,
              ring: hasUnread ? kBrandColors : null,
              online: isOnline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight:
                                hasUnread ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                      if (time.isNotEmpty)
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                hasUnread ? FontWeight.w700 : FontWeight.w500,
                            color: hasUnread
                                ? AppTheme.accentPink
                                : cs.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastMsg.isEmpty ? 'Say hi' : lastMsg,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight:
                                hasUnread ? FontWeight.w600 : FontWeight.w400,
                            color: hasUnread
                                ? cs.onSurface
                                : cs.onSurface.withValues(alpha: 0.55),
                          ),
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          margin: const EdgeInsets.only(left: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          constraints: const BoxConstraints(minWidth: 20),
                          decoration: BoxDecoration(
                            gradient:
                                const LinearGradient(colors: kBrandColors),
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusFull),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact relative time: now / 5m / 3h / 2d / 4w.
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

/// Pick somebody to message: a search bar over everyone, each with their
/// league on show.
class _NewChatSheet extends StatefulWidget {
  final List<UserModel> users;
  final ValueChanged<UserModel> onPick;

  const _NewChatSheet({required this.users, required this.onPick});

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> {
  final _ctrl = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = _q.isEmpty
        ? widget.users
        : widget.users
            .where((u) => u.username.toLowerCase().contains(_q.toLowerCase()))
            .toList();
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, scrollCtrl) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Row(
              children: [
                GradientIcon(Icons.edit_rounded, size: 20),
                SizedBox(width: 8),
                Text(
                  'New message',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ArenaSearchField(
              controller: _ctrl,
              hint: 'Search people',
              onChanged: (v) => setState(() => _q = v.trim()),
            ),
          ),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      'Nobody by that name',
                      style:
                          TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                    ),
                  )
                : ListView.builder(
                    controller: scrollCtrl,
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final u = shown[i];
                      final league = LeagueBadge.gradientFor(u.league);
                      return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 20),
                        leading:
                            ArenaAvatar(name: u.username, size: 44, ring: league),
                        title: Text(
                          u.username,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Align(
                          alignment: Alignment.centerLeft,
                          child: InfoChip(
                            label: u.league,
                            icon: Icons.shield_rounded,
                            color: league.first,
                          ),
                        ),
                        trailing: const GradientIcon(Icons.send_rounded, size: 20),
                        onTap: () => widget.onPick(u),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
