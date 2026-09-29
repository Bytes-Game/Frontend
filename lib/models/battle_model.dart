/// Battles: who is winning, when it ends, and a person's record.
///
/// Maps to the Go backend's battles.go and battles_http.go. A battle runs
/// for a set number of days from the moment somebody answers it. The server
/// counts only genuine votes, then likes, views and shares, and decides the
/// winner when the time is up.
library;

import 'package:myapp/models/challenge_model.dart';

/// Reads a number that may arrive as an int or a double.
double _toDouble(Object? v) => v is num ? v.toDouble() : 0;
int _toInt(Object? v) => v is num ? v.toInt() : 0;
DateTime? _toTime(Object? v) =>
    v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;

/// One side of a battle and everything counted for it.
class BattleSide {
  final String userId;
  final String username;

  /// "creator" or "responder".
  final String role;

  /// The answer's id. Empty for the creator's side.
  final String responseId;

  /// Every vote cast for this side. With [likes], [views] and [shares], the
  /// same numbers every other screen shows.
  final double votes;

  /// The votes that decide the battle: votes from people who never watched,
  /// or from throwaway accounts, taken off; a vote from a very new account
  /// counts half. Only differs from [votes] when some did not count.
  final double countedVotes;
  final int rawVotes;
  final int removedVotes;
  final int likes;
  final int views;
  final int shares;
  final int rank;
  final bool leading;

  const BattleSide({
    required this.userId,
    required this.username,
    required this.role,
    this.responseId = '',
    this.votes = 0,
    this.countedVotes = 0,
    this.rawVotes = 0,
    this.removedVotes = 0,
    this.likes = 0,
    this.views = 0,
    this.shares = 0,
    this.rank = 0,
    this.leading = false,
  });

  bool get isCreator => role == 'creator';

  factory BattleSide.fromJson(Map<String, dynamic> j) => BattleSide(
    userId: '${j['userId'] ?? ''}',
    username: '${j['username'] ?? ''}',
    role: '${j['role'] ?? ''}',
    responseId: '${j['responseId'] ?? ''}',
    votes: _toDouble(j['votes']),
    // A server from before the two sets sent the counted ones as "votes".
    countedVotes: _toDouble(j['countedVotes'] ?? j['votes']),
    rawVotes: _toInt(j['rawVotes']),
    removedVotes: _toInt(j['removedVotes']),
    likes: _toInt(j['likes']),
    views: _toInt(j['views']),
    shares: _toInt(j['shares']),
    rank: _toInt(j['rank']),
    leading: j['leading'] == true,
  );
}

/// The live count of one battle.
class BattleStandings {
  final String challengeId;
  final String status;
  final int battleDays;
  final DateTime? acceptedAt;
  final DateTime? endsAt;
  final bool resolved;
  final List<BattleSide> sides;

  /// How many votes were taken off, by reason, in the server's own words.
  final Map<String, int> removed;

  /// The side the signed-in person voted for: "creator", an answer's id, or
  /// empty if they have not voted.
  final String yourVote;

  const BattleStandings({
    required this.challengeId,
    required this.status,
    required this.battleDays,
    this.acceptedAt,
    this.endsAt,
    this.resolved = false,
    this.sides = const [],
    this.removed = const {},
    this.yourVote = '',
  });

  /// Voting has closed, whether or not the server has decided it yet.
  bool get over =>
      resolved || (endsAt != null && !endsAt!.isAfter(DateTime.now()));

  /// Nobody has answered yet, so there is no battle to count.
  bool get notStarted => acceptedAt == null;

  BattleSide? get creator {
    for (final s in sides) {
      if (s.isCreator) return s;
    }
    return null;
  }

  int get removedTotal => removed.values.fold(0, (a, b) => a + b);

  /// Everything added up across the players — what the battle page shows
  /// as its totals, so they always match the rows of the live score.
  int get totalVotes => sides.fold(0, (a, s) => a + s.votes.round());
  int get totalLikes => sides.fold(0, (a, s) => a + s.likes);
  int get totalViews => sides.fold(0, (a, s) => a + s.views);
  int get totalShares => sides.fold(0, (a, s) => a + s.shares);

  /// Some votes did not count, so the score that decides the battle is not
  /// the one on show.
  bool get countedDiffers => sides.any((s) => s.countedVotes != s.votes);

