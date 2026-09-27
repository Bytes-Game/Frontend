import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_processor_service.dart';

/// The two ways a challenge starts — record now, or upload from the phone —
/// in one place, so the pop-out on the + button and the one on a profile's
/// Battle button run the same steps rather than two copies that drift
/// apart.
///
/// Either way ends on the trim screen with the clip, which then carries on
/// to the details screen and the upload.
class CreateFlow {
  CreateFlow._();

  /// Open the in-app camera. Asks for camera and microphone first; without
  /// both there is no preview to show, so it says so rather than opening a
  /// black screen.
  static Future<void> record(BuildContext context, {String from = ''}) async {
    EventTracker.instance.trackTap(
      target: 'create_challenge_record',
      pageName: from.isEmpty ? 'create_challenge_page' : from,
    );
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!context.mounted) return;
    if (!cam.isGranted || !mic.isGranted) {
      _toast(context, 'Camera and microphone permission required.');
      return;
    }
    final recorded = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const RecordVideoPage()));
    if (!context.mounted || recorded == null || recorded.isEmpty) return;
    await _continueWithSource(context, recorded);
  }

  /// Pick a video from the phone.
  static Future<void> upload(BuildContext context, {String from = ''}) async {
    EventTracker.instance.trackTap(
      target: 'create_challenge_pick',
      pageName: from.isEmpty ? 'create_challenge_page' : from,
    );
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
      // A real path on disk, not a stream — the trim step hands the path
      // straight to the native trimmer.
      withData: false,
    );
    if (!context.mounted) return;
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.first.path;
    if (path == null || path.isEmpty) {
      _toast(context, 'Could not read the selected file. Try another.');
      return;
    }
    await _continueWithSource(context, path);
  }

  /// With a clip in hand, recorded or picked: on to the trim screen.
  static Future<void> _continueWithSource(
    BuildContext context,
    String sourcePath,
  ) async {
    EventTracker.instance.track(
      eventType: 'create_challenge_source_selected',
      contentId: 'pending',
      contentType: 'challenge',
      metadata: {
        'reelMaxSeconds': VideoProcessorService.maxReelDuration.inSeconds,
      },
    );
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VideoTrimPage(sourcePath: sourcePath)),
    );
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}
