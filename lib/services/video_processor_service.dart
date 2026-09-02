import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as vt;

import 'network_quality_service.dart';

/// Output of one variant transcode. [path] is the local file produced
/// by [VideoProcessorService] — caller owns the lifecycle (delete after
/// upload, or rely on the OS temp-dir cleanup).
class VideoVariantFile {
  final String label;          // "480p" | "720p" | "1080p"
  final String path;           // absolute local path
  final int sizeBytes;         // file size, used for upload progress bar
  final Duration? duration;    // source duration as reported by ffmpeg
  final int? width;            // encoded frame width (best-effort)
  final int? height;           // encoded frame height (best-effort)

  const VideoVariantFile({
    required this.label,
    required this.path,
    required this.sizeBytes,
    this.duration,
    this.width,
    this.height,
  });
}

/// All artifacts produced from one source video, ready to be uploaded.
class ProcessedVideo {
  final List<VideoVariantFile> variants;   // one per VideoQuality target
  final String thumbnailPath;              // jpeg poster frame
  final int thumbnailSizeBytes;
  final Duration sourceDuration;

  const ProcessedVideo({
    required this.variants,
    required this.thumbnailPath,
    required this.thumbnailSizeBytes,
    required this.sourceDuration,
  });

  /// Convenience: total bytes across all artifacts. Used to surface a
  /// realistic upload size in the UI (helps users on metered data
  /// understand what they're about to send).
  int get totalUploadBytes =>
      thumbnailSizeBytes +
      variants.fold<int>(0, (sum, v) => sum + v.sizeBytes);
}

/// Local progress emitted while we're transcoding. Stage names map 1:1
/// to user-visible status messages on the upload screen — keep them
/// short (rendered in a thin progress strip).
class ProcessingEvent {
  final String stage;     // "thumbnail" | "720p" | "1080p" | "done"
  final double fraction;  // 0..1 across the whole job, monotonic
  const ProcessingEvent(this.stage, this.fraction);
}

/// Kind of artifact emitted by [VideoProcessorService.processStream]. We
/// distinguish video variants from the thumbnail so the uploader knows
/// which presigned URL slot to drop each one into without depending on
/// emit order.
enum ProcessingArtifactKind { thumbnail, video }

/// One file produced by [VideoProcessorService.processStream]. Same
/// shape as [VideoVariantFile] / the thumbnail tuple in [ProcessedVideo]
/// but unified into a single type so the upload pipeline can treat
/// every artifact uniformly (presign → PUT → mark done).
///
/// Emitted as soon as the file is in the staging dir; the caller can
/// start uploading it immediately while the next variant is still
/// being encoded.
class ProcessingArtifact {
  final ProcessingArtifactKind kind;
  /// "thumbnail" for the JPEG, "720p" / "1080p" for video variants.
  /// Matches the variant labels [MediaUploadService] presigns against.
  final String label;
  final String path;
  final int sizeBytes;
  /// MIME for the HTTP PUT Content-Type header.
  final String contentType;
  final Duration? duration;
  final int? width;
  final int? height;

  const ProcessingArtifact({
    required this.kind,
    required this.label,
    required this.path,
    required this.sizeBytes,
    required this.contentType,
    this.duration,
    this.width,
    this.height,
  });
}

/// VideoProcessorService takes a source video file (camera capture or
/// file_picker pick) and produces three quality variants + a thumbnail
/// — all locally on the device — so the backend never has to touch the
/// bytes (Render's free tier doesn't have the CPU for ffmpeg).
///
/// Designed around the constraints of [video_compress]:
///   * Only ONE compression can run at a time per process. We serialize.
///   * The package writes to its own cache dir. We copy/move to our
///     temp dir so cleanup is straightforward and outputs survive a
///     subsequent compression call (which clears the cache).
///   * Audio is preserved by default; we don't strip it.
class VideoProcessorService {
  VideoProcessorService._();
  static final VideoProcessorService instance = VideoProcessorService._();

  /// Hard cap on how long a reel can be. Anything longer is silently
  /// truncated by [process] via video_compress's startTime/duration
  /// args so users don't accidentally upload a 10-minute file.
  static const Duration maxReelDuration = Duration(seconds: 60);

  /// Whether [process] can run on the current platform. Both of the
  /// underlying plugins (video_compress + video_thumbnail) only ship
  /// Android/iOS native backends; on Windows/macOS/Linux they throw
  /// MissingPluginException on the first call. Callers that surface
  /// the create or response pipelines in their UI should check this
  /// first and route around (e.g. hide the "Post" button on desktop).
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// The variant label this source will be uploaded under.
  ///
  /// The uploader has to name its slots BEFORE the file exists — the presign
  /// round-trip happens first and the label is part of the key it signs — so
  /// this is how the caller learns the answer in advance. It must agree with
  /// what the pipeline actually emits, so both read the same measurement
  /// through the same function.
  static String labelForSize(num? width, num? height) {
    final w = width?.toInt() ?? 0;
    final h = height?.toInt() ?? 0;
    return NetworkQualityService.labelForLongSide(w > h ? w : h);
  }

