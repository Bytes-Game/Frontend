import 'dart:async';

import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';

/// The live score of one battle.
///
/// Who is ahead on genuine votes, then likes, views and shares; how long
/// voting has left; how many votes did not count and why; a vote button for
/// each side; and, for the person who posted the challenge, a way to make
/// the battle run longer.
///
/// The numbers are the server's own count (GET /challenges/{id}/standings),
/// the same one that decides the winner when time is up. Nothing here is
/// worked out on the phone.
class BattleScoreboard extends StatefulWidget {
  final String challengeId;

  /// The signed-in person, or null.
  final String? viewerId;

  /// Casts a vote. For the creator's side it is called with the challenge's
  /// own id, as every vote dialog in the app does. Null hides the buttons.
  final Future<void> Function(String responseId)? onVote;

  /// Change this to make the scoreboard load again — after a vote, say.
  final int refreshToken;

  const BattleScoreboard({
    super.key,
    required this.challengeId,
    this.viewerId,
    this.onVote,
    this.refreshToken = 0,
  });

  @override
  State<BattleScoreboard> createState() => _BattleScoreboardState();
}

class _BattleScoreboardState extends State<BattleScoreboard> {
  BattleStandings? _standings;
  bool _loading = true;
  bool _failed = false;
  bool _extending = false;
  Timer? _tick;

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
      if (s != null) _standings = s;
    });
  }

  bool get _viewerIsIn =>
      widget.viewerId != null &&
      (_standings?.sides.any((s) => s.userId == widget.viewerId) ?? false);

  bool get _viewerIsCreator =>
      widget.viewerId != null && _standings?.creator?.userId == widget.viewerId;

  Future<void> _extend() async {
    final s = _standings;
    if (s == null) return;
    final choices = [14, 21, 30].where((d) => d > s.battleDays).toList();
    if (choices.isEmpty) return;
    final days = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Make the battle longer'),
              subtitle: Text('It can be made longer, never shorter.'),
            ),
            for (final d in choices)
              ListTile(
                leading: const Icon(Icons.more_time),
                title: Text('$d days in total'),
                subtitle: Text('${d - s.battleDays} more days'),
                onTap: () => Navigator.pop(ctx, d),
              ),
          ],
        ),
      ),
    );
    if (days == null || !mounted) return;
    setState(() => _extending = true);
    final res = await ApiService.extendBattle(
      challengeId: widget.challengeId,
      days: days,
    );
    if (!mounted) return;
    setState(() => _extending = false);
    if (!res.ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(res.message)));
    }
    _load();
  }

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

    final total = s.sides.fold<double>(0, (a, b) => a + b.votes);
    final canVote =
        widget.onVote != null && !s.over && !s.notStarted && !_viewerIsIn;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.14),
            cs.tertiary.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.scoreboard_outlined, color: cs.primary, size: 22),
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
                share: total > 0 ? side.votes / total : 0,
                decided: s.resolved,
                onVote: canVote
                    ? () => widget.onVote!(
                        side.isCreator ? widget.challengeId : side.responseId,
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
          if (s.removedTotal > 0) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _showRemoved(s),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: cs.secondary),
                  const SizedBox(width: 6),
                  Text(
                    '${s.removedTotal} ${s.removedTotal == 1 ? 'vote' : 'votes'} '
                    "didn't count. Why?",
                    style: tt.bodySmall?.copyWith(
                      color: cs.secondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_viewerIsCreator && !s.over && s.battleDays < 30) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _extending ? null : _extend,
              icon: const Icon(Icons.more_time, size: 18),
              label: const Text('Make it longer'),
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
                'Only genuine votes decide a battle. These were taken off:',
              ),
              const SizedBox(height: 10),
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
  final double share;
  final bool decided;
  final VoidCallback? onVote;

  const _SideRow({
    required this.side,
    required this.share,
    required this.decided,
    this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final accent = side.isCreator ? Colors.orange : Colors.lightBlue;
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
                votesText(side.votes),
                style: tt.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
              const SizedBox(width: 4),
              Text('votes', style: tt.labelSmall),
              if (onVote != null) ...[
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: onVote,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
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
