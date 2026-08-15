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
  /// The ceiling is human reaction time, and that is what sets this value.
  /// A user cannot see a battle arrive, decide to flip it, and get a
  /// horizontal drag moving in less than roughly 250ms of reaction plus
  /// the gesture itself. Any delay under that closes before a real person
  /// could reach the one case that costs anything — a flip that starts
  /// while the opponent is still opening, which turns the cube onto a
  /// poster for a moment instead of live video. At half a second there is
  /// margin on both sides of that, so the lag case should not occur at
  /// all in practice.
  ///
  /// The floor is the failure this exists to stop. A fling passes a reel
  /// in two to four hundred milliseconds, and the old always-on behaviour
  /// meant every battle in that fling opened a video decoder and an audio
  /// decoder nobody would ever see or hear. Going below ~400ms starts
  /// handing that back. Zero IS the old behaviour.
  ///
  /// So this is the short end of the useful range, not the middle of it.
  /// It was 1200ms when the dwell was introduced; that was chosen against
  /// the risk of a poster flash, before working out that reaction time
  /// already rules that out much earlier.
  static const Duration dwell = Duration(milliseconds: 500);

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
