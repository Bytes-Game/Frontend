import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:myapp/services/device_capabilities.dart';

/// Coarse classification of the user's connection. We deliberately
/// avoid finer buckets — anything more granular gets routed to the
/// same variant URL anyway, so the extra precision is wasted.
enum NetworkQuality {
  /// Wifi or wired Ethernet. Assume real bandwidth, ship the highest
  /// variant we have.
  high,

  /// 4G/LTE. Plenty for 720p reels but flaky enough that 1080p can
  /// stall on the first chunk.
  medium,

  /// 3G or worse, or a flaky/saturated cellular link (RTT spikes,
  /// retries climbing). Always start with the lightest variant so the
  /// reel actually plays — users abandon a feed long before they care
  /// that the resolution was 480p.
  low,

  /// We genuinely don't know yet (still booting, or the OS hasn't
  /// reported). Treat as medium — it's the safest pick: high enough
  /// quality to not be insulting, low enough to not stall.
  unknown,
}

/// NetworkQualityService is the single place anything in the app asks
/// "what variant should I play right now?". It keeps a cached value so
/// the answer is constant-time on the hot path (reel scroll), and
/// updates that cache when [connectivity_plus] reports a change.
///
/// We do NOT do ACTIVE bandwidth probing here — a speed test burns data and
/// delays the first frame, which is the thing viewers actually feel.
///
/// We do measure passively, which costs neither. Warming a reel already
/// downloads a fixed slice and already knows how long it took, so every
/// warmed reel is a free reading of the real link. See [recordThroughput].
/// The connection TYPE still decides how much to read ahead; the measured
/// speed decides which quality is safe to play.
class NetworkQualityService {
  NetworkQualityService._();
  static final NetworkQualityService instance = NetworkQualityService._();

  NetworkQuality _current = NetworkQuality.unknown;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final _controller = StreamController<NetworkQuality>.broadcast();

  /// Current cached classification. Safe to call before [start].
  NetworkQuality get current => _current;

  /// Force the classification. Tests need this because the 1080p problem
  /// only appears on a HIGH-quality link — on `unknown` the preference
  /// order already puts 720p first, so a cap test that doesn't set this
  /// passes whether or not the cap exists.
  @visibleForTesting
  void debugSetQuality(NetworkQuality q) => _current = q;

  /// Hot stream of changes. UI can listen and animate transitions
  /// (e.g. re-pick a higher variant when wifi reconnects mid-feed).
  Stream<NetworkQuality> get stream => _controller.stream;

  /// Initialize the listener. Idempotent — safe to call from main()
  /// and again from screens that need a guaranteed-live value.
  Future<void> start() async {
    if (_sub != null) return;
    final c = Connectivity();
    try {
      final initial = await c.checkConnectivity();
      _apply(initial);
    } catch (e) {
      if (kDebugMode) debugPrint('connectivity probe failed: $e');
    }
    _sub = c.onConnectivityChanged.listen(_apply, onError: (Object e) {
      if (kDebugMode) debugPrint('connectivity stream error: $e');
    });
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _controller.close();
  }

  void _apply(List<ConnectivityResult> results) {
    final next = _classify(results);
    if (next == _current) return;
    _current = next;
    _controller.add(next);
  }

