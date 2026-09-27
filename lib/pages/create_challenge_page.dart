import 'package:flutter/material.dart';

import 'package:myapp/services/create_flow.dart';
import 'package:myapp/services/page_tracker.dart';

/// Entry screen for the create-challenge flow. Two big choices: record
/// in-app or pick a file from the device. Whichever the user picks
/// drops them into [VideoTrimPage] with the source path; the trim
/// screen then forwards to [ChallengeMetadataPage] which runs the
/// transcode + upload + create.
///
/// We keep this screen deliberately small and full-bleed — it's a
/// decision page, not a form. The previous URL-paste form has been
/// retired now that the backend supports direct R2 uploads.
class CreateChallengePage extends StatefulWidget {
  const CreateChallengePage({super.key});

  @override
  State<CreateChallengePage> createState() => _CreateChallengePageState();
}

class _CreateChallengePageState extends State<CreateChallengePage>
    with PageTracker<CreateChallengePage> {
  @override
  String get pageName => 'create_challenge_page';

  bool _busy = false;

  // Both choices run the shared steps in CreateFlow, the same ones the
  // pop-out on the + button uses.
  Future<void> _onRecord() async {
    if (_busy) return;
    await CreateFlow.record(context, from: pageName);
  }

  Future<void> _onPickFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CreateFlow.upload(context, from: pageName);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      // Use the default theme scaffold/app-bar so the page picks up
      // the user's system theme (light or dark). The previous forced
      // Colors.black background washed out white38/white60 text and
      // looked out of place when the rest of the app was in light
      // mode.
      appBar: AppBar(
        elevation: 0,
        title: const Text('Create Challenge'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text(
                'How do you want to capture your challenge?',
                style: tt.titleMedium?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'You can record up to 60 seconds. We\'ll automatically '
                'create three quality versions so playback stays smooth '
                'on any network.',
                style: tt.bodyMedium?.copyWith(
                  // 0.72 lands comfortably above WCAG AA on both
                  // light and dark backgrounds; the old white60
                  // (0.235 effective on light) was unreadable.
                  color: cs.onSurface.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(height: 28),
              _bigChoice(
                cs: cs,
                icon: Icons.videocam_rounded,
                title: 'Record now',
                subtitle: 'Use the in-app camera with flip and flash',
                onTap: _busy ? null : _onRecord,
              ),
              const SizedBox(height: 16),
              _bigChoice(
                cs: cs,
                icon: Icons.video_library_rounded,
                title: 'Pick from device',
                subtitle: 'Upload a clip from your gallery or files',
                onTap: _busy ? null : _onPickFile,
              ),
              const Spacer(),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),
              Text(
                'Tip: shorter clips post faster and get watched more.',
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigChoice({
    required ColorScheme cs,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          // Subtle border so the card has a visible edge on both
          // light and dark themes — without it, in light mode the
          // surfaceContainerHighest can sit very close to the
          // background lightness and look flat.
          border: Border.all(
            color: cs.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 30, color: cs.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}
