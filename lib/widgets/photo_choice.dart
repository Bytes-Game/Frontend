import 'dart:io';

import 'package:flutter/material.dart';

import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/services/chat_media.dart';

/// "Take a photo" or "Choose from your photos", then the photo — for a
/// photo challenge or a photo answer.
///
/// The picture comes from the same picker a chat photo does (it is shrunk
/// to a few hundred KB there, see DevicePhotoSource), so a test can stand
/// in for the phone's camera the same way. Null when the person backed out
/// at either step. [camera] says it was taken just now, so it is not in the
/// phone's gallery yet.
Future<({File file, bool camera})?> choosePhoto(
  BuildContext context, {
  String title = '',
}) async {
  final camera = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ListTile(
              key: const ValueKey('post_photo_camera'),
              leading: const Icon(Icons.photo_camera_rounded, color: kAccent),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              key: const ValueKey('post_photo_gallery'),
              leading: const Icon(Icons.photo_library_rounded, color: kAccent),
              title: const Text('Choose from your photos'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    ),
  );
  if (camera == null || !context.mounted) return null;
  final file = await ChatMedia.instance.photos.pick(camera: camera);
  return file == null ? null : (file: file, camera: camera);
}
