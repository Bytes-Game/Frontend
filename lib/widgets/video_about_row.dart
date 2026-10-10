import 'package:flutter/material.dart';

import 'package:myapp/models/video_about.dart';
import 'package:myapp/services/api_service.dart';

/// "What's this video about?" — the app's answer to Instagram's AI button
/// under a reel.
///
/// A tap opens it, and it says in a sentence or two what happens in the
/// video and what is said in it. The server's model wrote that sentence
/// while it watched the upload anyway (see video_about.go on the server),
/// so asking costs one small request and no waiting for a model.
///
/// It always says where the sentence came from, and that a model wrote it
/// and can be wrong: it is a guess about somebody else's video, not their
/// words.
class VideoAboutRow extends StatefulWidget {
  final String challengeId;

  /// The answer in a battle, when that is the video on screen; empty for
  /// the challenger's.
  final String responseId;

  /// Whose answer it is, for the label; empty for the challenger's video.
  final String whose;

  const VideoAboutRow({
    super.key,
    required this.challengeId,
    this.responseId = '',
    this.whose = '',
  });

  /// Answers already read, so opening the comments again shows it at once.
  /// Only finished ones: a video still being looked at is asked again.
  static final _known = <String, VideoAbout>{};

  @visibleForTesting
  static void debugForget() => _known.clear();

  @override
  State<VideoAboutRow> createState() => _VideoAboutRowState();
}

// The comment sheet's own colours: it is dark whatever the phone's theme.
const _white = Colors.white;
const _muted = Color(0xFF8E8E93);
const _accent = Color(0xFF0A84FF);

class _VideoAboutRowState extends State<VideoAboutRow> {
  bool _open = false;
  bool _loading = false;
  bool _failed = false;
  VideoAbout? _about;

  String get _key => '${widget.challengeId}/${widget.responseId}';

  @override
  void initState() {
    super.initState();
    _about = VideoAboutRow._known[_key];
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final got = await ApiService.getVideoAbout(
      widget.challengeId,
      responseId: widget.responseId,
    );
    if (!mounted) return;
    if (got != null && got.looked) VideoAboutRow._known[_key] = got;
    setState(() {
      _loading = false;
      _about = got;
      // ApiService has already said why in the log.
      _failed = got == null;
    });
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open && _about == null && !_loading) _load();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.whose.isEmpty
        ? "What's this video about?"
        : "What's ${widget.whose}'s answer about?";
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('video_about_ask'),
          onTap: _toggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome_rounded, size: 15, color: _accent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  _open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: _accent,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: _open ? _answer() : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _answer() {
    if (_loading) {
      return const Padding(
        key: ValueKey('video_about_loading'),
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: _muted),
            ),
            SizedBox(width: 8),
            Text('Reading the video…',
                style: TextStyle(color: _muted, fontSize: 13)),
          ],
        ),
      );
    }
    if (_failed) {
      return InkWell(
        key: const ValueKey('video_about_retry'),
        onTap: _load,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text(
            "Couldn't load that. Tap to try again.",
            style: TextStyle(color: _muted, fontSize: 13),
          ),
        ),
      );
    }
    final a = _about ?? const VideoAbout();
    final String text;
    final String note;
    if (a.about.isNotEmpty) {
      text = a.about;
      note = a.from == 'shown'
          ? 'Written by AI from what happens in the video. It can be wrong.'
          : 'Written by AI from what is said and shown in the video. It can '
              'be wrong.';
    } else if (a.topics.isNotEmpty) {
      text = 'Looks like: ${a.topics.take(5).join(', ')}.';
      note = 'AI could not sum this one up, so these are its best words for '
          'it. They can be wrong.';
    } else if (!a.looked) {
      text = 'This video is still being looked at.';
      note = 'Check back in a few minutes.';
    } else {
      text = 'Nothing to say about this one.';
      note = 'AI looked, but could not tell what it is about.';
    }
    return Container(
      key: const ValueKey('video_about_answer'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 2, bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            key: const ValueKey('video_about_text'),
            style: const TextStyle(color: _white, fontSize: 14, height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(note, style: const TextStyle(color: _muted, fontSize: 11.5)),
        ],
      ),
    );
  }
}
