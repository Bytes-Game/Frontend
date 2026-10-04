import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

/// Sharing a battle or a short into a chat, and how it looks there.
///
/// A shared video used to go into the chat as plain text — a title and the
/// raw address of the video file — so the other person saw a link. Now it
/// is a message of its own kind ("share"): the server keeps which video it
/// is and sends the video back with the message, and the chat draws it as a
/// tall video card, the way Instagram shows a shared reel. One tap plays
/// it.

/// The video a "share" message points at, or null when it is unavailable
/// (deleted, or friends-only and not for this person).
ChallengeModel? sharedVideoOf(Map<String, dynamic> message) {
  final shared = message['shared'];
  if (shared is! Map) return null;
  final ch = shared['challenge'];
  if (ch is! Map) return null;
  return ChallengeModel.fromJson(Map<String, dynamic>.from(ch));
}

bool _isBattle(ChallengeModel c) =>
    c.topResponseVideoUrl.isNotEmpty || c.topResponseUsername.isNotEmpty;

/// A shared battle or short in a chat: the video's picture, who made it,
/// what it is, and a play button. A battle shows both sides, face to face.
/// Any note sent with it sits underneath, as a bubble of its own.
class SharedVideoCard extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;

  /// The bubble colour for the note under the card.
  final Color bubbleColor;

  const SharedVideoCard({
    super.key,
    required this.message,
    required this.isMe,
    required this.bubbleColor,
  });

  @override
  Widget build(BuildContext context) {
    final video = sharedVideoOf(message);
    final note = '${message['message'] ?? ''}'.trim();
    final screen = MediaQuery.of(context).size.width;
    final width = (screen * 0.6).clamp(160.0, 230.0);
    return Column(
      crossAxisAlignment: isMe
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (video == null)
          _Unavailable(width: width)
        else
          _VideoCard(video: video, width: width),
        if (note.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            constraints: BoxConstraints(maxWidth: screen * 0.72),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              note,
              style: TextStyle(
                color: isMe
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface,
                fontSize: 15,
                height: 1.3,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _VideoCard extends StatelessWidget {
  final ChallengeModel video;
  final double width;

  const _VideoCard({required this.video, required this.width});

  @override
  Widget build(BuildContext context) {
    final battle = _isBattle(video);
    final height = width * 1.6;
    final who = battle
        ? '@${video.creatorUsername} vs @${video.topResponseUsername}'
        : '@${video.creatorUsername}';
    return Semantics(
      button: true,
      label:
          '${battle ? 'Battle' : 'Short'}: ${video.title}, by $who. '
          'Tap to watch.',
      child: GestureDetector(
        key: const ValueKey('shared_video_card'),
        onTap: () => openVideoPlaylist(context, [video], 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (battle)
                  Row(
                    children: [
                      Expanded(child: _Poster(url: video.thumbnailUrl)),
                      const SizedBox(width: 2),
                      Expanded(
                        child: _Poster(url: video.topResponseThumbnailUrl),
                      ),
                    ],
                  )
                else
                  _Poster(url: video.thumbnailUrl),
                // Shade top and bottom so the words read on any picture.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0x99000000),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0xCC000000),
                      ],
                      stops: [0, 0.25, 0.55, 1],
                    ),
                  ),
                ),
                if (battle)
                  const Center(child: _VsBadge())
                else
                  const Center(child: _PlayBadge()),
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Row(
                    children: [
                      ArenaAvatar(name: video.creatorUsername, size: 22),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          who,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(color: Color(0x99000000), blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        video.title.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _KindChip(battle: battle),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  final String? url;
  const _Poster({required this.url});

  @override
  Widget build(BuildContext context) {
    const fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2C2C2E), Color(0xFF111113)],
        ),
      ),
    );
    final u = url ?? '';
    if (u.isEmpty) return fallback;
    return Image.network(
      u,
      fit: BoxFit.cover,
      cacheWidth: 400,
      errorBuilder: (_, _, _) => fallback,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : fallback,
    );
  }
}

class _PlayBadge extends StatelessWidget {
  const _PlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 1.5,
        ),
      ),
      child: const Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: 32,
      ),
    );
  }
}

