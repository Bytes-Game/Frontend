import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/media_upload_service.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// What changing the profile photo came to.
class PhotoChange {
  /// The profile as the server now has it; null when nothing changed.
  final UserModel? user;

  /// Why it did not change, in words for the person; empty when it did, or
  /// when they backed out.
  final String problem;

  const PhotoChange({this.user, this.problem = ''});
}

/// Changing your profile photo, the way Instagram does it: take one or pick
/// one, frame it in a circle, and it is everywhere.
///
/// The photo is uploaded the way a photo post is, then its address is saved
/// on your profile. The server only accepts a picture you uploaded (see
/// profile_photo.go), and DataProvider.setUser puts it into the AvatarBook,
/// so every place you appear shows it at once.
class ProfilePhotoFlow {
  ProfilePhotoFlow._();

  /// Frames [photo] in a square, shown as a circle; the picture as JPEG
  /// bytes, or null when the person backed out. A seam: tests stand in for
  /// the editor, which needs a real picture decoder.
  static Future<Uint8List?> Function(BuildContext context, File photo) crop =
      _cropWithEditor;

  /// The most a profile photo needs to be. It is never shown bigger than
  /// the profile page's circle.
  static const maxSide = 640.0;

  /// Take a photo ([camera]) or choose one, frame it, upload it, and save
  /// it as [me]'s profile photo.
  static Future<PhotoChange> change(
    BuildContext context,
    UserModel me, {
    required bool camera,
  }) async {
    final picked = await ChatMedia.instance.photos.pick(camera: camera);
    if (picked == null || !context.mounted) return const PhotoChange();
    final framed = await crop(context, picked);
    if (framed == null || framed.isEmpty) return const PhotoChange();
    final File file;
    try {
      // edited_photo_: the app's clean-up knows it as the editor's copy.
      final dir = await getTemporaryDirectory();
      file = File(
        '${dir.path}/edited_photo_profile_'
        '${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(framed, flush: true);
    } catch (e) {
      debugPrint('[profile] the framed photo could not be kept: $e');
      return const PhotoChange(problem: "Couldn't use that photo. Try again.");
    }
    final up = await MediaUploadService.instance.uploadPhoto(
      userId: me.id,
      photo: file,
    );
    if (up == null) {
      return const PhotoChange(
        problem: "Couldn't upload your photo. Check your connection and "
            'try again.',
      );
    }
    return _save(me, up.defaultVideoUrl);
  }

  /// Closes the crop screen. A seam, so a test can see that the tick
  /// leads somewhere.
  @visibleForTesting
  static void closeCrop(BuildContext route) {
    final nav = Navigator.of(route);
    if (nav.canPop()) nav.pop();
  }

  /// The whole of changing your photo from one tap — on your profile's
  /// picture, or on Edit profile: take one, choose one, or remove it; then
  /// it is framed, uploaded and on screen everywhere, and a few words say
  /// how it went. [onBusy] is told while it uploads, for a spinner.
  static Future<void> chooseAndChange(
    BuildContext context, {
    ValueChanged<bool>? onBusy,
  }) async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final me = dp.user;
    if (me == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('profile_photo_camera'),
              leading: const Icon(Icons.photo_camera_rounded, color: kAccent),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              key: const ValueKey('profile_photo_gallery'),
              leading: const Icon(Icons.photo_library_rounded, color: kAccent),
              title: const Text('Choose from your photos'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (me.avatarUrl.isNotEmpty)
              ListTile(
                key: const ValueKey('profile_photo_remove'),
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: const Text(
                  'Remove current picture',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    onBusy?.call(true);
    final PhotoChange change;
    try {
      change = choice == 'remove'
          ? await remove(me)
          : await ProfilePhotoFlow.change(context, me,
              camera: choice == 'camera');
    } finally {
      onBusy?.call(false);
    }
    final updated = change.user;
    final say = context.mounted ? ScaffoldMessenger.maybeOf(context) : null;
    if (updated != null) {
      // Only the photo is taken from the answer: anything else on the
      // profile (an Edit profile form half filled in) stays as it is.
      final now = dp.user ?? me;
      dp.setUser(now.copyWith(avatarUrl: updated.avatarUrl));
      say?.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(updated.avatarUrl.isEmpty
            ? 'Profile photo removed'
            : 'Profile photo updated'),
      ));
    } else if (change.problem.isNotEmpty) {
      say?.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(change.problem),
      ));
    }
  }

  /// Take the profile photo away; the initial shows again.
  static Future<PhotoChange> remove(UserModel me) => _save(me, '');

  static Future<PhotoChange> _save(UserModel me, String url) async {
    final saved = await ApiService.updateUserProfile(
      userId: me.id,
      avatarUrl: url,
    );
    if (!saved.success) {
      debugPrint('[profile] the photo was not saved: ${saved.error}');
      return const PhotoChange(
        problem: "Couldn't change your photo. Try again.",
      );
    }
    return PhotoChange(user: saved.user ?? me.copyWith(avatarUrl: url));
  }

  static Future<Uint8List?> _cropWithEditor(
    BuildContext context,
    File photo,
  ) async {
    Uint8List? out;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (route) => CropRotateEditor.file(
          photo,
          initConfigs: CropRotateEditorInitConfigs(
            theme: editorTheme,
            convertToUint8List: true,
            configs: ProImageEditorConfigs(
              theme: editorTheme,
              cropRotateEditor: const CropRotateEditorConfigs(
                initAspectRatio: 1,
                aspectRatios: [AspectRatioItem(text: '1:1', value: 1)],
                // Framed in a circle, the way it will be shown; saved
                // square, so nothing outside the circle turns black.
                initialCropMode: CropMode.oval,
                exportOvalMask: false,
              ),
              imageGeneration: const ImageGenerationConfigs(
                outputFormat: OutputFormat.jpg,
                jpegQuality: 90,
                maxOutputSize: Size(maxSide, maxSide),
              ),
            ),
            callbacks: ProImageEditorCallbacks(
              onImageEditingComplete: (bytes) async => out = bytes,
              // The tick, and the X. The editor hands the picture over and
              // then asks to be closed — and with nothing here to close it,
              // the tick left you sitting on the crop screen with your
              // photo already chosen. Now it goes, and you are back where
              // you started, watching your new photo arrive.
              onCloseEditor: (_) => closeCrop(route),
            ),
          ),
        ),
      ),
    );
    return out;
  }
}