  /// [labelForSize] for a file we have not measured yet.
  ///
  /// Falls back to the old fixed `720p` if the file cannot be read. That is
  /// not a good answer, but it is the answer this code gave for every video
  /// until now, so an unreadable file is no worse off than before.
  static Future<String> variantLabelFor(String sourcePath) async {
    try {
      final info = await VideoCompress.getMediaInfo(sourcePath);
      return labelForSize(info.width, info.height);
    } catch (_) {
      return '720p';
    }
  }

  /// Run the full pipeline. Emits progress on [onProgress] if provided.
  /// Throws on unrecoverable errors (codec failure, disk full, etc.) —
  /// callers should wrap in try/catch and surface a friendly message.
  Future<ProcessedVideo> process({
    required String sourcePath,
    ValueChanged<ProcessingEvent>? onProgress,
  }) async {
    // Fail fast on unsupported platforms with a message a UI layer can
    // actually show — without this guard, a desktop build would dive
    // into VideoCompress.getMediaInfo, hit a MissingPluginException
    // mid-pipeline, and bubble up an opaque error several layers above
    // where the actual cause lives.
    if (!isSupported) {
      throw UnsupportedError(
        'Video processing requires Android or iOS. '
        'Desktop builds do not ship the native ffmpeg backend used by '
        'video_compress / video_thumbnail.',
      );
    }

    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw ArgumentError('Source file does not exist: $sourcePath');
    }

    // Ask ffmpeg what we're working with up front. We use this to clamp
    // the duration to maxReelDuration on the transcode pass.
    final info = await VideoCompress.getMediaInfo(sourcePath);
    final sourceMs = info.duration?.toInt() ?? 0;
    final clampedMs =
        sourceMs == 0 ? null : (sourceMs > maxReelDuration.inMilliseconds
            ? maxReelDuration.inMilliseconds
            : sourceMs);

    final tempDir = await getTemporaryDirectory();
    final stageDir = Directory(
      '${tempDir.path}/devf_upload_${DateTime.now().millisecondsSinceEpoch}',
    )..createSync(recursive: true);

    onProgress?.call(const ProcessingEvent('thumbnail', 0.05));

    // Thumbnail at t=1s (or 0 for very short clips). 480px wide is
    // enough for a feed poster — we don't need full-res JPEGs in the
    // listing endpoints.
    final thumbBytes = await vt.VideoThumbnail.thumbnailFile(
      video: sourcePath,
      thumbnailPath: stageDir.path,
      imageFormat: vt.ImageFormat.JPEG,
      maxWidth: 720,
      quality: 80,
      timeMs: sourceMs > 1500 ? 1000 : 0,
    );
    if (thumbBytes == null) {
      throw StateError('Failed to extract thumbnail from $sourcePath');
    }
    final thumbFile = File(thumbBytes);
    final thumbSize = await thumbFile.length();

    // Single-variant pass — the trimmed source is the upload. See the
    // long-form rationale on processStream() above; the short version
    // is that double-encoding on certain Android SoCs silently dropped
    // the audio track on user-uploaded reels. Server-side HLS provides
    // the bitrate ladder; on-device re-encoding adds zero quality and
    // strictly more failure surface.
    // Labelled by what we measured, not a fixed "720p" — the picker reads
    // labels as a bandwidth cost now. See labelForLongSide, and the same
    // change on processStream() below.
    final srcW = info.width?.toInt() ?? 0;
    final srcH = info.height?.toInt() ?? 0;
    final label = labelForSize(srcW, srcH);
    onProgress?.call(ProcessingEvent(label, 0.10));
    final dest = File('${stageDir.path}/source.mp4');
    await File(sourcePath).copy(dest.path);
    final sizeBytes = await dest.length();
    final variants = <VideoVariantFile>[
      VideoVariantFile(
        label: label,
        path: dest.path,
        sizeBytes: sizeBytes,
        duration: Duration(milliseconds: clampedMs ?? sourceMs),
        width: srcW > 0 ? srcW : null,
        height: srcH > 0 ? srcH : null,
      ),
    ];

    onProgress?.call(const ProcessingEvent('done', 1.0));