class _VsBadge extends StatelessWidget {
  const _VsBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: AppTheme.gradientPrimary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 10)],
      ),
      child: const Text(
        'VS',
        style: TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  final bool battle;
  const _KindChip({required this.battle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            battle ? Icons.bolt_rounded : Icons.play_circle_fill_rounded,
            color: Colors.white,
            size: 13,
          ),
          const SizedBox(width: 4),
          Text(
            battle ? 'Battle' : 'Short',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  final double width;
  const _Unavailable({required this.width});

  @override
  Widget build(BuildContext context) {
    final muted = quietText(context);
    return Container(
      key: const ValueKey('shared_video_unavailable'),
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: quietFill(context),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_off_rounded, color: muted, size: 28),
          const SizedBox(height: 8),
          Text(
            'Video unavailable',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            "It was deleted, or it isn't shared with you.",
            textAlign: TextAlign.center,
            style: TextStyle(color: muted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

// ── Sharing ────────────────────────────────────────────────────────────

/// The share sheet: the video at the top, the people you talk to most
/// first, tap as many as you like, add a note, Send. Each gets the video
/// as a card in your chat with them — never a link.
class ShareSheet extends StatefulWidget {
  final ChallengeModel challenge;

  /// For a battle: the side being shared — empty for the challenger's.
  final String responseId;

  const ShareSheet({super.key, required this.challenge, this.responseId = ''});

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  final _search = TextEditingController();
  final _note = TextEditingController();
  final Set<String> _picked = {};
  List<UserModel> _people = const [];
  List<String> _recent = const [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final dp = Provider.of<DataProvider>(context, listen: false);
    final me = dp.user?.id ?? '';
    _people = dp.allUsers.where((u) => u.id.isNotEmpty && u.id != me).toList();
    if (me.isNotEmpty) {
      // The chats the app already has put your people in order at once;
      // the fresh list re-orders them if anything changed.
      final kept = ChatCache.instance.chatsFor(me);
      if (kept != null) _useRecent(me, kept);
      _loadRecent(me);
    }
  }

  /// The people you have chatted with, newest first, go to the front.
  Future<void> _loadRecent(String me) async {
    final convs = await ChatCache.instance.load(me);
    if (!mounted || convs == null) return;
    setState(() => _useRecent(me, convs));
  }

  void _useRecent(String me, List<Map<String, dynamic>> convs) {
    _recent = [for (final c in convs) '${c['userId'] ?? ''}'];
    // Someone you chat with who is not in the app's list yet.
    final known = {for (final u in _people) u.id};
    for (final c in convs) {
      final id = '${c['userId'] ?? ''}';
      if (id.isEmpty || id == me || known.contains(id)) continue;
      _people = [
        ..._people,
        UserModel(
          id: id,
          username: '${c['username'] ?? ''}',
          league: '${c['league'] ?? ''}',
          wins: 0,
          losses: 0,
          followersCount: 0,
          followingCount: 0,
        ),
      ];
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    super.dispose();
  }

  List<UserModel> get _shown {
    final q = _search.text.trim().toLowerCase();
    final list = _people.where((u) {
      if (q.isEmpty) return true;
      return u.username.toLowerCase().contains(q) ||
          u.fullName.toLowerCase().contains(q);
    }).toList();
    int rank(UserModel u) {
      final i = _recent.indexOf(u.id);
      return i < 0 ? _recent.length : i;
    }

    list.sort((a, b) => rank(a).compareTo(rank(b)));
    return list;
  }

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id));
  }

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final me = dp.user?.id ?? '';
    if (me.isEmpty) return;
    setState(() => _sending = true);
    final to = _people.where((u) => _picked.contains(u.id)).toList();
    final results = await Future.wait([
      for (final u in to)
        ApiService.sendChatMessage(
          senderId: me,
          receiverId: u.id,
          message: _note.text.trim(),
          kind: 'share',
          challengeId: widget.challenge.id,
          responseId: widget.responseId,
        ),
    ]);
    if (!mounted) return;
    final failed = [
      for (var i = 0; i < to.length; i++)
        if (results[i] == null) to[i],
    ];
    final sent = to.length - failed.length;
    setState(() {
      _sending = false;
      // Who it went to is done; anyone it failed for stays picked, to try
      // again.
      _picked
        ..clear()
        ..addAll(failed.map((u) => u.id));
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (failed.isEmpty) {
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            sent == 1
                ? 'Sent to @${to.first.username}'
                : 'Sent to $sent people',
          ),
        ),
      );
      return;
    }
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          failed.length == 1
              ? "Couldn't send to @${failed.first.username}. Try again."
              : "Couldn't send to ${failed.length} people. Try again.",
        ),
      ),
    );
  }

  void _copyLink() {
    final c = widget.challenge;
    Clipboard.setData(
      ClipboardData(text: '${c.title} by @${c.creatorUsername}\n${c.videoUrl}'),
    );
    Navigator.of(context).pop();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Link copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? AppTheme.surfaceDark : AppTheme.surfaceLight;
    final muted = quietText(context);
    final c = widget.challenge;
    final battle = _isBattle(c);
    final shown = _shown;
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Material(
        key: const ValueKey('share_sheet'),
        color: surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXxl),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.78 - keyboard * 0.5,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              // What is being shared.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 44,
                        height: 64,
                        child: _Poster(url: c.thumbnailUrl),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.title.trim(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${battle ? 'Battle' : 'Short'} · @${c.creatorUsername}',
                            style: TextStyle(color: muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded, color: muted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ArenaSearchField(
                  controller: _search,
                  hint: 'Search people',
                  onChanged: (_) => setState(() {}),
                  onCleared: () => setState(() {}),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            _people.isEmpty
                                ? 'Follow people to share videos with them.'
                                : 'Nobody by that name.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: muted, fontSize: 14),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              mainAxisSpacing: 6,
                              childAspectRatio: 0.78,
                            ),
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final u = shown[i];
                          return _PersonTile(
                            key: ValueKey('share_person_${u.id}'),
                            user: u,
                            picked: _picked.contains(u.id),
                            onTap: () => _toggle(u.id),
                          );
                        },
                      ),
              ),
              _bottom(context, muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottom(BuildContext context, Color muted) {
    final divider = Divider(height: 1, color: muted.withValues(alpha: 0.18));
    if (_picked.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          divider,
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  _Action(
                    key: const ValueKey('share_copy_link'),
                    icon: Icons.link_rounded,
                    label: 'Copy link',
                    onTap: _copyLink,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final many = _picked.length > 1;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        divider,
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('share_note'),
                  controller: _note,
                  maxLength: 500,
                  minLines: 1,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: 'Write a message…',
                    counterText: '',
                    filled: true,
                    fillColor: quietFill(context),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    key: const ValueKey('share_send'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      ),
                    ),
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            many
                                ? 'Send separately (${_picked.length})'
                                : 'Send',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  final UserModel user;
  final bool picked;
  final VoidCallback onTap;

  const _PersonTile({
    super.key,
    required this.user,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: picked,
      label: '@${user.username}',
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: picked ? AppTheme.primary : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: ArenaAvatar(name: user.username, size: 56),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: AnimatedScale(
                    scale: picked ? 1 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? AppTheme.surfaceDark
                              : Colors.white,
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              user.username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: picked ? FontWeight.w600 : FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _Action({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: quietFill(context),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: Theme.of(context).colorScheme.onSurface,
                size: 24,
              ),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
