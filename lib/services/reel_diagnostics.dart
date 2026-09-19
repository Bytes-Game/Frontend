import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:myapp/services/decoder_budget.dart';

/// Which gesture a read-ahead spare was opened for.
///
/// The pool keeps a live player for every reel a single gesture can
/// reach. There are two such reels, and they are reached differently:
/// the next reel by a vertical swipe, a battle's opponent by a
/// horizontal flip. Both used to be tallied together, which made the
/// summary unable to answer the question the second one was added to
/// settle — is a flip landing on a ready player, or paying a cold open?
/// One number for both cannot say, because swipes vastly outnumber flips
/// and drown the flip's contribution in the total.
enum SpareLane {
  /// The reel one vertical swipe away.
  nextReel('swipe'),

  /// The active battle's opponent, one horizontal flip away.
  opponent('flip');

  const SpareLane(this.label);

  /// Short tag used in the summary line.
  final String label;
}

/// Playback diagnostics that survive a profile build.
///
/// Why this exists
/// ---------------
/// The loopback media proxy sits on the critical path of every reel, and its
/// original logging was behind `kDebugMode`. That flag is false in profile
/// builds — the only build worth measuring, since debug runs 3-10x slower and
/// its timings mean nothing. So the one build that could tell us whether the
/// proxy bound, whether prefix mode was active, and how many reels it actually
/// served printed exactly nothing about any of it. A component was shipped onto
/// the hot path with no way to observe it where it matters.
///
/// [_visible] is therefore `!kReleaseMode`: on in debug AND profile, off in
/// release so real users never pay for it.
///
/// Counters over chatter
/// ---------------------
/// A line per reel would be unreadable during a burst scroll and would itself
/// perturb the timings being measured. Instead every playback increments a
/// counter and a single summary prints every [_summaryEvery] reels, so a
/// 60-reel session yields a handful of lines that answer the question directly:
/// how many starts came from the proxy, from a whole cached file, and from the
/// network.
class ReelDiagnostics {
  ReelDiagnostics._();
  static final ReelDiagnostics instance = ReelDiagnostics._();

  /// Debug and profile, never release.
  static const bool _visible = !kReleaseMode;

  /// How many playbacks between summaries. Small enough to see a trend within
  /// a short session, large enough not to spam a fast scroll.
  static const int _summaryEvery = 10;

  /// ══════════════════════════════════════════════════════════════════════
  /// WHY A COUNT OF TEN IS NOT ENOUGH ON ITS OWN
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// A run arrived with ONE video started and then nothing. Not one summary
  /// in the whole file, because the count never reached ten — so every
  /// counter in this class died unread, and the session could not be
  /// compared with anything.
  ///
  /// A measurement you only get if the session ends tidily is a measurement
  /// you do not have. The sessions worth measuring are exactly the ones
  /// that end badly: the app killed for memory, the phone's power manager
  /// closing it, a run stopped early because something looked wrong.
  ///
  /// So the summary is also printed:
  ///
  ///   * on a timer, which survives the app being killed outright — a kill
  ///     gives no callback at all, so the only numbers that survive one are
  ///     the ones already written down;
  ///   * when the app goes to the background, which is a real exit as far
  ///     as the person holding it is concerned.
  ///
  /// Gated on something having actually changed, so an app sitting idle on
  /// a profile screen stays silent instead of repeating itself forever.
  /// Not const: a test sets it to a few milliseconds. Waiting twenty real
  /// seconds per case would make the suite unusable, and pulling in a fake
  /// clock package for it dragged four unrelated dependency upgrades along
  /// with it — including the maths library the battle flip animates with,
  /// which has no business moving inside a logging fix.
  @visibleForTesting
  static Duration heartbeatInterval = const Duration(seconds: 20);

  int _proxied = 0;
  int _wholeFile = 0;
  int _origin = 0;
  int _downloads = 0;
  int _prefixWarmed = 0;
  int _prefixFailed = 0;
  int _tailWarmed = 0;
  final Map<String, int> _prefixBailed = <String, int>{};
  final Map<SpareLane, int> _spareWarm = <SpareLane, int>{};
  final Map<SpareLane, int> _spareCold = <SpareLane, int>{};
  int _retired = 0;
  int _sinceSummary = 0;

