import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';

/// Report a video that doesn't match its challenge.
///
/// Asks first, because a report can cost somebody their battle: the server
/// takes the video down when its model agrees the video doesn't match, or
/// when enough viewers report it, and its owner loses rating points.
///
/// [responseId] names an answer; empty reports the challenge's own video.
/// Returns what came of it, or null when the person changed their mind.
Future<ReportResult?> reportVideo(
  BuildContext context, {
  required String challengeId,
  String responseId = '',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('report_dialog'),
      title: const Text("Doesn't match the challenge?"),
      content: const Text(
        'Report this video only if it has nothing to do with what the '
        'challenge asks. If that is confirmed, the video is taken down and '
        'its owner loses the battle and rating points.',
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
