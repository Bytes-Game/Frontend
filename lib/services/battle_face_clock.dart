/// How long each side of a battle was on screen.
///
/// A battle reel is one card with two videos: the person who posted the
/// challenge, and the person who answered it. You swipe sideways between
/// them. For a long time every view of that card was recorded against the
/// challenge alone, so the server could not tell who had actually been
/// watched — and counting those views for the creator would hand every tie
/// to them.
///
/// So the reel keeps this clock. The card turns it every time it flips, and
/// when the view is reported the feed asks how long each side was up. The
/// server counts a view for a side when that side was on screen for two
/// seconds or more (see battles.go in the backend).
class BattleFaceClock {
  /// Every turn, oldest first: when it happened and whether the answer's
  /// side was then showing. Before the first turn a battle shows its creator.
  final List<(DateTime, bool)> _turns = [];

  /// The answer's side is on screen now.
  bool get showingOpponent => _turns.isNotEmpty && _turns.last.$2;

  /// The card now shows [opponent]'s side, from [at] (default: now).
  void turn({required bool opponent, DateTime? at}) {
    if (showingOpponent == opponent) return;
    _turns.add((at ?? DateTime.now(), opponent));
  }

  /// How long each side was on screen between [since] and [now], in
  /// milliseconds. Forgets the turns it has counted, keeping only which side
  /// is showing, so the next view starts clean.
  ({int creatorMs, int opponentMs}) timesSince(DateTime since, DateTime now) {
    var opponent = false;
    for (final t in _turns) {
      if (t.$1.isAfter(since)) break;
      opponent = t.$2;
    }
    var cursor = since;
    var creatorMs = 0;
    var opponentMs = 0;
    for (final t in _turns) {
      if (!t.$1.isAfter(since)) continue;
      if (t.$1.isAfter(now)) break;
      final ms = t.$1.difference(cursor).inMilliseconds;
      if (opponent) {
        opponentMs += ms;
      } else {
        creatorMs += ms;
      }
      cursor = t.$1;
      opponent = t.$2;
    }
    final rest = now.difference(cursor).inMilliseconds;
    if (rest > 0) {
      if (opponent) {
        opponentMs += rest;
      } else {
        creatorMs += rest;
      }
    }
    if (_turns.length > 1) {
      final last = _turns.last;
      _turns
        ..clear()
        ..add(last);
    }
    return (creatorMs: creatorMs, opponentMs: opponentMs);
  }

  /// What a view of the battle carries: how long each side was watched, and
  /// which answer the other side is.
  Map<String, dynamic> viewDetails({
    required String responseId,
    required DateTime since,
    required DateTime now,
  }) {
    final t = timesSince(since, now);
    return {
      'responseId': responseId,
      'creatorMs': t.creatorMs,
      'opponentMs': t.opponentMs,
    };
  }

  /// What a completion or share on the battle carries: which side was on
  /// screen when it happened.
  Map<String, dynamic> sideDetails({required String responseId}) => {
    'side': showingOpponent ? 'opponent' : 'creator',
    'responseId': responseId,
  };
}
