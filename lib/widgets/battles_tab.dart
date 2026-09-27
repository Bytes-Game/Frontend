import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_scoreboard.dart' show votesText;
import 'package:myapp/widgets/video_grid_tile.dart';

/// One of a profile's battle tabs: Open, Live, Won, Lost or Draw.
///
/// Drawn as videos, the same grid as Search, each with one coloured line
/// saying where it stands: "Open", "Ahead 5–2" (with "2d left" beside the
/// views), "Won 5–2 · +16", "Lost 2–5 · −16". These tabs used to be lists of written notes about each
/// battle, the only grid in the app you could not watch.
class BattlesTab extends StatefulWidget {
  final String userId;

  /// Whose profile, for a battle the server sent without its video.
  final String ownerName;

  /// "open", "live", "won", "lost" or "draw".
  final String tab;
  final bool isOwn;

  /// Plays this tab's videos from [index], and only them.
  final void Function(List<ChallengeModel> videos, int index)? onPlay;

  /// Opens the battle page, for a battle that came without its video.
  final void Function(String challengeId) onOpen;

  const BattlesTab({
    super.key,
    required this.userId,
    required this.tab,
    required this.onOpen,
    this.onPlay,
    this.ownerName = '',
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
    // The ones that can be played, in the tab's order: a swipe goes to the
    // next battle on this tab.
    final playable = [
      for (final c in cards)
        if (c.video != null) c.video!,
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: PreloadVideoStarts(
        videos: playable,
        child: GridView.builder(
          padding: videoGridPadding,
          gridDelegate: videoGridDelegate,
          itemCount: cards.length,
          itemBuilder: (_, i) {
            final card = cards[i];
            final video = card.video;
            return VideoGridTile(
              key: ValueKey('battle_tile_${card.challengeId}'),
              video: video ?? _stand(card),
              badge: battleBadge(card),
              trailing: battleTimeLeft(card),
              onTap: () {
                final play = widget.onPlay;
                if (video != null && play != null) {
                  play(playable, playable.indexOf(video));
                } else {
                  widget.onOpen(card.challengeId);
                }
              },
            );
          },
        ),
      ),
    );
  }

  /// A battle the server sent without its video: enough to draw the tile.
  ChallengeModel _stand(BattleCard c) => ChallengeModel(
    id: c.challengeId,
    creatorId: '',
    creatorUsername: c.role == 'creator' ? widget.ownerName : c.opponent,
    creatorLeague: '',
    videoUrl: c.videoUrl,
    thumbnailUrl: c.thumbnailUrl,
    prefix: c.title,
    subject: '',
    visibility: 'arena',
    status: c.status,
    likes: 0,
    views: 0,
    createdAt: '',
    responseCount: c.status == 'open' ? 0 : 1,
  );

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

/// Where one battle stands, as the coloured line on its tile.
TileBadge battleBadge(BattleCard c) {
  final score = '${votesText(c.myVotes)}–${votesText(c.theirVotes)}';
  final rating = c.ratingChange == 0
      ? ''
      : ' · ${c.ratingChange > 0 ? '+' : '−'}${c.ratingChange.abs()}';
  switch (c.outcome) {
    case 'won':
      return TileBadge(
        'Won $score$rating',
        Icons.emoji_events_rounded,
        const Color(0xFF1E9E55),
      );
    case 'lost':
      return TileBadge(
        'Lost $score$rating',
        Icons.trending_down_rounded,
        const Color(0xFFD64545),
      );
    case 'draw':
      return TileBadge(
        'Draw $score',
        Icons.balance_rounded,
        const Color(0xFF5F6B7A),
      );
  }
  if (c.status == 'open') {
    return const TileBadge('Open', Icons.flag_rounded, Color(0xFFB7791F));
  }
  final ends = c.endsAt;
  if (ends != null && !ends.isAfter(DateTime.now())) {
    return TileBadge(
      'Deciding $score',
      Icons.hourglass_bottom_rounded,
      const Color(0xFF5F6B7A),
    );
  }
  return TileBadge(
    '${c.leading ? 'Ahead' : 'Behind'} $score',
    Icons.bolt_rounded,
    c.leading ? const Color(0xFF1E9E55) : const Color(0xFFD9822B),
  );
}

/// How long a live battle has left, short enough for a tile: "2d left",
/// "5h left", "40m left". Null for anything not being voted on now.
String? battleTimeLeft(BattleCard c) {
  final ends = c.endsAt;
  if (c.outcome.isNotEmpty || c.status == 'open' || ends == null) return null;
  final d = ends.difference(DateTime.now());
  if (d.isNegative) return null;
  if (d.inDays >= 1) return '${d.inDays}d left';
  if (d.inHours >= 1) return '${d.inHours}h left';
  return '${d.inMinutes < 1 ? 1 : d.inMinutes}m left';
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
