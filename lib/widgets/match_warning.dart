import 'package:flutter/material.dart';

// The warning, before a video goes up, that it has to match its challenge.
//
// A video that doesn't match costs its owner rating points: the server's
// check reads every upload, and people can report one. It never comes down —
// the owner pays instead. So people are told before they post, not after.

/// Above the button that posts a challenge.
const matchWarningChallenge =
    "Post a video that matches what you've written. If it doesn't, "
    "you'll lose rating points.";

/// Above the button that posts a photo challenge. No model checks a photo
/// (it only reads videos), but people can still report one that does not
/// match.
const matchWarningPhotoChallenge =
    "Post a photo that matches what you've written. If people report that "
    "it doesn't, you'll lose rating points.";

/// Under the button that takes a challenge on.
const matchWarningAnswer =
    'Your answer must do what the challenge asks. If it doesn\'t, '
    "you'll lose rating points.";

/// A small warning box: a flag and a sentence.
class MatchWarning extends StatelessWidget {
  final String text;

  const MatchWarning({super.key, required this.text});

  static const _amber = Color(0xFFFF9F0A);

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('match_warning'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.flag_rounded, size: 16, color: _amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last check before an answer is sent: does it answer [question]?
/// True to go ahead; false when the person wants to look again, and nothing
/// is sent.
///
/// [photo] for an answer to a photo challenge, which is a photo.
Future<bool> confirmAnswerMatches(
  BuildContext context,
  String question, {
  bool photo = false,
}) async {
  final what = photo ? 'photo' : 'video';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('answer_check'),
      title: Text('Does your $what answer this?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“$question”',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Text(
            "Only post a $what that does what the challenge asks. If it "
            "doesn't, you'll lose rating points.",
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Go back'),
        ),
        TextButton(
          key: const ValueKey('answer_check_post'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Post my answer'),
        ),
      ],
    ),
  );
  return ok == true;
}
