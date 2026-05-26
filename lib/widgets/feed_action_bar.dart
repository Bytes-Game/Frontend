import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

/// TikTok-style vertical action bar for the right side of the feed.
/// Shows like, dislike, comment, share for shorts.
/// Shows vote, like, comment, share for battles.
class FeedActionBar extends StatefulWidget {
  final ChallengeModel challenge;
  final List<ChallengeResponseModel> responses;
  final int battleSide; // 0=creator, 1=opponent

  const FeedActionBar({
    super.key,
    required this.challenge,
    required this.responses,
    this.battleSide = 0,
  });

  @override
  State<FeedActionBar> createState() => _FeedActionBarState();
}

class _FeedActionBarState extends State<FeedActionBar> {
  bool _liked = false;
  bool _disliked = false;
  int _likeCount = 0;
  bool _voted = false;
  String _votedFor = '';
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.challenge.likes;
  }

  @override
  void didUpdateWidget(FeedActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.challenge.id != widget.challenge.id) {
      _liked = false;
      _disliked = false;
      _likeCount = widget.challenge.likes;
      _voted = false;
      _votedFor = '';
      _saved = false;
    }
  }

  void _onLike() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    // Optimistic toggle
    setState(() {
      if (_liked) {
        _liked = false;
        _likeCount--;
      } else {
        _liked = true;
        _likeCount++;
        _disliked = false;
      }
    });
    final result = await ApiService.likeChallenge(
      challengeId: widget.challenge.id,
      userId: dp.user!.id,
    );
    // Sync with server
    if (result != null && mounted) {
      setState(() {
        _liked = result['liked'] == true;
        _likeCount = result['likes'] ?? _likeCount;
      });
    }
  }

  void _onDislike() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    setState(() {
      if (_disliked) {
        _disliked = false;
      } else {
        _disliked = true;
        if (_liked) {
          _liked = false;
          _likeCount--;
        }
      }
    });
    await ApiService.dislikeChallenge(
      challengeId: widget.challenge.id,
      userId: dp.user!.id,
    );
  }

  void _onComment() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeCommentSheet(challengeId: widget.challenge.id),
    );
  }

  void _onShare() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeShareSheet(challenge: widget.challenge),
    );
  }

  void _onSave() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    setState(() => _saved = !_saved);
    final result = await ApiService.toggleSaveChallenge(
      userId: dp.user!.id,
      challengeId: widget.challenge.id,
    );
    if (result != null && mounted) {
      setState(() {
        _saved = result['saved'] == true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_saved ? 'Saved to collection' : 'Removed from saved'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _onVote(String responseId, String username) async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    setState(() {
      _voted = true;
      _votedFor = username;
    });
    await ApiService.voteChallenge(
      challengeId: widget.challenge.id,
      responseId: responseId,
      voterId: dp.user!.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Voted for $username!'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasBattle = widget.responses.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Vote button (battles only)
        if (hasBattle) ...[
          _VoteButton(
            challenge: widget.challenge,
            responses: widget.responses,
            voted: _voted,
            votedFor: _votedFor,
            onVote: _onVote,
          ),
          const SizedBox(height: 20),
        ],

        // Like
        _ActionButton(
          icon: _liked ? Icons.favorite : Icons.favorite_border,
          label: _formatCount(_likeCount),
          color: _liked ? Colors.red : Colors.white,
          onTap: _onLike,
        ),
        const SizedBox(height: 20),

        // Dislike
        _ActionButton(
          icon: _disliked ? Icons.thumb_down : Icons.thumb_down_outlined,
          label: '',
          color: _disliked ? Colors.orange : Colors.white,
          onTap: _onDislike,
        ),
        const SizedBox(height: 20),

        // Comment
        _ActionButton(
          icon: Icons.chat_bubble_outline,
          label: '',
          color: Colors.white,
          onTap: _onComment,
        ),
        const SizedBox(height: 20),

        // Share
        _ActionButton(
          icon: Icons.share_outlined,
          label: '',
          color: Colors.white,
          onTap: _onShare,
        ),
        const SizedBox(height: 20),

        // Save / Bookmark
        _ActionButton(
          icon: _saved ? Icons.bookmark : Icons.bookmark_border,
          label: _saved ? 'Saved' : '',
          color: _saved ? Colors.amber : Colors.white,
          onTap: _onSave,
        ),
      ],
    );
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    if (n == 0) return '';
    return '$n';
  }
}

/// Single action button with icon + label.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 28),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Vote button for battles — shows trophy icon, opens vote dialog.
/// Allows changing vote by tapping again.
class _VoteButton extends StatelessWidget {
  final ChallengeModel challenge;
  final List<ChallengeResponseModel> responses;
  final bool voted;
  final String votedFor;
  final void Function(String responseId, String username) onVote;

