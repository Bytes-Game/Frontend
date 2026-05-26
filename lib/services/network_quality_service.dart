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
/// We do NOT do active bandwidth probing here. Probing burns data and
/// adds a delay before the first frame; the connectivity-type heuristic
/// is the right tradeoff for a reels app where time-to-first-frame is
/// the metric users actually feel.
class NetworkQualityService {
  NetworkQualityService._();
  static final NetworkQualityService instance = NetworkQualityService._();

  NetworkQuality _current = NetworkQuality.unknown;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  final _controller = StreamController<NetworkQuality>.broadcast();

  /// Current cached classification. Safe to call before [start].
  NetworkQuality get current => _current;

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
  String? pickVariantUrl(Map<String, String> variants) {
    if (variants.isEmpty) return null;
    final ramGb = DeviceCapabilities.instance.ramGb;
    final order = _preferenceOrder(_current, ramGb);
    for (final label in order) {
      final url = variants[label];
      if (url != null && url.isNotEmpty) return url;
    }
    // Last-resort: any variant we have.
    return variants.values.firstWhere(
      (s) => s.isNotEmpty,
      orElse: () => '',
    );
  }

  /// Preferred → fallback order for the current network and device.
  /// Device tier caps the maximum: low-RAM phones never get 1080p
  /// even on great wifi, because decoding it costs more Java heap than
  /// they can spare (MediaCodec frame queues scale with resolution²).
  List<String> _preferenceOrder(NetworkQuality q, double ramGb) {
    // Device ceiling — never offer above this on this device.
    //   < 3 GB  → 480p ceiling   (entry tier)
    //   < 5 GB  → 720p ceiling   (mid tier — most users)
    //   ≥ 5 GB  → 1080p          (flagship)
    final cap = ramGb < 3.0
        ? '480p'
        : ramGb < 5.0
            ? '720p'
            : '1080p';

    List<String> trim(List<String> order) {
      // Filter out anything higher than the device ceiling.
      const rank = {'480p': 0, '720p': 1, '1080p': 2};
      final capRank = rank[cap] ?? 2;
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
