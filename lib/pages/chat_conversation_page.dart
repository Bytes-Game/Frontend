import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/pages/chat_list_page.dart' show kDmBlue;

/// Instagram-DM-style conversation thread, point for point:
///   * Header: back chevron, avatar + name with "Active now / Active 2h
///     ago" subtitle, audio + video call icons on the right.
///   * Bubbles: 22px-rounded, IG blue for outgoing, grey for incoming;
///     consecutive messages from one sender group together (inner corners
///     tighten to 4px) and the incoming group shows one mini avatar at
///     its tail. No timestamps or ticks inside bubbles — IG has neither.
///   * Time: small centered grey captions between message runs separated
///     by 30+ minutes ("14:32", "Yesterday 09:10", …).
///   * Seen sign: a small grey "Seen" (or Delivered / Sent) caption under
///     your last message when it's the newest in the thread — exactly how
///     IG communicates read state.
///   * Composer: one rounded pill — blue camera circle inside-left, the
///     "Message…" field, mic / photo / sticker glyphs that swap to a blue
///     "Send" the moment you type.
/// Long-press keeps the full action sheet (reply, copy, forward, edit,
/// delete for me, unsend).
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

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;
    _msgCtrl.clear();

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
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            // Reply
            ListTile(
              leading: const Icon(Icons.reply),
              title: const Text('Reply'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() => _replyingTo = msg);
              },
            ),
            // Copy
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Clipboard.setData(
                    ClipboardData(text: msg['message'] ?? ''));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1)),
                );
              },
            ),
            // Forward
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(ctx);
                _showForwardPicker(msg);
              },
            ),
            // Edit (own messages within 15 min only)
            if (canEdit)
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('Edit'),
                subtitle: const Text('Available for 15 minutes after sending',
                    style: TextStyle(fontSize: 11)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _editingMsgId = msg['id'];
                    _msgCtrl.text = msg['message'] ?? '';
                  });
                },
              ),
            // Delete for me (anyone can remove from their view)
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7)),
              title: const Text('Delete for me'),
              onTap: () {
                Navigator.pop(ctx);
                _deleteForMe(msg);
              },
            ),
            // Unsend (own messages only — deletes for everyone)
            if (isMe)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Unsend',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMessage(msg);
                },
              ),
          ],
        ),
      ),
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
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            const SizedBox(height: 12),
            const Text('Forward to',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: users.length,
                itemBuilder: (_, i) {
                  final u = users[i];
                  return ListTile(
                    leading: CircleAvatar(
                      child: Text(u.username[0].toUpperCase()),
                    ),
                    title: Text(u.username),
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

  /// IG-style activity subtitle: "Active now", "Active 35m ago",
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
  /// consecutive messages (IG's rule), not merely on day change.
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
        title: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    widget.otherUsername.isNotEmpty
                        ? widget.otherUsername[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                        fontSize: 16),
                  ),
                ),
                if (_otherOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1CD14F),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color:
                                Theme.of(context).scaffoldBackgroundColor,
                            width: 2),
                      ),
                    ),
                  ),
              ],
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
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  if (activity.isNotEmpty)
                    Text(
                      activity,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            onPressed: () => _comingSoon('Audio calling'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => _comingSoon('Video calling'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // Messages
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Text(
                          'Say hello to ${widget.otherUsername}!',
                          style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.5)),
                        ),
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
                          // their facing corners, like IG.
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
                                // thing in the thread — IG behaviour.
                                showStatus: isMe && isNewest,
                                onLongPress: () =>
                                    _showMessageActions(msg),
                              ),
                            ],
                          );
                        },
                      ),
          ),

          // Reply preview
          if (_replyingTo != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyingTo!['senderId'] == _myId
                              ? 'Replying to yourself'
                              : 'Replying to ${widget.otherUsername}',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              color:
                                  cs.onSurface.withValues(alpha: 0.7)),
                        ),
                        Text(
                          _replyingTo!['message'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color:
                                  cs.onSurface.withValues(alpha: 0.5)),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _replyingTo = null),
                  ),
                ],
              ),
            ),

          // Edit indicator
          if (_editingMsgId != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
              child: Row(
                children: [
                  Icon(Icons.edit,
                      size: 16,
                      color: cs.onSurface.withValues(alpha: 0.7)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Editing message',
                        style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.7),
                            fontSize: 13)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() {
                      _editingMsgId = null;
                      _msgCtrl.clear();
                    }),
                  ),
                ],
              ),
            ),

          // ── Composer: single rounded pill, IG layout ──
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    // Blue camera circle, inside-left of the pill.
                    GestureDetector(
                      onTap: () => _comingSoon('Photo messaging'),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(
                          color: kDmBlue,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt,
                            size: 19, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _msgCtrl,
                        minLines: 1,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          hintText: 'Message...',
                          border: InputBorder.none,
                          isCollapsed: true,
                        ),
                        style: const TextStyle(fontSize: 15),
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                    // Right cluster: mic/photo/sticker glyphs at rest,
                    // blue Send while there's text (Save while editing).
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _msgCtrl,
                      builder: (_, value, _) {
                        final hasText = value.text.trim().isNotEmpty;
                        if (hasText || _editingMsgId != null) {
                          return TextButton(
                            onPressed: _sendMessage,
                            style: TextButton.styleFrom(
                              minimumSize: Size.zero,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(
                              _editingMsgId != null ? 'Save' : 'Send',
                              style: const TextStyle(
                                color: kDmBlue,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          );
                        }
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ComposerGlyph(
                              icon: Icons.mic_none_rounded,
                              onTap: () => _comingSoon('Voice messaging'),
                            ),
                            _ComposerGlyph(
                              icon: Icons.image_outlined,
                              onTap: () => _comingSoon('Photo messaging'),
                            ),
                            _ComposerGlyph(
                              icon: Icons.emoji_emotions_outlined,
                              onTap: () => _comingSoon('Stickers'),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One icon in the composer's right cluster.
class _ComposerGlyph extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ComposerGlyph({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Icon(icon,
            size: 24, color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

/// Centered small grey time caption between message runs — IG shows
/// "14:32" today, "Yesterday 09:10", the weekday within a week, then
/// full dates.
class _TimeHeader extends StatelessWidget {
  final String date;
  const _TimeHeader({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          _label(date),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.45),
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

/// One IG-style bubble: 22px corners (tightened to 4px on the grouped
/// side), IG blue for outgoing / grey for incoming, mini avatar at the
/// tail of an incoming group, reply quote + "Edited" captions above, and
/// the Seen / Delivered / Sent caption below when [showStatus].
class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final String otherUsername;
  final bool groupedWithPrev;
  final bool groupedWithNext;
  final bool showStatus;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.otherUsername,
    required this.groupedWithPrev,
    required this.groupedWithNext,
    required this.showStatus,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isDeleted = message['isDeleted'] == true;
    final isEdited = message['isEdited'] == true;
    final replyText = message['replyToText'] as String? ?? '';

    final incomingGrey =
        dark ? const Color(0xFF262626) : const Color(0xFFEFEFEF);

    // 22px outer corners; the corners facing a grouped neighbour tighten
    // to 4px on the sender's side (left for incoming, right for outgoing).
    const r = Radius.circular(22);
    const rs = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: !isMe && groupedWithPrev ? rs : r,
      bottomLeft: !isMe && groupedWithNext ? rs : r,
      topRight: isMe && groupedWithPrev ? rs : r,
      bottomRight: isMe && groupedWithNext ? rs : r,
    );

    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: isDeleted
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                  color: cs.onSurface.withValues(alpha: 0.3)),
            )
          : BoxDecoration(
              color: isMe ? kDmBlue : incomingGrey,
              borderRadius: radius,
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

    // Mini avatar sits only at the tail bubble of an incoming group.
    final Widget leading = !isMe
        ? (groupedWithNext
            ? const SizedBox(width: 24)
            : CircleAvatar(
                radius: 12,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  otherUsername.isNotEmpty
                      ? otherUsername[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: cs.onPrimaryContainer),
                ),
              ))
        : const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.only(
        top: groupedWithPrev ? 1.5 : 6,
        bottom: groupedWithNext ? 1.5 : 6,
      ),
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Reply caption + quoted mini-bubble above the message.
          if (replyText.isNotEmpty && !isDeleted) ...[
            Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 32, right: isMe ? 6 : 0, bottom: 2),
              child: Text(
                isMe
                    ? 'You replied'
                    : '$otherUsername replied',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.45)),
              ),
            ),
            Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 32, bottom: 2),
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.6,
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest
                      .withValues(alpha: dark ? 0.5 : 1),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  replyText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.55)),
                ),
              ),
            ),
          ],
          if (isEdited && !isDeleted)
            Padding(
              padding: EdgeInsets.only(
                  left: isMe ? 0 : 32, right: isMe ? 6 : 0, bottom: 2),
              child: Text(
                'Edited',
                style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.45)),
              ),
            ),

          // The bubble row (mini avatar + bubble for incoming).
          GestureDetector(
            onLongPress: isDeleted ? null : onLongPress,
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

          // The seen sign — small grey caption under your newest message.
          if (showStatus && !isDeleted)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(
                _statusLabel(),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: cs.onSurface.withValues(alpha: 0.45)),
              ),
            ),
        ],
      ),
    );
  }

  String _statusLabel() {
    if (message['isRead'] == true) return 'Seen';
    if ((message['status'] ?? '') == 'delivered') return 'Delivered';
    return 'Sent';
  }
}
