import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/league_badge.dart';

/// One conversation.
///
///   * Header: their picture (green dot when online), name, and "Active now"
///     or when they were last here; call buttons on the right.
///   * Your messages are filled with the brand gradient, theirs sit on a
///     soft surface. A run of messages from one person groups together,
///     with the corners between them tightened, and their picture once at
///     the end of the run.
///   * A time caption appears where 30 minutes or more pass between two
///     messages.
///   * Under your newest message: Seen, Delivered or Sent, with ticks.
///   * Swipe a message sideways to reply to it. Hold it for everything
///     else: reply, copy, forward, edit (for 15 minutes), delete, unsend.
///   * An empty chat offers a few one-tap openers, sent as real messages.
///   * The composer: photo on the left, the text field, and a gradient send
///     button that appears the moment there is something to send.
class ChatConversationPage extends StatefulWidget {
  final String otherUserId;
  final String otherUsername;

  const ChatConversationPage({
    super.key,
    required this.otherUserId,
    required this.otherUsername,
  });

  @override
  State<ChatConversationPage> createState() => _ChatConversationPageState();
}

class _ChatConversationPageState extends State<ChatConversationPage>
    with PageTracker<ChatConversationPage> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  StreamSubscription? _wsSub;
  bool _otherOnline = false;
  String _otherLastSeen = '';

  // Edit mode
  String? _editingMsgId;
  // Reply mode
  Map<String, dynamic>? _replyingTo;

  late final String _convId;

  @override
  String get pageName => 'chat_conversation_page';

  @override
  Map<String, dynamic> get pageParams => {
        'otherUserId': widget.otherUserId,
        'conversationId': _convId,
      };

  @override
  void initState() {
    final myId =
        Provider.of<DataProvider>(context, listen: false).user!.id;
    _convId = EventTracker.makeConversationId(myId, widget.otherUserId);
    super.initState();
    EventTracker.instance.trackChatOpen(
      conversationId: _convId,
      otherUserId: widget.otherUserId,
      source: 'conversation_direct',
    );
    _loadMessages();
    _listenForRealTime();
    _checkOnlineStatus();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _wsSub?.cancel();
    super.dispose();
  }

  String get _myId =>
      Provider.of<DataProvider>(context, listen: false).user!.id;

  Future<void> _checkOnlineStatus() async {
    final status =
        await ApiService.getUserOnlineStatus(widget.otherUsername);
    if (mounted) {
      setState(() {
        _otherOnline = status['online'] == true;
        _otherLastSeen = status['lastSeen'] ?? '';
      });
    }
  }

  Future<void> _loadMessages() async {
    final msgs =
        await ApiService.getChatMessages(_myId, widget.otherUserId);
    if (mounted) {
      setState(() {
        _messages = msgs.reversed.toList();
        _loading = false;
      });
      _scrollToBottom();
      final unreadInbound = _messages
          .where((m) =>
              m['senderId'] == widget.otherUserId && m['isRead'] != true)
          .length;
      if (unreadInbound > 0) {
        EventTracker.instance.trackMessagesRead(
          conversationId: _convId,
          messageCount: unreadInbound,
        );
      }
      ApiService.markChatRead(widget.otherUserId, _myId);
    }
  }

  void _listenForRealTime() {
    final ws = Provider.of<WebSocketService>(context, listen: false);
    _wsSub = ws.notificationStream.listen((notif) {
      if (notif.type == 'chat' && notif.senderId == widget.otherUserId) {
        setState(() {
          _messages.add({
            'id': notif.messageId ?? '',
            'senderId': notif.senderId ?? '',
            'senderUsername': notif.senderUsername ?? '',
            'receiverId': notif.receiverId ?? '',
            'receiverUsername': notif.receiverUsername ?? '',
            'message': notif.message,
            'isRead': true,
            'status': 'read',
            'isEdited': false,
            'isDeleted': false,
            'createdAt': notif.timestamp.toIso8601String(),
          });
          _otherOnline = true;
        });
        _scrollToBottom();
        EventTracker.instance.trackMessagesRead(
          conversationId: _convId,
          messageCount: 1,
        );
        ApiService.markChatRead(widget.otherUserId, _myId);
      }
    });
  }

  /// Sends what is in the composer, or [preset] — one of the openers an
  /// empty chat offers — without touching the composer.
  Future<void> _sendMessage([String? preset]) async {
    final text = (preset ?? _msgCtrl.text).trim();
    if (text.isEmpty) return;
    if (preset == null) _msgCtrl.clear();

    // Handle edit mode
    if (_editingMsgId != null) {
      final editId = _editingMsgId!;
      EventTracker.instance.trackTap(
        target: 'chat_message_edit_submit',
        pageName: 'chat_conversation_page',
        params: {'conversationId': _convId},
      );
      setState(() {
        final idx = _messages.indexWhere((m) => m['id'] == editId);
        if (idx != -1) {
          _messages[idx]['message'] = text;
          _messages[idx]['isEdited'] = true;
        }
        _editingMsgId = null;
      });
      await ApiService.editChatMessage(
        messageId: editId,
        senderId: _myId,
        text: text,
      );
      return;
    }

    final dp = Provider.of<DataProvider>(context, listen: false);
    final now = DateTime.now().toUtc().toIso8601String();
    final replyId = _replyingTo?['id'] as String? ?? '';
    final replyText = _replyingTo?['message'] as String? ?? '';
    setState(() {
      _messages.add({
        'id': 'temp_${DateTime.now().millisecondsSinceEpoch}',
        'senderId': _myId,
        'senderUsername': dp.user!.username,
        'receiverId': widget.otherUserId,
        'receiverUsername': widget.otherUsername,
        'message': text,
        'isRead': false,
        'status': 'sent',
        'isEdited': false,
        'isDeleted': false,
        'replyToId': replyId,
        'replyToText': replyText,
        'createdAt': now,
      });
      _replyingTo = null;
    });
    _scrollToBottom();

    EventTracker.instance.trackMessageSent(
      conversationId: _convId,
      messageLength: text.length,
      hasMedia: false,
    );

    await ApiService.sendChatMessage(
      senderId: _myId,
      receiverId: widget.otherUserId,
      message: text,
      replyToId: replyId.isNotEmpty ? replyId : null,
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _canEdit(Map<String, dynamic> msg) {
    final createdAt = DateTime.tryParse(msg['createdAt'] ?? '');
    if (createdAt == null) return false;
    return DateTime.now().toUtc().difference(createdAt).inMinutes < 15;
  }

  /// Feature slots IG has but our chat backend doesn't yet (media DMs,
  /// voice, calls). The glyphs are part of the exact layout — tapping
  /// tells the user it's on the way instead of silently doing nothing.
  void _comingSoon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what is coming soon'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showMessageActions(Map<String, dynamic> msg) {
    final isMe = msg['senderId'] == _myId;
    final isDeleted = msg['isDeleted'] == true;
    if (isDeleted) return;

    final canEdit = isMe && _canEdit(msg);

    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        Widget action(IconData icon, String label, VoidCallback onTap) {
          return Expanded(
            child: Pressable(
              onTap: onTap,
              child: Column(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.primary.withValues(alpha: 0.12),
                      border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.25),
                      ),
                    ),
                    alignment: Alignment.center,
                    child: GradientIcon(icon, size: 22),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The message being acted on, so it is clear which one.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                  child: Text(
                    msg['message'] ?? '',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.75)),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    action(Icons.reply_rounded, 'Reply', () {
                      Navigator.pop(ctx);
                      setState(() => _replyingTo = msg);
                    }),
                    action(Icons.copy_rounded, 'Copy', () {
                      Clipboard.setData(
                          ClipboardData(text: msg['message'] ?? ''));
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('Copied'),
                            duration: Duration(seconds: 1)),
                      );
                    }),
                    action(Icons.forward_rounded, 'Forward', () {
                      Navigator.pop(ctx);
                      _showForwardPicker(msg);
                    }),
                    // Edit: own messages, within 15 minutes of sending.
                    if (canEdit)
                      action(Icons.edit_rounded, 'Edit', () {
                        Navigator.pop(ctx);
                        setState(() {
                          _editingMsgId = msg['id'];
                          _msgCtrl.text = msg['message'] ?? '';
                        });
                      }),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                // Delete for me: anyone can remove a message from their view.
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: Icon(Icons.delete_outline_rounded,
                      color: cs.onSurface.withValues(alpha: 0.7)),
                  title: const Text('Delete for me'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _deleteForMe(msg);
                  },
                ),
                // Unsend: own messages only — deletes for everyone.
                if (isMe)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: const Icon(Icons.delete_forever_rounded,
                        color: AppTheme.error),
                    title: const Text('Unsend',
                        style: TextStyle(color: AppTheme.error)),
                    subtitle: const Text('Removes it for both of you'),
                    onTap: () {
                      Navigator.pop(ctx);
                      _deleteMessage(msg);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _deleteForMe(Map<String, dynamic> msg) {
    setState(() {
      _messages.removeWhere((m) => m['id'] == msg['id']);
    });
  }

  void _deleteMessage(Map<String, dynamic> msg) async {
    setState(() {
      msg['isDeleted'] = true;
      msg['message'] = 'Message unsent';
    });
    await ApiService.deleteChatMessage(
      messageId: msg['id'] ?? '',
      senderId: _myId,
    );
  }

  void _showForwardPicker(Map<String, dynamic> msg) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final users = dp.allUsers.where((u) => u.id != _myId).toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  GradientIcon(Icons.forward_rounded, size: 20),
                  SizedBox(width: 8),
                  Text('Forward to',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 18)),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: users.length,
                itemBuilder: (_, i) {
                  final u = users[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: ArenaAvatar(
                      name: u.username,
                      size: 42,
                      ring: LeagueBadge.gradientFor(u.league),
                    ),
                    title: Text(u.username,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    trailing:
                        const GradientIcon(Icons.send_rounded, size: 20),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await ApiService.forwardChatMessage(
                        messageId: msg['id'] ?? '',
                        senderId: _myId,
                        receiverId: u.id,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('Forwarded to ${u.username}'),
                              duration: const Duration(seconds: 1)),
                        );
                      }
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

  /// Activity subtitle: "Active now", "Active 35m ago",
  /// "Active 2h ago", "Active 3d ago" — empty when unknown.
  String _activityLabel() {
    if (_otherOnline) return 'Active now';
    if (_otherLastSeen.isEmpty) return '';
    final dt = DateTime.tryParse(_otherLastSeen);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
    return 'Active ${diff.inDays}d ago';
  }

  /// A centered time caption is inserted when 30+ minutes pass between
  /// consecutive messages, not merely on day change.
  bool _needsTimeHeader(Map<String, dynamic>? prev, Map<String, dynamic> cur) {
    if (prev == null) return true;
    final a = DateTime.tryParse(prev['createdAt'] ?? '');
    final b = DateTime.tryParse(cur['createdAt'] ?? '');
    if (a == null || b == null) return true;
    return b.difference(a).inMinutes >= 30;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final activity = _activityLabel();

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        titleSpacing: 0,
        centerTitle: false,
        title: Row(
          children: [
            ArenaAvatar(
              name: widget.otherUsername,
              size: 40,
              ring: _otherOnline ? kBrandColors : null,
              online: _otherOnline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.otherUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  if (activity.isNotEmpty)
                    Text(
                      activity,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: _otherOnline
                            ? AppTheme.success
                            : cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconBubble(
            icon: Icons.call_rounded,
            tooltip: 'Audio call',
            size: 38,
            onTap: () => _comingSoon('Audio calling'),
          ),
          const SizedBox(width: 8),
          IconBubble(
            icon: Icons.videocam_rounded,
            tooltip: 'Video call',
            size: 38,
            onTap: () => _comingSoon('Video calling'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? _EmptyThread(
                        name: widget.otherUsername,
                        onPick: _sendMessage,
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final msg = _messages[i];
                          final isMe = msg['senderId'] == _myId;
                          final showHeader = _needsTimeHeader(
                              i == 0 ? null : _messages[i - 1], msg);
                          // Grouping: consecutive bubbles from one sender
                          // (with no time caption splitting them) tighten
                          // their facing corners.
                          final prevSame = i > 0 &&
                              !showHeader &&
                              _messages[i - 1]['senderId'] ==
                                  msg['senderId'];
                          final nextSame = i < _messages.length - 1 &&
                              _messages[i + 1]['senderId'] ==
                                  msg['senderId'] &&
                              !_needsTimeHeader(msg, _messages[i + 1]);
                          final isNewest = i == _messages.length - 1;
                          return Column(
                            children: [
                              if (showHeader)
                                _TimeHeader(
                                    date: msg['createdAt'] ?? ''),
                              _MessageBubble(
                                message: msg,
                                isMe: isMe,
                                otherUsername: widget.otherUsername,
                                groupedWithPrev: prevSame,
                                groupedWithNext: nextSame,
                                // The seen sign lives under your last
                                // message only while it's the newest
                                // thing in the thread.
                                showStatus: isMe && isNewest,
                                onLongPress: () =>
                                    _showMessageActions(msg),
                                onReply: () =>
                                    setState(() => _replyingTo = msg),
                              ),
                            ],
                          );
                        },
                      ),
          ),

          // Replying to…
          if (_replyingTo != null)
            _ComposerBanner(
              icon: Icons.reply_rounded,
              title: _replyingTo!['senderId'] == _myId
                  ? 'Replying to yourself'
                  : 'Replying to ${widget.otherUsername}',
              body: _replyingTo!['message'] ?? '',
              onClose: () => setState(() => _replyingTo = null),
            ),

          // Editing…
          if (_editingMsgId != null)
            _ComposerBanner(
              icon: Icons.edit_rounded,
              title: 'Editing message',
              onClose: () => setState(() {
                _editingMsgId = null;
                _msgCtrl.clear();
              }),
            ),

          // ── Composer ──
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconBubble(
                    icon: Icons.add_photo_alternate_rounded,
                    tooltip: 'Photo',
                    size: 44,
                    onTap: () => _comingSoon('Photo messaging'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 11),
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.06),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusXxl),
                        border: Border.all(
                            color: cs.onSurface.withValues(alpha: 0.08)),
                      ),
                      child: TextField(
                        controller: _msgCtrl,
                        minLines: 1,
                        maxLines: 5,
                        cursorColor: AppTheme.primary,
                        decoration: const InputDecoration(
                          hintText: 'Message…',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          isCollapsed: true,
                        ),
                        style: const TextStyle(fontSize: 15),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Send appears the moment there is something to send
                  // (Save while editing); until then, the microphone.
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _msgCtrl,
                    builder: (_, value, _) {
                      final ready = value.text.trim().isNotEmpty ||
                          _editingMsgId != null;
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        transitionBuilder: (c, a) =>
                            ScaleTransition(scale: a, child: c),
                        child: ready
                            ? IconBubble(
                                key: const ValueKey('send'),
                                icon: _editingMsgId != null
                                    ? Icons.check_rounded
                                    : Icons.send_rounded,
                                tooltip:
                                    _editingMsgId != null ? 'Save' : 'Send',
                                filled: true,
                                size: 44,
                                onTap: _sendMessage,
                              )
                            : IconBubble(
                                key: const ValueKey('mic'),
                                icon: Icons.mic_rounded,
                                tooltip: 'Voice message',
                                size: 44,
                                onTap: () => _comingSoon('Voice messaging'),
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What an empty chat shows: who it is with, and a few openers that send
/// as real messages with one tap.
class _EmptyThread extends StatelessWidget {
  final String name;
  final ValueChanged<String> onPick;

  const _EmptyThread({required this.name, required this.onPick});

  static const openers = [
    '👋 Hey!',
    '⚔️ Up for a battle?',
    '🔥 Loved your video',
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArenaAvatar(name: name, size: 88, ring: kBrandColors),
            const SizedBox(height: 14),
            Text(
              name,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Say hello to $name',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in openers)
                  Pressable(
                    onTap: () => onPick(o),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusFull),
                        color: AppTheme.primary.withValues(alpha: 0.10),
                        border: Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Text(
                        o,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The strip above the composer while replying or editing: a gradient bar
/// down the side, what is happening, and a close button.
class _ComposerBanner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback onClose;

  const _ComposerBanner({
    required this.icon,
    required this.title,
    this.body,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      padding: const EdgeInsets.fromLTRB(0, 6, 4, 6),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: body == null ? 20 : 34,
            margin: const EdgeInsets.only(left: 8, right: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: kBrandColors,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          GradientIcon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: cs.onSurface.withValues(alpha: 0.8),
                  ),
                ),
                if (body != null && body!.isNotEmpty)
                  Text(
                    body!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Cancel',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Centered small time caption between message runs: "14:32" today,
/// "Yesterday 09:10", the weekday within a week, then full dates.
class _TimeHeader extends StatelessWidget {
  final String date;
  const _TimeHeader({required this.date});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          ),
          child: Text(
            _label(date),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  String _label(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final days = today.difference(day).inDays;

    if (days == 0) return time;
    if (days == 1) return 'Yesterday $time';
    if (days < 7) {
      const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return '${wk[local.weekday - 1]} $time';
    }
    const mo = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${local.day} ${mo[local.month]} ${local.year}, $time';
  }
}

/// One message: the brand gradient for yours, a soft surface for theirs,
/// corners tightened on the side facing a grouped neighbour, their picture
/// once at the end of their run, a quoted reply and "Edited" above, and
/// Seen / Delivered / Sent below when [showStatus].
///
/// Drag it sideways to reply: a reply arrow fades in as it moves, and past
/// the line it snaps back and the reply opens.
class _MessageBubble extends StatefulWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final String otherUsername;
  final bool groupedWithPrev;
  final bool groupedWithNext;
  final bool showStatus;
  final VoidCallback onLongPress;
  final VoidCallback onReply;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.otherUsername,
    required this.groupedWithPrev,
    required this.groupedWithNext,
    required this.showStatus,
    required this.onLongPress,
    required this.onReply,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  /// How far the bubble has been dragged, 0 to [_max].
  double _drag = 0;
  bool _armed = false;

  static const double _max = 72;
  static const double _trigger = 52;

  void _onDragUpdate(DragUpdateDetails d) {
    final next = (_drag + d.delta.dx.abs()).clamp(0.0, _max);
    final armed = next >= _trigger;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _drag = next;
      _armed = armed;
    });
  }

  void _onDragEnd([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    setState(() {
      _drag = 0;
      _armed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isMe = widget.isMe;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isDeleted = message['isDeleted'] == true;
    final isEdited = message['isEdited'] == true;
    final replyText = message['replyToText'] as String? ?? '';

    // 20px outer corners; the corners facing a grouped neighbour tighten
    // to 6px on the sender's side (left for incoming, right for outgoing).
    const r = Radius.circular(20);
    const rs = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: !isMe && widget.groupedWithPrev ? rs : r,
      bottomLeft: !isMe && widget.groupedWithNext ? rs : r,
      topRight: isMe && widget.groupedWithPrev ? rs : r,
      bottomRight: isMe && widget.groupedWithNext ? rs : r,
    );

    final incoming = dark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08), AppTheme.bgDark)
        : const Color(0xFFF0EEF7);

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: isDeleted
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: cs.onSurface.withValues(alpha: 0.3)),
            )
          : BoxDecoration(
              gradient: isMe
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: kBrandColors,
                    )
                  : null,
              color: isMe ? null : incoming,
              borderRadius: radius,
              boxShadow: isMe
                  ? [
                      BoxShadow(
                        color: AppTheme.primary.withValues(alpha: 0.22),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
      child: Text(
        message['message'] ?? '',
        style: TextStyle(
          color: isDeleted
              ? cs.onSurface.withValues(alpha: 0.5)
              : isMe
                  ? Colors.white
                  : cs.onSurface,
          fontSize: 15,
          height: 1.3,
          fontStyle: isDeleted ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );

    // Their picture sits only at the last bubble of their run.
    final Widget leading = !isMe
        ? (widget.groupedWithNext
            ? const SizedBox(width: 26)
            : ArenaAvatar(name: widget.otherUsername, size: 26))
        : const SizedBox.shrink();

    // Swipe towards the middle of the screen: right for theirs, left for
    // yours, which is the way a finger naturally pulls each.
    final dx = isMe ? -_drag : _drag;
    final replyHint = Opacity(
      opacity: (_drag / _trigger).clamp(0.0, 1.0),
      child: AnimatedScale(
        scale: _armed ? 1.15 : 0.9,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.primary.withValues(alpha: _armed ? 0.9 : 0.25),
          ),
          child: const Icon(Icons.reply_rounded, size: 18, color: Colors.white),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        top: widget.groupedWithPrev ? 1.5 : 6,
        bottom: widget.groupedWithNext ? 1.5 : 6,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Reply caption + quoted mini-bubble above the message.
          if (replyText.isNotEmpty && !isDeleted) ...[
            Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 34, right: isMe ? 6 : 0, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.reply_rounded,
                      size: 12, color: cs.onSurface.withValues(alpha: 0.45)),
                  const SizedBox(width: 3),
                  Text(
                    isMe ? 'You replied' : '${widget.otherUsername} replied',
                    style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurface.withValues(alpha: 0.45)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.only(left: isMe ? 0 : 34, bottom: 2),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.6,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border(
                    left: BorderSide(
                      color: AppTheme.primary.withValues(alpha: 0.6),
                      width: 3,
                    ),
                  ),
                ),
                child: Text(
                  replyText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6)),
                ),
              ),
            ),
          ],
          if (isEdited && !isDeleted)
            Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 34, right: isMe ? 6 : 0, bottom: 2),
              child: Text(
                'Edited',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.45)),
              ),
            ),

          // The bubble row (their picture + bubble for incoming), with the
          // reply arrow waiting behind it for a swipe.
          GestureDetector(
            onLongPress: isDeleted ? null : widget.onLongPress,
            onHorizontalDragUpdate: isDeleted ? null : _onDragUpdate,
            onHorizontalDragEnd: isDeleted ? null : _onDragEnd,
            onHorizontalDragCancel: isDeleted ? null : _onDragEnd,
            child: Stack(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              children: [
                if (_drag > 0)
                  Positioned(
                    left: isMe ? null : 2,
                    right: isMe ? 2 : null,
                    child: replyHint,
                  ),
                Transform.translate(
                  offset: Offset(dx, 0),
                  child: Row(
                    mainAxisAlignment:
                        isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!isMe) ...[leading, const SizedBox(width: 8)],
                      Flexible(child: bubble),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // The seen sign under your newest message.
          if (widget.showStatus && !isDeleted)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _statusIcon(),
                    size: 14,
                    color: message['isRead'] == true
                        ? AppTheme.accentCyan
                        : cs.onSurface.withValues(alpha: 0.45),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _statusLabel(),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface.withValues(alpha: 0.45)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel() {
    final m = widget.message;
    if (m['isRead'] == true) return 'Seen';
    if ((m['status'] ?? '') == 'delivered') return 'Delivered';
    return 'Sent';
  }

  IconData _statusIcon() {
    final m = widget.message;
    if (m['isRead'] == true) return Icons.done_all_rounded;
    if ((m['status'] ?? '') == 'delivered') return Icons.done_all_rounded;
    return Icons.check_rounded;
  }
}