  const _VoteButton({
    required this.challenge,
    required this.responses,
    required this.voted,
    required this.votedFor,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showVoteDialog(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: voted ? Colors.green : Colors.orange,
              shape: BoxShape.circle,
            ),
            child: Icon(
              voted ? Icons.how_to_vote : Icons.emoji_events,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            voted ? votedFor : 'Vote',
            style: TextStyle(
              color: voted ? Colors.green.shade300 : Colors.orange.shade300,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  void _showVoteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(voted ? 'Change Your Vote' : 'Cast Your Vote'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              challenge.title,
              style: const TextStyle(fontSize: 14),
              textAlign: TextAlign.center,
            ),
            if (voted) ...[
              const SizedBox(height: 8),
              Text(
                'Currently voted for: $votedFor',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Creator vote button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onVote(challenge.id, challenge.creatorUsername);
                },
                icon: const Icon(Icons.person),
                label: Text(challenge.creatorUsername),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('VS',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 8),
            // Opponent vote button
            if (responses.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    onVote(responses.first.id, responses.first.responderUsername);
                  },
                  icon: const Icon(Icons.person),
                  label: Text(responses.first.responderUsername),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// Public helper that pops the same vote dialog used by [_VoteButton],
/// but parameterized so callers don't need a full
/// [ChallengeResponseModel] list — only the (responseId, opponentUsername)
/// pair the home reels already carries on its enriched feed payload.
///
/// Exists so the SmartReelsFeed can show the dialog without instantiating
/// FeedActionBar (which expects a fully-fetched challenge + response set
/// the lightweight feed entries don't have). Calls [onVote] with the
/// chosen response ID and the username string the caller wants surfaced
/// in the post-vote toast.
///
/// Behavior matches the inline _showVoteDialog above: tap creator → vote
/// for the challenge.id (the creator's "side"), tap opponent → vote for
/// the response id; cancel dismisses without firing onVote.
Future<void> showChallengeVoteDialog({
  required BuildContext context,
  required String challengeTitle,
  required String challengeId,
  required String creatorUsername,
  required String opponentResponseId,
  required String opponentUsername,
  required bool voted,
  required String votedFor,
  required void Function(String responseId, String username) onVote,
}) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(voted ? 'Change Your Vote' : 'Cast Your Vote'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            challengeTitle,
            style: const TextStyle(fontSize: 14),
            textAlign: TextAlign.center,
          ),
          if (voted) ...[
            const SizedBox(height: 8),
            Text(
              'Currently voted for: $votedFor',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Creator side
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                // Match the inline behavior above: creator vote uses the
                // challenge id as the "response id" placeholder.
                onVote(challengeId, creatorUsername);
              },
              icon: const Icon(Icons.person),
              label: Text(creatorUsername.isEmpty ? 'Creator' : creatorUsername),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text('VS',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(height: 8),
          // Opponent side — only render when we have a real responseId
          // (defense in depth; the smart-reels caller only opens this
          // dialog when isBattle == true, which already gates on a
          // populated opponent).
          if (opponentResponseId.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  onVote(opponentResponseId,
                      opponentUsername.isEmpty ? 'Opponent' : opponentUsername);
                },
                icon: const Icon(Icons.person),
                label: Text(
                    opponentUsername.isEmpty ? 'Opponent' : opponentUsername),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

/// Comment bottom sheet — loads comments from API, allows adding new ones.
///
/// Public (non-underscore) so the SmartReelsFeed comment button can show the
/// same UI without duplicating 200 lines. If you change the constructor
/// signature, also update the call sites in feed_action_bar.dart's _onComment
/// and smart_reels_feed.dart's _ReelTile right-rail.
class ChallengeCommentSheet extends StatefulWidget {
  final String challengeId;
  const ChallengeCommentSheet({super.key, required this.challengeId});

  @override
  State<ChallengeCommentSheet> createState() => _ChallengeCommentSheetState();
}

class _ChallengeCommentSheetState extends State<ChallengeCommentSheet> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _comments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadComments();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    final comments = await ApiService.getChallengeComments(widget.challengeId);
    if (mounted) {
      setState(() {
        _comments = comments;
        _loading = false;
      });
    }
  }

  void _addComment() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    _ctrl.clear();

    // Optimistic add
    setState(() {
      _comments.add({
        'authorUsername': dp.user?.username ?? 'You',
        'text': text,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
    });

    // Send to API
    await ApiService.addChallengeComment(
      challengeId: widget.challengeId,
      userId: dp.user!.id,
      username: dp.user!.username,
      text: text,
    );
  }

  String _timeAgo(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '';
    final created = DateTime.tryParse(createdAt);
    if (created == null) return '';
    final diff = DateTime.now().difference(created);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('Comments',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const Divider(),

          // Comments list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _comments.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline,
                                size: 48,
                                color: cs.onSurface.withValues(alpha: 0.4)),
                            const SizedBox(height: 12),
                            Text('No comments yet',
                                style: TextStyle(
                                    color: cs.onSurface
                                        .withValues(alpha: 0.6))),
                            const SizedBox(height: 4),
                            Text('Be the first to comment!',
                                style: TextStyle(
                                    color: cs.onSurface
                                        .withValues(alpha: 0.5),
                                    fontSize: 12)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _comments.length,
                        itemBuilder: (_, i) {
                          final c = _comments[i];
                          final username =
                              c['authorUsername'] as String? ?? '?';
                          final text = c['text'] as String? ?? '';
                          final time = _timeAgo(c['createdAt'] as String?);
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  child: Text(username[0].toUpperCase(),
                                      style: const TextStyle(fontSize: 13)),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(username,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13)),
                                          if (time.isNotEmpty) ...[
                                            const SizedBox(width: 8),
                                            Text(time,
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: cs.onSurface
                                                        .withValues(
                                                            alpha: 0.5))),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(text,
                                          style:
                                              const TextStyle(fontSize: 14)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),

          // Input field
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: cs.outline.withValues(alpha: 0.3), width: 0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    decoration: const InputDecoration(
                      hintText: 'Add a comment...',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _addComment(),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.send, color: cs.primary),
                  onPressed: _addComment,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Share bottom sheet — in-app chat sharing + copy link.
///
/// Public (non-underscore) so the SmartReelsFeed share button can present
/// the same sheet without copy-pasting 100 lines of UI. Same rationale as
/// [ChallengeCommentSheet] above.
class ChallengeShareSheet extends StatelessWidget {
  final ChallengeModel challenge;
  const ChallengeShareSheet({super.key, required this.challenge});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final users = dp.allUsers
        .where((u) => u.id != (dp.user?.id ?? ''))
        .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.55,
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Text('Share',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const Divider(),

          // Copy link
          ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.link, size: 22),
            ),
            title: const Text('Copy Link'),
            subtitle: const Text('Share on any platform',
                style: TextStyle(fontSize: 12)),
            onTap: () {
              final shareText =
                  '${challenge.title} by ${challenge.creatorUsername}\n${challenge.videoUrl}';
              Clipboard.setData(ClipboardData(text: shareText));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Link copied to clipboard!'),
                    duration: Duration(seconds: 2)),
              );
            },
          ),
          const Divider(),

          // Send to users
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Send to',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: cs.onSurface.withValues(alpha: 0.6))),
            ),
          ),
          Expanded(
            child: users.isEmpty
                ? Center(
                    child: Text('No users to share with',
                        style: TextStyle(
                            color: cs.onSurface.withValues(alpha: 0.5))),
                  )
                : ListView.builder(
                    itemCount: users.length,
                    itemBuilder: (_, i) {
                      return _ShareUserTile(
                        user: users[i],
                        challenge: challenge,
                        senderId: dp.user!.id,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Individual user tile in the share sheet with send button.
class _ShareUserTile extends StatefulWidget {
  final UserModel user;
  final ChallengeModel challenge;
  final String senderId;

  const _ShareUserTile({
    required this.user,
    required this.challenge,
    required this.senderId,
  });

  @override
  State<_ShareUserTile> createState() => _ShareUserTileState();
}

class _ShareUserTileState extends State<_ShareUserTile> {
  bool _sent = false;
  bool _sending = false;

  void _send() async {
    if (_sent || _sending) return;
    setState(() => _sending = true);

    final msg =
        '🔥 ${widget.challenge.title} by ${widget.challenge.creatorUsername}\n${widget.challenge.videoUrl}';
    await ApiService.sendChatMessage(
      senderId: widget.senderId,
      receiverId: widget.user.id,
      message: msg,
    );

    if (mounted) {
      setState(() {
        _sent = true;
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        child: Text(widget.user.username[0].toUpperCase()),
      ),
      title: Text(widget.user.username),
      subtitle: Text(widget.user.league,
          style: TextStyle(
              fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
      trailing: SizedBox(
        width: 70,
        child: _sent
            ? const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 20),
                  SizedBox(width: 4),
                  Text('Sent', style: TextStyle(color: Colors.green, fontSize: 13)),
                ],
              )
            : TextButton(
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Send'),
              ),
      ),
    );
  }
}
