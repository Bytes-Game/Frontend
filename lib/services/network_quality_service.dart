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
  static const String reelsMaxLabel = '720p';

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
  }

  /// Measured bits per second, or null when there is not enough to say.
  ///
  /// The median rather than the average, because one download finishing
  /// against a warm CDN edge should not convince us the whole link is fast.
  int? get measuredBps {
    if (_throughputSamples.length < _minSamples) return null;
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
    String best = '480p';
    for (final entry in bitrateNeededFor.entries) {
      if (bps < entry.value * bitrateHeadroom) continue;
      if ((_labelRank[entry.key] ?? 0) > (_labelRank[best] ?? 0)) {
        best = entry.key;
      }
    }
    return best;
  }

  static const Map<String, int> _labelRank = {'480p': 0, '720p': 1, '1080p': 2};

  @visibleForTesting
  void debugClearThroughput() => _throughputSamples.clear();

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
    // Device ceiling — never offer above this on this device.
    //   < 3 GB  → 480p ceiling   (entry tier)
    //   < 5 GB  → 720p ceiling   (mid tier — most users)
    //   ≥ 5 GB  → 1080p          (flagship)
    final deviceCap = ramGb < 3.0
        ? '480p'
        : ramGb < 5.0
            ? '720p'
            : '1080p';

    const rank = {'480p': 0, '720p': 1, '1080p': 2};

    // Take the LOWER of the device ceiling and the caller's ceiling. The
    // device cap protects against OOM; the caller's cap reflects what is
    // worth decoding for the surface being rendered.
    var capRank = rank[deviceCap] ?? 2;
    final requested = rank[maxLabel];
    if (requested != null && requested < capRank) capRank = requested;

    List<String> trim(List<String> order) {
      return order
          .where((label) => (rank[label] ?? 99) <= capRank)
          .toList(growable: false);
    }

    switch (q) {
      case NetworkQuality.high:
        return trim(const ['1080p', '720p', '480p']);
      case NetworkQuality.medium:
      case NetworkQuality.unknown:
        return trim(const ['720p', '480p', '1080p']);
      case NetworkQuality.low:
        return trim(const ['480p', '720p', '1080p']);
    }
  }
}
