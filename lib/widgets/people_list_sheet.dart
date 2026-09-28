import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/battle_record_panel.dart' show LeagueEmblem;

/// "Who voted" for the two players in a battle: one tab per side, the
/// people who voted for that side, newest first.
///
/// Nobody is told when a vote comes in — that would be a ping for every
/// vote on a live battle. This is where the players look instead.
Future<void> showVoters(BuildContext context, String challengeId) {
  return _sheet(
    context,
    FutureBuilder<List<VoterSide>?>(
      future: ApiService.getVoters(challengeId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Loading();
        }
        final sides = snap.data;
        if (sides == null) {
          return const _Note("Couldn't load the votes. Try again in a moment.");
        }
        return DefaultTabController(
          length: sides.length,
          child: Column(
            children: [
              const _Title('Who voted'),
              TabBar(
                indicatorColor: Colors.white,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                dividerColor: Colors.white12,
                tabs: [
                  for (final s in sides)
                    Tab(
                      key: ValueKey('voters_tab_${s.username}'),
                      text: '${s.username} · ${s.voters.length}',
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final s in sides)
                      _People(
                        people: s.voters,
                        empty: 'No votes for ${s.username} yet.',
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// "Who liked" a video, for whoever posted it.
Future<void> showLikers(BuildContext context, String challengeId) {
  return _sheet(
    context,
    FutureBuilder<List<PersonAt>?>(
      future: ApiService.getLikers(challengeId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Loading();
        }
        final people = snap.data;
        if (people == null) {
          return const _Note("Couldn't load the likes. Try again in a moment.");
        }
        return Column(
          children: [
            _Title('Liked by ${people.length}'),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: _People(people: people, empty: 'No likes yet.'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> _sheet(BuildContext context, Widget child) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: const Color(0xFF161618),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => SizedBox(
      height: MediaQuery.of(ctx).size.height * 0.7,
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
          Expanded(child: child),
        ],
      ),
    ),
  );
}

class _Title extends StatelessWidget {
  final String text;

  const _Title(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _People extends StatelessWidget {
  final List<PersonAt> people;
  final String empty;

  const _People({required this.people, required this.empty});

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return _Note(empty);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: people.length,
      itemBuilder: (_, i) {
        final p = people[i];
        return ListTile(
          key: ValueKey('person_${p.userId}'),
          leading: ArenaAvatar(name: p.username, size: 40),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  p.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (p.league.isNotEmpty) ...[
                const SizedBox(width: 6),
                LeagueEmblem(league: p.league, size: 14),
              ],
            ],
          ),
          trailing: p.at == null
              ? null
              : Text(
                  _ago(p.at!),
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
        );
      },
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Center(
    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
  );
}

class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white60),
      ),
    ),
  );
}
