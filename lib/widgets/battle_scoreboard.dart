import 'dart:async';

import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';

/// The live score of one battle.
///
/// Each player's votes, likes, views and shares — the same numbers every
/// other screen shows — how long voting has left, and a vote button for each
/// side. When some votes don't count (people who never watched, throwaway
/// accounts), it says so, with the score that decides the winner.
///
/// The numbers are the server's own (GET /challenges/{id}/standings).
/// Nothing here is worked out on the phone, apart from showing a vote the
/// moment it is tapped.
class BattleScoreboard extends StatefulWidget {
  final String challengeId;

  /// The signed-in person, or null.
  final String? viewerId;

  /// Casts a vote — or moves it — and says how it went. For the creator's
  /// side it is called with the challenge's own id, as every vote dialog in
  /// the app does. Null hides the buttons.
  ///
  /// The scoreboard does not wait for it: the vote shows the moment it is
  /// tapped, and is taken back only if the server turns it down.
  final Future<ActionResult> Function(String responseId)? onVote;

  /// Change this to make the scoreboard load again — after a vote, say.
  final int refreshToken;

  /// Each fresh count, as it arrives — so the page around it can show the
  /// same totals, votes included, rather than a count of its own.
  final void Function(BattleStandings standings)? onStandings;

  const BattleScoreboard({
    super.key,
    required this.challengeId,
    this.viewerId,
    this.onVote,
    this.refreshToken = 0,
    this.onStandings,
  });

  @override
  State<BattleScoreboard> createState() => _BattleScoreboardState();
}

class _BattleScoreboardState extends State<BattleScoreboard> {
  BattleStandings? _standings;
  bool _loading = true;
  bool _failed = false;
  Timer? _tick;

  /// The side this person voted for: "creator", an answer's id, or empty.
  /// Set the moment they tap, before the server has answered.
  String _yourVote = '';

  /// Votes shown on top of the server's count while it catches up: +1 on
  /// the side just voted for, -1 on the side the vote moved from. Cleared
  /// when a fresh count comes in, which has the vote in it.
  Map<String, int> _pending = const {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
    // The countdown moves on its own; the score only when asked.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(BattleScoreboard old) {
    super.didUpdateWidget(old);
    if (old.refreshToken != widget.refreshToken ||
        old.challengeId != widget.challengeId) {
      _load();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await ApiService.getBattleStandings(widget.challengeId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = s == null;
      if (s != null) {
        _standings = s;
        if (s.yourVote.isNotEmpty) _yourVote = s.yourVote;
        if (!_sending) _pending = const {};
      }
    });
    if (s != null) widget.onStandings?.call(s);
  }

  /// The page's totals follow what this shows, the vote on screen included.
  void _tellPage() {
    final s = _standings;
    if (s != null) widget.onStandings?.call(s.withVotesMoved(_pending));
  }

  static String _sideKey(BattleSide side) =>
      side.isCreator ? 'creator' : side.responseId;

  void _say(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
  }

