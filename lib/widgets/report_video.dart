import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';

/// Report a video that doesn't match its challenge.
///
/// Asks first, because a report can cost somebody. Nothing is taken down:
/// when enough people report a video, or the server's check agrees with a
/// report, its owner loses rating points and the video stays up.
///
/// It can cost the reporter too. Somebody in the battle has a reason to
/// report the other side whatever it shows, so when [inBattle] they are told
/// that a report on a video the check finds DOES match costs them points.
///
/// [responseId] names an answer; empty reports the challenge's own video.
/// Returns what came of it, or null when the person changed their mind.
///
/// [photo] on a photo challenge. No check reads a photo — it only reads
/// videos — so only other viewers' reports can count, and the words say so.
Future<ReportResult?> reportVideo(
  BuildContext context, {
  required String challengeId,
  String responseId = '',
  bool inBattle = false,
  bool photo = false,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('report_dialog'),
      title: const Text("Doesn't match the challenge?"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            photo
                ? 'Report this photo only if it has nothing to do with what '
                      'the challenge asks. If enough other people agree, its '
                      'owner loses rating points. The photo stays up.'
                : 'Report this video only if it has nothing to do with what '
                      'the challenge asks. If our check or other people '
                      'agree, its owner loses rating points. The video stays '
                      'up.',
          ),
          if (inBattle) ...[
            const SizedBox(height: 10),
            Text(
              // On a photo the server counts a report from somebody in the
              // battle only when its check agrees, and it has no check for
              // photos — so it counts for nothing, and costs nothing.
              photo
                  ? "You're in this battle, so on a photo your report won't "
                        "count — only other viewers' reports do."
                  : "You're in this battle. If our check finds the video "
                        'does match the challenge, this report will cost you '
                        'rating points.',
              key: const ValueKey('report_in_battle'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('report_confirm'),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Report'),
        ),
      ],
    ),
  );
  if (sure != true) return null;
  final result = await ApiService.reportOffTopic(
    challengeId: challengeId,
    responseId: responseId,
  );
  messenger?.showSnackBar(SnackBar(content: Text(result.message)));
  return result;
}

/// The menu line that starts [reportVideo].
const reportMenuLabel = "Doesn't match the challenge";
