import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/notification_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/fold_in.dart';
import 'package:myapp/widgets/league_badge.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

/// The inbox.
///
/// From the top:
///   * "Messages", large, shrinking into the bar as the list scrolls under
///     it, and a new-message button.
///   * The app's search bar, filtering your chats as you type.
///   * "Active now": the people you talk to who are online right now, as a
///     row of pictures — tap one to open the chat. Only there when someone
///     is online, so it never takes space to say nothing.
///   * Delete a chat: swipe it to the left, or press and hold it. It goes
///     off your list only; the other person keeps theirs.
///   * Your chats. Each row folds up into place in 3D the first time it
///     scrolls into view, and leans away as it leaves the top (FoldIn).
///     Something unread: a bold name, the time in blue and a count. Your
///     own last message: "You:" and how far it got — a blue double tick
///     once seen. Somebody typing: "typing…" in blue, live.
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
  StreamSubscription? _liveSub;
  final Map<String, bool> _onlineStatus = {};

  /// Who is typing to you right now, by user id; each clears itself after a
  /// few seconds in case their "stopped" is lost.
  final Map<String, Timer> _typing = {};

  /// How far the list has scrolled, for the shrinking title.
  final _listScroll = ScrollController();
  double _scrolled = 0;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  String get pageName => 'chat_list_page';

  @override
  void initState() {
    super.initState();
    _listScroll.addListener(() {
      final v = _listScroll.offset.clamp(0.0, 60.0);
      if ((v - _scrolled).abs() > 0.5) setState(() => _scrolled = v);
    });
    _load();
    _listenForNewMessages();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _liveSub?.cancel();
    for (final t in _typing.values) {
      t.cancel();
    }
    _listScroll.dispose();
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
        _typing.remove(notif.senderId ?? '')?.cancel();
        _bringToTop(notif);
        _load();
      }
    });
    _liveSub = ws.events.listen(_onLive);
  }

  /// A new message puts its chat at the top straight away, with the new
  /// text and one more unread, the way every chat app's list moves. The
  /// reload that follows only confirms it.
  void _bringToTop(NotificationModel n) {
    final from = n.senderId ?? '';
    if (from.isEmpty || !mounted) return;
    final i = _conversations.indexWhere((c) => '${c['userId']}' == from);
    final old = i < 0 ? <String, dynamic>{} : _conversations[i];
    setState(() {
      if (i >= 0) _conversations.removeAt(i);
      _conversations.insert(0, {
        ...old,
        'userId': from,
        'username': old['username'] ?? n.senderUsername ?? '',
        'lastMessage': n.message,
        'lastTime': n.timestamp.toUtc().toIso8601String(),
        'lastFromMe': false,
        'lastStatus': '',
        'unreadCount': ((old['unreadCount'] as num?)?.toInt() ?? 0) + 1,
      });
    });
  }

  /// "Seen", "Delivered" and "typing…" on the rows, as they happen.
  void _onLive(Map<String, dynamic> ev) {
    if (!mounted) return;
    switch (ev['type']) {
      case 'chat_read':
        _markLast('${ev['readerId']}', 'read');
      case 'chat_delivered':
        _markLast('${ev['receiverId']}', 'delivered');
      case 'typing':
        final from = '${ev['from']}';
        _typing.remove(from)?.cancel();
        if (ev['typing'] == true) {
          _typing[from] = Timer(const Duration(seconds: 6), () {
            if (mounted) setState(() => _typing.remove(from));
          });
        }
        setState(() {});
    }
  }

  void _markLast(String userId, String status) {
    final i = _conversations.indexWhere((c) => '${c['userId']}' == userId);
    if (i < 0) return;
    final c = _conversations[i];
    if (c['lastFromMe'] != true || c['lastStatus'] == 'read') return;
    setState(() => c['lastStatus'] = status);
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

  /// "Delete chat?", and if so, asks the server. True once it is deleted.
  Future<bool> _deleteChat(Map<String, dynamic> c) => deleteChatWith(
        context,
        userId: '${c['userId']}',
        name: '${c['username'] ?? ''}',
      );

  void _forget(Map<String, dynamic> c) {
    setState(() => _conversations
        .removeWhere((x) => '${x['userId']}' == '${c['userId']}'));
  }

  /// Press and hold a chat: what can be done with it.
  void _chatOptions(Map<String, dynamic> c) => showChatOptions(
        context,
        userId: '${c['userId']}',
        name: '${c['username'] ?? ''}',
        onDeleted: () => _forget(c),
      );

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
            // ── Header: title left, new message right. The title shrinks
            // as the list scrolls up under it. ──
            Padding(
              padding: EdgeInsets.fromLTRB(20, 10 - _scrolled / 12, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Transform.scale(
                        scale: 1 - _scrolled / 60 * 0.3,
                        alignment: Alignment.centerLeft,
                        child: const Text(
                          'Messages',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_square, size: 24),
                    color: kAccent,
                    tooltip: 'New message',
                    onPressed: _showNewChatPicker,
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
                            controller: _listScroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 16),
                            children: [
                              if (showActive) ...[
                                const SectionTitle(
                                  title: 'Active now',
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
                                      return FoldIn(
                                        order: i,
                                        child: _ActivePerson(
                                          name: name,
                                          onTap: () => _openChat(
                                              c['userId'] ?? '', name),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              SectionTitle(
                                title: _query.isEmpty ? 'Chats' : 'Results',
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
                              for (final (i, c) in _filtered.indexed)
                                FoldIn(
                                  key: ValueKey('chat_${c['userId']}'),
                                  order: i,
                                  depth: true,
                                  // Swipe left to delete the chat.
                                  child: Dismissible(
                                    key: ValueKey('swipe_${c['userId']}'),
                                    direction: DismissDirection.endToStart,
                                    background: const _DeleteBehind(),
                                    confirmDismiss: (_) => _deleteChat(c),
                                    onDismissed: (_) => _forget(c),
                                    child: _ConversationTile(
                                      conversation: c,
                                      isOnline:
                                          _onlineStatus[c['username'] ?? ''] ??
                                              false,
                                      typing: _typing
                                          .containsKey('${c['userId']}'),
                                      onTap: () => _openChat(
                                        c['userId'] ?? '',
                                        c['username'] ?? '',
                                      ),
                                      onLongPress: () => _chatOptions(c),
                                    ),
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
  final bool typing;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ConversationTile({
    required this.conversation,
    required this.isOnline,
    required this.typing,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final username = conversation['username'] ?? '';
    final lastMsg = (conversation['lastMessage'] ?? '') as String;
    final unread = (conversation['unreadCount'] ?? 0) as int;
    final time = _relativeTime(conversation['lastTime'] ?? '');
    final hasUnread = unread > 0;
    final mine = conversation['lastFromMe'] == true;
    final status = conversation['lastStatus'] as String? ?? '';

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: 0.98,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          color: Colors.transparent,
        ),
        child: Row(
          children: [
            ArenaAvatar(
              name: username,
              size: 54,
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
                                hasUnread ? FontWeight.w700 : FontWeight.w600,
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
                                ? kAccent
                                : cs.onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      // Your own last message: how far it got.
                      if (mine && !typing) ...[
                        Icon(
                          status == 'sent'
                              ? Icons.check_rounded
                              : Icons.done_all_rounded,
                          size: 15,
                          color: status == 'read'
                              ? kAccent
                              : cs.onSurface.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, ?current],
                          ),
                          child: typing
                              ? const Text(
                                  'typing…',
                                  key: ValueKey('typing'),
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: kAccent,
                                  ),
                                )
                              : Text(
                                  lastMsg.isEmpty
                                      ? 'Say hi'
                                      : mine
                                          ? 'You: $lastMsg'
                                          : lastMsg,
                                  key: const ValueKey('last'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: hasUnread
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    color: hasUnread
                                        ? cs.onSurface
                                        : cs.onSurface.withValues(alpha: 0.55),
                                  ),
                                ),
                        ),
                      ),
                      if (mine && status == 'read' && !typing)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            'Seen',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withValues(alpha: 0.45),
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
                            color: kAccent,
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

/// What shows behind a chat as it is swiped away: red, with a bin.
class _DeleteBehind extends StatelessWidget {
  const _DeleteBehind();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      padding: const EdgeInsets.only(right: 24),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: AppTheme.error,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline_rounded, color: Colors.white),
          SizedBox(width: 6),
          Text(
            'Delete',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
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
            child: Text(
              'New message',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
                      final league = LeagueBadge.solidColor(u.league);
                      return ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 20),
                        leading: ArenaAvatar(name: u.username, size: 44),
                        title: Text(
                          u.username,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        // The league in its colour, with no shield: the
                        // shield is only in the profile's own box.
                        subtitle: Align(
                          alignment: Alignment.centerLeft,
                          child: InfoChip(label: u.league, color: league),
                        ),
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: quietText(context)),
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
