import 'package:flutter/material.dart';

import 'package:myapp/services/upload_job_manager.dart';

/// UploadStatusOverlay — floating banner stack that mirrors every
/// in-flight upload from [UploadJobManager]. Mounted at the app root
/// (in [MyApp.builder]) so it sits on top of whatever page the user is
/// on and stays put when they navigate.
///
/// This is the visual half of the TikTok-style background-upload
/// pattern: the user taps "Post", we pop them back to the feed
/// instantly, and this banner shows "Posting…" with live progress
/// while the upload finishes in the background. On success it flashes
/// "Posted ✓" then auto-dismisses ~3s later; on failure it sticks
/// around with a retry button.
///
/// Anchored bottom-center with a comfortable bottom inset so it doesn't
/// collide with the bottom nav bar. Multiple in-flight jobs stack
/// vertically (rare but possible — the user can post a challenge and a
/// response back-to-back).
class UploadStatusOverlay extends StatelessWidget {
  /// The child is the rest of the app — usually the routed page tree.
  /// We wrap it in a Stack so the banner can float over everything
  /// without affecting layout of the underlying widgets.
  final Widget child;
  const UploadStatusOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      // No clipping — banners can overflow the parent's bounds during
      // the slide-up entrance animation without getting cut off.
      clipBehavior: Clip.none,
      children: [
        child,
        // SafeArea so the banner sits above the system nav bar on
        // gesture-nav phones without Android cutting off the bottom.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            // Bottom inset clears the persistent bottom nav (typically
            // ~56-72px on Material 3). 80 picks a safe number that
            // doesn't depend on us reaching into MainShell to introspect.
            minimum: const EdgeInsets.only(bottom: 80),
            child: ValueListenableBuilder<List<UploadJob>>(
              valueListenable: UploadJobManager.instance.activeJobs,
              builder: (context, jobs, _) {
                if (jobs.isEmpty) return const SizedBox.shrink();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final job in jobs)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: _UploadJobCard(
                          key: ValueKey(job.id),
                          job: job,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Single banner for one [UploadJob]. Rebuilds on every progress tick
/// via the job's own [ValueNotifier] so the parent overlay doesn't
/// rebuild the whole stack on every byte uploaded.
class _UploadJobCard extends StatelessWidget {
  final UploadJob job;
  const _UploadJobCard({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<UploadJobState>(
      valueListenable: job.state,
      builder: (context, state, _) {
        final isFailed = state.stage == UploadJobStage.failed;
        final isDone = state.stage == UploadJobStage.done;
        final bg = isFailed
            ? cs.errorContainer
            : isDone
                ? cs.tertiaryContainer
                : cs.surfaceContainerHighest;
        final fg = isFailed
            ? cs.onErrorContainer
            : isDone
                ? cs.onTertiaryContainer
                : cs.onSurface;
        return Material(
          color: bg,
          elevation: 4,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            // Tap behavior: failed → no-op (use retry button), done →
            // dismiss early, in-progress → no-op (don't let user
            // accidentally lose the banner mid-flight).
            onTap: isDone
                ? () => UploadJobManager.instance.dismiss(job.id)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        isFailed
                            ? Icons.error_outline
                            : isDone
                                ? Icons.check_circle_outline
                                : Icons.cloud_upload_outlined,
                        size: 18,
                        color: fg,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isDone
                              ? '${job.title} ✓'
                              : (state.message ?? job.title),
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isFailed) ...[
                        TextButton(
                          onPressed: () =>
                              UploadJobManager.instance.retry(job),
                          style: TextButton.styleFrom(
                            foregroundColor: fg,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('Retry'),
                        ),
                        IconButton(
                          tooltip: 'Dismiss',
                          icon: Icon(Icons.close, size: 18, color: fg),
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              UploadJobManager.instance.dismiss(job.id),
                        ),
                      ],
                    ],
                  ),
                  if (!isFailed && !isDone) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: state.progress > 0 ? state.progress : null,
                        minHeight: 3,
                        backgroundColor: fg.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
