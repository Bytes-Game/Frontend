import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/chat_share_widgets.dart';
import 'package:myapp/widgets/mentions.dart';
import 'package:myapp/widgets/video_about_row.dart';
import 'package:myapp/widgets/arena_ui.dart' show PersonPhoto;

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
    final result = await ApiService.dislikeChallenge(
      challengeId: widget.challenge.id,
      userId: dp.user!.id,
    );
    // Sync with server — disliking clears the like server-side, so take
    // both counters from the response rather than trusting the optimistic
    // decrement (which would drift if the like was already gone).
    if (result != null && mounted) {
      setState(() {
        _disliked = result['disliked'] == true;
        _likeCount = result['likes'] ?? _likeCount;
        if (_disliked) _liked = false;
      });
    }
  }

  void _onComment() {
    showModalBottomSheet(
      // The sheet draws its own handle; the theme's would be a second.
      showDragHandle: false,
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
    final before = (_voted, _votedFor);
    setState(() {
      _voted = true;
      _votedFor = username;
    });
    final res = await ApiService.voteChallenge(
      challengeId: widget.challenge.id,
      responseId: responseId,
      voterId: dp.user!.id,
    );
    if (!mounted) return;
    // This used to say "Voted for …!" whatever the server answered, so a
    // vote that was never saved looked exactly like one that was.
    if (!res.ok) {
      setState(() {
        _voted = before.$1;
        _votedFor = before.$2;
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.ok ? 'Voted for $username!' : res.message),
        duration: Duration(seconds: res.ok ? 1 : 3),
      ),
    );
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
  // A sheet from the bottom with the two people side by side, rather than a
  // dialog of two orange and blue outlined buttons stacked with "VS" between
  // them. The one you already voted for is marked, so changing your mind is
  // one tap on the other.
  final creator = creatorUsername.isEmpty ? 'Creator' : creatorUsername;
  final opponent = opponentUsername.isEmpty ? 'Opponent' : opponentUsername;
  return showModalBottomSheet<void>(
    context: context,
    // One handle — its own — and no Cancel button: a drag down or a tap
    // outside closes it, as with every sheet.
    showDragHandle: false,
    backgroundColor: const Color(0xFF1C1C1E),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              voted ? 'Change your vote' : 'Who did it better?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              challengeTitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: _VoteSide(
                    key: const ValueKey('vote_creator'),
                    username: creator,
                    picked: voted && votedFor == creatorUsername,
                    onTap: () {
                      Navigator.pop(ctx);
                      // The creator's side is voted for with the challenge
                      // id standing in for a response id.
                      onVote(challengeId, creator);
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'vs',
                    style: TextStyle(
                      color: Color(0xFF8E8E93),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                // Only with a real answer to vote for (defence in depth;
                // the feed only opens this on a battle).
                Expanded(
                  child: opponentResponseId.isEmpty
                      ? const SizedBox()
                      : _VoteSide(
                          key: const ValueKey('vote_opponent'),
                          username: opponent,
                          picked: voted && votedFor == opponentUsername,
                          onTap: () {
                            Navigator.pop(ctx);
                            onVote(opponentResponseId, opponent);
                          },
                        ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    ),
  );
}

/// One person in the vote sheet: their initial, their name, and what a tap
/// does — "Vote", or a tick if they already have your vote.
class _VoteSide extends StatelessWidget {
  final String username;
  final bool picked;
  final VoidCallback onTap;

  const _VoteSide({
    super.key,
    required this.username,
    required this.picked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const blue = Color(0xFF0A84FF);
    return Material(
      color: const Color(0xFF2C2C2E),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: picked ? blue : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: const Color(0xFF3A3A3C),
                child: Text(
                  username[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: picked ? Colors.white12 : blue,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      picked ? Icons.check_rounded : Icons.how_to_vote_rounded,
                      size: 16,
                      color: picked ? const Color(0xFF30D158) : Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        picked ? 'Your vote' : 'Vote',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Comment bottom sheet — loads comments from API, allows adding new ones.
///
/// Public (non-underscore) so the SmartReelsFeed comment button can show the
/// same UI without duplicating 200 lines. If you change the constructor
/// signature, also update the call sites in feed_action_bar.dart's _onComment
/// and smart_reels_feed.dart's _ReelTile right-rail.
class ChallengeCommentSheet extends StatefulWidget {
  final String challengeId;

  /// Shown above the comments — the video's full caption and who posted
  /// it, so tapping a caption cut short on the video opens the whole of it
  /// with the conversation underneath, as in any app people know.
  final Widget? header;

  /// Told how many comments the video has: once they are read, and again
  /// each time one is posted. The number under the video's comment button
  /// listens, so posting a comment moves it — it used to stay where it was.
  final ValueChanged<int>? onCount;

  const ChallengeCommentSheet({
    super.key,
    required this.challengeId,
    this.header,
    this.onCount,
  });

  @override
  State<ChallengeCommentSheet> createState() => _ChallengeCommentSheetState();
}

/// The comments sheet's colours: dark whatever the phone's theme, the way
/// comments sit over a video in every short-video app.
class _Sheet {
  static const bg = Color(0xFF121214);
  static const field = Color(0xFF232326);
  static const line = Color(0xFF2C2C30);
  static const muted = Color(0xFF8E8E93);
  static const accent = Color(0xFF0A84FF);
}

class _ChallengeCommentSheetState extends State<ChallengeCommentSheet> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _comments = [];
  bool _loading = true;
  bool _sending = false;

  /// Whether the list on screen is the server's whole list, so its length
  /// is the real count.
  bool _readOk = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
    _loadComments();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadComments() async {
    final comments = await ApiService.getChallengeComments(widget.challengeId);
    if (!mounted) return;
    setState(() {
      _comments = comments ?? [];
      _readOk = comments != null;
      _loading = false;
    });
    // Only a real answer sets the number: one that could not be read would
    // say "0" about a video people have commented on.
    if (comments != null) widget.onCount?.call(comments.length);
  }

  Future<void> _addComment() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final me = dp.user;
    if (me == null) return;
    _ctrl.clear();
    // Shown at once, and taken back if the server says no — rather than
    // left on screen as if it had been posted.
    final mine = {
      'authorUsername': me.username,
      'text': text,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    setState(() {
      _comments.add(mine);
      _sending = true;
    });
    final saved = await ApiService.addChallengeComment(
      challengeId: widget.challengeId,
      userId: me.id,
      username: me.username,
      text: text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (saved != null) {
      // The list was read, so its length is the count; if it was not, read
      // it now rather than report a number built on a list we never had.
      if (_readOk) {
        widget.onCount?.call(_comments.length);
      } else {
        unawaited(_loadComments());
      }
    }
    if (saved == null) {
      setState(() => _comments.remove(mine));
      _ctrl.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't post your comment. Try again."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  static String timeAgo(String? createdAt) {
    if (createdAt == null || createdAt.isEmpty) return '';
    final created = DateTime.tryParse(createdAt);
    if (created == null) return '';
    final diff = DateTime.now().difference(created);
    if (diff.inSeconds < 60) return 'now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${(diff.inDays / 7).floor()}w';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final me = Provider.of<DataProvider>(context, listen: false).user;
    final count = _comments.length;
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: _Sheet.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          // Full width, so the × sits at the right edge rather than on top
          // of the title the Stack would otherwise shrink to.
          SizedBox(
            height: 44,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Text(
                  _loading
                      ? 'Comments'
                      : count == 1
                          ? '1 comment'
                          : '$count comments',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Positioned(
                  right: 4,
                  child: IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: _Sheet.muted,
                      size: 22,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _Sheet.line),
          Expanded(
            child: CustomScrollView(
              slivers: [
                if (widget.header != null) ...[
                  SliverToBoxAdapter(child: widget.header!),
                  const SliverToBoxAdapter(
                    child: Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: _Sheet.line,
                    ),
                  ),
                ],
                if (_loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: _Sheet.muted,
                        ),
                      ),
                    ),
                  )
                else if (_comments.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'No comments yet',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Start the conversation.',
                            style: TextStyle(color: _Sheet.muted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    sliver: SliverList.builder(
                      itemCount: _comments.length,
                      itemBuilder: (_, i) => _CommentRow(comment: _comments[i]),
                    ),
                  ),
              ],
            ),
          ),
          // People to mention, while an @name is being typed.
          MentionSuggestions(controller: _ctrl, dark: true),
          // Write one: your initial, a rounded dark field, and a send
          // button that only lights up when there is something to send.
          Container(
            padding: EdgeInsets.fromLTRB(
              12,
              8,
              8,
              8 + (bottomInset > 0 ? 0 : MediaQuery.of(context).padding.bottom),
            ),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _Sheet.line)),
            ),
            child: Row(
              children: [
                _CommentAvatar(name: me?.username ?? '?', size: 32),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: _Sheet.field,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    alignment: Alignment.centerLeft,
                    child: TextField(
                      controller: _ctrl,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      cursorColor: _Sheet.accent,
                      decoration: const InputDecoration(
                        hintText: 'Add a comment… @ to mention',
                        hintStyle: TextStyle(color: _Sheet.muted),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _addComment(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Post',
                  onPressed: _ctrl.text.trim().isEmpty ? null : _addComment,
                  icon: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _ctrl.text.trim().isEmpty
                          ? _Sheet.field
                          : _Sheet.accent,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      size: 20,
                      color: _ctrl.text.trim().isEmpty
                          ? _Sheet.muted
                          : Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A round initial for someone in the comments.
class _CommentAvatar extends StatelessWidget {
  final String name;
  final double size;

  const _CommentAvatar({required this.name, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: PersonPhoto(
        name: name,
        size: size,
        fallback: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF2C2C30),
          ),
          alignment: Alignment.center,
          child: Text(
            name.isEmpty ? '?' : name[0].toUpperCase(),
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// One comment: who, how long ago, and what they said.
class _CommentRow extends StatelessWidget {
  final Map<String, dynamic> comment;

  const _CommentRow({required this.comment});

  @override
  Widget build(BuildContext context) {
    final name = comment['authorUsername'] as String? ?? '?';
    final text = comment['text'] as String? ?? '';
    final time =
        _ChallengeCommentSheetState.timeAgo(comment['createdAt'] as String?);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentAvatar(name: name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: name,
                        style: const TextStyle(
                          color: _Sheet.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (time.isNotEmpty)
                        TextSpan(
                          text: '  $time',
                          style: const TextStyle(
                            color: Color(0xFF636366),
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                // @names in colour, and a tap opens their profile.
                MentionText(
                  text,
                  key: const ValueKey('comment_text'),
                  mentionColor: _Sheet.accent,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The top of the comments sheet when it opens from a video's caption: who
/// posted it, the caption in full, and "What's this video about?".
class CommentSheetCaption extends StatelessWidget {
  final String username;
  final String caption;
  final String detail;

  /// The video "What's this video about?" asks about; with no challenge,
  /// it is not offered.
  final String challengeId;

  /// The answer in a battle when that is the video on screen, and whose it
  /// is; empty for the challenger's.
  final String responseId;
  final String responder;

  const CommentSheetCaption({
    super.key,
    required this.username,
    required this.caption,
    this.detail = '',
    this.challengeId = '',
    this.responseId = '',
    this.responder = '',
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CommentAvatar(name: username, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  caption,
                  key: const ValueKey('full_caption'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15.5,
                    height: 1.35,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    detail,
                    style: const TextStyle(color: _Sheet.muted, fontSize: 12.5),
                  ),
                ],
                if (challengeId.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  VideoAboutRow(
                    challengeId: challengeId,
                    responseId: responseId,
                    whose: responseId.isEmpty ? '' : responder,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The share sheet: who to send the video to, as a card in your chat with
/// them, plus Copy link. See ShareSheet (chat_share_widgets.dart).
///
/// Public (non-underscore) so every share button — the reel, the action
/// bar, the battle page — opens the same sheet.
class ChallengeShareSheet extends StatelessWidget {
  final ChallengeModel challenge;

  /// For a battle: the side on screen when Share was tapped — empty for the
  /// challenger's video.
  final String responseId;

  const ChallengeShareSheet({
    super.key,
    required this.challenge,
    this.responseId = '',
  });

  @override
  Widget build(BuildContext context) =>
      ShareSheet(challenge: challenge, responseId: responseId);
}