  /// A tap on Vote. It shows at once — the button turns into "Your vote"
  /// and the count goes up by one, and down by one on the side the vote
  /// came from — and the server is told after. Waiting for the server
  /// first, then reloading the whole page, is what made voting feel like
  /// it did nothing.
  ///
  /// One vote each, and it can be moved: voting for the other side moves
  /// it there.
  Future<void> _cast(BattleSide side) async {
    if (_sending) return;
    final key = _sideKey(side);
    if (key == _yourVote) return;
    final before = _yourVote;
    setState(() {
      _yourVote = key;
      _pending = {key: 1, if (before.isNotEmpty) before: -1};
      _sending = true;
    });
    _tellPage();
    final res = await widget.onVote!(
      side.isCreator ? widget.challengeId : side.responseId,
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (!res.ok) {
        // Taken back, so they can try again.
        _pending = const {};
        _yourVote = before;
      }
    });
    if (!res.ok) {
      _tellPage();
      _say(res.message);
      return;
    }
    // The server's own count, quietly, once it has the vote.
    _load();
  }

  bool get _viewerIsIn =>
      widget.viewerId != null &&
      (_standings?.sides.any((s) => s.userId == widget.viewerId) ?? false);


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = _standings;

    if (s == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _loading
            ? const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Row(
                children: [
                  Icon(Icons.cloud_off, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  const Expanded(child: Text("Couldn't load the score.")),
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
      );
    }

    double shown(BattleSide side) =>
        side.votes + (_pending[_sideKey(side)] ?? 0);
    final total = s.sides.fold<double>(0, (a, b) => a + shown(b));
    final canVote =
        widget.onVote != null && !s.over && !s.notStarted && !_viewerIsIn;

    // A plain raised panel, the same as every other box on the battle page,
    // rather than a tinted gradient.
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF1C1C1E),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.emoji_events_rounded,
                color: Color(0xFFFFD60A),
                size: 22,
              ),
              const SizedBox(width: 8),
              Text('Live score', style: tt.titleMedium),
              const Spacer(),
              _clock(s, cs, tt),
            ],
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Showing the last score; the latest did not load.',
                style: tt.bodySmall?.copyWith(color: cs.error),
              ),
            ),
          const SizedBox(height: 12),
          if (s.notStarted)
            Text(
              'Voting starts when someone accepts, and runs for '
              '${s.battleDays} days.',
              style: tt.bodyMedium,
            )
          else
            for (final side in s.sides)
              _SideRow(
                side: side,
                votes: shown(side),
                share: total > 0 ? shown(side) / total : 0,
                decided: s.resolved,
                yours: _yourVote == _sideKey(side),
                // One vote each; voting for the other side moves it.
                onVote: canVote ? () => _cast(side) : null,
                onYours: canVote
                    ? () => _say(
                        'This is your vote. To change it, tap Vote on the '
                        'other side.',
                      )
                    : null,
              ),
          if (s.resolved) ...[
            const SizedBox(height: 4),
            Text(_verdict(s), style: tt.titleSmall),
          ] else if (s.over) ...[
            const SizedBox(height: 4),
            Text(
              'Voting has closed. The result is being worked out.',
              style: tt.bodySmall,
            ),
          ],
          // The numbers above are every vote cast. When some don't count
          // toward the winner, say so, with the score that does.
          if (s.countedDiffers) ...[
            const SizedBox(height: 8),
            InkWell(
              key: const ValueKey('counted_score'),
              onTap: () => _showRemoved(s),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: cs.secondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Counting genuine votes only: '
                      '${s.sides.map((x) => '${x.username} ${votesText(x.countedVotes)}').join(' – ')}. '
                      'Why?',
                      style: tt.bodySmall?.copyWith(
                        color: cs.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _clock(BattleStandings s, ColorScheme cs, TextTheme tt) {
    final String text;
    if (s.resolved) {
      text = 'Decided';
    } else if (s.notStarted) {
      text = '${s.battleDays} days';
    } else if (s.over) {
      text = 'Closed';
    } else {
      text = '${timeLeft(s.endsAt!.difference(DateTime.now()))} left';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  String _verdict(BattleStandings s) {
    final top = s.sides.where((x) => x.rank == 1).toList();
    if (top.isEmpty || !top.first.leading) return 'No result: nobody voted.';
    if (top.length > 1) return "It's a draw.";
    return '${top.first.username} won.';
  }

  void _showRemoved(BattleStandings s) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Votes that did not count',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'Every vote shows in the count, but only genuine votes '
                'decide who wins. These did not count:',
              ),
              const SizedBox(height: 10),
              if (s.removed.isEmpty)
                const Text(
                  'Votes from very new accounts count as half until the '
                  'account has been around for a while.',
                ),
              for (final e in s.removed.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Text(
                        '${e.value}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(e.key)),
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

/// "3d 4h", "5h 12m", "12m", "under a minute".
String timeLeft(Duration d) {
  if (d.inMinutes < 1) return 'under a minute';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

/// A vote count as people read it: "4", "4.5".
String votesText(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

class _SideRow extends StatelessWidget {
  final BattleSide side;

  /// The count to show: the server's, plus this person's vote while the
  /// server catches up.
  final double votes;
  final double share;
  final bool decided;

  /// This person's vote is on this side.
  final bool yours;
  final VoidCallback? onVote;

  /// A tap on "Your vote": says there is one vote each.
  final VoidCallback? onYours;

  const _SideRow({
    required this.side,
    required this.votes,
    required this.share,
    required this.decided,
    required this.yours,
    this.onVote,
    this.onYours,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    // The app's blue for the challenger, Apple's cyan for the answer: two
    // sides you can tell apart without the orange that clashed with the
    // rest of the app.
    final accent =
        side.isCreator ? const Color(0xFF0A84FF) : const Color(0xFF64D2FF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: accent.withValues(alpha: 0.25),
                child: Text(
                  side.username.isEmpty ? '?' : side.username[0].toUpperCase(),
                  style: TextStyle(color: accent, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            side.username,
                            overflow: TextOverflow.ellipsis,
                            style: tt.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (side.leading) ...[
                          const SizedBox(width: 4),
                          Icon(
                            decided ? Icons.emoji_events : Icons.trending_up,
                            size: 16,
                            color: Colors.amber,
                          ),
                        ],
                      ],
                    ),
                    Text(
                      side.isCreator ? 'Challenger' : 'Answer',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                votesText(votes),
                style: tt.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
              const SizedBox(width: 4),
              Text('votes', style: tt.labelSmall),
              if (yours) ...[
                const SizedBox(width: 8),
                _YourVote(onTap: onYours),
              ] else if (onVote != null) ...[
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: onVote,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0A84FF),
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: const Text('Vote'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(accent),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _stat(Icons.favorite, side.likes, cs),
              _stat(Icons.visibility, side.views, cs),
              _stat(Icons.share, side.shares, cs),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, int n, ColorScheme cs) => Padding(
    padding: const EdgeInsets.only(right: 14),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: cs.onSurface.withValues(alpha: 0.55)),
        const SizedBox(width: 3),
        Text(
          '$n',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    ),
  );
}

/// Where the Vote button was, once this person has voted for that side: a
/// green tick and "Your vote". Tapping it says there is one vote each.
class _YourVote extends StatelessWidget {
  final VoidCallback? onTap;

  const _YourVote({this.onTap});

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF30D158);
    return Material(
      key: const ValueKey('your_vote'),
      color: green.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_rounded, size: 16, color: green),
              SizedBox(width: 4),
              Text(
                'Your vote',
                style: TextStyle(
                  color: green,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
