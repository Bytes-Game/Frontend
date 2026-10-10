import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:myapp/models/music_track.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/pages/create_page.dart';
import 'package:myapp/pages/photo_editor_page.dart';
import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/pages/video_editor_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_processor_service.dart';

/// How a challenge starts, in one place, so the + button and a profile's
/// Battle button run the same steps rather than two copies that drift
/// apart.
///
/// Both open the create page: the phone's photos and videos in a grid,
/// with the camera first — the way Instagram and TikTok do it. Nobody is
/// asked "photo or video?": the thing picked already is one or the other.
/// Either goes on to its editor (a photo's, or a video's with the trim bar)
/// and then the details.
class CreateFlow {
  CreateFlow._();

  /// The create page. Returns when it closes — after a post, or when the
  /// person backed out.
  static Future<void> open(BuildContext context, {String from = ''}) async {
    EventTracker.instance.trackTap(
      target: 'create_challenge_open',
      pageName: from.isEmpty ? 'create_challenge_page' : from,
    );
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => CreatePage(from: from)));
  }

  /// The in-app camera, which takes a photo or records a video. Asks for
  /// the camera and microphone first; without both there is no preview to
  /// show, so it says so rather than opening a black screen. True when
  /// what it made was posted.
  static Future<bool> camera(BuildContext context, {String from = ''}) async {
    EventTracker.instance.trackTap(
      target: 'create_challenge_record',
      pageName: from.isEmpty ? 'create_challenge_page' : from,
    );
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!context.mounted) return false;
    if (!cam.isGranted || !mic.isGranted) {
      _toast(context, 'Camera and microphone permission required.');
      return false;
    }
    final made = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const RecordVideoPage(allowPhoto: true),
      ),
    );
    if (!context.mounted || made == null || made.isEmpty) return false;
    return continueWith(
      context,
      made,
      photo: RecordVideoPage.isPhotoPath(made),
      // Made just now: not in the gallery, so a copy is kept there.
      inGallery: false,
    );
  }

  /// With a photo or a video in hand: to its editor, and from there to the
  /// details. True when it was posted; false when the person came back
  /// without posting.
  ///
  /// The editor stays underneath the details page, so coming back from the
  /// details lands on the editor with the edits still there.
  ///
  /// [inGallery] is whether [path] is in the phone's gallery already; see
  /// SaveToPhone.
  static Future<bool> continueWith(
    BuildContext context,
    String path, {
    required bool photo,
    bool inGallery = true,
  }) async {
    EventTracker.instance.track(
      eventType: 'create_challenge_source_selected',
      contentId: 'pending',
      contentType: 'challenge',
      metadata: {
        'kind': photo ? 'photo' : 'video',
        'reelMaxSeconds': VideoProcessorService.maxReelDuration.inSeconds,
      },
    );
    final nav = Navigator.of(context);
    Future<bool> details(
      BuildContext from,
      String edited,
      MusicTrack? music,
    ) async {
      final posted = await Navigator.of(from).push<bool>(
        MaterialPageRoute(
          builder: (_) => ChallengeMetadataPage(
            processedSourcePath: edited,
            // A photo with a song comes back as a video: the photo, still,
            // with the song under it (see PhotoEditorPage).
            photo: photo && music == null,
            music: music,
          ),
        ),
      );
      return posted == true;
    }

    final posted = await nav.push<bool>(
      MaterialPageRoute(
        builder: (_) => photo
            ? PhotoEditorPage(
                sourcePath: path,
                onDone: details,
                inGallery: inGallery,
              )
            : VideoEditorPage(
                sourcePath: path,
                onDone: details,
                inGallery: inGallery,
              ),
      ),
    );
    return posted == true;
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}
