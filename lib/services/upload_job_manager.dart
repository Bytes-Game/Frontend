import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/media_upload_service.dart';
import 'package:myapp/services/video_processor_service.dart';

/// UploadJobManager — runs challenge / response uploads in the
/// background, off the screen lifecycle, so the user can tap "Post"
/// and immediately go back to the feed. This is the TikTok/Instagram
/// pattern: the post appears in the feed almost instantly, with the
/// transcode + upload finishing silently in the background and a
/// "Posted ✓" toast firing when it actually lands.
///
/// Design:
///   * One singleton owns every in-flight job. Jobs survive route
///     pushes/pops; closing the upload page DOES NOT cancel the job.
///     The only way to lose a job is to kill the app process.
///   * Each [UploadJob] exposes a `ValueNotifier<UploadJobState>` so
///     UI widgets (the status overlay, a profile-page badge, anything)
///     can rebuild against live progress without us re-implementing
///     pub-sub for every consumer.
///   * The manager calls into the existing streaming pipeline:
///     [VideoProcessorService.processStream] +
///     [MediaUploadService.uploadStream] — those two were rebuilt to
///     overlap compress + upload, and this layer just orchestrates
///     plus calls the final create/accept API and fires the global
///     "feed refresh" + "post complete" events.
///   * No use of [BuildContext] in the runner — everything contextless,
///     so a page being disposed mid-upload can't crash the job.
///
/// Failure mode: a failed job stays in [activeJobs] with
/// [UploadJobStage.failed] until the UI calls [dismiss]. We expose
/// [retry] to re-run the same source path through the pipeline; that
/// matters because most failures are transient network blips.
class UploadJobManager {
  UploadJobManager._();
  static final UploadJobManager instance = UploadJobManager._();

  /// All jobs currently visible to the UI. Includes in-progress AND
  /// recently-completed jobs (we keep terminal jobs around for ~3s so
  /// the user actually sees the "Posted ✓" state before it disappears).
  final ValueNotifier<List<UploadJob>> activeJobs = ValueNotifier(const []);

  /// Fires once per job when it reaches terminal success. UI uses this
  /// to navigate the user back into a fresh challenge / response view
  /// if they're still on a relevant screen, or to bump feed refresh
  /// counters globally so the next feed paint includes the new content.
  final StreamController<UploadJob> _completedCtl =
      StreamController<UploadJob>.broadcast();
  Stream<UploadJob> get onCompleted => _completedCtl.stream;

  // —— Public submit API ————————————————————————————————————————————

  /// Kick off a challenge-creation pipeline. Returns the job
  /// immediately — caller can pop their navigation and let the job
  /// finish on its own. The caller can listen to [job.state] for
  /// progress or just let the global overlay handle UI.
  UploadJob submitChallenge({
    required String creatorId,
    required String sourcePath,
    required ChallengeSubmissionMeta meta,
  }) {
    final job = UploadJob._(
      id: _newId(),
      kind: UploadJobKind.challenge,
      sourcePath: sourcePath,
      title: 'Posting challenge',
    );
    _enqueue(job);
    // Spin off the runner. Errors get caught inside _runChallenge so
    // unhandled async exceptions can't crash the app.
    // ignore: discarded_futures
    _runChallenge(job, creatorId: creatorId, meta: meta);
    return job;
  }

  /// Kick off a response-submission pipeline. Same lifecycle as
  /// [submitChallenge] — fire-and-forget from the caller's POV.
  UploadJob submitResponse({
    required String responderId,
    required String challengeId,
    required String sourcePath,
  }) {
    final job = UploadJob._(
      id: _newId(),
      kind: UploadJobKind.response,
      sourcePath: sourcePath,
      title: 'Submitting response',
      challengeId: challengeId,
    );
    _enqueue(job);
    // ignore: discarded_futures
    _runResponse(job, responderId: responderId, challengeId: challengeId);
    return job;
  }

  /// Remove a terminal job from [activeJobs]. Safe to call on
  /// non-terminal jobs (no-op) so UI code can dismiss without checking.
  void dismiss(String jobId) {
    final current = activeJobs.value;
    final next = current.where((j) => j.id != jobId).toList();
    if (next.length != current.length) {
      activeJobs.value = next;
    }
  }

