import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/call_service.dart';
import 'package:myapp/services/chat_notifications.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// One conversation.
///
///   * Header, on frosted glass that the messages scroll under: their
///     picture (green dot when online), name, and "typing…", "Active now"
///     or when they were last here; audio and video call buttons.
///   * Your messages in the accent blue, theirs on soft grey. A run from one
///     person groups together, corners tightened between them, their
///     picture once at the end of the run.
///   * A message that arrives — or that you send — pops into place from its
///     own side.
///   * Under your newest message: Sent, then Delivered, then Seen, changing
///     the moment it happens on their phone (see chat_live.go on the
///     server). A message that could not be sent says so; tap it to retry.
///   * While they type, a bubble with three bouncing dots.
///   * Scrolled up, a round button takes you back to the newest message and
///     counts what came in meanwhile.
///   * Swipe a message sideways to reply to it. Hold it for everything
///     else: reply, copy, forward, edit (for 15 minutes), delete, unsend.
///   * An empty chat offers a few one-tap openers, sent as real messages.
///   * Tap their name or picture at the top: "Delete chat", for you only.
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
  StreamSubscription? _liveSub;
  WebSocketService? _ws;
  bool _otherOnline = false;
  String _otherLastSeen = '';

  // Edit mode
  String? _editingMsgId;
  // Reply mode
  Map<String, dynamic>? _replyingTo;

  /// They are typing right now. Cleared by their "stopped", by a message
  /// from them, or after a few seconds of nothing in case "stopped" is lost.
  bool _theyType = false;
  Timer? _theyTypeTimer;

  /// When this phone last said "typing", so it says it every few seconds
  /// rather than on every key.
  DateTime? _saidTypingAt;
  Timer? _stoppedTypingTimer;

  /// Messages that arrived or were sent while this page was open: they pop
  /// in. The ones loaded with the page are simply there.
  final Set<String> _fresh = {};

  /// "Delivered" can arrive before the server has told this phone the id
  /// of the message it just sent. Kept until the id is known.
  final Set<String> _deliveredEarly = {};

  /// Scrolled away from the newest message, and how many came in since.
  bool _awayFromBottom = false;
  int _missed = 0;

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
    _scrollCtrl.addListener(_onScroll);
    _msgCtrl.addListener(_onComposerChanged);
    _loadMessages();
    _listenForRealTime();
    _checkOnlineStatus();
    // The chat is open: its notifications on the phone have done their job.
    // ignore: discarded_futures
    ChatNotifications.instance.forget(widget.otherUserId);
  }

  @override
  void dispose() {
    if (_saidTypingAt != null) _sayTyping(false);
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _wsSub?.cancel();
    _liveSub?.cancel();
    _theyTypeTimer?.cancel();
    _stoppedTypingTimer?.cancel();
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
      _scrollToBottom(jump: true);
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
    _ws = ws;
    _wsSub = ws.notificationStream.listen((notif) {
      if (notif.type == 'chat' && notif.senderId == widget.otherUserId) {
        final id = notif.messageId ?? '';
        setState(() {
          _messages.add({
            'id': id,
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
          _fresh.add(id);
          _otherOnline = true;
          _theyType = false;
          if (_awayFromBottom) _missed++;
        });
        if (!_awayFromBottom) _scrollToBottom();
        EventTracker.instance.trackMessagesRead(
          conversationId: _convId,
          messageCount: 1,
        );
        ApiService.markChatRead(widget.otherUserId, _myId);
      }
    });
    // "Seen", "Delivered" and "typing…", as they happen on their phone.
    _liveSub = ws.events.listen(_onLive);
  }

  void _onLive(Map<String, dynamic> ev) {
    if (!mounted) return;
    switch (ev['type']) {
      case 'chat_read':
        if (ev['readerId'] != widget.otherUserId) return;
        setState(() {
          for (final m in _messages) {
            if (m['senderId'] == _myId && m['status'] != 'failed') {
              m['isRead'] = true;
              m['status'] = 'read';
            }
          }
          _otherOnline = true;
        });
      case 'chat_delivered':
        if (ev['receiverId'] != widget.otherUserId) return;
        final ids = {
          for (final id in ev['messageIds'] as List? ?? const []) '$id',
        };
        setState(() {
          for (final m in _messages) {
            if (ids.remove(m['id']) && m['isRead'] != true) {
              m['status'] = 'delivered';
            }
          }
          _deliveredEarly.addAll(ids);
        });
      case 'typing':
        if (ev['from'] != widget.otherUserId) return;
        final typing = ev['typing'] == true;
        _theyTypeTimer?.cancel();
        if (typing) {
          _theyTypeTimer = Timer(const Duration(seconds: 6), () {
            if (mounted) setState(() => _theyType = false);
          });
        }
        setState(() {
          _theyType = typing;
          if (typing) _otherOnline = true;
        });
        if (typing && !_awayFromBottom) _scrollToBottom();
    }
  }

  /// Tells them "typing…" every few seconds while there is something in
  /// the box, and "stopped" once it is empty, sent, or left alone.
  void _onComposerChanged() {
    if (_editingMsgId != null) return;
    final has = _msgCtrl.text.trim().isNotEmpty;
    _stoppedTypingTimer?.cancel();
    if (!has) {
      if (_saidTypingAt != null) _sayTyping(false);
      return;
    }
    final now = DateTime.now();
    final said = _saidTypingAt;
    if (said == null || now.difference(said) > const Duration(seconds: 3)) {
      _sayTyping(true);
    }
    _stoppedTypingTimer = Timer(const Duration(seconds: 5), () {
      if (_saidTypingAt != null) _sayTyping(false);
    });
  }

  void _sayTyping(bool typing) {
    _saidTypingAt = typing ? DateTime.now() : null;
    if (!typing) _stoppedTypingTimer?.cancel();
    _ws?.send({
      'type': 'typing',
      'to': widget.otherUserId,
      'typing': typing,
    });
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    final away = pos.maxScrollExtent - pos.pixels > 240;
    if (away != _awayFromBottom) {
      setState(() {
        _awayFromBottom = away;
        if (!away) _missed = 0;
      });
    }
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

    if (_saidTypingAt != null) _sayTyping(false);
    final dp = Provider.of<DataProvider>(context, listen: false);
    final now = DateTime.now().toUtc().toIso8601String();
    final replyId = _replyingTo?['id'] as String? ?? '';
    final replyText = _replyingTo?['message'] as String? ?? '';
    final tempId = 'temp_${DateTime.now().microsecondsSinceEpoch}';
    final msg = <String, dynamic>{
      'id': tempId,
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
    };
    setState(() {
      _messages.add(msg);
      _fresh.add(tempId);
      _replyingTo = null;
    });
    _scrollToBottom();

    EventTracker.instance.trackMessageSent(
      conversationId: _convId,
      messageLength: text.length,
      hasMedia: false,
    );
    await _deliver(msg);
  }

  /// Sends [msg] to the server and puts the server's id on it, which is
  /// what "Delivered" and "Seen" are matched against. Marks it failed when
  /// the server could not be reached.
  Future<void> _deliver(Map<String, dynamic> msg) async {
    final replyId = msg['replyToId'] as String? ?? '';
    final res = await ApiService.sendChatMessage(
      senderId: _myId,
      receiverId: widget.otherUserId,
      message: msg['message'] as String? ?? '',
      replyToId: replyId.isNotEmpty ? replyId : null,
    );
    if (!mounted) return;
    setState(() {
      if (res == null) {
        msg['status'] = 'failed';
        return;
      }
      final serverId = res['id'];
      if (serverId == null) return;
      final id = '$serverId';
      _fresh.add(id);
      msg['id'] = id;
      if (msg['isRead'] != true) {
        msg['status'] = _deliveredEarly.remove(id) ? 'delivered' : 'sent';
      }
    });
  }

  Future<void> _retry(Map<String, dynamic> msg) async {
    HapticFeedback.selectionClick();
    setState(() => msg['status'] = 'sent');
    await _deliver(msg);
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final end = _scrollCtrl.position.maxScrollExtent;
      if (jump) {
        _scrollCtrl.jumpTo(end);
      } else {
        _scrollCtrl.animateTo(
          end,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  bool _canEdit(Map<String, dynamic> msg) {
    final createdAt = DateTime.tryParse(msg['createdAt'] ?? '');
    if (createdAt == null) return false;
    return DateTime.now().toUtc().difference(createdAt).inMinutes < 15;
  }

  /// Rings them. The call screen comes up over everything (CallHost).
  void _call({required bool video}) {
    final calls = Provider.of<CallService>(context, listen: false);
    if (calls.busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You're already on a call"),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    EventTracker.instance.trackTap(
      target: video ? 'chat_video_call' : 'chat_audio_call',
      pageName: 'chat_conversation_page',
      params: {'conversationId': _convId},
    );
    // ignore: discarded_futures
    calls.start(
      CallPeer(id: widget.otherUserId, username: widget.otherUsername),
      video: video,
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
                      color: quietFill(ctx),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 22, color: cs.onSurface),
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
              child: Text('Forward to',
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: users.length,
                itemBuilder: (_, i) {
                  final u = users[i];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: ArenaAvatar(name: u.username, size: 42),
                    title: Text(u.username,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.send_rounded,
                        size: 20, color: kAccent),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final activity = _activityLabel();
    final top = MediaQuery.of(context).padding.top + kToolbarHeight;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        leading: const BackButton(),
        titleSpacing: 0,
        centerTitle: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: _Frost(
          border: const Border(bottom: BorderSide(width: 0.5)),
          child: const SizedBox.expand(),
        ),
        // Tap the person: what can be done with this chat (delete it).
        title: GestureDetector(
          key: const ValueKey('chat_person'),
          behavior: HitTestBehavior.opaque,
          onTap: () => showChatOptions(
            context,
            userId: widget.otherUserId,
            name: widget.otherUsername,
            // Deleted: nothing left to show here, back to the chat list.
            onDeleted: () => Navigator.of(context).maybePop(),
          ),
          child: Row(
          children: [
            ArenaAvatar(
              name: widget.otherUsername,
              size: 38,
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
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _theyType
                        ? const Text(
                            'typing…',
                            key: ValueKey('typing'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: kAccent,
                            ),
                          )
                        : activity.isEmpty
                            ? const SizedBox.shrink()
                            : Text(
                                activity,
                                key: ValueKey(activity),
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: _otherOnline
                                      ? AppTheme.success
                                      : cs.onSurface.withValues(alpha: 0.5),
                                ),
                              ),
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
        actions: [
          IconBubble(
            icon: Icons.call_rounded,
            tooltip: 'Audio call',
            size: 38,
            onTap: () => _call(video: false),
          ),
          const SizedBox(width: 8),
          IconBubble(
            icon: Icons.videocam_rounded,
            tooltip: 'Video call',
            size: 38,
            onTap: () => _call(video: true),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: DecoratedBox(
        // A faint wash of the accent behind the top of the thread, so the
        // frosted header has something to frost. Both ends solid: fading a
        // see-through blue into solid white mixes a strong blue half way.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.45],
            colors: [
              Color.alphaBlend(
                kAccent.withValues(alpha: dark ? 0.09 : 0.05),
                Theme.of(context).scaffoldBackgroundColor,
              ),
              Theme.of(context).scaffoldBackgroundColor,
            ],
          ),
        ),
        child: Column(
          children: [
            // Messages
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? Padding(
                          padding: EdgeInsets.only(top: top),
                          child: _EmptyThread(
                            name: widget.otherUsername,
                            onPick: _sendMessage,
                          ),
                        )
                      : Stack(
                          children: [
                            ListView.builder(
                              controller: _scrollCtrl,
                              padding: EdgeInsets.fromLTRB(12, top + 8, 12, 8),
                              itemCount: _messages.length + 1,
                              itemBuilder: (_, i) {
                                if (i == _messages.length) {
                                  return _TypingBubble(
                                    visible: _theyType,
                                    name: widget.otherUsername,
                                  );
                                }
                                return _messageAt(i);
                              },
                            ),
                            Positioned(
                              right: 14,
                              bottom: 10,
                              child: _JumpToLatest(
                                visible: _awayFromBottom,
                                count: _missed,
                                onTap: () {
                                  setState(() => _missed = 0);
                                  _scrollToBottom();
                                },
                              ),
                            ),
                          ],
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

            _composer(cs),
          ],
        ),
      ),
    );
  }

  Widget _messageAt(int i) {
    final msg = _messages[i];
    final isMe = msg['senderId'] == _myId;
    final showHeader = _needsTimeHeader(i == 0 ? null : _messages[i - 1], msg);
    // Grouping: consecutive bubbles from one sender (with no time caption
    // splitting them) tighten their facing corners.
    final prevSame =
        i > 0 && !showHeader && _messages[i - 1]['senderId'] == msg['senderId'];
    final nextSame = i < _messages.length - 1 &&
        _messages[i + 1]['senderId'] == msg['senderId'] &&
        !_needsTimeHeader(msg, _messages[i + 1]);
    final isNewest = i == _messages.length - 1;
    final failed = msg['status'] == 'failed';
    final bubble = _MessageBubble(
      message: msg,
      isMe: isMe,
      otherUsername: widget.otherUsername,
      groupedWithPrev: prevSame,
      groupedWithNext: nextSame,
      // The seen sign lives under your last message only while it's the
      // newest thing in the thread. A failed one always says so.
      showStatus: isMe && (isNewest || failed),
      onLongPress: () => _showMessageActions(msg),
      onReply: () => setState(() => _replyingTo = msg),
      onRetry: failed ? () => _retry(msg) : null,
    );
    return Column(
      key: ValueKey('msg_${identityHashCode(msg)}'),
      children: [
        if (showHeader) _TimeHeader(date: msg['createdAt'] ?? ''),
        _fresh.contains(msg['id'])
            ? _PopIn(fromRight: isMe, child: bubble)
            : bubble,
      ],
    );
  }

  /// The composer, on frosted glass: the text box, and a send button that
  /// lights up the moment there is something to send.
  ///
  /// There used to be a photo button and a microphone here that only said
  /// "coming soon". Photo and voice messages are not built, so nothing on
  /// screen offers them.
  Widget _composer(ColorScheme cs) {
    return _Frost(
      border: const Border(top: BorderSide(width: 0.5)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const SizedBox(width: 4),
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(AppTheme.radiusXxl),
                    border:
                        Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
                  ),
                  child: TextField(
                    controller: _msgCtrl,
                    minLines: 1,
                    maxLines: 5,
                    cursorColor: AppTheme.primary,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Message…',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isCollapsed: true,
                      // Zero, explicitly. The app's theme gives every text box 20
                      // pixels of padding at the side and 16 above and below, and a
                      // collapsed field still takes it — which pushed the words
                      // right and off-centre inside this slim bar.
                      contentPadding: EdgeInsets.zero,
                    ),
                    style: const TextStyle(fontSize: 15),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Send lights up the moment there is something to send (it is
              // Save while editing); until then it is dimmed and does
              // nothing.
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _msgCtrl,
                builder: (_, value, _) {
                  final ready =
                      value.text.trim().isNotEmpty || _editingMsgId != null;
                  return AnimatedOpacity(
                    duration: const Duration(milliseconds: 160),
                    opacity: ready ? 1 : 0.35,
                    child: AnimatedScale(
                      duration: const Duration(milliseconds: 160),
                      scale: ready ? 1 : 0.9,
                      child: IconBubble(
                        key: const ValueKey('send'),
                        icon: _editingMsgId != null
                            ? Icons.check_rounded
                            : Icons.arrow_upward_rounded,
                        tooltip: _editingMsgId != null ? 'Save' : 'Send',
                        filled: true,
                        size: 44,
                        onTap: ready ? _sendMessage : null,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted glass: whatever scrolls behind shows through, blurred.
/// "Delete chat with [name]?", and if so, asks the server to delete it —
/// the whole chat, for the person asking only. [name] keeps theirs, and a
/// new message starts the chat again with just that message.
///
/// True once it is deleted. False when they changed their mind, or the
/// server said no (and then they are told, so it never fails silently).
Future<bool> deleteChatWith(
  BuildContext context, {
  required String userId,
  required String name,
}) async {
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete chat with $name?'),
      content: Text(
        'This deletes the whole chat for you. $name will still have it.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('delete_chat_confirm'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.error),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (sure != true) return false;
  final ok = await ApiService.clearChat(userId);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Couldn't delete the chat. Try again."),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return ok;
}

/// What can be done with a chat: for now, delete it. Shown when you hold a
/// chat in the list, or tap the person at the top of the chat. Calls
/// [onDeleted] once the server has deleted it.
void showChatOptions(
  BuildContext context, {
  required String userId,
  required String name,
  required VoidCallback onDeleted,
}) {
  HapticFeedback.mediumImpact();
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('delete_chat'),
            leading:
                const Icon(Icons.delete_outline_rounded, color: AppTheme.error),
            title: const Text('Delete chat',
                style: TextStyle(color: AppTheme.error)),
            subtitle: const Text('Only for you'),
            onTap: () async {
              Navigator.of(ctx).pop();
              if (await deleteChatWith(context, userId: userId, name: name) &&
                  context.mounted) {
                onDeleted();
              }
            },
          ),
        ],
      ),
    ),
  );
}

class _Frost extends StatelessWidget {
  final Widget child;
  final Border border;
  const _Frost({required this.child, required this.border});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg.withValues(alpha: 0.78),
            border: Border(
              top: border.top == BorderSide.none
                  ? BorderSide.none
                  : BorderSide(
                      color: cs.onSurface.withValues(alpha: 0.08),
                      width: 0.5,
                    ),
              bottom: border.bottom == BorderSide.none
                  ? BorderSide.none
                  : BorderSide(
                      color: cs.onSurface.withValues(alpha: 0.08),
                      width: 0.5,
                    ),
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A message arriving: it springs out of its own side of the screen,
/// tipped back in 3D, and settles flat.
class _PopIn extends StatefulWidget {
  final bool fromRight;
  final Widget child;
  const _PopIn({required this.fromRight, required this.child});

  @override
  State<_PopIn> createState() => _PopInState();
}

class _PopInState extends State<_PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) {
        final t = Curves.easeOutBack.transform(_c.value);
        final f = Curves.easeOut.transform(_c.value);
        return Opacity(
          opacity: f,
          child: Transform(
            alignment: widget.fromRight
                ? Alignment.bottomRight
                : Alignment.bottomLeft,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015)
              ..multiply(Matrix4.translationValues(0, (1 - f) * 18, 0))
              ..multiply(Matrix4.rotationX((1 - f) * 0.5))
              ..multiply(Matrix4.diagonal3Values(
                  0.6 + 0.4 * t, 0.6 + 0.4 * t, 1)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Their "typing…" bubble: three dots rising and falling in turn.
class _TypingBubble extends StatefulWidget {
  final bool visible;
  final String name;
  const _TypingBubble({required this.visible, required this.name});

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.visible) _dots.repeat();
  }

  @override
  void didUpdateWidget(_TypingBubble old) {
    super.didUpdateWidget(old);
    if (widget.visible && !_dots.isAnimating) _dots.repeat();
    if (!widget.visible && _dots.isAnimating) _dots.stop();
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final cs = Theme.of(context).colorScheme;
    final incoming = dark ? const Color(0xFF26252A) : const Color(0xFFE9E9EB);
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.bottomLeft,
      child: !widget.visible
          ? const SizedBox(width: double.infinity)
          : Padding(
              key: const ValueKey('typing_bubble'),
              padding: const EdgeInsets.only(top: 6, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ArenaAvatar(name: widget.name, size: 26),
                  const SizedBox(width: 8),
                  _PopIn(
                    fromRight: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      decoration: BoxDecoration(
                        color: incoming,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: AnimatedBuilder(
                        animation: _dots,
                        builder: (_, _) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var k = 0; k < 3; k++) ...[
                              if (k > 0) const SizedBox(width: 4),
                              _dot(cs, (_dots.value - k * 0.18) % 1),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _dot(ColorScheme cs, double v) {
    final lift = math.sin(v * math.pi * 2).clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, -4 * lift),
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: cs.onSurface.withValues(alpha: 0.35 + 0.35 * lift),
        ),
      ),
    );
  }
}

/// Back to the newest message, with how many came in while scrolled up.
class _JumpToLatest extends StatelessWidget {
  final bool visible;
  final int count;
  final VoidCallback onTap;
  const _JumpToLatest({
    required this.visible,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedScale(
        scale: visible ? 1 : 0.4,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Tooltip(
            message: 'Newest messages',
            child: Pressable(
              onTap: onTap,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.surface,
                      border: Border.all(
                          color: cs.onSurface.withValues(alpha: 0.08)),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 14,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Icon(Icons.keyboard_arrow_down_rounded,
                        color: cs.onSurface),
                  ),
                  if (count > 0)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: kAccent,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusFull),
                        ),
                        child: Text(
                          count > 99 ? '99+' : '$count',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What an empty chat shows: their picture on a glass card that swings up
/// into place in 3D — drag across it and it leans after the finger — and a
/// few openers that send as real messages with one tap.
class _EmptyThread extends StatefulWidget {
  final String name;
  final ValueChanged<String> onPick;

  const _EmptyThread({required this.name, required this.onPick});

  static const openers = [
    '👋 Hey!',
    '⚔️ Up for a battle?',
    '🔥 Loved your video',
  ];

  @override
  State<_EmptyThread> createState() => _EmptyThreadState();
}

class _EmptyThreadState extends State<_EmptyThread>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = widget.name;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _enter,
              builder: (_, child) {
                final t = Curves.easeOutBack.transform(_enter.value);
                final f = Curves.easeOut.transform(_enter.value);
                return Opacity(
                  opacity: f,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0012)
                      ..multiply(Matrix4.translationValues(0, (1 - t) * 40, 0))
                      ..multiply(Matrix4.rotationX((1 - t) * 0.9)),
                    child: child,
                  ),
                );
              },
              child: SizedBox(
                width: 240,
                child: TiltCard(
                  radius: 28,
                  child: Container(
                    width: 240,
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                          color: cs.onSurface.withValues(alpha: 0.06)),
                    ),
                    child: Column(
                      children: [
                        ArenaAvatar(name: name, size: 88),
                        const SizedBox(height: 14),
                        Text(
                          name,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Say hello to $name',
                          style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.55)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 26),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in _EmptyThread.openers)
                  Pressable(
                    onTap: () => widget.onPick(o),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusFull),
                        color: quietFill(context),
                      ),
                      child: Text(
                        o,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
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
              color: kAccent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Icon(icon, size: 18, color: kAccent),
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

/// One message: the accent blue for yours, a soft surface for theirs,
/// corners tightened on the side facing a grouped neighbour, their picture
/// once at the end of their run, a quoted reply and "Edited" above, and
/// Seen / Delivered / Sent below when [showStatus] — or, when it could not
/// be sent, "Not sent · Tap to retry".
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
  final VoidCallback? onRetry;

  const _MessageBubble({
    required this.message,
    required this.isMe,
    required this.otherUsername,
    required this.groupedWithPrev,
    required this.groupedWithNext,
    required this.showStatus,
    required this.onLongPress,
    required this.onReply,
    this.onRetry,
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

    // Apple's Messages greys for the other person's bubbles.
    final incoming = dark ? const Color(0xFF26252A) : const Color(0xFFE9E9EB);

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
              color: isMe ? kAccent : incoming,
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
            color: _armed ? kAccent : quietFill(context),
          ),
          child: Icon(
            Icons.reply_rounded,
            size: 18,
            color: _armed ? Colors.white : cs.onSurface,
          ),
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

          // The seen sign under your newest message. It changes the moment
          // it changes on their phone, so the change is animated.
          if (widget.showStatus && !isDeleted)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                transitionBuilder: (c, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.4),
                      end: Offset.zero,
                    ).animate(a),
                    child: c,
                  ),
                ),
                child: _status(cs),
              ),
            ),
        ],
      ),
    );
  }

  Widget _status(ColorScheme cs) {
    final message = widget.message;
    if (message['status'] == 'failed') {
      return GestureDetector(
        key: const ValueKey('failed'),
        onTap: widget.onRetry,
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_rounded, size: 14, color: AppTheme.error),
            SizedBox(width: 3),
            Text(
              'Not sent · Tap to retry',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.error,
              ),
            ),
          ],
        ),
      );
    }
    final label = _statusLabel();
    return Row(
      key: ValueKey(label),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _statusIcon(),
          size: 14,
          color: message['isRead'] == true
              ? kAccent
              : cs.onSurface.withValues(alpha: 0.45),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: cs.onSurface.withValues(alpha: 0.45)),
        ),
      ],
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
