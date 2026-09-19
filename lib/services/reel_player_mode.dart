// EXPERIMENT BRANCH. Not on main.
//
// ═══════════════════════════════════════════════════════════════════════
// ONE PLAYER, OR A FEW
// ═══════════════════════════════════════════════════════════════════════
//
// The feed on main keeps a small number of videos OPEN at the same time:
// the one being watched, one warm spare for the next swipe, and — during a
// battle flip — the opponent's. Each open video costs a hardware decoder.
//
// This flag turns all of that off. With it on, exactly one video is open
// at any moment: the one filling the screen. Nothing above it, nothing
// below it, and during a battle turn only the face coming in. Everything
// else shows its cover picture until the user actually arrives at it.
//
// WHAT THIS IS NOT
//
// It is NOT "stop downloading ahead". The app still fetches the next
// videos' bytes in the background exactly as before, and that is the part
// that makes a swipe feel instant — the file is already on the phone, so
// opening it is a disk read rather than a trip to the network. TikTok
// preloads too; what it does not do is hold several decoders open.
//
// WHAT IT COSTS
//
// A swipe now has to BUILD a player, not just unpause one. That build is
// the tens-of-milliseconds the warm spare used to hide. The bet is that
// building one video against a file already on disk is cheaper than
// keeping three decoders fighting each other — which is what the device
// logs kept showing on cheap phones.
//
// HOW TO GO BACK
//
// Set [onePlayer] to false. That is the whole rollback: every changed
// path checks this one flag, so nothing else has to be undone.
class ReelPlayerMode {
  ReelPlayerMode._();

  /// True = one open video at a time. False = the pooled behaviour main
  /// ships today.
  ///
  /// Not const, so a test can flip it and put it back.
  static bool onePlayer = true;

  /// Put it back to what this branch ships. For tests that flip it.
  static void reset() => onePlayer = true;
}