  /// Re-run a failed job using the same source path + metadata.
  /// Returns the NEW job. The old job is dismissed so the UI shows
  /// just one entry for "this upload" instead of cluttering with
  /// historical attempts.
  UploadJob? retry(UploadJob job) {
    if (job.state.value.stage != UploadJobStage.failed) return null;
    UploadJob? fresh;
    switch (job.kind) {
      case UploadJobKind.challenge:
        final meta = job._challengeMeta;
        final creatorId = job._creatorId;
        if (meta == null || creatorId == null) return null;
        fresh = submitChallenge(
          creatorId: creatorId,
          sourcePath: job.sourcePath,
          meta: meta,
        );
      case UploadJobKind.response:
        final cid = job.challengeId;
        final rid = job._responderId;
        if (cid == null || rid == null) return null;
        fresh = submitResponse(
          responderId: rid,
          challengeId: cid,
          sourcePath: job.sourcePath,
        );
    }
    dismiss(job.id);
    return fresh;
  }

  // —— Internal: job runners ———————————————————————————————————————

  Future<void> _runChallenge(
    UploadJob job, {
    required String creatorId,
    required ChallengeSubmissionMeta meta,
  }) async {
    job._creatorId = creatorId;
    job._challengeMeta = meta;
    final start = DateTime.now();
    EventTracker.instance.track(
      eventType: 'challenge_pipeline_start',
      contentId: 'pending',
      contentType: 'challenge',
      metadata: {'jobId': job.id, 'visibility': meta.visibility},
    );

    final pathsToCleanup = <String>[];
    try {
      job._update((s) => s.copyWith(stage: UploadJobStage.processing));

      // We estimate total upload bytes from the source file size to
      // power the progress bar before the first artifact lands. Real
      // bytes are slightly different (compressed output ≠ source) but
      // it's close enough that the bar moves believably from t=0.
      final estimatedBytes = await _estimateBytes(job.sourcePath);

      final processed = VideoProcessorService.instance.processStream(
        sourcePath: job.sourcePath,
        onProgress: (e) {
          job._update((s) => s.copyWith(
                stage: UploadJobStage.processing,
                progress: e.fraction * 0.5,
                message: 'Encoding ${e.stage}…',
              ));
        },
      );

      // Tee the artifact stream so we can both (a) feed it to the
      // uploader AND (b) collect every path for cleanup at the end.
      // dart's StreamController<broadcast> doesn't preserve order/back
      // pressure for async generators, so we wrap manually.
      final upstream = StreamController<ProcessingArtifact>();
      // ignore: discarded_futures
      () async {
        try {
          await for (final a in processed) {
            pathsToCleanup.add(a.path);
            upstream.add(a);
          }
          await upstream.close();
        } catch (e, st) {
          upstream.addError(e, st);
          await upstream.close();
        }
      }();

      job._update((s) => s.copyWith(
            stage: UploadJobStage.uploading,
            progress: 0.5,
            message: 'Uploading…',
          ));

      final uploaded = await MediaUploadService.instance.uploadStream(
        userId: creatorId,
        artifacts: upstream.stream,
        expectedTotalBytes: estimatedBytes,
        expectedItems: const [
          (kind: 'thumbnail', variant: 'default', contentType: 'image/jpeg'),
          (kind: 'video', variant: '720p', contentType: 'video/mp4'),
        ],
        onProgress: (p) {
          // 50%..95% of the overall bar comes from the upload phase.
          // (Last 5% reserved for the finalize API call.)
          job._update((s) => s.copyWith(
                stage: UploadJobStage.uploading,
                progress: 0.5 + p.fraction * 0.45,
                activeVariant: p.activeVariant,
                message: p.activeVariant == null
                    ? 'Uploading…'
                    : 'Uploading ${p.activeVariant}…',
              ));
        },
      );

      if (uploaded == null) {
        throw _PipelineFailure('upload_fail',
            'Upload failed. Check your connection and retry.');
      }

      job._update((s) => s.copyWith(
            stage: UploadJobStage.finalizing,
            progress: 0.96,
            message: 'Posting…',
          ));

      final challenge = await ApiService.createChallenge(
        creatorId: creatorId,
        videoUrl: uploaded.defaultVideoUrl,
        videoVariants: uploaded.videoVariants,
        thumbnailUrl: uploaded.thumbnailUrl,
        prefix: meta.prefix,
        subject: meta.subject,
        visibility: meta.visibility,
        category: meta.category,
        emotionTags: meta.emotionTags,
        // energyLevel removed from the create payload — the server
        // derives it from the metadata it already has. See
        // energy_classifier.go on the backend.
      );
      if (challenge == null) {
        throw _PipelineFailure('create_fail',
            'Could not save the challenge. Tap retry to try again.');
      }

      EventTracker.instance.trackUploadComplete(
        uploadType: 'challenge',
        contentId: challenge.id,
        durationMs: DateTime.now().difference(start).inMilliseconds,
        totalElapsedMs: DateTime.now().difference(start).inMilliseconds,
      );

      job._update((s) => s.copyWith(
            stage: UploadJobStage.done,
            progress: 1.0,
            message: 'Posted',
            result: challenge,
          ));
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
    } on _PipelineFailure catch (f) {
      _fail(job, f.code, f.message);
    } catch (e) {
      _fail(job, 'unknown', 'Something went wrong: $e');
    } finally {
      // Always clean up local files — even on failure, those temp files
      // would otherwise pile up across retries.
      await VideoProcessorService.instance.cleanupArtifacts(pathsToCleanup);
    }
  }

