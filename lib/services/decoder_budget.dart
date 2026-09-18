import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the chip says about how many H.264 videos it will decode at once.
///
/// ══════════════════════════════════════════════════════════════════════════
/// WHY THIS IS ONLY A READING, AND NOT YET A DECISION
/// ══════════════════════════════════════════════════════════════════════════
///
/// The app keeps several videos open so a swipe lands on one already playing.
/// How many it MAY keep is a property of the chip, not of memory, and nothing
/// tells the app up front: it assumes four for every phone and finds out it
/// was wrong only when a request is refused, or a decoder is taken back
/// mid-playback, which the viewer sees as a frozen video.
///
/// So this asks. It does not yet act on the answer, and that is deliberate:
///
///   * [VideoPlayerService.maxConcurrentDecoders] carries a written-down
///     account of a release where the pool was dropped below what the screen
///     needs. It did not reduce live decoders. The screen asks for the same
///     players either way; a smaller pool only recycles them faster — "40
///     player opens and 37 retirements for 14 distinct videos". Fewer live
///     decoders has to come from asking for FEWER PLAYERS, not from a cap
///     underneath the demand. So the obvious policy is already known to be
///     wrong, and shipping it again on a phone nobody has measured would be
///     repeating a documented mistake.
///
///   * Nobody has seen what any phone answers here. Not this one. Designing
///     a policy against a number that has never been read is the guessing
///     that two counters in this app have already had to correct.
///
/// The reading goes into the log. Once there are real numbers — especially
/// from a cheap phone — the policy can be designed against them.
class DecoderBudget {
  DecoderBudget._();
  static final DecoderBudget instance = DecoderBudget._();

  static const MethodChannel _channel = MethodChannel('devf/device_media');

  /// Each H.264 decoder this phone carries, and how many instances it says
  /// it will run. Empty when the question could not be asked — an old
  /// Android, a platform that is not Android, or a codec list that would not
  /// enumerate.
  Map<String, int> instancesByCodec = const {};

  /// True once [probe] has finished, successfully or not.
  bool probed = false;

  /// What actually binds: the smallest count among the chip's OWN decoders.
  ///
  /// Android's software fallback reports a generous number because software
  /// decoding is limited by the processor rather than by fixed hardware. It
  /// is also far too slow for this feed. Counting it would report that
  /// generosity as though the chip had it, which is the opposite of useful on
  /// the phones this is for.
  ///
  /// Null when nothing was read, or when the only decoders present are
  /// software ones.
  int? get hardwareBudget {
    final hw = instancesByCodec.entries
        .where((e) => !isSoftware(e.key))
        .map((e) => e.value)
        .where((n) => n > 0);
    if (hw.isEmpty) return null;
    return hw.reduce((a, b) => a < b ? a : b);
  }

  /// Whether a codec name belongs to a software decoder.
  ///
  /// Android's own are named by convention: `c2.android.*` for the Codec2
  /// generation and `OMX.google.*` for the one before it. Everything else is
  /// the vendor's, which is the hardware. `isHardwareAccelerated()` would say
  /// this directly but only arrived in API 29, and the phones that matter
  /// most here are the old ones.
  static bool isSoftware(String codecName) {
    final n = codecName.toLowerCase();
    // `.sw` is a suffix on some vendor builds and a segment on others, so it
    // has to be matched both ways. Checking only for '.sw.' misses
    // `OMX.qcom.video.decoder.avc.sw`, which is a software decoder reporting
    // a software decoder's generous instance count.
    return n.startsWith('c2.android.') ||
        n.startsWith('omx.google.') ||
        n.endsWith('.sw') ||
        n.contains('.sw.');
  }

  /// Whether this platform can be asked at all. A seam, so the asking can
  /// be tested: the answer only exists on Android, and a test host is not
  /// one.
  @visibleForTesting
  static bool Function() canAsk = () => Platform.isAndroid;

  /// Ask the phone. Idempotent; safe to call from main().
  Future<void> probe() async {
    if (probed) return;
    probed = true;
    if (!canAsk()) return;
    try {
      final raw = await _channel
          .invokeMapMethod<String, int>('videoDecoderInstances');
      if (raw == null || raw.isEmpty) return;
      instancesByCodec = Map.unmodifiable(raw);
    } catch (e) {
      // A phone that will not answer keeps the behaviour it already had.
      if (kDebugMode) debugPrint('decoder budget probe failed: $e');
    }
  }

  /// One line for the log: every reading, and which one binds.
  ///
  /// Empty when nothing was read, so a platform that cannot answer does not
  /// carry a row of nothing through the one line that gets read.
  String summary() {
    if (instancesByCodec.isEmpty) return '';
    final parts = instancesByCodec.entries.map((e) =>
        '${e.key}${DecoderBudget.isSoftware(e.key) ? '(sw)' : ''}=${e.value}');
    final hw = hardwareBudget;
    return 'decoders{${parts.join(' ')}}'
        '${hw == null ? '' : ' hardware=$hw'}';
  }

  @visibleForTesting
  void debugSet(Map<String, int> value) {
    instancesByCodec = Map.unmodifiable(value);
    probed = true;
  }

  @visibleForTesting
  void debugReset() {
    instancesByCodec = const {};
    probed = false;
  }
}
