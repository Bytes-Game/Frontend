import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/widgets/league_badge.dart';

/// A person's battle record: league, rating, how close the next league is,
/// wins, losses and draws, win rate and current streak.
///
/// Everything here comes from the server's record (the summary on
/// GET /users/{id}/battles). A loss really does cost rating, and a rating left
/// alone at the top drains away, so the numbers move — which is why the
/// rating counts up to its value rather than just appearing.
class BattleRecordPanel extends StatelessWidget {
  final BattleRecord record;

  /// Whose record this is, for the words: "you" on your own profile.
  final bool isOwn;

  const BattleRecordPanel({
    super.key,
    required this.record,
    this.isOwn = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final step = LeagueStep.of(record.rating, decided: record.decided);
    final colors = LeagueBadge.gradientFor(record.league);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.first.withValues(alpha: 0.22),
            colors.last.withValues(alpha: 0.10),
            cs.surface.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(color: colors.first.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LeagueEmblem(league: record.league, size: 64),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.league.toUpperCase(),
                      style: tt.labelLarge?.copyWith(
                        letterSpacing: 2.4,
                        fontWeight: FontWeight.w800,
                        color: colors.first,
                      ),
                    ),
                    // Scales down rather than overflowing on a narrow
                    // screen or with large text turned on.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          CountUp(
                            value: record.rating,
                            style: tt.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('rating', style: tt.labelMedium),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _WinRateRing(record: record),
            ],
          ),
          const SizedBox(height: 14),
          _LeagueProgress(step: step, isOwn: isOwn),
          const SizedBox(height: 14),
          Row(
            children: [
              _Tally(label: 'Wins', value: record.wins, color: Colors.green),
              const SizedBox(width: 10),
              _Tally(
                label: 'Losses',
                value: record.losses,
                color: Colors.redAccent,
              ),
              const SizedBox(width: 10),
              _Tally(label: 'Draws', value: record.draws, color: Colors.grey),
            ],
          ),
          if (record.streak > 1) ...[
            const SizedBox(height: 12),
            _StreakLine(record: record, isOwn: isOwn),
          ],
        ],
      ),
    );
  }
}

/// A league's emblem: a shield in the league's colours with its initial.
class LeagueEmblem extends StatelessWidget {
  final String league;
  final double size;

  const LeagueEmblem({super.key, required this.league, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final colors = LeagueBadge.gradientFor(league);
    final unranked = league.toLowerCase() == 'unranked';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors.last.withValues(alpha: 0.45),
            blurRadius: size * 0.3,
          ),
        ],
      ),
      child: Icon(
        unranked ? Icons.shield_outlined : Icons.shield,
        color: Colors.white,
        size: size * 0.55,
      ),
    );
  }
}

/// A number that counts up to [value] when it first appears.
class CountUp extends StatelessWidget {
  final int value;
  final TextStyle? style;
  final Duration duration;

  const CountUp({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 900),
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text('${v.round()}', style: style),
    );
  }
}

class _LeagueProgress extends StatelessWidget {
  final LeagueStep step;
  final bool isOwn;

  const _LeagueProgress({required this.step, required this.isOwn});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final String caption;
    if (step.league == 'Unranked') {
      caption = isOwn
          ? 'Finish your first battle to earn a league.'
          : 'No battles decided yet.';
    } else if (step.next == null) {
      caption = 'Top league. It has to be defended every week.';
    } else {
      caption = '${step.pointsToNext} points to ${step.next}';
    }
    final nextColors = LeagueBadge.gradientFor(step.next ?? step.league);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: step.progress),
          duration: const Duration(milliseconds: 1100),
          curve: Curves.easeOutCubic,
          builder: (_, v, _) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: v,
              minHeight: 8,
              backgroundColor: cs.onSurface.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(nextColors.first),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          caption,
          style: tt.bodySmall?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _WinRateRing extends StatelessWidget {
  final BattleRecord record;

  const _WinRateRing({required this.record});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return SizedBox(
      width: 64,
      height: 64,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: record.winRate),
        duration: const Duration(milliseconds: 1100),
        curve: Curves.easeOutCubic,
        builder: (_, v, _) => Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: v,
                strokeWidth: 6,
                backgroundColor: cs.onSurface.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation(Colors.green),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  record.decided == 0 ? '–' : '${(v * 100).round()}%',
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text('won', style: tt.labelSmall),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tally extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _Tally({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            CountUp(
              value: value,
              style: tt.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
            Text(label, style: tt.labelMedium),
          ],
        ),
      ),
    );
  }
}

class _StreakLine extends StatelessWidget {
  final BattleRecord record;
  final bool isOwn;

  const _StreakLine({required this.record, required this.isOwn});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final won = record.streakOf == 'won';
    final text = won
        ? '${record.streak} wins in a row'
        : isOwn
        ? '${record.streak} losses in a row — the Lost tab shows by how much'
        : '${record.streak} losses in a row';
    return Row(
      children: [
        Icon(
          won ? Icons.local_fire_department : Icons.trending_down,
          color: won ? Colors.deepOrange : Colors.redAccent,
          size: 20,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