  Future<void> _runResponse(
    UploadJob job, {
    required String responderId,
    required String challengeId,
  }) async {
    job._responderId = responderId;
    final start = DateTime.now();
    EventTracker.instance.track(
      eventType: 'response_pipeline_start',
      contentId: challengeId,
      contentType: 'challenge_response',
      metadata: {'jobId': job.id},
    );

    final pathsToCleanup = <String>[];
    try {
      job._update((s) => s.copyWith(stage: UploadJobStage.processing));
      final estimatedBytes = await _estimateBytes(job.sourcePath);

      final processed = VideoProcessorService.instance.processStream(
        sourcePath: job.sourcePath,
        onProgress: (e) {
          job._update((s) => s.copyWith(
                stage: UploadJobStage.processing,
                progress: e.fraction * 0.5,
                message: 'Encoding ${e.stage}…',
              ));
        },
      );

      final upstream = StreamController<ProcessingArtifact>();
      // ignore: discarded_futures
      () async {
        try {
          await for (final a in processed) {
            pathsToCleanup.add(a.path);
            upstream.add(a);
          }
          await upstream.close();
        } catch (e, st) {
          upstream.addError(e, st);
          await upstream.close();
        }
      }();

      job._update((s) => s.copyWith(
            stage: UploadJobStage.uploading,
            progress: 0.5,
            message: 'Uploading…',
          ));

      final uploaded = await MediaUploadService.instance.uploadStream(
        userId: responderId,
        artifacts: upstream.stream,
        expectedTotalBytes: estimatedBytes,
        expectedItems: const [
          (kind: 'thumbnail', variant: 'default', contentType: 'image/jpeg'),
          (kind: 'video', variant: '720p', contentType: 'video/mp4'),
        ],
        onProgress: (p) {
          job._update((s) => s.copyWith(
                stage: UploadJobStage.uploading,
                progress: 0.5 + p.fraction * 0.45,
                activeVariant: p.activeVariant,
                message: p.activeVariant == null
                    ? 'Uploading…'
                    : 'Uploading ${p.activeVariant}…',
              ));
        },
      );

      if (uploaded == null) {
        throw _PipelineFailure('upload_fail',
            'Upload failed. Check your connection and retry.');
      }

      job._update((s) => s.copyWith(
            stage: UploadJobStage.finalizing,
            progress: 0.96,
            message: 'Submitting…',
          ));

      final response = await ApiService.acceptChallenge(
        challengeId: challengeId,
        responderId: responderId,
        videoUrl: uploaded.defaultVideoUrl,
        videoVariants: uploaded.videoVariants,
        thumbnailUrl: uploaded.thumbnailUrl,
      );
      if (response == null) {
        throw _PipelineFailure('submit_fail',
            'Could not submit your response. Tap retry to try again.');
      }

      EventTracker.instance.trackUploadComplete(
        uploadType: 'challenge_response',
        contentId: challengeId,
        durationMs: DateTime.now().difference(start).inMilliseconds,
        totalElapsedMs: DateTime.now().difference(start).inMilliseconds,
      );

      job._update((s) => s.copyWith(
            stage: UploadJobStage.done,
            progress: 1.0,
            message: 'Posted',
            result: response,
          ));
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
    } on _PipelineFailure catch (f) {
      _fail(job, f.code, f.message);
    } catch (e) {
      _fail(job, 'unknown', 'Something went wrong: $e');
    } finally {
      await VideoProcessorService.instance.cleanupArtifacts(pathsToCleanup);
    }
  }

  // —— Internal: misc plumbing ——————————————————————————————————————

  void _enqueue(UploadJob job) {
    activeJobs.value = [...activeJobs.value, job];
  }

  void _fail(UploadJob job, String code, String message) {
    EventTracker.instance.track(
      eventType: job.kind == UploadJobKind.challenge
          ? 'challenge_pipeline_fail'
          : 'response_pipeline_fail',
      contentId: job.challengeId ?? 'pending',
      contentType: job.kind == UploadJobKind.challenge
          ? 'challenge'
          : 'challenge_response',
      metadata: {'code': code, 'jobId': job.id},
    );
    job._update((s) => s.copyWith(
          stage: UploadJobStage.failed,
          errorCode: code,
          message: message,
        ));
    // Failed jobs stay visible until the user retries or dismisses.
  }