  /// True when a counter has moved since the last summary was printed.
  ///
  /// The gate on the timer. Without it an app left open on a profile page
  /// prints the same line every twenty seconds for as long as it sits
  /// there, and the one line worth reading is buried in copies of itself.
  bool _changedSinceSummary = false;

  Timer? _heartbeat;

  /// How many times a timer has actually been CREATED.
  ///
  /// Counted because the leak it guards against is invisible from the
  /// outside. Starting a fresh timer per video without stopping the last
  /// one leaves fifty of them ticking after fifty videos — and they all
  /// fire together, so the first one clears the "something changed" flag
  /// and the other forty-nine find nothing to say. The log looks perfect.
  /// The same shape of leak, hidden behind the same kind of guard, has
  /// already been found once in this app's first-frame watchers.
  int _heartbeatStarts = 0;

  /// Live view of the warming pipeline, installed by `VideoCacheService`.
  ///
  /// Every counter above is cumulative, which is what makes them cheap —
  /// but a cumulative count cannot tell a stalled pipeline from a finished
  /// one. `downloads` stuck at 7 while `starts` climbs to 30 reads
  /// identically whether warming ran out of new URLs to fetch (a short
  /// feed the user scrolled back over, nothing wrong) or whether its one
  /// download slot is wedged behind a fetch that never completes (a real
  /// stall, with a queue piling up behind it). Only the instantaneous
  /// depths separate those, and they live in the cache — so the cache
  /// offers them here rather than this class reaching across for them.
  String Function()? _pipelineProbe;

  /// Register the snapshot appended to every [summary].
  void setPipelineProbe(String Function() probe) {
    if (!_visible) return;
    _pipelineProbe = probe;
  }

  /// One-off diagnostic line. Prefixed so it can be grepped out of the very
  /// noisy Android media logs: `flutter run --profile | grep "\[reel\]"`.
  void log(String message) {
    if (!_visible) return;
    debugPrint('[reel] $message');
  }

  void recordProxiedStart() => _record(() => _proxied++);
  void recordWholeFileStart() => _record(() => _wholeFile++);
  void recordOriginStart() => _record(() => _origin++);

  /// A queued URL was dequeued and its download actually began.
  ///
  /// Separates the two ways warming can produce nothing: the prefetch
  /// never ran at all (downloads=0), versus it ran on every reel and gave
  /// up each time (downloads high, warmed 0). Those need opposite fixes,
  /// and without this counter the summary reads identically for both.
  void recordDownloadStarted() {
    if (!_visible) return;
    _downloads++;
  }

  /// How long a reel took to go from "on screen" to a moving picture.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// EVERY STALL MEASUREMENT BEFORE THIS ONE WAS MEDIATEK-ONLY
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// Round after round of this app's tuning was read off a line the
  /// MediaTek decoder prints:
  ///
  ///     onReleaseOutputBuffer: Render time interval reaches 434ms
  ///
  /// It is not an Android line. It is that vendor's. A log from a Qualcomm
  /// phone contains ZERO of them — so on that phone there was no stall
  /// measurement at all, and the counters that did exist said the session
  /// was going WELL while the person holding it said the feed stuck a lot.
  ///
  /// Every number in this summary says something about the app's own
  /// plumbing: was a player ready, did the bytes come off the disk, how
  /// many decoders are open. None of them is the thing a person actually
  /// experiences, which is: I swiped, and then I waited.
  ///
  /// This is that. Started when a reel becomes the one on screen, stopped
  /// when its picture first moves, measured by the app itself so it reads
  /// the same on every chip.
  void recordFirstFrameWait(Duration d) {
    if (!_visible) return;
    final ms = d.inMilliseconds;
    if (ms < 0) return;
    _firstFrameWaits.add(ms);
    // Bounded: a long session should not grow this without limit, and the
    // shape of the recent past is what anybody reading a log wants.
    if (_firstFrameWaits.length > _firstFrameMemory) {
      _firstFrameWaits.removeAt(0);
    }
  }

  static const int _firstFrameMemory = 200;
  final List<int> _firstFrameWaits = [];

  @visibleForTesting
  int get debugFirstFrameCount => _firstFrameWaits.length;

