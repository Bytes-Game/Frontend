import 'package:flutter/foundation.dart';

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

  int _proxied = 0;
  int _wholeFile = 0;
  int _origin = 0;
  int _downloads = 0;
  int _prefixWarmed = 0;
  int _prefixFailed = 0;
  final Map<String, int> _prefixBailed = <String, int>{};
  int _spareWarm = 0;
  int _spareCold = 0;
  int _retired = 0;
  int _sinceSummary = 0;

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
  void recordSpareWarm() {
    if (!_visible) return;
    _spareWarm++;
  }

  /// The spare was opened before its slice arrived and went to the
  /// network. Some of these are unavoidable (first reel of a session, a
  /// genuinely slow connection); a high ratio means
  /// [VideoPlayerService.spareWarmGrace] is too short for real devices.
  void recordSpareCold() {
    if (!_visible) return;
    _spareCold++;
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
    if (++_sinceSummary >= _summaryEvery) {
      _sinceSummary = 0;
      log(summary());
    }
  }

  /// Current tallies. Also useful from a debugger or a test.
  String summary() {
    final starts = _proxied + _wholeFile + _origin;
    if (starts == 0) return 'no reels played yet';
    String pct(int n) => '${(n * 100 / starts).round()}%';
    final bailed = _prefixBailed.isEmpty
        ? ''
        : ' bailed{${_prefixBailed.entries.map((e) => '${e.key}:${e.value}').join(',')}}';
    return 'starts=$starts  proxy=$_proxied (${pct(_proxied)})  '
        'file=$_wholeFile (${pct(_wholeFile)})  network=$_origin (${pct(_origin)})  '
        '| downloads=$_downloads prefixes warmed=$_prefixWarmed '
        'failed=$_prefixFailed$bailed  '
        '| spare warm=$_spareWarm cold=$_spareCold '
        '| players retired=$_retired${_pipeline()}';
  }

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
    _prefixWarmed = _prefixFailed = 0;
    _prefixBailed.clear();
    _spareWarm = _spareCold = 0;
    _retired = 0;
    _sinceSummary = 0;
    _pipelineProbe = null;
  }

  @visibleForTesting
  int get debugRetired => _retired;

  @visibleForTesting
  int get debugSpareWarm => _spareWarm;

  @visibleForTesting
  int get debugSpareCold => _spareCold;

  @visibleForTesting
  int get debugProxied => _proxied;
  @visibleForTesting
  int get debugWholeFile => _wholeFile;
  @visibleForTesting
  int get debugOrigin => _origin;
}