  /// This count with votes moved on screen before the server has them:
  /// [delta] by side — "creator", or an answer's id.
  BattleStandings withVotesMoved(Map<String, int> delta) {
    if (delta.isEmpty) return this;
    return BattleStandings(
      challengeId: challengeId,
      status: status,
      battleDays: battleDays,
      acceptedAt: acceptedAt,
      endsAt: endsAt,
      resolved: resolved,
      removed: removed,
      yourVote: yourVote,
      sides: [
        for (final s in sides)
          BattleSide(
            userId: s.userId,
            username: s.username,
            role: s.role,
            responseId: s.responseId,
            votes: s.votes + (delta[s.isCreator ? 'creator' : s.responseId] ?? 0),
            countedVotes: s.countedVotes,
            rawVotes: s.rawVotes,
            removedVotes: s.removedVotes,
            likes: s.likes,
            views: s.views,
            shares: s.shares,
            rank: s.rank,
            leading: s.leading,
          ),
      ],
    );
  }

  factory BattleStandings.fromJson(Map<String, dynamic> j) => BattleStandings(
    challengeId: '${j['challengeId'] ?? ''}',
    status: '${j['status'] ?? ''}',
    battleDays: _toInt(j['battleDays']),
    acceptedAt: _toTime(j['acceptedAt']),
    endsAt: _toTime(j['endsAt']),
    resolved: j['resolved'] == true,
    sides: (j['participants'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(BattleSide.fromJson)
        .toList(),
    removed: {
      for (final e in (j['removed'] as Map? ?? const {}).entries)
        '${e.key}': _toInt(e.value),
    },
    yourVote: '${j['yourVote'] ?? ''}',
  );
}

/// One battle on a profile's Open / Live / Won / Lost / Draw tab.
class BattleCard {
  final String challengeId;
  final String title;
  final String thumbnailUrl;
  final String videoUrl;

  /// "creator" or "responder": which side the profile's owner was on.
  final String role;

  /// "open", "active" or "completed".
  final String status;

  /// "won", "lost" or "draw" once decided; empty before.
  final String outcome;
  final DateTime? createdAt;
  final DateTime? endsAt;
  final DateTime? decidedAt;
  final double myVotes;
  final double theirVotes;
  final String opponent;
  final int ratingChange;

  /// For a live battle: the owner is ahead right now.
  final bool leading;

  /// The battle as a video to play: the same record every feed sends, with
  /// its answer and the viewer's own likes and votes. Null from a server
  /// that does not send it yet.
  final ChallengeModel? video;

  const BattleCard({
    required this.challengeId,
    required this.title,
    this.thumbnailUrl = '',
    this.videoUrl = '',
    this.role = '',
    this.status = '',
    this.outcome = '',
    this.createdAt,
    this.endsAt,
    this.decidedAt,
    this.myVotes = 0,
    this.theirVotes = 0,
    this.opponent = '',
    this.ratingChange = 0,
    this.leading = false,
    this.video,
  });

  factory BattleCard.fromJson(Map<String, dynamic> j) => BattleCard(
    challengeId: '${j['challengeId'] ?? ''}',
    title: '${j['title'] ?? ''}',
    thumbnailUrl: '${j['thumbnailUrl'] ?? ''}',
    videoUrl: '${j['videoUrl'] ?? ''}',
    role: '${j['role'] ?? ''}',
    status: '${j['status'] ?? ''}',
    outcome: '${j['outcome'] ?? ''}',
    createdAt: _toTime(j['createdAt']),
    endsAt: _toTime(j['endsAt']),
    decidedAt: _toTime(j['decidedAt']),
    myVotes: _toDouble(j['myVotes']),
    theirVotes: _toDouble(j['theirVotes']),
    opponent: '${j['opponent'] ?? ''}',
    ratingChange: _toInt(j['ratingChange']),
    leading: j['leading'] == true,
    video: j['video'] is Map<String, dynamic>
        ? ChallengeModel.fromJson(j['video'] as Map<String, dynamic>)
        : null,
  );
}

/// A person's battle record, shown at the top of their profile.
class BattleRecord {
  final int rating;
  final String league;
  final int wins;
  final int losses;
  final int draws;

  /// How many in a row, and of what: "won", "lost", or "" for none.
  final int streak;
  final String streakOf;

  /// How many battles are on each tab: open, live, won, lost, draw.
  final Map<String, int> counts;

  const BattleRecord({
    this.rating = 1000,
    this.league = 'Unranked',
    this.wins = 0,
    this.losses = 0,
    this.draws = 0,
    this.streak = 0,
    this.streakOf = '',
    this.counts = const {},
  });

  int get decided => wins + losses + draws;

  /// Share of decided battles won, 0..1. Zero before any are decided.
  double get winRate => decided == 0 ? 0 : wins / decided;

  factory BattleRecord.fromJson(Map<String, dynamic> j) => BattleRecord(
    rating: j['rating'] is num ? _toInt(j['rating']) : 1000,
    league: '${j['league'] ?? ''}'.isEmpty ? 'Unranked' : '${j['league']}',
    wins: _toInt(j['wins']),
    losses: _toInt(j['losses']),
    draws: _toInt(j['draws']),
    streak: _toInt(j['streak']),
    streakOf: '${j['streakOf'] ?? ''}',
    counts: {
      for (final e in (j['counts'] as Map? ?? const {}).entries)
        '${e.key}': _toInt(e.value),
    },
  );
}

/// One page of a profile's battles tab, with the record above it.
class BattlesPage {
  final BattleRecord record;
  final String tab;
  final List<BattleCard> battles;

  const BattlesPage({
    required this.record,
    required this.tab,
    this.battles = const [],
  });

  factory BattlesPage.fromJson(Map<String, dynamic> j) => BattlesPage(
    record: BattleRecord.fromJson(
      (j['summary'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    tab: '${j['tab'] ?? ''}',
    battles: (j['battles'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(BattleCard.fromJson)
        .toList(),
  );
}

/// What happened to a vote. [message] is the server's own reason when it
/// was refused — "You can't vote in your own battle.", "This battle has
/// ended." — so the person is told why rather than just "failed".
class ActionResult {
  final bool ok;
  final String message;
  const ActionResult(this.ok, [this.message = '']);
}

/// What came of reporting a video that doesn't match its challenge.
class ReportResult {
  /// The server has the report.
  final bool sent;

  /// The video is down now — this report, or one before it, settled it.
  final bool takenDown;

  /// What to tell the person, in the server's words when it gave some.
  final String message;

  const ReportResult(this.sent, this.takenDown, this.message);
}

/// Where a rating sits on the league ladder.
///
/// The thresholds are the server's (leagueFor in battles.go): a league is
/// earned by rating, and nobody has one until a battle of theirs is decided.
/// They are repeated here only to draw progress towards the next league; the
/// league itself always comes from the server.
class LeagueStep {
  final String league;

  /// The next league up, or null at the top.
  final String? next;

  /// How far from this league's floor to the next one's, 0..1. Always 1 at
  /// the top.
  final double progress;

  /// Rating points still needed for the next league. Zero at the top.
  final int pointsToNext;

  const LeagueStep(this.league, this.next, this.progress, this.pointsToNext);

  static const _floors = <(String, int)>[
    ('Bronze', 0),
    ('Silver', 1050),
    ('Gold', 1150),
    ('Platinum', 1300),
    ('Diamond', 1500),
  ];

  /// Bronze's progress is drawn from this rating, not from zero, so a new
  /// player's bar means something.
  static const _bronzeFloor = 900;

  factory LeagueStep.of(int rating, {required int decided}) {
    if (decided == 0) {
      return const LeagueStep('Unranked', 'Bronze', 0, 0);
    }
    var i = 0;
    for (var k = 0; k < _floors.length; k++) {
      if (rating >= _floors[k].$2) i = k;
    }
    if (i == _floors.length - 1) {
      return LeagueStep(_floors[i].$1, null, 1, 0);
    }
    final floor = i == 0 ? _bronzeFloor : _floors[i].$2;
    final ceiling = _floors[i + 1].$2;
    final p = ((rating - floor) / (ceiling - floor)).clamp(0.0, 1.0);
    return LeagueStep(_floors[i].$1, _floors[i + 1].$1, p, ceiling - rating);
  }
}

/// Someone on a "who voted" or "who liked" list, and when.
class PersonAt {
  final String userId;
  final String username;
  final String league;
  final DateTime? at;

  const PersonAt({
    required this.userId,
    required this.username,
    this.league = '',
    this.at,
  });

  factory PersonAt.fromJson(Map<String, dynamic> j) => PersonAt(
    userId: '${j['userId'] ?? ''}',
    username: '${j['username'] ?? ''}',
    league: '${j['league'] ?? ''}',
    at: _toTime(j['at']),
  );
}

/// One video — the creator's, or an answer — and the people on a list for
/// it: who liked it, voted for it, or shared it. Only the people in the
/// video are sent these.
class PeopleSide {
  final String username;

  /// "creator" or "responder".
  final String role;
  final String responseId;
  final List<PersonAt> people;

  const PeopleSide({
    required this.username,
    required this.role,
    this.responseId = '',
    this.people = const [],
  });

  bool get isCreator => role == 'creator';

  factory PeopleSide.fromJson(Map<String, dynamic> j) => PeopleSide(
    username: '${j['username'] ?? ''}',
    role: '${j['role'] ?? ''}',
    responseId: '${j['responseId'] ?? ''}',
    people: (j['people'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PersonAt.fromJson)
        .toList(),
  );
}
