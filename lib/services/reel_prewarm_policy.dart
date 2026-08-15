/// When a battle reel is allowed to open its opponent's player early.
///
/// A battle carries two videos and the user can flip between them with a
/// horizontal swipe, so the opponent has to be ready before the cube turn
/// finishes. The obvious way to guarantee that is to open the opponent's
/// player the moment the battle becomes the active reel — which is what
/// this used to do, and it is expensive in a way that does not show up
/// until you read a device log.
///
/// Every live player is a video decoder AND, for content that carries an
/// audio track, an audio decoder. The audio one is pure waste on a
/// prewarmed opponent: it is muted and paused, so ExoPlayer decodes
/// enough to fill its buffers and then throws all of it away. A profile
/// run showed exactly that shape — `Qinput: 133, Render: 0, Drop: 124` —
/// on a feed whose catalog is mostly battles. Two decoders per battle on
/// screen, one of them never heard.
///
/// [VideoPlayerService.prefetch] already made this trade for upcoming
/// reels: warm every URL in the window as BYTES, give a live player to
/// exactly one of them. The opponent's bytes are warmed too — the feed
/// puts the active reel's opponent near the front of the warm window — so
/// the only thing the eager player bought over opening on the flip was
/// the time between "reel became active" and "user tapped".
///
/// Which the user usually never spends. A fast scroller flips nothing;
/// they pass through battles at a reel a second and pay two decoders for
/// each. So the player now waits for [dwell]: stay on a battle long
/// enough to look at it, and the opponent opens in the background against
/// warm bytes. Scroll past and nothing is allocated at all.
library;

class ReelPrewarmPolicy {
  const ReelPrewarmPolicy._();

  /// How long a battle must be the active reel before its opponent gets a
  /// player.
  ///
  /// Longer than a pass-through (the feed treats under 800ms as a skip)
  /// and shorter than the time it takes to read a battle's caption and
  /// decide to flip. Wrong in the slow direction costs one cube turn that
  /// starts on a poster; wrong in the fast direction costs a decoder pair
  /// on every battle the user scrolls past, which is the failure this
  /// exists to stop.
  static const Duration dwell = Duration(milliseconds: 1200);

  /// Whether to open the opponent's player at all.
  ///
  /// [maxPoolSize] gates the low-RAM tiers: a 2-slot pool holds the active
  /// reel and one read-ahead spare, and taking a third live decoder there
  /// is how those devices OOM. They keep create-on-flip.
  static bool shouldPrewarmOpponent({
    required bool isBattle,
    required bool isActive,
    required bool alreadyOpen,
    required int maxPoolSize,
  }) {
    if (!isBattle) return false;
    if (!isActive) return false;
    if (alreadyOpen) return false;
    return maxPoolSize >= 3;
  }
}
