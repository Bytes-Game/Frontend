import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/music_track.dart';

/// "♪ Title · Artist" under a video with a free song. Tapped, it shows the
/// whole credit — the artist, the licence, and where the song came from —
/// which is what the licence asks in return for the song being free.
class MusicCreditLine extends StatelessWidget {
  final MusicCredit credit;
  const MusicCreditLine({super.key, required this.credit});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMusicCredit(context, credit),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_note_rounded, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              credit.line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The whole credit for [credit], in a sheet.
Future<void> showMusicCredit(BuildContext context, MusicCredit credit) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surfaceDark,
    builder: (ctx) => SafeArea(
      child: Padding(
        key: const ValueKey('music_credit_sheet'),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.music_note_rounded, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    credit.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (credit.artist.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'by ${credit.artist}',
                style: const TextStyle(color: Colors.white70),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'Free music · ${credit.licenceLabel}',
              style: const TextStyle(color: AppTheme.textMutedDark),
            ),
            if (credit.attribution.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                credit.attribution,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
            if (credit.sourceUrl.isNotEmpty)
              _Link(label: 'Where the song is from', url: credit.sourceUrl),
            if (credit.licenceUrl.isNotEmpty)
              _Link(label: 'The licence', url: credit.licenceUrl),
          ],
        ),
      ),
    ),
  );
}

/// A web address, there to read or copy.
class _Link extends StatelessWidget {
  final String label;
  final String url;
  const _Link({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.textMutedDark,
                    fontSize: 12,
                  ),
                ),
                SelectableText(
                  url,
                  style: const TextStyle(color: AppTheme.primary, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(
              Icons.copy_rounded,
              color: Colors.white54,
              size: 18,
            ),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}
