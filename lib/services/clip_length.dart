/// How long a clip may run, and what the picker on the trim screen offers.
///
/// Pure arithmetic, deliberately separate from the trim page: the rules
/// here are the ones that decide what actually gets uploaded, and a rule
/// that only exists inside a `State` class can only be checked by reading
/// the source and hoping. Everything in this file is exercised directly.
library;

/// The clip-length picker's rules.
abstract final class ClipLength {
  /// The lengths offered, shortest first, for a given hard [cap].
  ///
  /// DERIVED, not typed in. Anything longer than the cap is dropped, so
  /// the picker cannot offer a length the server would refuse. If the cap
  /// ever moves the options move with it, instead of going quietly stale —
  /// the exact failure the trim screen already carries a comment about
  /// ("mirrors processor cap", which is how two numbers that must agree
  /// start not agreeing).
  static List<Duration> optionsWithin(Duration cap) => const <Duration>[
        Duration(seconds: 30),
        Duration(minutes: 1),
        Duration(minutes: 2),
        Duration(minutes: 3),
      ].where((d) => d <= cap).toList(growable: false);

  /// What a clip is when nobody has chosen: one minute.
  ///
  /// Not the cap. A short-video app should hand people a short video by
  /// default and let them ask for more, rather than posting three minutes
  /// because three minutes is where the ceiling happens to sit.
  ///
  /// Clamped, so this stays a real option if the cap ever drops below a
  /// minute.
  static Duration defaultWithin(Duration cap) {
    const preferred = Duration(minutes: 1);
    final options = optionsWithin(cap);
    // A cap below the shortest option leaves nothing to offer; the cap
    // itself is then the only honest answer.
    if (options.isEmpty) return cap;
    // Chosen FROM the options rather than clamped to the cap. Clamping
    // looks right and is not: a cap of 45 seconds would default to 45
    // seconds, which is not one of the buttons, so the screen would open
    // with nothing selected and no way to get back to that length.
    final fits = options.where((d) => d <= preferred);
    return fits.isNotEmpty ? fits.last : options.first;
  }

  /// "30s", "1 min", "2 min".
  static String label(Duration d) =>
      d.inSeconds < 60 ? '${d.inSeconds}s' : '${d.inMinutes} min';

  /// Where the trim window should sit after a length is chosen.
  ///
  /// [totalMs] is how long the source runs, [limitMs] the length chosen,
  /// and [startMs] where the start handle is now.
  ///
  /// Three rules, in order:
  ///   * a source shorter than the chosen length is taken WHOLE — the
  ///     picker is a ceiling, not a target, so choosing "3 min" for a
  ///     twelve-second clip posts twelve seconds and not an error;
  ///   * the window keeps the start the person has already found, so
  ///     picking a longer length does not throw away the moment they
  ///     just scrubbed to;
  ///   * a window that would run off the end SLIDES BACK to fit rather
  ///     than being cut short, because a clip that can have its full
  ///     length should get it.
  static ({int startMs, int endMs}) window({
    required int totalMs,
    required int limitMs,
    required int startMs,
  }) {
    if (totalMs <= 0) return (startMs: 0, endMs: 0);
    final span = limitMs < totalMs ? limitMs : totalMs;
    var start = startMs;
    if (start + span > totalMs) start = totalMs - span;
    if (start < 0) start = 0;
    return (startMs: start, endMs: start + span);
  }
}