    return ProcessedVideo(
      variants: variants,
      thumbnailPath: thumbFile.path,
      thumbnailSizeBytes: thumbSize,
      sourceDuration: Duration(milliseconds: sourceMs),
    );
  }

  /// Streaming variant of [process] — yields each artifact (thumbnail
  /// first, then 720p, then 1080p) the moment it's ready, so the caller
  /// can start uploading earlier artifacts in parallel with later
  /// encodes still running.
  ///
  /// This is the form used by [UploadJobManager] for background uploads.
  /// On a typical reel, the thumbnail lands within ~3s, the 720p in
  /// ~30-60s, the 1080p in another ~60-120s. The uploader gets ~30-90s
  /// of "free" overlap where bytes are flying to R2 while ffmpeg is
  /// still chewing on the next variant.
  ///
  /// Cleanup: callers should track every emitted [ProcessingArtifact]
  /// path and delete it after upload. We do NOT auto-delete here — that
  /// would race with the upload reading the file.
  ///
  /// Throws on unrecoverable errors. Use try/catch around the stream
  /// (await for) and present a friendly error to the user.
  Stream<ProcessingArtifact> processStream({
    required String sourcePath,
    ValueChanged<ProcessingEvent>? onProgress,
  }) async* {
    if (!isSupported) {
      throw UnsupportedError(
        'Video processing requires Android or iOS.',
      );
    }
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw ArgumentError('Source file does not exist: $sourcePath');
    }

    final info = await VideoCompress.getMediaInfo(sourcePath);
    final sourceMs = info.duration?.toInt() ?? 0;
    final clampedMs =
        sourceMs == 0 ? null : (sourceMs > maxReelDuration.inMilliseconds
            ? maxReelDuration.inMilliseconds
            : sourceMs);

    final tempDir = await getTemporaryDirectory();
    final stageDir = Directory(
      '${tempDir.path}/devf_upload_${DateTime.now().millisecondsSinceEpoch}',
    )..createSync(recursive: true);

    // ── Thumbnail ──────────────────────────────────────────────────
    onProgress?.call(const ProcessingEvent('thumbnail', 0.05));
    final thumbBytes = await vt.VideoThumbnail.thumbnailFile(
      video: sourcePath,
      thumbnailPath: stageDir.path,
      imageFormat: vt.ImageFormat.JPEG,
      maxWidth: 720,
      quality: 80,
      timeMs: sourceMs > 1500 ? 1000 : 0,
    );
    if (thumbBytes == null) {
      throw StateError('Failed to extract thumbnail from $sourcePath');
    }
    final thumbFile = File(thumbBytes);
    final thumbSize = await thumbFile.length();
    yield ProcessingArtifact(
      kind: ProcessingArtifactKind.thumbnail,
      label: 'thumbnail',
      path: thumbFile.path,
      sizeBytes: thumbSize,
      contentType: 'image/jpeg',
    );

    // ── Video upload (single pass — no device-side re-encode) ─────
    //
    // History: we used to run TWO video_compress passes here (720p +
    // 1080p variants) on top of the trim's already-compressed file,
    // for a total of three MediaCodec encodes per upload. On certain
    // Android SoCs (MTK c2.mtk.* decoders are the worst offenders),
    // every additional encode is another chance for the audio track
    // to be silently dropped — even with `includeAudio: true`. The
    // symptom users reported was silent challenge playback; the
    // mechanism was a per-encode audio-mux config that some vendor
    // codec stacks ignored.
    //
    // Fix: stop re-encoding. The trim step (video_trim_page.dart)
    // already produces a moderate-bitrate MP4 with AAC audio that
    // we can ship to R2 as-is. The server-side HLS worker
    // (devb/cmd/hls-worker/main.go) ladders this single source into
    // 240p..1080p renditions WITH ffmpeg's audio probing — that path
    // is reliable across every SoC because it's vanilla FFmpeg on a
    // Linux box, not vendor MediaCodec.
    //
    // We still emit ONE upload variant so the client's variant-picker has
    // something to play in the window before the server has converted this.
    //
    // Labelled by the picture we actually measured, NOT a fixed "720p". This
    // used to be hard-coded with a comment calling the label cosmetic, and it
    // stopped being cosmetic the day the picker started reading labels as a
    // bandwidth cost: a 1080p camera file tagged "720p" is the app being told
    // a 4 Mbps video costs 2.5, so it never drops down when it cannot keep
    // up. See NetworkQualityService.labelForLongSide.
    final srcW = info.width?.toInt() ?? 0;
    final srcH = info.height?.toInt() ?? 0;
    final label = labelForSize(srcW, srcH);
    onProgress?.call(ProcessingEvent(label, 0.10));
    final dest = File('${stageDir.path}/source.mp4');
    await File(sourcePath).copy(dest.path);
    final sizeBytes = await dest.length();
    yield ProcessingArtifact(
      kind: ProcessingArtifactKind.video,
      label: label,
      path: dest.path,
      sizeBytes: sizeBytes,
      contentType: 'video/mp4',
      duration: Duration(
        milliseconds: clampedMs ?? sourceMs,
      ),
    );

    onProgress?.call(const ProcessingEvent('done', 1.0));
  }

  /// Cleanup helper for the streaming API. Pass it every artifact path
  /// you collected from [processStream] (so we know what to delete).
  /// Best-effort — temp dir GCs on its own anyway, but explicit cleanup
  /// is friendlier on storage-tight phones.
  Future<void> cleanupArtifacts(Iterable<String> paths) async {
    for (final p in paths) {
      try {
        final f = File(p);
        if (f.existsSync()) await f.delete();
      } catch (_) {/* ignore */}
    }
  }

  /// Best-effort cleanup. Safe to call multiple times.
  Future<void> cleanup(ProcessedVideo p) async {
    for (final v in p.variants) {
      try {
        final f = File(v.path);
        if (f.existsSync()) await f.delete();
      } catch (_) {/* ignore — temp dir GCs on its own anyway */}
    }
    try {
      final t = File(p.thumbnailPath);
      if (t.existsSync()) await t.delete();
    } catch (_) {}
  }

}
