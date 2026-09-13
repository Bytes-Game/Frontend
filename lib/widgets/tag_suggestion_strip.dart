import 'package:flutter/material.dart';

import 'package:myapp/services/api_service.dart';

/// Offers the creator the tags the model noticed on their own video.
///
/// ══════════════════════════════════════════════════════════════════════════
/// WHY THIS IS HERE AND NOT ON THE POSTING SCREEN
/// ══════════════════════════════════════════════════════════════════════════
///
/// Every video is read, listened to and looked at after it is posted. That
/// pass produces topics in the model's own words — "street food", "long
/// distance relationship" — and it was all for the machine. The person who
/// made the video never saw any of it, and their own tags, which decide who
/// the video reaches, stayed whatever they typed in the half minute before
/// posting.
///
/// It cannot happen while they are posting. The pass runs on a build machine
/// that takes about two minutes to start before it does anything, measured
/// with every binary and model already cached. Nobody spends two minutes on
/// the title screen, and the ways around that — a hosted API, or a model on
/// the phone — cost either the creator's privacy or half a gigabyte of app.
///
/// Waiting is not just the cheap option. By the time this runs the model has
/// watched the whole video, rather than guessing from a title nobody has
/// written yet.
///
/// ══════════════════════════════════════════════════════════════════════════
/// IT MUST BE POSSIBLE TO IGNORE
/// ══════════════════════════════════════════════════════════════════════════
///
/// This sits in a feed somebody is scrolling. So it renders nothing at all
/// until it has something to offer: no spinner, no empty box, no layout shift
/// on a reel that has no suggestions — which is most of them, most of the
/// time. Every failure is silence.
class TagSuggestionStrip extends StatefulWidget {
  /// The challenge this is about. The server checks that the caller made it.
  final String challengeId;

  const TagSuggestionStrip({super.key, required this.challengeId});

  @override
  State<TagSuggestionStrip> createState() => _TagSuggestionStripState();
}

class _TagSuggestionStripState extends State<TagSuggestionStrip> {
  TagSuggestions? _s;
  bool _busy = false;
  /// Which challenge the current [_s] belongs to. A reel tile is reused as
  /// the feed scrolls, so without this the tags from the last video would
  /// briefly show on the next one — and worse, a tap would file them against
  /// the wrong video.
  String _loadedFor = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TagSuggestionStrip old) {
    super.didUpdateWidget(old);
    if (old.challengeId != widget.challengeId) {
      setState(() => _s = null);
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.challengeId;
    if (id.isEmpty) return;
    final got = await ApiService.getTagSuggestions(id);
    // The feed may have moved on while this was in flight.
    if (!mounted || widget.challengeId != id) return;
    setState(() {
      _s = got;
      _loadedFor = id;
    });
  }

  Future<void> _decide({String? add, bool dismissAll = false}) async {
    final id = widget.challengeId;
    final s = _s;
    if (s == null || _busy || id.isEmpty) return;
    setState(() => _busy = true);
    final got = await ApiService.decideTagSuggestions(
      id,
      add: add == null ? const [] : [add],
      dismiss: dismissAll ? s.suggested : const [],
    );
    if (!mounted || widget.challengeId != id) return;
    setState(() {
      _busy = false;
      // A failed call leaves what was there. Guessing the new state and
      // being wrong would show the creator tags they do not have.
      if (got != null) _s = got;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    // Nothing to say, or not about this reel yet: take up no space.
    if (s == null || s.isEmpty || _loadedFor != widget.challengeId) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              const Text(
                'Spotted in your video',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const Spacer(),
              TextButton(
                onPressed: _busy ? null : () => _decide(dismissAll: true),
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'No thanks',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in s.suggested)
                ActionChip(
                  label: Text('# $tag'),
                  avatar: const Icon(Icons.add, size: 15),
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 12),
                  onPressed: _busy ? null : () => _decide(add: tag),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
