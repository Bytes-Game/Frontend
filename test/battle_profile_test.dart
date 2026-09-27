// The profile built around battles, and the 3D card in Search.
//
// Every test looks for something that IS on screen, so a page broken into
// showing nothing cannot pass by having nothing to find.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/battle_record_panel.dart';
import 'package:myapp/widgets/battles_tab.dart';
import 'package:myapp/widgets/profile_card_3d.dart';
import 'package:myapp/widgets/scroll_reveal.dart';

UserModel user(String id, String name) => UserModel(
  id: id,
  username: name,
  wins: 3,
  losses: 1,
  followersCount: 12,
  followingCount: 4,
  league: 'Silver',
  rating: 1080,
);

final summary = {
  'rating': 1080,
  'league': 'Silver',
  'wins': 3,
  'losses': 1,
  'draws': 0,
  'streak': 2,
  'streakOf': 'won',
  'counts': {'open': 1, 'live': 2, 'won': 3, 'lost': 1, 'draw': 0},
};

Map<String, dynamic> card(String outcome) => {
  'challengeId': '70',
  'title': 'who dances better',
  'role': 'creator',
  'status': outcome.isEmpty ? 'active' : 'completed',
  'outcome': outcome,
  'myVotes': outcome == 'lost' ? 2 : 5,
  'theirVotes': outcome == 'lost' ? 5 : 2,
  'opponent': 'leo',
  'ratingChange': outcome == 'lost' ? -16 : 16,
  'createdAt': '2026-09-01T10:00:00Z',
  'endsAt': '2099-01-01T10:00:00Z',
  'leading': outcome.isEmpty,
};

late List<String> asked;

/// Whether the battles come with their videos, as the server now sends.
late bool withVideos;

Map<String, dynamic> video(String id) => {
  'id': id,
  'creatorId': '5',
  'creatorUsername': 'maya',
  'creatorLeague': 'Silver',
  'videoUrl': 'https://x/$id.mp4',
  'prefix': 'who dances',
  'subject': 'better',
  'status': 'completed',
  'visibility': 'arena',
  'likes': 3,
  'views': 40,
  'responseCount': 1,
  'topResponseId': '9$id',
  'topResponseVideoUrl': 'https://x/r$id.mp4',
  'createdAt': '2026-09-01T10:00:00Z',
};