  /// Typical and worst wait, in milliseconds.
  ///
  /// The median rather than the average: one reel that took eight seconds
  /// should not be able to describe the other fifty. The worst is carried
  /// separately because that one is what somebody remembers.
  String _firstFrames() {
    if (_firstFrameWaits.isEmpty) return '';
    final v = List<int>.from(_firstFrameWaits)..sort();
    final mid = v[v.length ~/ 2];
    final p90 = v[(v.length * 9) ~/ 10];
    return '  | wait n=${v.length} median=${mid}ms p90=${p90}ms worst=${v.last}ms';
  }

  /// A player was told to shut down, and finished shutting down.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// THE SLOT IS FREE BEFORE THE DECODER IS
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// The feed keeps four players. When a reel scrolls away its slot is
  /// handed to the next reel straight away — but telling the phone to shut
  /// the old one down is not instant, and the decoder stays occupied until
  /// it finishes. So the app's own books can say four while the phone is
  /// holding more.
  ///
  /// A device log showed thirteen decoders alive at once against a pool of
  /// four, with eighty-six players retired over the session. The search
  /// grid was ruled out — it peaked at one — and the sizes say seven of the
  /// twelve created just before the peak were the FEED's.
  ///
  /// This is the number that says whether shutting down is the reason. If
  /// it sits at eight or nine, that is the answer. If it sits at zero, the
  /// suspicion is wrong and the extra decoders are coming from somewhere
  /// else entirely — which is exactly what the preview count did to the
  /// last theory.
  void recordReleaseStarted() {
    if (!_visible) return;
    _releasing++;
    if (_releasing > _releasingPeak) _releasingPeak = _releasing;
  }

  void recordReleaseFinished() {
    if (!_visible) return;
    if (_releasing > 0) _releasing--;
  }

  int _releasing = 0;
  int _releasingPeak = 0;

  @visibleForTesting
  int get debugReleasing => _releasing;

  @visibleForTesting
  int get debugReleasingPeak => _releasingPeak;

  /// A search-grid preview built a player, and gave one back.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THIS IS COUNTED SEPARATELY FROM THE FEED'S PLAYERS
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// The feed's players come from a pool that cannot exceed four. The
  /// grid's do not — each tile owns its own — so the two have to be told
  /// apart to know which one is holding decoders.
  ///
  /// A device log showed the phone's live decoder count climbing from five
  /// to TWELVE, every one of them in the stretch just after the search page
  /// opened, with seven created and not one released. Android reclaimed a
  /// decoder by force during it.
  ///
  /// It could not be settled from that log. Reels are now served at the
  /// same 480p the grid uses, so a decoder's size no longer says which part
  /// of the app asked for it — the one signal that separated them is gone.
  /// Rather than guess, the app now says it out loud.
  void recordPreviewOpened() {
    if (!_visible) return;
    _previewOpened++;
    _previewLive++;
    if (_previewLive > _previewPeak) _previewPeak = _previewLive;
  }

  void recordPreviewReleased() {
    if (!_visible) return;
    _previewReleased++;
    if (_previewLive > 0) _previewLive--;
  }

  int _previewOpened = 0;
  int _previewReleased = 0;
  int _previewLive = 0;
  int _previewPeak = 0;

  @visibleForTesting
  int get debugPreviewLive => _previewLive;

  @visibleForTesting
  int get debugPreviewPeak => _previewPeak;

  /// A reel's opening slice was fetched and handed to the proxy.
  void recordPrefixWarmed() {
    if (!_visible) return;
    _prefixWarmed++;
  }

  /// A prefix warm failed and fell through to the whole-file path.
  void recordPrefixFailed() {
    if (!_visible) return;
    _prefixFailed++;
  }

  /// A warmed reel also got the END of its file cached, because its index
  /// lives there rather than at the front.
  ///
  /// Counted separately from [recordPrefixWarmed] — which it always
  /// accompanies — because it is the direct replacement for what used to
  /// be `bailed{moovAtEnd:n}`, and the two want comparing across runs. A
  /// session where that tag was large and this one is now similarly large
  /// is the fix working; a session where both are small is a catalog that
  /// never had the problem.
  void recordTailWarmed() {
    if (!_visible) return;
    _tailWarmed++;
  }

