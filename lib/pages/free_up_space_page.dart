import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/leftover_files.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/video_cache_service.dart';

/// Settings → Free up space. Shows what the app is keeping on the phone
/// and lets the user get it back, the way TikTok's screen of the same
/// name does.
///
/// Two kinds, because they behave differently:
///
///   * Saved videos: the start of upcoming videos, saved so a swipe opens
///     instantly, and whatever was watched this session. Always safe to
///     clear; it only costs a slower first second on the next few videos.
///     See [VideoCacheService.clear].
///   * Leftover recordings: copies that recording and posting leave behind.
///     Anything a post that has not finished still needs is kept. See
///     [LeftoverFiles].
class FreeUpSpacePage extends StatefulWidget {
  const FreeUpSpacePage({super.key});

  @override
  State<FreeUpSpacePage> createState() => _FreeUpSpacePageState();
}

class _FreeUpSpacePageState extends State<FreeUpSpacePage>
    with PageTracker<FreeUpSpacePage> {
  @override
  String get pageName => 'free_up_space_page';

  int? _savedVideos;
  LeftoverScan? _leftovers;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final saved = await VideoCacheService.instance.bytesOnDisk();
    final left = await LeftoverFiles.instance.scan();
    if (!mounted) return;
    setState(() {
      _savedVideos = saved;
      _leftovers = left;
    });
  }

  Future<void> _clear(String what, Future<int> Function() clear) async {
    if (_busy) return;
    setState(() => _busy = true);
    final int freed;
    try {
      freed = await clear();
      EventTracker.instance.trackTap(
        target: 'free_up_space_clear',
        pageName: pageName,
        params: {'what': what, 'bytes': freed},
      );
      await _measure();
    } finally {
      // Whatever went wrong, the buttons must come back. A screen stuck
      // with every button greyed out looks exactly like "nothing to clear".
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          freed > 0 ? 'Freed ${formatBytes(freed)}' : 'Nothing to clear',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final saved = _savedVideos;
    final left = _leftovers;
    final kept = left?.keptBytes ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Free up space')),
      body: SafeArea(
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppTheme.space16),
              child: Text(
                'Clearing never touches your posts, your gallery, or a post '
                'that is still sending.',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
              ),
            ),
            _row(
              key: const Key('free_up_space_saved_videos'),
              icon: Icons.play_circle_outline,
              title: 'Saved videos',
              subtitle:
                  'The start of videos, kept so they play instantly. '
                  'They download again when you need them.',
              bytes: saved,
              onClear: () =>
                  _clear('saved_videos', VideoCacheService.instance.clear),
            ),
            const Divider(height: 0),
            _row(
              key: const Key('free_up_space_leftovers'),
              icon: Icons.video_file_outlined,
              title: 'Leftover recordings',
              subtitle:
                  'Extra copies left behind after recording or posting.'
                  '${kept > 0 ? ' ${formatBytes(kept)} is kept for a post '
                            'that has not finished.' : ''}',
              bytes: left?.freeable,
              onClear: () => _clear('leftovers', LeftoverFiles.instance.clear),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required int? bytes,
    required VoidCallback onClear,
  }) {
    final measuring = bytes == null;
    return ListTile(
      key: key,
      leading: Icon(icon),
      title: Row(
        children: [
          Expanded(child: Text(title)),
          Text(
            measuring ? '…' : formatBytes(bytes),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      subtitle: Text(subtitle),
      isThreeLine: true,
      trailing: TextButton(
        onPressed: (_busy || measuring || bytes == 0) ? null : onClear,
        child: const Text('Clear'),
      ),
    );
  }
}

/// Bytes as a person reads them: "0 KB", "740 KB", "12.3 MB", "1.24 GB".
String formatBytes(int bytes) {
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / kb).ceil()} KB';
}
