import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/device_gallery.dart';

/// A copy of what you post, in your phone's gallery, the way Instagram and
/// TikTok keep one.
///
/// Only for something the gallery does not have already: a photo or video
/// made with the app's camera, or one changed in an editor. A photo or
/// video picked from the gallery and posted unchanged is there already, and
/// a second copy would only take space.
///
/// The copy is the phone's own photo or video from then on: it does not
/// count towards the app's size, and it stays if the app is removed. The
/// app's own working copies are still deleted (see LeftoverFiles).
///
/// On until it is switched off in Settings, "Save your posts to your
/// phone". The choice is one word in a file of its own, like the other
/// small things the app remembers.
class SaveToPhone {
  SaveToPhone._();
  static final SaveToPhone instance = SaveToPhone._();

  /// Where the choice is kept. A seam for tests.
  @visibleForTesting
  static Future<Directory> Function() directory =
      getApplicationSupportDirectory;

  static const _fileName = 'save_posts_to_phone';

  bool? _on;

  /// Whether posts are saved to the phone. On until switched off.
  Future<bool> isOn() async {
    final known = _on;
    if (known != null) return known;
    var on = true;
    try {
      final f = File('${(await directory()).path}/$_fileName');
      if (await f.exists()) on = (await f.readAsString()).trim() != 'off';
    } catch (e) {
      debugPrint('[save] could not read "save your posts", so it is on: $e');
    }
    return _on = on;
  }

  Future<void> setOn(bool on) async {
    _on = on;
    try {
      final dir = await directory();
      await dir.create(recursive: true);
      await File(
        '${dir.path}/$_fileName',
      ).writeAsString(on ? 'on' : 'off', flush: true);
    } catch (e) {
      debugPrint('[save] could not remember "save your posts": $e');
    }
  }

  /// After a post: a copy of [path] in the gallery, when it is on. Says
  /// whether one was made.
  Future<bool> keep(String path, {required bool isVideo}) async {
    if (!await isOn()) return false;
    final kept = await DeviceGallery.instance.keepInGallery(
      path,
      isVideo: isVideo,
    );
    if (kept) debugPrint('[save] a copy of the post is in the gallery');
    return kept;
  }

  /// For tests: read the choice again, as a fresh start of the app would.
  @visibleForTesting
  void debugForget() => _on = null;
}
