import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/video_processor_service.dart';

/// Result of a complete upload run. The two URL bags are exactly what
/// CreateChallenge expects:
///   * [defaultVideoUrl] — the canonical/default-quality URL (we pick
///     720p as the safe middle ground for any client that ignores the
///     variants map).
///   * [videoVariants] — the full {label → publicUrl} map, persisted on
///     the Challenge row and consumed by the adaptive player.
///   * [thumbnailUrl] — single poster frame URL.
class UploadResult {
  final String defaultVideoUrl;
  final Map<String, String> videoVariants;
  final String thumbnailUrl;
  final String uploadId; // server-issued; useful for diagnostics

  const UploadResult({
    required this.defaultVideoUrl,
    required this.videoVariants,
    required this.thumbnailUrl,
    required this.uploadId,
  });
}

/// Per-upload progress update. Sums the bytes uploaded across all PUTs
/// in [bytesSent] vs [bytesTotal] so the UI can show one progress bar
/// for the whole batch.
class UploadProgress {
  final int bytesSent;
  final int bytesTotal;
  final String stage;          // "presigning" | "uploading" | "done"
  final String? activeVariant; // currently transferring file label
  const UploadProgress({
    required this.bytesSent,
    required this.bytesTotal,
    required this.stage,
    this.activeVariant,
  });

  double get fraction =>
      bytesTotal == 0 ? 0 : (bytesSent / bytesTotal).clamp(0.0, 1.0);
}

/// MediaUploadService:
///   1. Calls /api/v1/media/presign once with one entry per artifact
///      (3 video variants + 1 thumbnail).
///   2. PUTs each artifact to R2 in parallel using the returned signed
///      URLs (we cap parallelism at 2 so a phone on weak wifi doesn't
///      thrash all four streams simultaneously).
///   3. Retries each PUT up to [maxRetries] with exponential backoff —
///      mobile networks routinely drop one PUT mid-batch and a single
///      retry is the difference between "challenge posted" and "user
///      bounces and never tries again".
class MediaUploadService {
  MediaUploadService._();
  static final MediaUploadService instance = MediaUploadService._();

  /// Max parallel PUTs in flight. 2 gives a meaningful speedup over
  /// serial without saturating typical 4G uplinks (which would slow
  /// every transfer down and make the progress bar look frozen).
  static const _maxParallel = 2;

  /// Per-PUT retry budget. 3 attempts ≈ "transient blip recoverable,
  /// bad network never finishes" sweet spot.
  static const maxRetries = 3;

  /// Default-quality label persisted into Challenge.video_url. 720p is
  /// the right middle ground — any client that ignores the variants
  /// map still gets HD-ish playback.
  static const _defaultVariantLabel = '720p';