  /// The prefix fetch gave up before registering with the proxy, without
  /// throwing — the origin refused the range, sent an unusable
  /// Content-Range, or the body arrived empty. These paths are the quiet
  /// majority of "warming did nothing": they are neither `warmed` nor
  /// `failed`, so a summary reading `warmed=0 failed=0` says only that
  /// the prefix path produced nothing, never which of the three reasons.
  /// [reason] is a short tag, tallied so one line names the culprit.
  void recordPrefixBailed(String reason) {
    if (!_visible) return;
    _prefixBailed[reason] = (_prefixBailed[reason] ?? 0) + 1;
  }

  /// The read-ahead spare controller was opened with its opening slice
  /// already cached, so it starts against the proxy.
  ///
  /// [lane] says which gesture the spare was opened for — see [SpareLane].
  void recordSpareWarm(SpareLane lane) {
    if (!_visible) return;
    _spareWarm[lane] = (_spareWarm[lane] ?? 0) + 1;
  }

  /// The spare was opened before its slice arrived and went to the
  /// network. Some of these are unavoidable (first reel of a session, a
  /// genuinely slow connection); a high ratio means
  /// [VideoPlayerService.spareWarmGrace] is too short for real devices.
  void recordSpareCold(SpareLane lane) {
    if (!_visible) return;
    _spareCold[lane] = (_spareCold[lane] ?? 0) + 1;
  }

  /// A pooled player was shut down and released.
  ///
  /// `starts` counts players opened, so this counts the other end, and
  /// the pair is the only direct read on decoder churn. Every open/retire
  /// cycle is a hardware video decoder plus an audio decoder created and
  /// torn down — expensive enough that a device log showing far more of
  /// them than there are distinct reels is itself the finding. A healthy
  /// session retires roughly one player per reel LEFT BEHIND; retires
  /// keeping pace with starts on a short feed means the pool is
  /// rebuilding players it already had.
  void recordPlayerRetired() {
    if (!_visible) return;
    _retired++;
  }

  void _record(void Function() bump) {
    if (!_visible) return;
    bump();
    _changedSinceSummary = true;
    _startHeartbeat();
    if (++_sinceSummary >= _summaryEvery) _emitSummary();
  }

  /// Print the summary and reset what decides when the next one is due.
  void _emitSummary() {
    _sinceSummary = 0;
    _changedSinceSummary = false;
    log(summary());
  }

