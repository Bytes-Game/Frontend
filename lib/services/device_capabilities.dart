import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import 'package:myapp/services/video_player_service.dart';

/// Reads the device's physical RAM at startup and configures the video
/// player pool to match. The whole point: a Redmi with 2GB RAM
/// shouldn't try to keep 4 ExoPlayer instances alive (it'll get
/// OOM-killed), and a Galaxy S24 with 12GB shouldn't be capped at 4
/// when it could comfortably keep 8 warm for instant scroll in any
/// direction.
///
/// Detection is best-effort:
///   - Android: device_info_plus exposes physical RAM directly.
///   - iOS: device_info_plus does NOT expose RAM. iPhones since the
///     iPhone 8 (2017) all have ≥2GB, recent models 4-8GB. Assume
///     mid-tier (4GB).
///   - Web / desktop: we don't run the heavy reels feed on those
///     surfaces today, but if we ever do, default to mid-tier.
///
/// Any detection failure falls back to [VideoPoolConfig.fallback],
/// which matches the previous static behaviour — never worse than
/// before this service existed.
class DeviceCapabilities {
  DeviceCapabilities._();
  static final DeviceCapabilities instance = DeviceCapabilities._();

  /// Detected RAM in GB. Set by [probe]. Defaults to 4.0 (mid-tier)
  /// until probe completes. Exposed so other services can make their
  /// own tier-based choices (e.g. image cache size).
  double ramGb = 4.0;

  /// True once [probe] has resolved (success or fallback).
  bool _probed = false;
  bool get probed => _probed;

  /// Detect device RAM and configure [VideoPlayerService] accordingly.
  /// Idempotent — safe to call from main() and re-call from anywhere
  /// without re-probing.
  Future<void> probe() async {
    if (_probed) return;
    final detected = await _detectRamGb();
    if (detected != null) ramGb = detected;
    _probed = true;
    VideoPlayerService.instance.configure(VideoPoolConfig.forRam(ramGb));
    if (kDebugMode) {
      debugPrint(
        'DeviceCapabilities: detected ${ramGb.toStringAsFixed(1)}GB RAM '
        '→ pool ${VideoPlayerService.instance.config.maxPoolSize}, '
        'prefetch ${VideoPlayerService.instance.config.prefetchAhead}'
        ' (burst ${VideoPlayerService.instance.config.prefetchAheadBurst})',
      );
    }
  }

  Future<double?> _detectRamGb() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        // device_info_plus historically reports physicalRamSize in MB,
        // but different package versions have shipped KB or bytes.
        // Sanity-check the value against plausible phone-RAM ranges
        // (0.5 GB to 32 GB) so we don't get fooled by a unit mismatch.
        final raw = a.physicalRamSize;
        if (raw > 0) {
          final candidates = <double>[
            raw / 1024.0,                       // raw is MB
            raw / (1024.0 * 1024.0),            // raw is KB
            raw / (1024.0 * 1024.0 * 1024.0),   // raw is bytes
          ];
          for (final gb in candidates) {
            if (gb >= 0.5 && gb <= 32) return gb;
          }
        }
        // physicalRamSize returned something nonsensical — fall back
        // to API-level-based heuristic so we still tier roughly. New
        // Android versions only run on devices with ≥2GB.
        if (a.version.sdkInt >= 33) return 6.0; // Android 13+ flagships
        if (a.version.sdkInt >= 29) return 4.0; // Android 10+
        return 2.0;                              // older
      }
      if (Platform.isIOS) {
        // device_info_plus's IosDeviceInfo doesn't expose RAM. Use
        // the model identifier to bucket. The list is long; instead
        // of maintaining it, bias by major iPhone era:
        //   utsname.machine "iPhone14,2" → iPhone 13 Pro (6GB)
        //   "iPhone15,*" → iPhone 14 series (6GB)
        //   "iPhone16,*" → iPhone 15 series (6-8GB)
        // For unknown / older, assume 4GB — the floor since iPhone XS.
        final i = await info.iosInfo;
        final m = i.utsname.machine; // e.g. "iPhone15,2"
        final match = RegExp(r'iPhone(\d+),').firstMatch(m);
        if (match != null) {
          final gen = int.tryParse(match.group(1) ?? '') ?? 0;
          if (gen >= 16) return 8.0; // iPhone 15 Pro / 16 series
          if (gen >= 14) return 6.0; // iPhone 13 / 14
          if (gen >= 11) return 4.0; // iPhone XS / 11 / 12
          return 2.0;                // very old (rare)
        }
        return 4.0;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceCapabilities probe error: $e');
    }
    // Web / desktop / detection failure → null means use the fallback
    // config the service already starts with.
    return null;
  }
}
