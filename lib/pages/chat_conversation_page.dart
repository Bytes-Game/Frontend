import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';

/// WhatsApp-style chat conversation page with date separators, ticks,
/// online status, and message actions (reply, edit, delete, forward, copy).
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
      msg['message'] = 'This message was deleted';
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

  String _formatLastSeen(String iso) {
    if (iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    String time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (diff.inDays == 0) return 'last seen today at $time';
    if (diff.inDays == 1) return 'last seen yesterday at $time';
    return 'last seen ${local.day}/${local.month} at $time';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
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
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
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
                      style: const TextStyle(fontSize: 16)),
                  Text(
                    _otherOnline
                        ? 'online'
                        : _formatLastSeen(_otherLastSeen),
                    style: TextStyle(
                      fontSize: 12,
                      color: _otherOnline
                          ? Colors.green
                          : cs.onSurface.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
                              color: cs.onSurface.withOpacity(0.5)),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (_, i) {
                          final showDate = i == 0 ||
                              _differentDay(
                                  _messages[i]['createdAt'],
                                  _messages[i - 1]['createdAt']);
                          return Column(
                            children: [
                              if (showDate)
                                _DateSeparator(
                                    date: _messages[i]['createdAt'] ?? ''),
                              _MessageBubble(
                                message: _messages[i],
                                isMe: _messages[i]['senderId'] == _myId,
                                onLongPress: () =>
                                    _showMessageActions(_messages[i]),
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
              color: cs.surfaceContainerHighest.withOpacity(0.5),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 36,
                    color: cs.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _replyingTo!['senderUsername'] ?? '',
                          style: TextStyle(
                              color: cs.primary,
                              fontWeight: FontWeight.w600,
                              fontSize: 12),
                        ),
                        Text(
                          _replyingTo!['message'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withOpacity(0.6)),
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
              color: Colors.orange.withOpacity(0.1),
              child: Row(
                children: [
                  const Icon(Icons.edit, size: 16, color: Colors.orange),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Editing message',
                        style: TextStyle(
                            color: Colors.orange, fontSize: 13)),
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

          // Input bar
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: BoxDecoration(
              color: Theme.of(context).scaffoldBackgroundColor,
              border: Border(
                top: BorderSide(
                    color: cs.outline.withOpacity(0.2), width: 0.5),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      decoration: InputDecoration(
                        hintText: 'Message...',
                        filled: true,
                        fillColor:
                            cs.surfaceContainerHighest.withOpacity(0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: cs.primary,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(
                        _editingMsgId != null ? Icons.check : Icons.send,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _differentDay(String? a, String? b) {
    if (a == null || b == null) return true;
    final da = DateTime.tryParse(a);
    final db = DateTime.tryParse(b);
    if (da == null || db == null) return true;
    final la = da.toLocal();
    final lb = db.toLocal();
    return la.year != lb.year || la.month != lb.month || la.day != lb.day;
  }
}

/// Date separator between message groups.
class _DateSeparator extends StatelessWidget {
  final String date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _formatDate(date),
            style: TextStyle(
              fontSize: 12,
              color:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);

    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) {
      const days = [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday',
        'Friday', 'Saturday', 'Sunday'
      ];
      return days[local.weekday - 1];
    }
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${local.day} ${months[local.month]} ${local.year}';
  }
}

/// WhatsApp-style message bubble with ticks, time, edit indicator.
class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final VoidCallback onLongPress;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final time = _formatTime(message['createdAt'] ?? '');
    final isRead = message['isRead'] == true;
    final isEdited = message['isEdited'] == true;
    final isDeleted = message['isDeleted'] == true;
    final status = message['status'] ?? 'sent';
    final replyText = message['replyToText'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isDeleted
                      ? cs.surfaceContainerHigh
                      : isMe
                          ? cs.primary
                          : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Reply preview
                    if (replyText.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 4),
                        decoration: BoxDecoration(
                          color: isMe
                              ? Colors.white.withOpacity(0.15)
                              : Colors.black.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(
                            left: BorderSide(
                              color: isMe
                                  ? Colors.white.withOpacity(0.5)
                                  : cs.primary,
                              width: 3,
                            ),
                          ),
                        ),
                        child: Text(
                          replyText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isMe
                                ? Colors.white.withOpacity(0.7)
                                : cs.onSurface.withOpacity(0.6),
                          ),
                        ),
                      ),
                    ],

                    // Message text
                    Text(
                      message['message'] ?? '',
                      style: TextStyle(
                        color: isDeleted
                            ? cs.onSurface.withValues(alpha: 0.5)
                            : isMe
                                ? Colors.white
                                : cs.onSurface,
                        fontSize: 15,
                        fontStyle:
                            isDeleted ? FontStyle.italic : FontStyle.normal,
                      ),
                    ),

                    const SizedBox(height: 3),

                    // Time + edited + ticks
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isEdited && !isDeleted)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Text('edited',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                    color: isMe
                                        ? Colors.white.withOpacity(0.6)
                                        : cs.onSurface
                                            .withValues(alpha: 0.5))),
                          ),
                        Text(
                          time,
                          style: TextStyle(
                            color: isMe
                                ? Colors.white.withOpacity(0.7)
                                : cs.onSurface.withOpacity(0.4),
                            fontSize: 11,
                          ),
                        ),
                        if (isMe && !isDeleted) ...[
                          const SizedBox(width: 3),
                          _TickIcon(
                            status: status,
                            isRead: isRead,
                          ),
                        ],
                      ],
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

  String _formatTime(String iso) {
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

/// WhatsApp-style tick icon: single grey, double grey, double blue.
class _TickIcon extends StatelessWidget {
  final String status;
  final bool isRead;

  const _TickIcon({required this.status, required this.isRead});

  @override
  Widget build(BuildContext context) {
    if (isRead) {
      // Blue double tick
      return const Icon(Icons.done_all, size: 16, color: Colors.lightBlueAccent);
    }
    if (status == 'delivered') {
      // Grey double tick
      return Icon(Icons.done_all, size: 16, color: Colors.white.withOpacity(0.6));
    }
    // Single grey tick (sent)
    return Icon(Icons.done, size: 16, color: Colors.white.withOpacity(0.6));
  }
}