void fakeServer() {
  asked = [];
  withVideos = false;
  ApiService.useClient(
    MockClient((req) async {
      asked.add('${req.url.path}?${req.url.query}');
      final p = req.url.path;
      if (p.endsWith('/battles')) {
        final tab = req.url.queryParameters['tab'] ?? '';
        return http.Response(
          json.encode({
            'summary': summary,
            'tab': tab,
            'battles': [
              if (tab == 'lost') card('lost'),
              if (tab == 'won' && !withVideos) card('won'),
              if (tab == 'won' && withVideos)
                for (final id in ['70', '71'])
                  {...card('won'), 'challengeId': id, 'video': video(id)},
              if (tab == 'live') card(''),
            ],
          }),
          200,
        );
      }
      if (p.endsWith('/challenges')) return http.Response('[]', 200);
      return http.Response('{}', 200);
    }),
  );
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  group('the league ladder', () {
    test('matches the server\'s thresholds', () {
      expect(LeagueStep.of(1000, decided: 0).league, 'Unranked');
      expect(LeagueStep.of(1000, decided: 1).league, 'Bronze');
      final silver = LeagueStep.of(1080, decided: 4);
      expect(silver.league, 'Silver');
      expect(silver.next, 'Gold');
      expect(silver.pointsToNext, 70);
      expect(silver.progress, closeTo(0.3, 0.001));
      final top = LeagueStep.of(1600, decided: 9);
      expect(top.league, 'Diamond');
      expect(top.next, isNull);
      expect(top.progress, 1);
    });
  });

  group('the record panel', () {
    testWidgets('shows the league, rating, record and streak', (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BattleRecordPanel(
              record: BattleRecord.fromJson(summary),
              isOwn: true,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('SILVER'), findsOneWidget);
      expect(
        find.text('1080'),
        findsOneWidget,
        reason: 'the rating counts up to its value',
      );
      expect(find.text('70 points to Gold'), findsOneWidget);
      expect(find.text('Wins'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('2 wins in a row'), findsOneWidget);
    });

    testWidgets('before any battle is decided, says how to earn a league', (
      t,
    ) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BattleRecordPanel(record: BattleRecord(), isOwn: true),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('UNRANKED'), findsOneWidget);
      expect(
        find.text('Finish your first battle to earn a league.'),
        findsOneWidget,
      );
    });
  });

  group('battle tabs', () {
    testWidgets('a lost battle is a video tile with the score, and one sent '
        'without its video still opens the battle page', (t) async {
      final opened = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BattlesTab(userId: '5', tab: 'lost', onOpen: opened.add),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(asked.single, contains('/api/v1/users/5/battles?tab=lost'));
      expect(find.byKey(const ValueKey('battle_tile_70')), findsOneWidget);
      expect(find.text('Lost 2–5 · −16'), findsOneWidget);
      expect(find.text('who dances better'), findsOneWidget);
      await t.tap(find.text('who dances better'));
      expect(opened, ['70']);
    });

    testWidgets('a battle with its video plays this tab\'s videos, from the '
        'one tapped', (t) async {
      withVideos = true;
      final played = <(List<String>, int)>[];
      final opened = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BattlesTab(
              userId: '5',
              tab: 'won',
              onOpen: opened.add,
              onPlay: (videos, i) =>
                  played.add(([for (final v in videos) v.id], i)),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Won 5–2 · +16'), findsNWidgets(2));
      expect(find.text('VS'), findsNWidgets(2), reason: 'both are battles');
      await t.tap(find.byKey(const ValueKey('battle_tile_71')));
      expect(opened, isEmpty, reason: 'it plays, not the battle page');
      expect(played.single.$1, ['70', '71']);
      expect(played.single.$2, 1);
    });

    testWidgets('a live battle says who is ahead and how long is left', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BattlesTab(userId: '5', tab: 'live', onOpen: (_) {}),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Ahead 5–2'), findsOneWidget);
      expect(find.textContaining('d left'), findsOneWidget);
    });

    test('the line on each tile', () {
      BattleCard c({
        String outcome = '',
        String status = 'active',
        bool leading = false,
        DateTime? endsAt,
        int rating = 0,
      }) => BattleCard(
        challengeId: '1',
        title: 't',
        outcome: outcome,
        status: status,
        myVotes: 4.5,
        theirVotes: 3,
        leading: leading,
        endsAt: endsAt,
        ratingChange: rating,
      );
      expect(battleBadge(c(status: 'open')).label, 'Open');
      expect(battleBadge(c(outcome: 'lost', rating: -12)).label,
          'Lost 4.5–3 · −12');
      expect(battleBadge(c(outcome: 'draw')).label, 'Draw 4.5–3');
      expect(
        battleBadge(
          c(endsAt: DateTime.now().subtract(const Duration(minutes: 1))),
        ).label,
        'Deciding 4.5–3',
      );
      final live = c(
        leading: true,
        endsAt: DateTime.now().add(const Duration(hours: 5, minutes: 1)),
      );
      expect(battleBadge(live).label, 'Ahead 4.5–3');
      expect(battleTimeLeft(live), '5h left');
      expect(
        battleTimeLeft(
          c(endsAt: DateTime.now().add(const Duration(days: 2, hours: 3))),
        ),
        '2d left',
      );
      expect(battleTimeLeft(c(outcome: 'won')), isNull);
      expect(battleTimeLeft(c(status: 'open')), isNull);
    });
  });

  group('the 3D card', () {
    testWidgets('front: who they are and their record; back: the breakdown', (
      t,
    ) async {
      var opened = false;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileCard3D(
              user: user('5', 'maya'),
              onOpenProfile: () => opened = true,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(asked.single, contains('/api/v1/users/5/battles'));
      expect(find.text('@maya'), findsOneWidget);
      expect(find.text('SILVER'), findsOneWidget);
      expect(find.text('1080'), findsOneWidget);
      expect(find.text('View profile'), findsOneWidget);

      // Dragging tilts it; letting go springs it back. Neither may throw.
      await t.drag(find.text('@maya'), const Offset(60, -40));
      await t.pumpAndSettle();

      await t.tap(find.text('View profile'));
      expect(opened, isTrue);

      await t.tap(find.text('@maya'));
      await t.pumpAndSettle();
      expect(find.text("@maya's battles"), findsOneWidget);
      expect(find.text('Live battles'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
    });

    test('holding on a person in Search opens it', () {
      final code = File('lib/pages/search_page.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code, contains('onLongPress: () => _peekProfile(user, position)'));
      expect(code, contains('showProfileCard3D('));
    });
  });

  group('scroll-driven motion', () {
    test('an entrance runs from the bottom edge to a third of the way up', () {
      expect(
        ScrollReveal.progressFor(topOnScreen: 800, viewportHeight: 800),
        0,
      );
      expect(
        ScrollReveal.progressFor(topOnScreen: 400, viewportHeight: 800),
        1,
      );
      expect(
        ScrollReveal.progressFor(topOnScreen: 664, viewportHeight: 800),
        closeTo(0.5, 0.01),
      );
    });

    testWidgets('a section low on the screen arrives as it is scrolled up', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        MaterialApp(
          home: ListView(
            children: const [
              SizedBox(height: 760),
              ScrollReveal(
                child: SizedBox(height: 200, child: Text('arrives')),
              ),
              SizedBox(height: 1200),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      double opacity() => t
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.text('arrives'),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      final low = opacity();
      expect(
        low,
        lessThan(0.7),
        reason: 'near the bottom edge it is still arriving',
      );
      await t.drag(find.byType(ListView), const Offset(0, -500));
      await t.pumpAndSettle();
      expect(opacity(), 1.0, reason: 'a third of the way up, it has arrived');
    });

    testWidgets('the whole profile: arena, record, tabs, and motion', (
      t,
    ) async {
      final dp = DataProvider()..setUser(user('1', 'me'));
      EventTracker.instance.dispose();
      // Tall enough that the tab strip, below the record, is drawn.
      await t.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: dp,
          child: MaterialApp(
            home: ProfilePage(user: user('5', 'maya'), isEmbedded: false),
          ),
        ),
      );
      await t.pumpAndSettle();

      // The record came from the server, and the tabs carry its counts.
      expect(asked.any((a) => a.contains('/users/5/battles?tab=live')), isTrue);
      expect(find.text('Silver · 1080'), findsOneWidget);
      expect(find.text('Won 3'), findsOneWidget);
      expect(find.text('Lost 1'), findsOneWidget);
      expect(find.text('Shorts'), findsOneWidget);
      // The record panel is on the page, and it and the intro slide in.
      expect(find.text('70 points to Gold'), findsOneWidget);
      expect(find.byType(ScrollReveal), findsNWidgets(2));
      // Another person's profile: no Liked or Saved.
      expect(find.text('Saved'), findsNothing);

      // The avatar shrinks into the bar as the page scrolls up.
      Size avatar() => t.getSize(
        find
            .ancestor(of: find.text('M'), matching: find.byType(Container))
            .first,
      );
      final before = avatar();
      await t.drag(find.text('Followers'), const Offset(0, -300));
      await t.pumpAndSettle();
      expect(avatar().width, lessThan(before.width));

      // The Lost tab shows the battle that was lost, as a video.
      // The tab strip scrolls sideways; bring the tab into view first.
      await t.ensureVisible(find.text('Lost 1'));
      await t.pumpAndSettle();
      await t.tap(find.text('Lost 1'));
      await t.pumpAndSettle();
      expect(find.text('Lost 2–5 · −16'), findsOneWidget);
      expect(find.byKey(const ValueKey('battle_tile_70')), findsOneWidget);
    });
  });
}
