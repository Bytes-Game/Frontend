import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_scoreboard.dart' show timeLeft, votesText;

/// One of a profile's battle tabs: Open, Live, Won, Lost or Draw.
///
/// Open is challenges nobody has answered yet. Live is battles being voted
/// on now, with who is ahead. Won, Lost and Draw are decided ones — and a
/// lost one says by how much and to whom, so there is something to work on.
class BattlesTab extends StatefulWidget {
  final String userId;

  /// "open", "live", "won", "lost" or "draw".
  final String tab;
  final bool isOwn;

  /// Opens a battle. Given its challenge id.
  final void Function(String challengeId) onOpen;

  const BattlesTab({
    super.key,
    required this.userId,
    required this.tab,
    required this.onOpen,
    this.isOwn = false,
  });

  @override
  State<BattlesTab> createState() => _BattlesTabState();
}

class _BattlesTabState extends State<BattlesTab>
    with AutomaticKeepAliveClientMixin {
  List<BattleCard>? _cards;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    final page = await ApiService.getUserBattles(
      userId: widget.userId,
      tab: widget.tab,
    );
    if (!mounted) return;
    setState(() {
      _failed = page == null;
      _cards = page?.battles ?? _cards;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cards = _cards;
    if (cards == null) {
      return _failed
          ? _Message(
              icon: Icons.cloud_off,
              title: "Couldn't load these battles",
              action: TextButton(onPressed: _load, child: const Text('Retry')),
            )
          : const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (cards.isEmpty) return _empty();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => BattleCardTile(
          card: cards[i],
          onTap: () => widget.onOpen(cards[i].challengeId),
        ),
      ),
    );
  }

  Widget _empty() {
    final own = widget.isOwn;
    switch (widget.tab) {
      case 'open':
        return _Message(
          icon: Icons.flag_outlined,
          title: 'No open challenges',
          subtitle: own
              ? 'Challenges nobody has accepted yet will wait here.'
              : 'Nothing waiting for an answer right now.',
        );
      case 'live':
        return _Message(
          icon: Icons.bolt_outlined,
          title: 'No live battles',
          subtitle: own
              ? 'When someone accepts a challenge, the battle and its live '
                    'score show up here.'
              : 'Not in a battle right now.',
        );
      case 'won':
        return const _Message(
          icon: Icons.emoji_events_outlined,
          title: 'No wins yet',
        );
      case 'lost':
        return _Message(
          icon: Icons.sentiment_satisfied_alt_outlined,
          title: 'No losses',
          subtitle: own ? 'Nothing to work on here yet.' : null,
        );
      default:
        return const _Message(icon: Icons.balance, title: 'No draws');
    }
  }
}

/// One battle on a profile tab.
class BattleCardTile extends StatelessWidget {
  final BattleCard card;
  final VoidCallback onTap;

  const BattleCardTile({super.key, required this.card, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final look = _look(card);
    return Material(
      color: look.color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: look.color.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              _Thumb(
                url: card.thumbnailUrl,
                icon: look.icon,
                color: look.color,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title.isEmpty ? 'Untitled battle' : card.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tt.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      look.headline,
                      style: tt.bodyMedium?.copyWith(
                        color: look.color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (look.detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        look.detail,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (card.ratingChange != 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: (card.ratingChange > 0 ? Colors.green : Colors.red)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${card.ratingChange > 0 ? '+' : ''}${card.ratingChange}',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: card.ratingChange > 0 ? Colors.green : Colors.red,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How one battle card reads: its colour, icon and two lines.
({Color color, IconData icon, String headline, String detail}) _look(
  BattleCard c,
) {
  final score = '${votesText(c.myVotes)}–${votesText(c.theirVotes)}';
  final vs = c.opponent.isEmpty ? '' : ' @${c.opponent}';
  switch (c.outcome) {
    case 'won':
      return (
        color: Colors.green,
        icon: Icons.emoji_events,
        headline: 'Won $score${vs.isEmpty ? '' : ' vs$vs'}',
        detail: '',
      );
    case 'lost':
      return (
        color: Colors.redAccent,
        icon: Icons.trending_down,
        headline: 'Lost $score${vs.isEmpty ? '' : ' to$vs'}',
        detail: lossLesson(c),
      );
    case 'draw':
      return (
        color: Colors.blueGrey,
        icon: Icons.balance,
        headline: 'Draw $score${vs.isEmpty ? '' : ' with$vs'}',
        detail: '',
      );
  }
  if (c.status == 'open') {
    return (
      color: Colors.amber.shade700,
      icon: Icons.flag,
      headline: 'Waiting for someone to accept',
      detail: 'Voting starts when it is answered',
    );
  }
  final left = c.endsAt == null
      ? ''
      : c.endsAt!.isAfter(DateTime.now())
      ? '${timeLeft(c.endsAt!.difference(DateTime.now()))} left'
      : 'voting closed, being decided';
  return (
    color: c.leading ? Colors.green : Colors.orange,
    icon: Icons.bolt,
    headline:
        '${c.leading ? 'Ahead' : 'Behind'} $score${vs.isEmpty ? '' : ' vs$vs'}',
    detail: left,
  );
}

/// One honest line on what a lost battle came down to, from what the server
/// knows about it.
String lossLesson(BattleCard c) {
  final gap = c.theirVotes - c.myVotes;
  if (c.myVotes == 0 && c.theirVotes == 0) {
    return 'Decided on likes and views: no genuine votes either side.';
  }
  if (c.myVotes == 0) {
    return 'No genuine votes counted for this side. More people watching '
        'it to the end is where it starts.';
  }
  if (gap <= 1) return 'Lost by ${votesText(gap)} vote — that close.';
  return 'Lost by ${votesText(gap)} votes.';
}

class _Thumb extends StatelessWidget {
  final String url;
  final IconData icon;
  final Color color;

  const _Thumb({required this.url, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: color.withValues(alpha: 0.2),
      child: Icon(icon, color: color),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 52,
        height: 72,
        child: url.isEmpty
            ? fallback
            : Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const _Message({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 96),
      children: [
        Icon(icon, size: 44, color: cs.onSurface.withValues(alpha: 0.35)),
        const SizedBox(height: 10),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ],
        if (action != null) Center(child: action),
      ],
    );
  }
}