  /// Run the whole upload. Returns null if any unrecoverable step
  /// fails — callers should toast and let the user retry.
  Future<UploadResult?> upload({
    required String userId,
    required ProcessedVideo processed,
    ValueChanged<UploadProgress>? onProgress,
  }) async {
    final totalBytes = processed.totalUploadBytes;

    onProgress?.call(UploadProgress(
      bytesSent: 0,
      bytesTotal: totalBytes,
      stage: 'presigning',
    ));

    // Step 1: ask backend for one signed PUT per artifact.
    final items = <Map<String, String>>[
      {
        'kind': 'thumbnail',
        'variant': 'default',
        'contentType': 'image/jpeg',
      },
      for (final v in processed.variants)
        {
          'kind': 'video',
          'variant': v.label,
          'contentType': 'video/mp4',
        },
    ];
    final presigned =
        await ApiService.presignMediaUpload(userId: userId, items: items);
    if (presigned == null) return null;

    final uploadId = (presigned['uploadId'] ?? '') as String;
    final returnedItems =
        (presigned['items'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    if (returnedItems.length != items.length) return null;

    // Build a (kind,variant) → entry map so we can pair signed URLs
    // back to local files without depending on response order.
    String slot(String kind, String variant) => '$kind|$variant';
    final urlByKey = {
      for (final e in returnedItems)
        slot(e['kind'] as String, e['variant'] as String): e,
    };

    // Step 2: build the unit-of-work list. Each unit owns its bytes
    // count so the aggregate progress bar can sum them up monotonically.
    final units = <_UploadUnit>[];
    units.add(_UploadUnit(
      label: 'thumbnail',
      file: File(processed.thumbnailPath),
      contentType: 'image/jpeg',
      sizeBytes: processed.thumbnailSizeBytes,
      uploadUrl: urlByKey[slot('thumbnail', 'default')]!['uploadUrl'] as String,
      publicUrl: urlByKey[slot('thumbnail', 'default')]!['publicUrl'] as String,
    ));
    for (final v in processed.variants) {
      units.add(_UploadUnit(
        label: v.label,
        file: File(v.path),
        contentType: 'video/mp4',
        sizeBytes: v.sizeBytes,
        uploadUrl: urlByKey[slot('video', v.label)]!['uploadUrl'] as String,
        publicUrl: urlByKey[slot('video', v.label)]!['publicUrl'] as String,
      ));
    }

    // Step 3: parallel PUTs with bounded concurrency. We track sent
    // bytes per unit so a retry resets that unit's counter — the
    // aggregate stays accurate even when one unit retries.
    final sentByLabel = <String, int>{};
    int sumSent() =>
        sentByLabel.values.fold<int>(0, (a, b) => a + b);

    Future<bool> runUnit(_UploadUnit u) async {
      for (var attempt = 1; attempt <= maxRetries; attempt++) {
        sentByLabel[u.label] = 0;
        onProgress?.call(UploadProgress(
          bytesSent: sumSent(),
          bytesTotal: totalBytes,
          stage: 'uploading',
          activeVariant: u.label,
        ));
        try {
          final ok = await _putWithProgress(u, (n) {
            sentByLabel[u.label] = n;
            onProgress?.call(UploadProgress(
              bytesSent: sumSent(),
              bytesTotal: totalBytes,
              stage: 'uploading',
              activeVariant: u.label,
            ));
          });
          if (ok) {
            sentByLabel[u.label] = u.sizeBytes;
            return true;
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('upload ${u.label} attempt $attempt failed: $e');
          }
        }
        if (attempt < maxRetries) {
          // Exponential backoff: 400ms, 1.6s, 6.4s. Caps before users
          // get bored — the upload screen is already showing them a
          // spinner, so we don't want to drag a single retry past ~7s.
          final delayMs = 400 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
      return false;
    }

    // Run units N at a time. Drain a queue rather than chunking so
    // smaller files (the thumbnail) don't block big ones from starting.
    final queue = List<_UploadUnit>.from(units);
    final inflight = <Future<bool>>{};
    var allOk = true;

    Future<void> spawnNext() async {
      if (queue.isEmpty) return;
      final next = queue.removeAt(0);
      late Future<bool> fut;
      fut = runUnit(next).whenComplete(() => inflight.remove(fut));
      inflight.add(fut);
    }

    while (queue.isNotEmpty && inflight.length < _maxParallel) {
      await spawnNext();
    }
    while (inflight.isNotEmpty) {
      final completed = await Future.any(inflight);
      if (!completed) allOk = false;
      while (queue.isNotEmpty && inflight.length < _maxParallel) {
        await spawnNext();
      }
    }

    if (!allOk) return null;

    // Step 4: assemble the result. Default URL falls back to the
    // largest variant if 720p is somehow missing.
    final variantUrls = <String, String>{
      for (final u in units)
        if (u.label != 'thumbnail') u.label: u.publicUrl,
    };
    final defaultUrl = variantUrls[_defaultVariantLabel] ??
        variantUrls['1080p'] ??
        variantUrls['480p'] ??
        '';
    final thumbUrl =
        units.firstWhere((u) => u.label == 'thumbnail').publicUrl;

    onProgress?.call(UploadProgress(
      bytesSent: totalBytes,
      bytesTotal: totalBytes,
      stage: 'done',
    ));

    return UploadResult(
      defaultVideoUrl: defaultUrl,
      videoVariants: variantUrls,
      thumbnailUrl: thumbUrl,
      uploadId: uploadId,
    );
  }

  /// Streaming variant of [upload] — consumes a stream of artifacts as
  /// they're produced by [VideoProcessorService.processStream] and
  /// starts the PUT for each one the moment it lands. This overlaps the
  /// compress + upload phases: the thumbnail uploads while the 720p is
  /// encoding, the 720p uploads while the 1080p is encoding, etc. End-
  /// to-end wall time drops by ~30-50% vs the all-then-all sequence.
  ///
  /// [expectedItems] lists every (kind, variant, contentType) the
  /// stream will yield. We presign all of them up front in one round-
  /// trip so the first PUT can start the instant its artifact arrives,
  /// not after a second presign hop.
  ///
  /// Caller owns deleting the artifact files. Uploader does NOT delete
  /// them — it does not own their lifecycle.
  Future<UploadResult?> uploadStream({
    required String userId,
    required Stream<ProcessingArtifact> artifacts,
    required int expectedTotalBytes,
    required List<({String kind, String variant, String contentType})>
        expectedItems,
    ValueChanged<UploadProgress>? onProgress,
  }) async {
    onProgress?.call(UploadProgress(
      bytesSent: 0,
      bytesTotal: expectedTotalBytes,
      stage: 'presigning',
    ));

    final presigned = await ApiService.presignMediaUpload(
      userId: userId,
      items: expectedItems
          .map((e) => {
                'kind': e.kind,
                'variant': e.variant,
                'contentType': e.contentType,
              })
          .toList(),
    );
    if (presigned == null) return null;

    final uploadId = (presigned['uploadId'] ?? '') as String;
    final returnedItems = (presigned['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    if (returnedItems.length != expectedItems.length) return null;

    String slot(String kind, String variant) => '$kind|$variant';
    final urlByKey = {
      for (final e in returnedItems)
        slot(e['kind'] as String, e['variant'] as String): e,
    };

    // Aggregate progress across all units. `sentByLabel` is updated by
    // each per-unit progress callback so the UI sees a single monotonic
    // bar even though uploads start at different times.
    final sentByLabel = <String, int>{};
    int sumSent() => sentByLabel.values.fold<int>(0, (a, b) => a + b);

    // We track the publicUrl for each successful upload so the result
    // assembly at the end can build the variants map without depending
    // on the order things finished in.
    final publicUrlByLabel = <String, String>{};
    final inflight = <Future<bool>>{};

    Future<bool> runOneUnit(ProcessingArtifact art) async {
      final kind = art.kind == ProcessingArtifactKind.thumbnail
          ? 'thumbnail'
          : 'video';
      final variant =
          art.kind == ProcessingArtifactKind.thumbnail ? 'default' : art.label;
      final entry = urlByKey[slot(kind, variant)];
      if (entry == null) return false;

      final unit = _UploadUnit(
        label: art.label,
        file: File(art.path),
        contentType: art.contentType,
        sizeBytes: art.sizeBytes,
        uploadUrl: entry['uploadUrl'] as String,
        publicUrl: entry['publicUrl'] as String,
      );

      for (var attempt = 1; attempt <= maxRetries; attempt++) {
        sentByLabel[unit.label] = 0;
        onProgress?.call(UploadProgress(
          bytesSent: sumSent(),
          bytesTotal: expectedTotalBytes,
          stage: 'uploading',
          activeVariant: unit.label,
        ));
        try {
          final ok = await _putWithProgress(unit, (n) {
            sentByLabel[unit.label] = n;
            onProgress?.call(UploadProgress(
              bytesSent: sumSent(),
              bytesTotal: expectedTotalBytes,
              stage: 'uploading',
              activeVariant: unit.label,
            ));
          });
          if (ok) {
            sentByLabel[unit.label] = unit.sizeBytes;
            publicUrlByLabel[unit.label] = unit.publicUrl;
            return true;
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('uploadStream ${unit.label} attempt $attempt: $e');
          }
        }
        if (attempt < maxRetries) {
          final delayMs = 400 * (1 << (attempt - 1));
          await Future.delayed(Duration(milliseconds: delayMs));
        }
      }
      return false;
    }

    // Drain the stream and spawn a PUT per artifact as it arrives. We
    // also cap parallelism: if the producer is fast (e.g. very short
    // clip) and we'd otherwise spawn 3 uploads at once on a flaky 3G
    // link, we'd starve every transfer. Same bound as upload().
    var allOk = true;
    await for (final art in artifacts) {
      // Wait for a slot if we're already at capacity.
      while (inflight.length >= _maxParallel) {
        final done = await Future.any(inflight);
        if (!done) allOk = false;
      }
      late Future<bool> fut;
      fut = runOneUnit(art).whenComplete(() => inflight.remove(fut));
      inflight.add(fut);
    }
    while (inflight.isNotEmpty) {
      final done = await Future.any(inflight);
      if (!done) allOk = false;
    }
    if (!allOk) return null;

    // Assemble result. Same defaulting rule as upload(): 720p is the
    // canonical/default URL; fall back to whatever else we have if it's
    // somehow missing.
    final variantUrls = <String, String>{
      for (final entry in publicUrlByLabel.entries)
        if (entry.key != 'thumbnail') entry.key: entry.value,
    };
    final defaultUrl = variantUrls[_defaultVariantLabel] ??
        variantUrls['1080p'] ??
        variantUrls['720p'] ??
        variantUrls['480p'] ??
        '';
    final thumbUrl = publicUrlByLabel['thumbnail'] ?? '';

    onProgress?.call(UploadProgress(
      bytesSent: expectedTotalBytes,
      bytesTotal: expectedTotalBytes,
      stage: 'done',
    ));

    return UploadResult(
      defaultVideoUrl: defaultUrl,
      videoVariants: variantUrls,
      thumbnailUrl: thumbUrl,
      uploadId: uploadId,
    );
  }

  /// Streaming PUT with byte-level progress callbacks. We use
  /// http.StreamedRequest so the file isn't slurped into RAM — a 1080p
  /// reel can be ~10MB and we'd OOM phones with the basic
  /// http.put(file.readAsBytesSync()) shape.
  Future<bool> _putWithProgress(
    _UploadUnit u,
    ValueChanged<int> onBytesSent,
  ) async {
    final length = await u.file.length();
    final req = http.StreamedRequest('PUT', Uri.parse(u.uploadUrl));
    req.headers['Content-Type'] = u.contentType;
    // Tell R2 to remember this Cache-Control on the stored object so
    // every future GET — by ANY client, via ANY CDN POP — returns it.
    // Cloudflare's edge cache honours this hint automatically: a
    // `public, max-age=31536000, immutable` directive means an edge POP
    // can serve the same bytes for a year without re-checking with
    // origin. This is the single biggest "free" CDN win we have:
    // turning every viral video into an edge-cached asset after the
    // first viewer per POP, instead of every viewer hitting origin.
    //
    // `immutable` is correct here because the object key is
    // content-addressed (per-upload prefix + variant label) — we never
    // overwrite a stored object. If someone re-uploads, they get a
    // fresh uploadID and therefore a fresh URL.
    //
    // The presign-signed headers are limited to `host`, so we can set
    // arbitrary additional headers on the PUT without invalidating the
    // signature (this is intentional — see media_storage.go).
    req.headers['Cache-Control'] =
        'public, max-age=31536000, immutable';
    req.contentLength = length;

    var sent = 0;
    final completer = Completer<void>();
    final sub = u.file.openRead().listen(
      (chunk) {
        req.sink.add(chunk);
        sent += chunk.length;
        onBytesSent(sent);
      },
      onDone: () {
        req.sink.close();
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    final res = await http.Client().send(req);
    await sub.cancel();
    if (!completer.isCompleted) completer.complete();

    // R2 returns 200 on successful PUT. Some S3-compat layers return
    // 201; accept both for resilience.
    return res.statusCode == 200 || res.statusCode == 201;
  }
}

/// Bag of per-file state used internally by the parallel uploader.
class _UploadUnit {
  final String label;
  final File file;
  final String contentType;
  final int sizeBytes;
  final String uploadUrl;
  final String publicUrl;
  _UploadUnit({
    required this.label,
    required this.file,
    required this.contentType,
    required this.sizeBytes,
    required this.uploadUrl,
    required this.publicUrl,
  });
}
