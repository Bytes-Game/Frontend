import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the chip says about how many H.264 videos it will decode at once.
///
/// The app keeps several videos open so a swipe lands on one already playing.
/// How many it MAY keep is a property of the chip, not of memory, and nothing
/// tells the app up front: it used to assume four for every phone and find out
/// it was wrong only when a request was refused, or a decoder was taken back
/// mid-playback, which the viewer sees as a frozen video.
///
/// So this asks, and [VideoPoolConfig.workingSetFor] sizes the feed by the
/// answer. Two things about how it is used are worth keeping in view, because
/// both are mistakes this repo has already made once:
///
///   * It lowers DEMAND, not the cap. [VideoPlayerService.maxConcurrentDecoders]
///     carries the account of a release that lowered the pool and changed
///     nothing — the screen asked for the same players either way, so the same
///     number were alive AND one was thrown away on every swipe: "40 player
///     opens and 37 retirements for 14 distinct videos". Fewer live decoders
///     has to come from asking for fewer players. So what the budget moves is
///     prefetchAhead and prefetchBack, which decide whether a neighbour gets a
///     player at all.
///
///   * A phone that will not answer keeps exactly the behaviour it had before
///     any of this existed. [hardwareBudget] is null then, and null changes
///     nothing.
///
/// And plainly: both phones measured so far answer 15 and 16, so on both of
/// them this changes nothing at all. It is for the phones nobody has held yet.
/// The full reading still goes to the log either way, which is how the next
/// phone gets measured.
class DecoderBudget {
  DecoderBudget._();
  static final DecoderBudget instance = DecoderBudget._();

  static const MethodChannel _channel = MethodChannel('devf/device_media');

  /// Each H.264 decoder this phone carries, and how many instances it says
  /// it will run. Empty when the question could not be asked — an old
  /// Android, a platform that is not Android, or a codec list that would not
  /// enumerate.
  Map<String, int> instancesByCodec = const {};

  /// The chip's H.265 decoders, same shape as [instancesByCodec].
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// A DIFFERENT QUESTION FROM THE ONE ABOVE
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// [instancesByCodec] asks "how many videos may I keep open". This asks
  /// something simpler and more consequential: can this phone decode H.265
  /// AT ALL?
  ///
  /// The server now makes an H.265 copy of the 480p and 720p pictures, about
  /// a third smaller for the same quality. Phones that can play it get a
  /// video that loads faster on mobile data without looking worse. Phones
  /// that cannot must never be sent one — an H.265 file on a phone that
  /// cannot decode it is not a soft picture, it is no picture.
  ///
  /// Empty is the common and correct answer on an older phone.
  Map<String, int> hevcByCodec = const {};

  /// Whether this phone has a HARDWARE H.265 decoder.
  ///
  /// Hardware specifically. Android ships a software H.265 decoder on
  /// devices whose chip has none, and it would answer "yes" to a plain
  /// "can you decode this" — then decode a full-screen reel at a few frames
  /// a second while emptying the battery. That is worse than the H.264 file
  /// it replaced, which is the one thing this must not be.
  ///
  /// False unless positively confirmed. A phone that cannot be asked — iOS,
  /// an old Android, a codec list that will not enumerate — keeps exactly
  /// the files it is served today. Guessing yes costs a black screen;
  /// guessing no costs nothing anybody can see.
  bool get hasHardwareHevc =>
      hevcByCodec.entries.any((e) => !isSoftware(e.key) && e.value > 0);

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
      if (raw != null && raw.isNotEmpty) {
        instancesByCodec = Map.unmodifiable(raw);
      }
      // Asked separately, and its failure kept separate: an old Android that
      // answers the H.264 question and not this one should still get its
      // player pool sized. Losing both to one throw would be a phone quietly
      // dropping back to the old defaults for a reason nothing records.
      final hevc =
          await _channel.invokeMapMethod<String, int>('hevcDecoderInstances');
      if (hevc != null && hevc.isNotEmpty) {
        hevcByCodec = Map.unmodifiable(hevc);
      }
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
    // Whether H.265 is on is worth a word in the one line that gets read: it
    // decides which files this phone is served, and "the video looks soft"
    // reads the same either way.
    final hevc = hevcByCodec.isEmpty
        ? ' hevc=no'
        : (hasHardwareHevc ? ' hevc=yes' : ' hevc=software-only');
    return 'decoders{${parts.join(' ')}}'
        '${hw == null ? '' : ' hardware=$hw'}$hevc';
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