  /// Start the timer, once, the first time there is anything to report.
  ///
  /// Lazily rather than from the constructor: this class is reached by
  /// tests and by code paths that never play a video, and a timer left
  /// running holds the test isolate open — which shows up as a run that
  /// hangs, not as the leak it actually is.
  void _startHeartbeat() {
    if (_heartbeat != null) return;
    _heartbeatStarts++;
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_changedSinceSummary) _emitSummary();
    });
  }

  /// The app is going away — write down whatever has been counted.
  ///
  /// Called from the lifecycle observer in main.dart. This is the last
  /// chance to save the numbers on an ORDERLY exit. The timer above is
  /// what covers the disorderly ones, which give no warning at all.
  void noteGoingToBackground() {
    if (!_visible) return;
    if (_changedSinceSummary) _emitSummary();
  }

  /// Current tallies. Also useful from a debugger or a test.
  /// How many players have been told to shut down and have not finished.
  ///
  /// Always shown once anything has been retired, because zero here is an
  /// ANSWER, not an absence: it rules the shutdown queue out as the reason
  /// decoders are piling up.
  String _releasingNow() =>
      _retired == 0 ? '' : ' (shutting down now=$_releasing peak=$_releasingPeak)';

  /// How many players the SEARCH GRID is holding — live now, and the most
  /// it ever held. Silent until the grid has opened one, so a session that
  /// never visits search does not carry a row of zeroes.
  String _previews() => _previewOpened == 0
      ? ''
      : '  | previews live=$_previewLive peak=$_previewPeak '
          'opened=$_previewOpened released=$_previewReleased';

  String summary() {
    final starts = _proxied + _wholeFile + _origin;
    if (starts == 0) return 'no reels played yet';
    String pct(int n) => '${(n * 100 / starts).round()}%';
    final bailed = _prefixBailed.isEmpty
        ? ''
        : ' bailed{${_prefixBailed.entries.map((e) => '${e.key}:${e.value}').join(',')}}';
    // What the chip says it will run at once, once per summary. It is the
    // ceiling everything else in this line is operating under, and until it
    // is in a log nobody knows what any phone answers.
    final budget = DecoderBudget.instance.summary();
    return '${budget.isEmpty ? '' : '$budget  '}'
        'starts=$starts  proxy=$_proxied (${pct(_proxied)})  '
        'file=$_wholeFile (${pct(_wholeFile)})  network=$_origin (${pct(_origin)})  '
        '| downloads=$_downloads prefixes warmed=$_prefixWarmed '
        '(+tail $_tailWarmed) failed=$_prefixFailed$bailed  '
        '| ${_spares()}  '
        '| players retired=$_retired${_releasingNow()}'
        '${_firstFrames()}${_previews()}${_pipeline()}';
  }

  /// Spare tallies, one group per gesture, warm before cold.
  ///
  /// A lane with nothing in it is printed as `0/0` rather than left out.
  /// Absence is the answer worth seeing, and a missing line looks like no
  /// answer at all.
  ///
  /// The two lanes now count different moments, because they cost
  /// different things:
  ///
  ///   swipe — a player opened AHEAD of the gesture. Warm means its bytes
  ///           were already down when the read-ahead built it.
  ///   flip  — a player opened AT the gesture. Nothing is read ahead for
  ///           an opponent any more; holding a fourth decoder for a
  ///           gesture most battles never receive was getting decoders
  ///           reclaimed out from under the reels on screen. Warm means
  ///           the opponent's bytes were down by the time somebody
  ///           flipped, so the turn only had to build a decoder.
  ///
  /// So `flip 0/0` now means nobody flipped, which is ordinary. Cold
  /// flips are the fault worth chasing: the bytes are supposed to be
  /// warmed at position 2 of the read-ahead window, so a cold one says
  /// that window is not reaching opponents in time.
  String _spares() => SpareLane.values
      .map(
        (l) =>
            '${l.label} ${_spareWarm[l] ?? 0}/${_spareCold[l] ?? 0} warm/cold',
      )
      .join('  ');

  /// The pipeline snapshot, or nothing if no probe is installed.
  ///
  /// A probe that throws must not cost us the summary. The whole line is
  /// the only window into the cache during a profile run, and losing it to
  /// a fault in the observation code would be the same class of mistake as
  /// the one this file exists to fix.
  String _pipeline() {
    final probe = _pipelineProbe;
    if (probe == null) return '';
    try {
      return '  | ${probe()}';
    } catch (_) {
      return '  | pipeline unavailable';
    }
  }

  @visibleForTesting
  void debugReset() {
    _proxied = _wholeFile = _origin = 0;
    _downloads = 0;
    _prefixWarmed = _prefixFailed = _tailWarmed = 0;
    _prefixBailed.clear();
    _spareWarm.clear();
    _spareCold.clear();
    _retired = 0;
    _sinceSummary = 0;
    _changedSinceSummary = false;
    // A timer left behind holds the test isolate open and the run never
    // finishes. That reads as a broken test runner rather than as the leak
    // it is, so it gets cancelled here with everything else.
    _heartbeat?.cancel();
    _heartbeat = null;
    _heartbeatStarts = 0;
    _pipelineProbe = null;
    // The preview census too. A reset that leaves some counters behind is
    // worse than no reset: every test after the first reads numbers it did
    // not produce, and the failures point at the wrong code.
    _previewOpened = _previewReleased = _previewLive = _previewPeak = 0;
    _releasing = _releasingPeak = 0;
    _firstFrameWaits.clear();
  }

  /// How many timers this class has started. One, for a whole session.
  @visibleForTesting
  int get debugHeartbeatStarts => _heartbeatStarts;

  @visibleForTesting
  int get debugRetired => _retired;

  @visibleForTesting
  int debugSpareWarm(SpareLane lane) => _spareWarm[lane] ?? 0;

  @visibleForTesting
  int debugSpareCold(SpareLane lane) => _spareCold[lane] ?? 0;

  @visibleForTesting
  int get debugProxied => _proxied;
  @visibleForTesting
  int get debugWholeFile => _wholeFile;
  @visibleForTesting
  int get debugOrigin => _origin;

  /// Reels whose opening slice reached the proxy. Read against the
  /// cancelled tally: that pair is how warming is judged from a log, and
  /// the summary line only prints once a reel has actually started, so a
  /// test that wants the number has to ask for it.
  @visibleForTesting
  int get debugPrefixWarmed => _prefixWarmed;
}
