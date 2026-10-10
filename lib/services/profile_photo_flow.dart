import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/media_upload_service.dart';

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
        builder: (_) => CropRotateEditor.file(
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
            ),
          ),
        ),
      ),
    );
    return out;
  }
}
