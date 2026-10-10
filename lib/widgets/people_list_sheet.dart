import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/open_profile.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// The lists behind the counts: who liked, who voted for whom, who shared.
enum PeopleList { likes, votes, shares }

extension on PeopleList {
  String get what => name;

  String title(int n) => switch (this) {
    PeopleList.likes => 'Liked by $n',
    PeopleList.votes => n == 1 ? '1 vote' : '$n votes',
    PeopleList.shares => 'Shared by $n',
  };

  String empty(String username) => switch (this) {
    PeopleList.likes => 'No likes for $username yet.',
    PeopleList.votes => 'No votes for $username yet.',
    PeopleList.shares => 'Nobody has shared $username\'s video yet.',
  };
}

/// Who liked, voted or shared — opened by tapping the number under the
/// button, as on Instagram.
///
/// One tab per video on a battle (the creator's and the answer), opening on
/// [startOnAnswer]'s; a single list on a short. Anyone who can watch the
/// video can open it, as on Instagram, and a tap on somebody — their
/// picture or their name — opens their profile.
Future<void> showPeople(
  BuildContext context,
  String challengeId,
  PeopleList list, {
  bool startOnAnswer = false,
}) {
  return _sheet(
    context,
    FutureBuilder<List<PeopleSide>?>(
      future: ApiService.getPeople(challengeId, list.what),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Loading();
        }
        final sides = snap.data;
        if (sides == null || sides.isEmpty) {
          return const _Note("Couldn't load the list. Try again in a moment.");
        }
        final total = sides.fold(0, (a, s) => a + s.people.length);
        if (sides.length == 1) {
          final only = sides.first;
          return Column(
            children: [
              _Title(list.title(total)),
              const Divider(height: 1, color: Colors.white12),
              Expanded(
                child: _People(
                  people: only.people,
                  empty: list.empty(only.username),
                ),
              ),
            ],
          );
        }
        final answerAt = sides.indexWhere((s) => !s.isCreator);
        return DefaultTabController(
          length: sides.length,
          initialIndex: startOnAnswer && answerAt > 0 ? answerAt : 0,
          child: Column(
            children: [
              _Title(list.title(total)),
              TabBar(
                indicatorColor: Colors.white,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                dividerColor: Colors.white12,
                tabs: [
                  for (final s in sides)
                    Tab(
                      key: ValueKey('people_tab_${s.username}'),
                      text: '${s.username} · ${s.people.length}',
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final s in sides)
                      _People(people: s.people, empty: list.empty(s.username)),
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
          onTap: () => openProfileByName(context, p.username),
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
