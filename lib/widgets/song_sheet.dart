import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/song_edit.dart';

/// The song's settings, over an editor: which part of the song plays, how
/// long a photo shows for, how loud the song and the video's own sound are,
/// fades, and a way to change or remove the song.
///
/// The editor hears every change as it happens:
///   * [onVolume] — a volume moved: apply it now, without starting over.
///   * [onPart] — the part, a fade or the length changed: play the post
///     from its start, so the change is heard where it begins.
///
/// [length] is how long the post is — the kept part of a video, or the
/// photo's chosen length — asked again whenever the sheet redraws, since a
/// photo's can change in here.
Future<void> showSongSheet(
  BuildContext context, {
  required MusicTrack track,
  required SongEdit edit,
  required Duration Function() length,
  bool videoSound = false,
  List<Duration> lengths = const [],
  ValueChanged<Duration>? onLength,
  required VoidCallback onVolume,
  required VoidCallback onPart,
  required VoidCallback onChangeSong,
  required VoidCallback onRemoveSong,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surfaceDark,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) {
        final postLength = length();
        const muted = TextStyle(color: AppTheme.textMutedDark, fontSize: 13);
        Widget fade(String key, String label, bool on, ValueChanged<bool> set) =>
            FilterChip(
              key: ValueKey(key),
              label: Text(label),
              selected: on,
              showCheckmark: true,
              onSelected: (v) {
                setSheet(() => set(v));
                onPart();
              },
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.music_note_rounded,
                      color: AppTheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        track.credit.line,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (track.duration > const Duration(seconds: 2)) ...[
                  const SizedBox(height: 16),
                  const Text('Part of the song', style: muted),
                  const SizedBox(height: 8),
                  SongPartStrip(
                    songLength: track.duration,
                    length: postLength,
                    start: edit.startWithin(track.duration, postLength),
                    onChanged: (s) => setSheet(() => edit.start = s),
                    onChangeEnd: onPart,
                  ),
                ],
                if (lengths.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('How long the photo shows', style: muted),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final l in lengths)
                        ChoiceChip(
                          key: ValueKey('photo_length_${l.inSeconds}'),
                          label: Text('${l.inSeconds}s'),
                          selected: l == postLength,
                          onSelected: (_) {
                            onLength?.call(l);
                            setSheet(() {});
                            onPart();
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                const Text('Volume', style: muted),
                _Level(
                  label: 'Song',
                  sliderKey: 'music_volume',
                  value: edit.songVolume,
                  onChanged: (v) {
                    setSheet(() => edit.songVolume = v);
                    onVolume();
                  },
                ),
                if (videoSound)
                  _Level(
                    label: 'Video',
                    sliderKey: 'video_volume',
                    value: edit.videoVolume,
                    min: 0,
                    onChanged: (v) {
                      setSheet(() => edit.videoVolume = v);
                      onVolume();
                    },
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    fade(
                      'music_fade_in',
                      'Fade in',
                      edit.fadeIn,
                      (v) => edit.fadeIn = v,
                    ),
                    fade(
                      'music_fade_out',
                      'Fade out',
                      edit.fadeOut,
                      (v) => edit.fadeOut = v,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      key: const ValueKey('music_change'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onChangeSong();
                      },
                      child: const Text('Change song'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('music_remove'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onRemoveSong();
                      },
                      child: const Text(
                        'Remove song',
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// A volume slider with its name in front.
class _Level extends StatelessWidget {
  final String label;
  final String sliderKey;
  final double value;
  final double min;
  final ValueChanged<double> onChanged;

  const _Level({
    required this.label,
    required this.sliderKey,
    required this.value,
    required this.onChanged,
    this.min = 0.05,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: const TextStyle(color: Colors.white)),
        ),
        Expanded(
          child: Slider(
            key: ValueKey(sliderKey),
            value: value.clamp(min, 1.0),
            min: min,
            max: 1,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${(value * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(color: AppTheme.textMutedDark),
          ),
        ),
      ],
    );
  }
}

/// The whole song as a strip, with the part that plays marked on it: as
/// wide as the post is long. Drag it, or tap where it should be.
///
/// The bars are a ruler, all the same height. They do not show how loud
/// the song is there: the app does not read the song's sound, and bars
/// that looked like it would be telling a story that is not true.
class SongPartStrip extends StatelessWidget {
  final Duration songLength;

  /// How long the post is: the width of the marked part.
  final Duration length;

  /// Where the marked part starts.
  final Duration start;
  final ValueChanged<Duration> onChanged;
  final VoidCallback onChangeEnd;

  const SongPartStrip({
    super.key,
    required this.songLength,
    required this.length,
    required this.start,
    required this.onChanged,
    required this.onChangeEnd,
  });

  Duration get _latest => SongEdit.latestStart(songLength, length);

  Duration _clamp(Duration d) {
    if (d < Duration.zero) return Duration.zero;
    return d > _latest ? _latest : d;
  }

  Duration _at(double dx, double width) => Duration(
    microseconds: (songLength.inMicroseconds * dx / width).round(),
  );

  static String clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final whole = songLength <= length;
    final end = whole ? songLength : start + length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final width = box.maxWidth;
            return GestureDetector(
              key: const ValueKey('song_part'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: whole
                  ? null
                  : (d) => onChanged(_clamp(start + _at(d.delta.dx, width))),
              onHorizontalDragEnd: whole ? null : (_) => onChangeEnd(),
              onTapUp: whole
                  ? null
                  : (d) {
                      onChanged(
                        _clamp(_at(d.localPosition.dx, width) - length ~/ 2),
                      );
                      onChangeEnd();
                    },
              child: SizedBox(
                height: 48,
                width: width,
                child: CustomPaint(
                  painter: _StripPainter(
                    from: whole ? 0 : start.inMicroseconds / songLength.inMicroseconds,
                    to: whole ? 1 : end.inMicroseconds / songLength.inMicroseconds,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 6),
        Text(
          whole
              ? 'The whole song (${clock(songLength)}), then again from the '
                    'start'
              : '${clock(start)} – ${clock(end)}  of ${clock(songLength)}',
          key: const ValueKey('song_part_time'),
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }
}

class _StripPainter extends CustomPainter {
  /// The marked part, as fractions of the whole song.
  final double from;
  final double to;

  _StripPainter({required this.from, required this.to});

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 4.0;
    final bar = Paint()..strokeWidth = 2;
    final top = size.height * 0.25;
    final bottom = size.height * 0.75;
    for (var x = gap / 2; x < size.width; x += gap) {
      final f = x / size.width;
      bar.color = f >= from && f <= to ? Colors.white : Colors.white24;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), bar);
    }
    final window = RRect.fromRectAndRadius(
      Rect.fromLTRB(from * size.width, 2, to * size.width, size.height - 2),
      const Radius.circular(8),
    );
    canvas.drawRRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppTheme.primary,
    );
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.from != from || old.to != to;
}