  void _scheduleAutoDismiss(UploadJob job) {
    // Keep the "Posted ✓" state visible for 3s so the user actually
    // notices it. Then auto-dismiss to avoid clutter — a 4-post burst
    // would otherwise leave 4 stale entries on screen forever.
    Future.delayed(const Duration(seconds: 3), () => dismiss(job.id));
  }

  Future<int> _estimateBytes(String sourcePath) async {
    // Rough heuristic: assume our 720p copy + thumbnail total ~70% of
    // source size. Used purely to seed the progress bar before the first
    // artifact lands and we start tracking real bytes per unit.
    try {
      final size = File(sourcePath).lengthSync();
      return (size * 0.7 + 100 * 1024).round();
    } catch (_) {
      // Fallback: assume 20 MB so the bar shows non-zero motion even if
      // we somehow can't stat the source.
      return 20 * 1024 * 1024;
    }
  }

  String _newId() => 'job_${DateTime.now().microsecondsSinceEpoch}';
}

/// Stage of an [UploadJob]. The UI maps these to friendly status text;
/// the job runner uses them to gate progress-bar math.
enum UploadJobStage {
  queued,
  processing,
  uploading,
  finalizing,
  done,
  failed,
}

enum UploadJobKind { challenge, response }

/// Immutable snapshot of a job's live state. Replaced (not mutated) on
/// every progress tick so [ValueNotifier] correctly fires listeners.
class UploadJobState {
  final UploadJobStage stage;
  final double progress;       // 0..1 overall (covers process + upload + finalize)
  final String? activeVariant; // "thumbnail" | "720p" | "1080p"
  final String? message;
  final String? errorCode;
  final Object? result;        // ChallengeModel | ChallengeResponseModel | null

  const UploadJobState({
    this.stage = UploadJobStage.queued,
    this.progress = 0,
    this.activeVariant,
    this.message,
    this.errorCode,
    this.result,
  });

  UploadJobState copyWith({
    UploadJobStage? stage,
    double? progress,
    String? activeVariant,
    String? message,
    String? errorCode,
    Object? result,
  }) {
    return UploadJobState(
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      activeVariant: activeVariant ?? this.activeVariant,
      message: message ?? this.message,
      errorCode: errorCode ?? this.errorCode,
      result: result ?? this.result,
    );
  }
}

/// One in-flight upload. Carries everything the runner needs to retry
/// itself plus a [ValueNotifier] so UI widgets can rebuild on progress.
class UploadJob {
  final String id;
  final UploadJobKind kind;
  final String sourcePath;
  final String title;
  final String? challengeId;   // set for response jobs
  final ValueNotifier<UploadJobState> state =
      ValueNotifier(const UploadJobState());

  // Retry-only state (kept so the manager can rebuild a fresh job from
  // the same inputs without making the UI re-collect them).
  ChallengeSubmissionMeta? _challengeMeta;
  String? _creatorId;
  String? _responderId;

  UploadJob._({
    required this.id,
    required this.kind,
    required this.sourcePath,
    required this.title,
    this.challengeId,
  });

  void _update(UploadJobState Function(UploadJobState) f) {
    state.value = f(state.value);
  }
}

/// Bag of challenge-creation metadata captured from the metadata page
/// form. Passed to [UploadJobManager.submitChallenge] so the runner
/// can fire the createChallenge API call after upload completes.
///
/// `energyLevel` retired — the backend derives it from
/// category + subject + caption (see energy_classifier.go) so the
/// metadata page no longer asks. The recommender doesn't notice the
/// change because the derived value is still written to the column
/// it has always read.
class ChallengeSubmissionMeta {
  final String prefix;
  final String subject;
  final String visibility;
  final String category;
  final List<String> emotionTags;

  const ChallengeSubmissionMeta({
    required this.prefix,
    required this.subject,
    required this.visibility,
    required this.category,
    required this.emotionTags,
  });
}

/// Internal typed failure that the runner throws to short-circuit the
/// pipeline at a known step. Top-level catch maps it to a UI-friendly
/// failure state without losing the error code for analytics.
class _PipelineFailure implements Exception {
  final String code;
  final String message;
  _PipelineFailure(this.code, this.message);
}

// ChallengeResponseModel + ChallengeModel are referenced via the
// `result` field on [UploadJobState] (typed as Object? to support both).
// The import keeps the symbol available to consumers via re-export
// without forcing them to import the model file separately.
// ignore: unused_element
typedef _ResponseResultType = ChallengeResponseModel;
