import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/own_uploads.dart';
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

  /// EARLY UPLOAD (the TikTok trick): call this the moment trimming
  /// finishes — i.e. when the metadata page OPENS, not when the user
  /// taps Post. Processing + upload run while they type the title, so
  /// by Post time the bytes are usually already in R2 and
  /// [finalizeChallenge] only has to make one API call: posting feels
  /// instant.
  ///
  /// [photo] for a photo challenge: [sourcePath] is the picture, and the
  /// upload is that one file, with nothing to convert.
  UploadJob prepareChallenge({
    required String creatorId,
    required String sourcePath,
    bool photo = false,
  }) {
    final job = UploadJob._(
      id: _newId(),
      kind: UploadJobKind.challenge,
      sourcePath: sourcePath,
      title: photo ? 'Preparing photo' : 'Preparing video',
      isPhoto: photo,
    );
    job._creatorId = creatorId;
    job._prepared = Completer<UploadResult?>();
    _enqueue(job);
    // ignore: discarded_futures
    _runPrepare(job, userId: creatorId);
    return job;
  }

  /// Attach metadata to a prepared job and post it. If the prepare leg
  /// failed (network died while the user was typing), this falls back
  /// to the full pipeline transparently — the caller never has to care
  /// which path ran. Returns the job carrying the terminal state.
  Future<UploadJob> finalizeChallenge(
      UploadJob job, ChallengeSubmissionMeta meta) async {
    job._challengeMeta = meta;
    await _persistJobs();
    final prepared = job._prepared;
    if (prepared == null) {
      // Not a prepared job — legacy full-pipeline path.
      return job;
    }
    if (job._abandoned) {
      job._abandoned = false; // user came back — un-abandon
    }
    final uploaded = await prepared.future;
    if (uploaded == null) {
      // Prepare leg failed — rerun everything with the metadata we now
      // have. The overlay shows one fresh job instead of a dead one.
      dismiss(job.id);
      return submitChallenge(
        creatorId: job._creatorId ?? '',
        sourcePath: job.sourcePath,
        meta: meta,
        photo: job.isPhoto,
      );
    }
    // ignore: discarded_futures
    _finalizePrepared(job, uploaded, meta);
    return job;
  }

  /// The user backed out of the create flow after a prepare started.
  /// Marks the job so it quietly disappears when the upload leg ends
  /// (already-uploaded R2 objects are orphaned; the backend's cleanup
  /// job reaps objects with no challenge row).
  void abandonPrepared(UploadJob job) {
    if (job._prepared == null) return;
    job._abandoned = true;
    if (job._prepared!.isCompleted) {
      dismiss(job.id);
    }
  }

  /// Kick off a challenge-creation pipeline. Returns the job
  /// immediately — caller can pop their navigation and let the job
  /// finish on its own. The caller can listen to [job.state] for
  /// progress or just let the global overlay handle UI.
  UploadJob submitChallenge({
    required String creatorId,
    required String sourcePath,
    required ChallengeSubmissionMeta meta,
    bool photo = false,
  }) {
    final job = UploadJob._(
      id: _newId(),
      kind: UploadJobKind.challenge,
      sourcePath: sourcePath,
      title: 'Posting challenge',
      isPhoto: photo,
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
  ///
  /// [photo] answers a photo challenge with the picture at [sourcePath].
  UploadJob submitResponse({
    required String responderId,
    required String challengeId,
    required String sourcePath,
    bool photo = false,
    String musicTrackId = '',
  }) {
    final job = UploadJob._(
      id: _newId(),
      kind: UploadJobKind.response,
      sourcePath: sourcePath,
      title: 'Submitting response',
      challengeId: challengeId,
      isPhoto: photo,
    );
    job._musicTrackId = musicTrackId;
    _enqueue(job);
    // ignore: discarded_futures
    _runResponse(job, responderId: responderId, challengeId: challengeId);
    return job;
  }

  /// The videos that posts on this phone still need.
  ///
  /// Asked by "Free up space" before it deletes leftovers. A post that
  /// failed and is waiting for a retry still needs the video it was made
  /// from; delete it and "tap to retry" quietly becomes "record it again".
  /// A finished post needs nothing, so its video is fair game.
  Set<String> get filesStillNeeded => {
        for (final j in activeJobs.value)
          if (j.state.value.stage != UploadJobStage.done) j.sourcePath,
      };

  /// Whether a post is being prepared or sent right now.
  ///
  /// While one is, its working copies sit in a folder of their own that is
  /// not named after the job, so there is no telling which folder is whose.
  /// "Free up space" leaves all of them alone until nothing is running.
  bool get anyRunning => activeJobs.value.any((j) => switch (j.state.value.stage) {
        UploadJobStage.done || UploadJobStage.failed => false,
        _ => true,
      });

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
          photo: job.isPhoto,
        );
      case UploadJobKind.response:
        final cid = job.challengeId;
        final rid = job._responderId;
        if (cid == null || rid == null) return null;
        fresh = submitResponse(
          responderId: rid,
          challengeId: cid,
          sourcePath: job.sourcePath,
          photo: job.isPhoto,
          musicTrackId: job._musicTrackId,
        );
    }
    dismiss(job.id);
    return fresh;
  }

  // —— Internal: job runners ———————————————————————————————————————

  /// Prepare leg: processing + upload only (progress 0..0.9). Completes
  /// [job._prepared] with the upload result (null on failure) so
  /// [finalizeChallenge] can pick up whenever the user taps Post.
  Future<void> _runPrepare(UploadJob job, {required String userId}) async {
    if (job.isPhoto) return _preparePhoto(job, userId: userId);
    final pathsToCleanup = <String>[];
    try {
      job._update((s) => s.copyWith(stage: UploadJobStage.processing));
      final estimatedBytes = await _estimateBytes(job.sourcePath);
      final videoLabel =
          await VideoProcessorService.variantLabelFor(job.sourcePath);

      final processed = VideoProcessorService.instance.processStream(
        sourcePath: job.sourcePath,
        onProgress: (e) {
          job._update((s) => s.copyWith(
                stage: UploadJobStage.processing,
                progress: e.fraction * 0.5,
                message: 'Preparing ${e.stage}…',
              ));
        },
      );

      // How long the video we are about to send runs. The transcode knows
      // it and reports it on every video artifact; the server refuses
      // anything over the limit and has to be told, so it is picked up
      // here rather than measured again.
      var uploadedDuration = Duration.zero;

      final upstream = StreamController<ProcessingArtifact>();
      // ignore: discarded_futures
      () async {
        try {
          await for (final a in processed) {
            pathsToCleanup.add(a.path);
            if (a.kind == ProcessingArtifactKind.thumbnail) {
              job._poster = a.path;
            }
            final d = a.duration;
            if (d != null && d > uploadedDuration) uploadedDuration = d;
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
        userId: userId,
        artifacts: upstream.stream,
        expectedTotalBytes: estimatedBytes,
        expectedItems: [
          (kind: 'thumbnail', variant: 'default', contentType: 'image/jpeg'),
          // Not a fixed '720p': the presign key carries the variant name, so
          // it has to be the label the pipeline will actually emit for this
          // file. Both sides read it through VideoProcessorService.
          (kind: 'video', variant: videoLabel, contentType: 'video/mp4'),
        ],
        onProgress: (p) {
          job._update((s) => s.copyWith(
                stage: UploadJobStage.uploading,
                progress: 0.5 + p.fraction * 0.4,
                activeVariant: p.activeVariant,
                message: 'Uploading…',
              ));
        },
      );

      if (uploaded == null) {
        job._prepared?.complete(null);
        // Don't _fail() here — the user may still be typing metadata;
        // finalizeChallenge falls back to the full pipeline on Post.
        // Show a quiet holding state instead of a scary red entry.
        job._update((s) => s.copyWith(
              stage: UploadJobStage.queued,
              progress: 0,
              message: 'Will retry on post',
            ));
        return;
      }

      job._preparedDuration = uploadedDuration;
      job._prepared?.complete(uploaded);
      if (job._abandoned) {
        dismiss(job.id);
        return;
      }
      job._update((s) => s.copyWith(
            stage: UploadJobStage.queued,
            progress: 0.9,
            message: 'Ready to post',
          ));
    } catch (e) {
      if (!(job._prepared?.isCompleted ?? true)) {
        job._prepared?.complete(null);
      }
      job._update((s) => s.copyWith(
            stage: UploadJobStage.queued,
            progress: 0,
            message: 'Will retry on post',
          ));
    } finally {
      await VideoProcessorService.instance.cleanupArtifacts(pathsToCleanup);
    }
  }

  /// Finalize leg for a prepared job: one createChallenge call.
  Future<void> _finalizePrepared(
      UploadJob job, UploadResult uploaded, ChallengeSubmissionMeta meta) async {
    final start = DateTime.now();
    final uploadedDuration = job._preparedDuration;
    try {
      job._update((s) => s.copyWith(
            stage: UploadJobStage.finalizing,
            progress: 0.96,
            message: 'Posting…',
          ));
      final challenge = await ApiService.createChallenge(
        creatorId: job._creatorId ?? '',
        videoUrl: uploaded.defaultVideoUrl,
        videoVariants: uploaded.videoVariants,
        thumbnailUrl: uploaded.thumbnailUrl,
        duration: uploadedDuration,
        prefix: meta.prefix,
        subject: meta.subject,
        visibility: meta.visibility,
        category: meta.category,
        emotionTags: meta.emotionTags,
        tags: meta.tags,
        battleDays: meta.battleDays,
        visibleTo: meta.visibleTo,
        openToBattles: meta.openToBattles,
        mediaType: job.isPhoto ? 'photo' : 'video',
        musicTrackId: meta.musicTrackId,
      );
      if (challenge == null) {
        _fail(job, 'create_fail',
            'Could not save the challenge. Tap retry to try again.');
        return;
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
      // Keep what went up, so it plays at once from your profile. A photo
      // is not played: the picture is fetched like any other.
      if (!job.isPhoto) {
        unawaited(OwnUploads.instance
            .keep('challenge:${challenge.id}', job.sourcePath));
      }
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
      await _removePersisted(job.id);
    } on ApiRefused catch (e) {
      // The server looked at it and said no, and said why. Retrying will
      // never change that, so show the reason instead of "try again".
      _fail(job, 'refused', e.reason);
    } catch (e) {
      _fail(job, 'unknown', 'Something went wrong: $e');
    }
  }

  Future<void> _runChallenge(
    UploadJob job, {
    required String creatorId,
    required ChallengeSubmissionMeta meta,
  }) async {
    job._creatorId = creatorId;
    job._challengeMeta = meta;
    // Persist now that the job carries full retry info — an app kill
    // from here on restores a tappable retry on next launch.
    // ignore: discarded_futures
    _persistJobs();
    final start = DateTime.now();
    EventTracker.instance.track(
      eventType: 'challenge_pipeline_start',
      contentId: 'pending',
      contentType: 'challenge',
      metadata: {'jobId': job.id, 'visibility': meta.visibility},
    );
    if (job.isPhoto) {
      return _runPhoto(
        job,
        userId: creatorId,
        failCode: 'create_fail',
        failMessage: 'Could not save the challenge. Tap retry to try again.',
        send: (uploaded) => ApiService.createChallenge(
          creatorId: creatorId,
          videoUrl: uploaded.defaultVideoUrl,
          thumbnailUrl: uploaded.thumbnailUrl,
          prefix: meta.prefix,
          subject: meta.subject,
          visibility: meta.visibility,
          category: meta.category,
          emotionTags: meta.emotionTags,
          tags: meta.tags,
          battleDays: meta.battleDays,
          visibleTo: meta.visibleTo,
          openToBattles: meta.openToBattles,
          mediaType: 'photo',
        ),
      );
    }

    final pathsToCleanup = <String>[];
    try {
      job._update((s) => s.copyWith(stage: UploadJobStage.processing));

      // We estimate total upload bytes from the source file size to
      // power the progress bar before the first artifact lands. Real
      // bytes are slightly different (compressed output ≠ source) but
      // it's close enough that the bar moves believably from t=0.
      final estimatedBytes = await _estimateBytes(job.sourcePath);
      final videoLabel =
          await VideoProcessorService.variantLabelFor(job.sourcePath);

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
      // How long the video we are about to send runs. The transcode knows
      // it and reports it on every video artifact; the server refuses
      // anything over the limit and has to be told, so it is picked up
      // here rather than measured again.
      var uploadedDuration = Duration.zero;

      final upstream = StreamController<ProcessingArtifact>();
      // ignore: discarded_futures
      () async {
        try {
          await for (final a in processed) {
            pathsToCleanup.add(a.path);
            if (a.kind == ProcessingArtifactKind.thumbnail) {
              job._poster = a.path;
            }
            final d = a.duration;
            if (d != null && d > uploadedDuration) uploadedDuration = d;
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
        expectedItems: [
          (kind: 'thumbnail', variant: 'default', contentType: 'image/jpeg'),
          // Not a fixed '720p': the presign key carries the variant name, so
          // it has to be the label the pipeline will actually emit for this
          // file. Both sides read it through VideoProcessorService.
          (kind: 'video', variant: videoLabel, contentType: 'video/mp4'),
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
        duration: uploadedDuration,
        prefix: meta.prefix,
        subject: meta.subject,
        visibility: meta.visibility,
        category: meta.category,
        emotionTags: meta.emotionTags,
        tags: meta.tags,
        battleDays: meta.battleDays,
        visibleTo: meta.visibleTo,
        openToBattles: meta.openToBattles,
        musicTrackId: meta.musicTrackId,
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
      // Keep what went up, so it plays at once from your profile.
      unawaited(OwnUploads.instance
          .keep('challenge:${challenge.id}', job.sourcePath));
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
      await _removePersisted(job.id);
    } on _PipelineFailure catch (f) {
      _fail(job, f.code, f.message);
    } on ApiRefused catch (e) {
      // The server looked at it and said no, and said why. Retrying will
      // never change that, so show the reason instead of "try again".
      _fail(job, 'refused', e.reason);
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
    // ignore: discarded_futures
    _persistJobs();
    final start = DateTime.now();
    EventTracker.instance.track(
      eventType: 'response_pipeline_start',
      contentId: challengeId,
      contentType: 'challenge_response',
      metadata: {'jobId': job.id},
    );
    if (job.isPhoto) {
      return _runPhoto(
        job,
        userId: responderId,
        failCode: 'submit_fail',
        failMessage: 'Could not submit your response. Tap retry to try again.',
        send: (uploaded) => ApiService.acceptChallenge(
          challengeId: challengeId,
          responderId: responderId,
          videoUrl: uploaded.defaultVideoUrl,
          thumbnailUrl: uploaded.thumbnailUrl,
          mediaType: 'photo',
        ),
      );
    }

    final pathsToCleanup = <String>[];
    try {
      job._update((s) => s.copyWith(stage: UploadJobStage.processing));
      final estimatedBytes = await _estimateBytes(job.sourcePath);
      final videoLabel =
          await VideoProcessorService.variantLabelFor(job.sourcePath);

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

      // How long the video we are about to send runs. The transcode knows
      // it and reports it on every video artifact; the server refuses
      // anything over the limit and has to be told, so it is picked up
      // here rather than measured again.
      var uploadedDuration = Duration.zero;

      final upstream = StreamController<ProcessingArtifact>();
      // ignore: discarded_futures
      () async {
        try {
          await for (final a in processed) {
            pathsToCleanup.add(a.path);
            if (a.kind == ProcessingArtifactKind.thumbnail) {
              job._poster = a.path;
            }
            final d = a.duration;
            if (d != null && d > uploadedDuration) uploadedDuration = d;
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
        expectedItems: [
          (kind: 'thumbnail', variant: 'default', contentType: 'image/jpeg'),
          // Not a fixed '720p': the presign key carries the variant name, so
          // it has to be the label the pipeline will actually emit for this
          // file. Both sides read it through VideoProcessorService.
          (kind: 'video', variant: videoLabel, contentType: 'video/mp4'),
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
        duration: uploadedDuration,
        musicTrackId: job._musicTrackId,
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
      unawaited(OwnUploads.instance
          .keep('response:${response.id}', job.sourcePath));
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
      await _removePersisted(job.id);
    } on _PipelineFailure catch (f) {
      _fail(job, f.code, f.message);
    } on ApiRefused catch (e) {
      // The server looked at it and said no, and said why. Retrying will
      // never change that, so show the reason instead of "try again".
      _fail(job, 'refused', e.reason);
    } catch (e) {
      _fail(job, 'unknown', 'Something went wrong: $e');
    } finally {
      await VideoProcessorService.instance.cleanupArtifacts(pathsToCleanup);
    }
  }

  // —— Internal: photos ——————————————————————————————————————————————
  //
  // A photo challenge or a photo answer: one picture, already a small JPEG
  // from the picker. Nothing to convert, so no processing stage — it goes
  // straight up, and then the same create or accept call a video makes,
  // saying it is a photo.

  /// Upload [job]'s picture, moving its bar from 0 to [upTo].
  Future<UploadResult?> _sendPhoto(
    UploadJob job,
    String userId, {
    required double upTo,
  }) {
    job._poster = job.sourcePath;
    job._update((s) => s.copyWith(
          stage: UploadJobStage.uploading,
          progress: 0,
          message: 'Uploading photo…',
        ));
    return MediaUploadService.instance.uploadPhoto(
      userId: userId,
      photo: File(job.sourcePath),
      onProgress: (p) => job._update((s) => s.copyWith(
            stage: UploadJobStage.uploading,
            progress: p.fraction * upTo,
            activeVariant: 'photo',
            message: 'Uploading photo…',
          )),
    );
  }

  /// The prepare leg of a photo challenge: the upload, while the creator
  /// types. See [prepareChallenge].
  Future<void> _preparePhoto(UploadJob job, {required String userId}) async {
    UploadResult? uploaded;
    try {
      uploaded = await _sendPhoto(job, userId, upTo: 0.9);
    } catch (e) {
      debugPrint('[upload] preparing the photo failed: $e');
    }
    job._prepared?.complete(uploaded);
    if (uploaded == null) {
      // The same quiet holding state a video gets: Post tries again.
      job._update((s) => s.copyWith(
            stage: UploadJobStage.queued,
            progress: 0,
            message: 'Will retry on post',
          ));
      return;
    }
    if (job._abandoned) {
      dismiss(job.id);
      return;
    }
    job._update((s) => s.copyWith(
          stage: UploadJobStage.queued,
          progress: 0.9,
          message: 'Ready to post',
        ));
  }

  /// A photo challenge or answer posted in one go: upload, then [send] it.
  Future<void> _runPhoto(
    UploadJob job, {
    required String userId,
    required Future<Object?> Function(UploadResult) send,
    required String failCode,
    required String failMessage,
  }) async {
    final start = DateTime.now();
    try {
      final uploaded = await _sendPhoto(job, userId, upTo: 0.95);
      if (uploaded == null) {
        throw _PipelineFailure('upload_fail',
            'Upload failed. Check your connection and retry.');
      }
      job._update((s) => s.copyWith(
            stage: UploadJobStage.finalizing,
            progress: 0.96,
            message: job.kind == UploadJobKind.challenge
                ? 'Posting…'
                : 'Submitting…',
          ));
      final result = await send(uploaded);
      if (result == null) throw _PipelineFailure(failCode, failMessage);
      EventTracker.instance.trackUploadComplete(
        uploadType: job.kind == UploadJobKind.challenge
            ? 'challenge'
            : 'challenge_response',
        contentId: job.challengeId ??
            (result is ChallengeModel ? result.id : 'pending'),
        durationMs: DateTime.now().difference(start).inMilliseconds,
        totalElapsedMs: DateTime.now().difference(start).inMilliseconds,
      );
      job._update((s) => s.copyWith(
            stage: UploadJobStage.done,
            progress: 1.0,
            message: 'Posted',
            result: result,
          ));
      _completedCtl.add(job);
      _scheduleAutoDismiss(job);
      await _removePersisted(job.id);
    } on _PipelineFailure catch (f) {
      _fail(job, f.code, f.message);
    } on ApiRefused catch (e) {
      // The server said no, and why — a photo answering a video challenge,
      // say. Retrying will not change that.
      _fail(job, 'refused', e.reason);
    } catch (e) {
      _fail(job, 'unknown', 'Something went wrong: $e');
    }
  }

  // —— Internal: misc plumbing ——————————————————————————————————————

  void _enqueue(UploadJob job) {
    activeJobs.value = [...activeJobs.value, job];
    // ignore: discarded_futures
    _persistJobs();
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
    // Failed jobs stay visible until the user retries or dismisses —
    // and persisted, so an app kill doesn't erase the retry option.
    // ignore: discarded_futures
    _persistJobs();
  }

  void _scheduleAutoDismiss(UploadJob job) {
    // Keep the "Posted ✓" state visible for 3s so the user actually
    // notices it. Then auto-dismiss to avoid clutter — a 4-post burst
    // would otherwise leave 4 stale entries on screen forever.
    Future.delayed(const Duration(seconds: 3), () => dismiss(job.id));
  }

  // —— Internal: crash-survival persistence ————————————————————————
  //
  // Jobs used to live only in memory: killing the app mid-upload lost
  // the post silently. We persist lightweight descriptors (paths +
  // metadata, never bytes) of every job that has enough information to
  // retry, and restore them as tappable-retry entries on next launch.
  // A job whose source file no longer exists (temp dir purged) is
  // dropped — retrying it could never work.

  File? _persistFile;

  /// For tests: find the jobs file again, in whatever folder the phone's
  /// documents are in now — each test has a folder of its own.
  @visibleForTesting
  void debugForgetJobsFile() {
    _persistFile = null;
    debugResetSaving();
  }

  /// For tests: start the queue of saves afresh. A save left over from the
  /// last test can never finish — that test's clock has stopped — and
  /// without this every save after it, and every post waiting on one,
  /// would wait for it for ever. Done before every test
  /// (test/flutter_test_config.dart).
  @visibleForTesting
  void debugResetSaving() => _saving = Future<void>.value();

  Future<File?> _jobsFile() async {
    if (_persistFile != null) return _persistFile;
    try {
      final dir = await getApplicationDocumentsDirectory();
      _persistFile = File('${dir.path}/upload_jobs_v1.json');
      return _persistFile;
    } catch (_) {
      return null;
    }
  }

  /// The save in progress, so the next one waits for it.
  Future<void> _saving = Future<void>.value();

  /// For tests: done when every save asked for so far has landed.
  @visibleForTesting
  Future<void> get debugSaved => _saving;

  /// For tests: save the list now, as any change to a post does.
  @visibleForTesting
  Future<void> debugSave() => _persistJobs();

  /// Saves the list, after any save already going, so the last state of the
  /// list is the one on disk.
  ///
  /// Most callers do not wait for this, so saves used to overlap. Two
  /// writes to one file at once can mix: a shorter list written over a
  /// longer one leaves the end of the longer one behind, the file no
  /// longer reads, and every unsent post is gone at the next start.
  Future<void> _persistJobs() {
    final next = _saving.then((_) => _writeJobs());
    _saving = next;
    return next;
  }

  Future<void> _writeJobs() async {
    final f = await _jobsFile();
    if (f == null) return;
    try {
      final descriptors = activeJobs.value
          .where((j) =>
              j.state.value.stage != UploadJobStage.done && j._hasRetryInfo)
          .map((j) => j._descriptor())
          .toList();
      // Written whole to a file of its own, then put in place in one step:
      // the app being killed mid-write leaves the last good list, not half
      // of a new one.
      final part = File('${f.path}.part');
      await part.writeAsString(json.encode(descriptors), flush: true);
      await part.rename(f.path);
    } catch (e) {
      debugPrint(
        '[upload] could not save the unsent posts, so they may not come '
        'back after the app closes: $e',
      );
    }
  }

  Future<void> _removePersisted(String jobId) => _persistJobs();

  /// Restore interrupted jobs from the last app run. Called once from
  /// main() after startup; fire-and-forget.
  Future<void> restorePersisted() async {
    final f = await _jobsFile();
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final list = json.decode(raw) as List<dynamic>;
      var restored = 0;
      for (final d in list) {
        final m = d as Map<String, dynamic>;
        final sourcePath = m['sourcePath'] as String? ?? '';
        if (sourcePath.isEmpty || !File(sourcePath).existsSync()) continue;
        final kind = m['kind'] == 'response'
            ? UploadJobKind.response
            : UploadJobKind.challenge;
        final job = UploadJob._(
          id: _newId(),
          kind: kind,
          sourcePath: sourcePath,
          title: kind == UploadJobKind.challenge
              ? 'Posting challenge'
              : 'Submitting response',
          challengeId: m['challengeId'] as String?,
          isPhoto: m['photo'] == true,
        );
        job._creatorId = m['creatorId'] as String?;
        job._responderId = m['responderId'] as String?;
        job._musicTrackId = m['musicTrackId'] as String? ?? '';
        final metaJson = m['meta'] as Map<String, dynamic>?;
        if (metaJson != null) {
          job._challengeMeta = ChallengeSubmissionMeta(
            prefix: metaJson['prefix'] as String? ?? '',
            subject: metaJson['subject'] as String? ?? '',
            visibility: metaJson['visibility'] as String? ?? 'arena',
            // Empty, not 'other'. A job saved before the app was killed
            // either carried a real category or carried nothing; inventing
            // 'other' on the way back in would tell the server the creator
            // answered when they had not.
            category: metaJson['category'] as String? ?? '',
            tags: (metaJson['tags'] as List? ?? [])
                .map((e) => e.toString())
                .toList(),
            emotionTags: (metaJson['emotionTags'] as List? ?? [])
                .map((e) => e.toString())
                .toList(),
            battleDays: metaJson['battleDays'] as int? ?? 0,
            visibleTo: (metaJson['visibleTo'] as List? ?? [])
                .map((e) => e.toString())
                .toList(),
            musicTrackId: metaJson['musicTrackId'] as String? ?? '',
            openToBattles: metaJson['openToBattles'] as bool? ?? true,
          );
        }
        if (!job._hasRetryInfo) continue;
        job._update((s) => s.copyWith(
              stage: UploadJobStage.failed,
              errorCode: 'interrupted',
              message: 'Upload was interrupted — tap retry',
            ));
        activeJobs.value = [...activeJobs.value, job];
        restored++;
      }
      if (restored > 0) {
        EventTracker.instance.track(
          eventType: 'upload_jobs_restored',
          contentId: 'restore',
          contentType: 'upload',
          metadata: {'count': restored},
        );
      }
    } catch (e) {
      // Corrupt persistence file — wipe it rather than fail every boot.
      // Said out loud: from the outside this looks exactly like having no
      // unsent posts.
      debugPrint(
        '[upload] the saved unsent posts could not be read, so none come '
        'back: $e',
      );
      try {
        await f.delete();
      } catch (e) {
        debugPrint('[upload] could not remove the unreadable list: $e');
      }
    }
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
  final String? activeVariant; // "thumbnail" | a rendition label
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

  /// A photo challenge or photo answer: [sourcePath] is the picture.
  final bool isPhoto;
  final ValueNotifier<UploadJobState> state =
      ValueNotifier(const UploadJobState());

  // Retry-only state (kept so the manager can rebuild a fresh job from
  // the same inputs without making the UI re-collect them).
  ChallengeSubmissionMeta? _challengeMeta;
  String? _creatorId;
  String? _responderId;

  /// An answer's free song, by its id in the music library; empty for
  /// none. (A challenge's rides in [_challengeMeta].)
  String _musicTrackId = '';

  /// The free song this answer credits, by its id; empty for none.
  String get musicTrackId => _musicTrackId;

  // Early-upload (prepare/finalize) state. _prepared completes with the
  // upload result when the prepare leg lands; _abandoned marks a job
  // whose create-flow was backed out of before Post.
  Completer<UploadResult?>? _prepared;
  bool _abandoned = false;

  /// How long the prepared video runs, measured during the prepare leg.
  ///
  /// The prepare leg transcodes and uploads; the finalize leg posts. Only
  /// the first of those sees the video, so the length has to be carried
  /// across. Zero means the prepare leg never got to measure it, which the
  /// server treats as "not stated" and settles by measuring the file.
  Duration _preparedDuration = Duration.zero;

  UploadJob._({
    required this.id,
    required this.kind,
    required this.sourcePath,
    required this.title,
    this.challengeId,
    this.isPhoto = false,
  });

  /// What the creator wrote, from the moment they pressed Post. Null while
  /// the video is only being prepared in the background as they type —
  /// nothing has been posted yet, so nothing should show as posting.
  ChallengeSubmissionMeta? get postedAs => _challengeMeta;

  /// A picture of the video on this phone, once processing has made one.
  /// Deleted with the other working files when the job ends.
  String? get posterPath => _poster;
  String? _poster;

  /// A job that runs nothing, sitting at [stage], for tests of code that
  /// reads the job list — "Free up space" asks it which files to keep.
  @visibleForTesting
  factory UploadJob.debug({
    required String sourcePath,
    required UploadJobStage stage,
    ChallengeSubmissionMeta? postedAs,
    double progress = 0,
    String? creatorId,
  }) {
    final job = UploadJob._(
      id: 'debug_${sourcePath.hashCode}_${stage.name}_${_debugJobs++}',
      kind: UploadJobKind.challenge,
      sourcePath: sourcePath,
      title: '',
    );
    job._challengeMeta = postedAs;
    job._creatorId = creatorId;
    job.state.value = UploadJobState(stage: stage, progress: progress);
    return job;
  }

  static int _debugJobs = 0;

  /// For tests: finish a [debug] job as the runner does — done, with the
  /// post the server made — and tell whoever listens for finished posts.
  @visibleForTesting
  void debugFinish(Object result) {
    _update((s) => s.copyWith(stage: UploadJobStage.done, result: result));
    UploadJobManager.instance._completedCtl.add(this);
  }

  void _update(UploadJobState Function(UploadJobState) f) {
    state.value = f(state.value);
  }

  /// A job is worth persisting only when a retry could actually run:
  /// challenges need creator + metadata, responses need responder + id.
  bool get _hasRetryInfo => switch (kind) {
        UploadJobKind.challenge => _creatorId != null && _challengeMeta != null,
        UploadJobKind.response => _responderId != null && challengeId != null,
      };

  Map<String, dynamic> _descriptor() => {
        'kind': kind == UploadJobKind.response ? 'response' : 'challenge',
        'sourcePath': sourcePath,
        'challengeId': challengeId,
        'creatorId': _creatorId,
        'responderId': _responderId,
        if (isPhoto) 'photo': true,
        if (_musicTrackId.isNotEmpty) 'musicTrackId': _musicTrackId,
        if (_challengeMeta != null)
          'meta': {
            'prefix': _challengeMeta!.prefix,
            'subject': _challengeMeta!.subject,
            'visibility': _challengeMeta!.visibility,
            'category': _challengeMeta!.category,
            'emotionTags': _challengeMeta!.emotionTags,
            'tags': _challengeMeta!.tags,
            'battleDays': _challengeMeta!.battleDays,
            'visibleTo': _challengeMeta!.visibleTo,
            if (_challengeMeta!.musicTrackId.isNotEmpty)
              'musicTrackId': _challengeMeta!.musicTrackId,
            // Kept, so a post retried after the app closed is still a
            // normal post if that is what was chosen.
            if (!_challengeMeta!.openToBattles) 'openToBattles': false,
          },
      };
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
  /// The creator's own words for what the video is about.
  ///
  /// These used to ride in on [emotionTags] because the backend had no
  /// field for them. It has one now, and the two mean different things:
  /// emotions come from a fixed list the ranker matches against a user's
  /// mood, while these are free text. Mixed together, neither worked.
  final List<String> tags;

  /// How many days voting runs once somebody answers: 7 to 30. Zero means
  /// the usual, which the server reads as 7.
  final int battleDays;

  /// For "Only friends": the particular friends chosen, by user id. Empty
  /// means all of them.
  final List<String> visibleTo;

  /// The free song mixed into the video, by its id in the music library.
  /// Empty for none.
  final String musicTrackId;

  /// Whether anybody may answer it with their own video. Off makes it a
  /// normal post, whose [subject] is its caption and [prefix] empty.
  final bool openToBattles;

  const ChallengeSubmissionMeta({
    required this.prefix,
    required this.subject,
    required this.visibility,
    required this.category,
    required this.emotionTags,
    this.tags = const [],
    this.battleDays = 0,
    this.visibleTo = const [],
    this.musicTrackId = '',
    this.openToBattles = true,
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