  NetworkQuality _classify(List<ConnectivityResult> results) {
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      // No connection — pick low so we don't even try to load 1080p
      // when the call comes back online.
      return NetworkQuality.low;
    }
    // connectivity_plus may report multiple active interfaces; rank
    // them and pick the best.
    var best = NetworkQuality.unknown;
    for (final r in results) {
      final q = _qualityFor(r);
      if (_priority(q) > _priority(best)) best = q;
    }
    return best;
  }

  NetworkQuality _qualityFor(ConnectivityResult r) {
    switch (r) {
      case ConnectivityResult.wifi:
      case ConnectivityResult.ethernet:
        return NetworkQuality.high;
      case ConnectivityResult.mobile:
        // We can't tell 5G from 3G via connectivity_plus alone — Android
        // exposes it but iOS doesn't. Assume medium for any cellular
        // link; the player will downgrade further if first-chunk
        // latency is bad.
        return NetworkQuality.medium;
      case ConnectivityResult.vpn:
      case ConnectivityResult.bluetooth:
      case ConnectivityResult.other:
        return NetworkQuality.medium;
      case ConnectivityResult.satellite:
        // Starlink-class links are bursty but generally OK for 720p; we
        // pick medium so first-frame latency stays reasonable instead of
        // gambling on 1080p.
        return NetworkQuality.medium;
      case ConnectivityResult.none:
        return NetworkQuality.low;
    }
  }

  int _priority(NetworkQuality q) {
    switch (q) {
      case NetworkQuality.high:
        return 3;
      case NetworkQuality.medium:
        return 2;
      case NetworkQuality.unknown:
        return 1;
      case NetworkQuality.low:
        return 0;
    }
  }

  /// Pick the best variant URL we have for the current network AND
  /// device tier. Network sets the upper bound by bandwidth; device RAM
  /// sets the upper bound by Java-heap MediaCodec footprint. The picker
  /// takes the *lower* of the two ceilings, so a 2GB phone on wifi
  /// still gets 480p rather than OOM-ing on 1080p.
  ///
  /// `variants` comes straight off ChallengeModel.videoVariants. If
  /// it's empty (legacy challenge created before multi-bitrate landed)
  /// the caller should fall back to ChallengeModel.videoUrl — we
  /// signal that by returning null.
  /// Hard ceiling for the reels feed, independent of RAM or bandwidth.
  ///
  /// The RAM tiers below answer "what can this device survive decoding?".
  /// That is the wrong question for a full-screen vertical reel, where
  /// the right question is "what can the viewer actually SEE?" — and on
  /// a phone the answer is nothing above 720p. A 7.1 GB device was
  /// therefore picking 1080p on wifi and paying roughly double the
  /// decode cost for pixels that never reach the eye; device logs showed
  /// 1920x1080 decoder sessions and render intervals in the seconds.
  ///
  /// Surfaces where the extra detail is genuinely visible (a full-screen
  /// detail view on a tablet, say) can pass a higher [maxLabel].
  /// The highest rung a reel may use. 720p_hq rather than 720p: both are the
  /// same 1280-wide picture, and this cap exists to keep 1920-wide video off
  /// phone screens, not to cap how many bits a 1280-wide one may spend.
  static const String reelsMaxLabel = '720p_hq';

  /// The highest rung to hand out while the link has NEVER been measured.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// THE APP USED TO ASSUME THE BEST CASE AND FIND OUT LATER
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// A feed page arrives with twenty items and every one is assigned a
  /// rendition the moment it is parsed — before a single byte has been
  /// downloaded, so before anything has been measured. With nothing
  /// measured the ceiling stayed at [reelsMaxLabel] and the preference
  /// order for an unknown connection starts at 720p_hq, so the whole first
  /// page was committed to the LARGEST files on no evidence at all.
  ///
  /// From a device log, a single session:
  ///
  ///     quality{720p_hq:19 ... link=measuring}      <- first page
  ///     quality{720p_hq:19 ... link=5.5Mbps affords=720p}
  ///     quality{720p_hq:19 ... link=4.0Mbps affords=480p}
  ///     quality{720p_hq:19 ... link=2.9Mbps affords=480p}
  ///
  /// Nineteen reels were served at the top rung while blind, and then the
  /// count NEVER MOVED AGAIN across seventy more picks: once it could
  /// measure, the app decided this link could not carry 720p_hq even once.
  /// It took nineteen reels to find that out, and those nineteen are the
  /// ones that stalled — every cold open in that session landed in the
  /// first fifty reels, and the last forty swipes had none at all.
  ///
  /// So: start low and let evidence raise it, which is what every adaptive
  /// player does. The cost is a softer picture for the first few reels of a
  /// first-ever run; the benefit is that they play.
  static const String unmeasuredMaxLabel = '480p';

  // ══════════════════════════════════════════════════════════════════════
  // HOW FAST THE CONNECTION ACTUALLY IS
  // ══════════════════════════════════════════════════════════════════════
  //
  // Everything above this point answers "what KIND of connection is this?"
  // — wifi, mobile, none. That is not the same question as "can it carry
  // this video", and treating it as though it were is what made reels
  // freeze.
  //
  // A device log made the gap plain. 96% of reels started instantly from
  // cache, the download queue was empty and every slot idle, and the
  // decoder still ran dry 394 times across 160 reels. Nothing was
  // competing for the connection. The connection just could not carry a
  // 3.5 Mbps video, and the app had no way to find that out: it saw wifi,
  // called it fast, and served 720p to something that could not stream it.
  //
  // The comment on the cellular branch above already promised "the player
  // will downgrade further if first-chunk latency is bad". Nothing ever
  // did. This is that.
  //
  // The measurement is free. Warming a reel already downloads a fixed
  // slice and already knows how long it took, so every warmed reel is a
  // throughput sample of exactly the thing we care about — this phone,
  // this network, this CDN, right now — rather than a guess from the
  // interface type.

  /// Sustained bits per second each rendition needs, from what the server
  /// actually encodes to. Kept next to the labels so the two move together.
  static const Map<String, int> bitrateNeededFor = <String, int>{
    '480p': 1500000,
    '720p': 2500000,
    '720p_hq': 3500000,
    '1080p': 6000000,
  };

  /// How much faster than the file's own bitrate the link has to be before
  /// we will choose it.
  ///
  /// Streaming at exactly the file's rate leaves nothing for a slow moment,
  /// and a reel only has to fall behind once to visibly stop. A third again
  /// is enough to ride out normal variation without being so cautious that
  /// good connections get a soft picture.
  static const double bitrateHeadroom = 1.3;

  /// How long a reel is typically on screen before the next swipe.
  ///
  /// Only used to work out how fast read-ahead has to run to keep up. It is
  /// a property of how people use a short-video feed, not of this app, and
  /// six seconds is deliberately on the short side: guessing too short
  /// reserves a little too much bandwidth, guessing too long reserves too
  /// little and the reserve stops doing its job.
  static const double typicalDwellSeconds = 6;

  /// Bandwidth held back from the picture, so the NEXT reel can be fetched
  /// while this one plays.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY A LINK IS NOT ALL FOR THE VIDEO ON SCREEN
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// This used to compare a rendition's bitrate against the whole link. The
  /// link has two consumers, not one: the reel playing now, and the reels
  /// being warmed for the swipe that is about to happen. Spending it all on
  /// the first starves the second, and a feed whose next reel is never ready
  /// is a feed that stops on every swipe.
  ///
  /// Measured on a device at 3.3 Mbps, before this existed:
  ///
  ///   reel 30    93% of starts warm    28 warms finished     7 cancelled
  ///   reel 80    54% of starts warm    32 warms finished    60 cancelled
  ///
  /// Fifty reels apart. In between it started sixty-one more downloads and
  /// finished four. The app had decided 3.3 Mbps affords 720p, which costs
  /// 2.5 Mbps to play, leaving 0.8 Mbps for read-ahead — and reading ahead
  /// six reels needs about 9 MB, which at 0.8 Mbps takes a minute and a
  /// half. The user crosses six reels in fifteen seconds. The window could
  /// never fill, and every swipe cancelled what was in flight.
  ///
  /// So the reserve is what read-ahead actually costs: one reel's opening
  /// slice per reel watched. VideoCacheService.prefixBytes over
  /// [typicalDwellSeconds], which is 1 Mbps at today's 768 KB slice. A test
  /// keeps the two tied together, because raising the slice without raising
  /// this would quietly put the starvation back.
  ///
  /// The trade is deliberate and it is the one TikTok makes: a slightly
  /// softer picture that starts the instant you swipe beats a sharper one
  /// that makes you wait. On a link with room to spare nothing changes —
  /// the reserve is a rounding error against 10 Mbps and the best rendition
  /// is still chosen.
  static const int readAheadReserveBps = 1048576;

  /// Recent throughput samples in bits per second, newest last.
  final List<int> _throughputSamples = <int>[];

  /// Enough samples to trust the answer. Below this the connection type is
  /// still the best guess available — one slow download is a slow download,
  /// not a slow network.
  static const int _minSamples = 3;

  /// How many samples to keep. Short enough to follow someone walking out
  /// of wifi range, long enough that a single stall does not redefine the
  /// connection.
  static const int _maxSamples = 8;

  /// Record how fast a real download went. Called by the warming pipeline,
  /// which is doing this work anyway.
  ///
  /// Tiny or instant downloads are dropped rather than recorded: a slice
  /// served from a local buffer can look like a gigabit link and would drag
  /// the median somewhere no real network lives.
  void recordThroughput(int bytes, Duration elapsed) {
    if (bytes < 64 * 1024) return;
    final ms = elapsed.inMilliseconds;
    if (ms < 50) return;
    _throughputSamples.add((bytes * 8 * 1000) ~/ ms);
    if (_throughputSamples.length > _maxSamples) {
      _throughputSamples.removeAt(0);
    }
    _offerToRemember();
  }

  /// Hand the current reading to whoever is keeping it for the next run.
  ///
  /// Only when it has actually MOVED — first time it is known, and after
  /// that only on a change of more than a fifth. A reading that wobbles by
  /// a few percent between downloads is the same reading, and rewriting the
  /// file for each one would be a disk write per video for a number nobody
  /// reads until the next launch.
  void _offerToRemember() {
    final worth = bpsWorthRemembering;
    if (worth == null) return;
    final prev = _lastOffered;
    if (prev != null && (worth - prev).abs() <= prev ~/ 5) return;
    _lastOffered = worth;
    onSpeedSettled?.call(worth);
  }

  int? _lastOffered;

  /// Where a settled reading goes so the next run can open on it. Wired in
  /// main(); left null in tests, which is why this service still has no
  /// opinion about files.
  static void Function(int bps)? onSpeedSettled;

  /// What the link measured LAST time the app ran, if anything.
  ///
  /// Samples live in memory, so before this every launch started blind and
  /// paid the cold start above all over again — the same nineteen reels at
  /// the wrong rendition, every single time the app was opened. A phone's
  /// connection is not usually a different connection between launches, so
  /// last time's answer is a far better opening guess than no answer.
  ///
  /// It is only a fallback: the moment this run has [_minSamples] real
  /// readings of its own they win outright, so moving from wifi to cellular
  /// corrects itself within a few downloads rather than being believed for
  /// the session.
  int? _rememberedBps;

  /// Seed the opening guess from a previous run. Idempotent; ignored once
  /// this run has measured anything itself.
  void restoreRememberedBps(int? bps) {
    if (bps == null || bps <= 0) return;
    _rememberedBps = bps;
  }

  /// What to hand the store, or null when this run has nothing worth
  /// keeping. Deliberately the LIVE reading only — writing the remembered
  /// value back would let one unusual session pin the guess for ever.
  int? get bpsWorthRemembering =>
      _throughputSamples.length >= _minSamples ? measuredBps : null;

  /// Measured bits per second, or null when nothing — this run or any
  /// previous one — has anything to say.
  ///
  /// The median rather than the average, because one download finishing
  /// against a warm CDN edge should not convince us the whole link is fast.
  int? get measuredBps {
    if (_throughputSamples.length < _minSamples) return _rememberedBps;
    final sorted = List<int>.from(_throughputSamples)..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// The best rendition this connection can actually carry, or null when we
  /// have not measured enough to have an opinion.
  ///
  /// Never returns nothing: if even the smallest rendition is beyond the
  /// link, that is still the one to serve — a soft picture that plays beats
  /// a sharp one that stops.
  String? get affordableLabel {
    final bps = measuredBps;
    if (bps == null) return null;
    // What is left for the picture once read-ahead has been paid for. It can
    // go negative on a very slow link, in which case nothing qualifies and
    // the floor below applies — which is right: a soft picture that plays
    // still beats a sharp one that stops.
    final forPicture = bps - readAheadReserveBps;
    String best = '480p';
    for (final entry in bitrateNeededFor.entries) {
      if (forPicture < entry.value * bitrateHeadroom) continue;
      if ((_labelRank[entry.key] ?? 0) > (_labelRank[best] ?? 0)) {
        best = entry.key;
      }
    }
    return best;
  }

  /// Bits per second left over for reading ahead, once the reel on screen
  /// has been paid for. Null while there is not enough measurement to say.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THIS IS NOT JUST [readAheadReserveBps]
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// [readAheadReserveBps] is a FLOOR. It is bandwidth the quality picker
  /// refuses to spend on the picture, so that read-ahead always has
  /// something. It is not what read-ahead actually gets — on a link with
  /// room to spare, read-ahead gets the floor plus everything the picture
  /// did not use.
  ///
  /// This is the real figure: what is measured, minus what the reel on
  /// screen actually costs.
  ///
  /// It subtracts the rendition's own bitrate, NOT the bitrate times
  /// [bitrateHeadroom]. The headroom is how much faster the link has to be
  /// before we will PICK a rendition; it is not bandwidth the rendition
  /// spends. Subtracting it here would charge read-ahead for a margin
  /// nobody consumes, and understate the spare by a third of the picture —
  /// most of a reel's worth per swipe at 720p.
  ///
  /// Capped at [reelsMaxLabel], because that is the ceiling the feed
  /// actually asks for. Without the cap, a fast link would be charged for
  /// a 1080p reel the feed will never request.
  ///
  /// Never negative. On a link too slow for even the smallest rendition
  /// the honest answer is "nothing spare", not a negative budget.
  int? get spareBpsForReadAhead {
    final bps = measuredBps;
    if (bps == null) return null;
    var label = affordableLabel ?? reelsMaxLabel;
    final cap = _labelRank[reelsMaxLabel] ?? 2;
    if ((_labelRank[label] ?? 0) > cap) label = reelsMaxLabel;
    final picture = bitrateNeededFor[label] ?? bitrateNeededFor[reelsMaxLabel]!;
    final spare = bps - picture;
    return spare < 0 ? 0 : spare;
  }

  /// Quality order — how good each rendition looks, and so which one to
  /// prefer. Not the same as how hard it is to DECODE: 720p_hq is the same
  /// 1280-wide picture as 720p with more bits spent on it, so it ranks higher
  /// here and identically for decode cost. See _preferenceOrder.
  static const Map<String, int> _labelRank = {
    '480p': 0,
    '720p': 1,
    '720p_hq': 2,
    '1080p': 3,
  };

  /// The label a video of this picture size belongs under.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THIS EXISTS AT ALL
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// The upload path used to tag every video it sent as `720p` with a comment
  /// saying the label was cosmetic. It was, once — nothing read it. It is not
  /// any more: [pickVariantUrl] decides what this connection can carry by
  /// looking the label up in [bitrateNeededFor], so `720p` is now a claim
  /// that the file costs about 2.5 Mbps.
  ///
  /// A phone that recorded 1080p therefore uploaded a file the app would go
  /// on to treat as a modest 720p one — and so never stepped down from,
  /// however badly it was coping. The server overwrites the label with a real
  /// rendition once it has converted the video, so the wrong answer only
  /// stood between upload and conversion. That is exactly the window in which
  /// somebody watches their own upload back.
  ///
  /// Measuring costs nothing: the uploader already reads the file's size to
  /// build a thumbnail.
  ///
  /// The boundaries match the server's ladder (cmd/hls-worker/progressive.go)
  /// — the smallest rung whose picture is not smaller than this one.
  /// The bitrate to expect from a variant URL, or null if it is not one of
  /// ours.
  ///
  /// The worker names each rendition after its label — 480p.mp4, 720p.mp4,
  /// 720p_hq.mp4 — and that is already what videoVariants is keyed by, so the
  /// name is a claim about the bitrate the same way the label is. This reads
  /// it back for the one caller that has a URL and no label: the cache,
  /// deciding how much of a file is enough to start playing.
  ///
  /// Null for a raw upload or anything else unrecognised. The caller decides
  /// what to assume, and should assume the worst — a file whose bitrate we do
  /// not know could be anything, and guessing low means starting too early
  /// and stalling.
  static int? bitrateForVariantUrl(String url) {
    if (url.isEmpty) return null;
    var path = url;
    final q = path.indexOf('?');
    if (q >= 0) path = path.substring(0, q);
    final slash = path.lastIndexOf('/');
    var name = slash >= 0 ? path.substring(slash + 1) : path;
    if (!name.endsWith('.mp4')) return null;
    name = name.substring(0, name.length - 4);
    return bitrateNeededFor[name];
  }

  static String labelForLongSide(int longSide) {
    if (longSide <= 0) return '720p'; // unmeasurable: the old default
    if (longSide <= 854) return '480p';
    if (longSide <= 1280) return '720p';
    return '1080p';
  }

  @visibleForTesting
  void debugClearThroughput() {
    _throughputSamples.clear();
    // The remembered reading and the last one offered are part of "what
    // this service believes about the link". Leaving them behind means a
    // test that asks for a blind service does not get one, and the blind
    // case is the whole reason any of this exists.
    _rememberedBps = null;
    _lastOffered = null;
  }

  /// Renditions already chosen, keyed by whatever the caller calls a video.
  ///
  /// Capped, and oldest-first, because a long session scrolls past far more
  /// videos than it will ever come back to.
  final Map<String, String> _chosenFor = {};

  /// How many choices to remember. A URL per video is tens of bytes, and a
  /// feed session that revisits something five hundred videds ago is not a
  /// session anyone has.
  static const int _chosenMemory = 500;

  /// Pick a rendition for [key] and KEEP that choice for the session.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THE CHOICE HAS TO STICK
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// [pickVariantUrl] answers for the link as it is right now, and the link
  /// moves. Measured in one session:
  ///
  ///	link=5.9Mbps  affords=720p_hq
  ///	link=2.9Mbps  affords=480p
  ///	link=3.7Mbps  affords=480p
  ///
  /// The feed re-parses the same videos constantly — the server deliberately
  /// re-sends them, `repeat=20` of 20 on most pages — and every re-parse
  /// asked again. So one video would be warmed as 720p_hq and, minutes
  /// later, opened as 480p: a different file, with none of it on disk.
  ///
  /// The arithmetic in the same session says exactly that. 67 distinct URLs
  /// were warmed out of a catalogue of 56 videos, so at least eleven videos
  /// were fetched under TWO addresses. And warming pulled away from
  /// playback as it went:
  ///
  ///	starts=50  warmed=40  served from cache=30
  ///	starts=60  warmed=51  served from cache=32
  ///
  /// Eleven more videos warmed, two more used.
  ///
  /// So a video keeps the rendition it was first given. The cost is a
  /// slightly soft picture if the link improves a lot while someone is
  /// still scrolling; the thing it buys is that the bytes fetched for a
  /// video are the bytes that video is opened with. A stall is far more
  /// noticeable than a rung of quality, and videos entering the feed for
  /// the first time still get the current answer.
  String? stickyVariantUrl(String key, Map<String, String> variants,
      {String? maxLabel = reelsMaxLabel}) {
    // One guard, checked once. An earlier version tested the key on the way
    // in AND on the way out, which reads as careful and is not: with the
    // read guarded, the write guard could never change what any caller saw,
    // so deleting it broke nothing and no test could notice.
    if (key.isEmpty) return pickVariantUrl(variants, maxLabel: maxLabel);

    final already = _chosenFor[key];
    if (already != null) return already;

    final picked = pickVariantUrl(variants, maxLabel: maxLabel);
    if (picked != null && picked.isNotEmpty) {
      if (_chosenFor.length >= _chosenMemory) {
        _chosenFor.remove(_chosenFor.keys.first);
      }
      _chosenFor[key] = picked;
    }
    return picked;
  }

  @visibleForTesting
  void debugClearChosenVariants() => _chosenFor.clear();

  String? pickVariantUrl(Map<String, String> variants,
      {String? maxLabel = reelsMaxLabel}) {
    if (variants.isEmpty) {
      _countPick('none');
      return null;
    }
    final ramGb = DeviceCapabilities.instance.ramGb;
    // Take the lower of what the caller asked for and what the link has
    // actually been managing. Before this, the ceiling came only from the
    // connection TYPE, so a slow wifi was handed 720p and starved on it.
    var ceiling = maxLabel;
    final affordable = affordableLabel;
    if (affordable != null) {
      final asked = _labelRank[ceiling ?? reelsMaxLabel] ?? 2;
      if ((_labelRank[affordable] ?? 0) < asked) ceiling = affordable;
    } else if (maxLabel == reelsMaxLabel) {
      // Nothing measured, this run or any previous one. Open low rather
      // than assuming the best case — see [unmeasuredMaxLabel] for what
      // assuming the best case cost.
      //
      // Only on the REEL path. A caller that passed its own ceiling has
      // asked for something specific — a full-screen detail view on a
      // tablet is the case this exists for — and overriding that with a
      // cautious default would make the opt-out do nothing. The cold start
      // being fixed here is the feed's: twenty items committed at once, on
      // a fast scroll, before a byte has been measured. A detail view is
      // one video that somebody chose to open.
      if ((_labelRank[unmeasuredMaxLabel] ?? 0) <
          (_labelRank[ceiling ?? reelsMaxLabel] ?? 2)) {
        ceiling = unmeasuredMaxLabel;
      }
    }
    final order = _preferenceOrder(_current, ramGb, ceiling);
    for (final label in order) {
      final url = variants[label];
      if (url != null && url.isNotEmpty) {
        _countPick(label);
        return url;
      }
    }
    // Last-resort: any variant we have.
    _countPick('other');
    return variants.values.firstWhere(
      (s) => s.isNotEmpty,
      orElse: () => '',
    );
  }

  /// How many reels were served at each quality, this run.
  ///
  /// This exists because "the video looks soft" and "the video keeps
  /// stopping" are reported the same way by a viewer, and until now nothing
  /// said which rendition was actually on screen. Two different faults —
  /// being handed 480p when 720p exists, versus being handed 720p and
  /// stalling through it — were indistinguishable in a device log, so
  /// neither could be ruled out.
  ///
  /// `none` counts reels with no rendition map at all, which fall back to
  /// the original upload. That is not a fault: the server deliberately makes
  /// no renditions for a video already inside its quality ceiling.
  static final Map<String, int> variantPicks = <String, int>{};

  void _countPick(String label) {
    variantPicks[label] = (variantPicks[label] ?? 0) + 1;
  }

  /// Compact "480p:3 720p:17" for a log line, or empty when nothing has been
  /// picked yet. Ends with the measured link speed and the best rendition it
  /// can carry, so a log says WHY a quality was chosen and not just which.
  static String variantPicksSummary() {
    final parts = variantPicks.entries.map((e) => '${e.key}:${e.value}').toList();
    final bps = instance.measuredBps;
    if (bps == null) {
      parts.add('link=measuring');
    } else {
      parts.add('link=${(bps / 1e6).toStringAsFixed(1)}Mbps');
      parts.add('affords=${instance.affordableLabel}');
    }
    return parts.join(' ');
  }

  /// Preferred → fallback order for the current network and device.
  /// Device tier caps the maximum: low-RAM phones never get 1080p
  /// even on great wifi, because decoding it costs more Java heap than
  /// they can spare (MediaCodec frame queues scale with resolution²).
  List<String> _preferenceOrder(
      NetworkQuality q, double ramGb, String? maxLabel) {
    // What a phone can DECODE follows the number of pixels, and nothing else.
    //   < 3 GB  → 854 wide   (entry tier)
    //   < 5 GB  → 1280 wide  (mid tier — most users)
    //   ≥ 5 GB  → 1920 wide  (flagship)
    //
    // 720p_hq sits at 1 here, the same as 720p, because it IS 720p — the same
    // 1280-wide picture with more bits spent on it. A phone that can decode
    // one can decode the other. Ranking it above 720p here would have hidden
    // it from every mid-range phone, which is most of them, for a cost it does
    // not actually impose.
    const decodeRank = {'480p': 0, '720p': 1, '720p_hq': 1, '1080p': 2};
    final deviceCapRank = ramGb < 3.0
        ? 0
        : ramGb < 5.0
            ? 1
            : 2;

    // What a CONNECTION can carry is the other ceiling, and it is the one that
    // separates the two 720p rungs. It arrives as maxLabel, already lowered by
    // the measured link speed — see pickVariantUrl.
    final requested = _labelRank[maxLabel];

    List<String> trim(List<String> order) {
      return order.where((label) {
        if ((decodeRank[label] ?? 99) > deviceCapRank) return false;
        if (requested != null && (_labelRank[label] ?? 99) > requested) {
          return false;
        }
        return true;
      }).toList(growable: false);
    }

    switch (q) {
      case NetworkQuality.high:
        return trim(const ['1080p', '720p_hq', '720p', '480p']);
      case NetworkQuality.medium:
      case NetworkQuality.unknown:
        return trim(const ['720p_hq', '720p', '480p', '1080p']);
      case NetworkQuality.low:
        return trim(const ['480p', '720p', '720p_hq', '1080p']);
    }
  }
}
