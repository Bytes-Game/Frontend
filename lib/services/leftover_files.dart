import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/upload_job_manager.dart';

/// The copies of videos that recording and posting leave behind, and the
/// "Free up space" button that deletes them.
///
/// WHY THIS EXISTS
///
/// A recorded post passes through the app's temporary folder several times
/// on its way out, and nothing ever deleted the copies it left there:
///
///   REC…mp4            the camera's own recording (Android)
///   devf_record_…mp4   our copy of that, handed to the trim screen
///   devf_trim_…mp4     the trimmed video that actually gets posted
///   devf_upload_…/     the folder an upload works in, left behind after
///   file_picker/…      the picker's copy of a video chosen from the gallery
///
/// and since the editors and the Music button:
///
///   devf_edit_…mp4     a video the editor remade, a full copy of it
///   devf_cut_…mp4      a video the editor only cut shorter
///   devf_edit_still_…  a photo made into a still video, before its song
///                      goes under it (a devf_edit_ copy like any other)
///   edited_photo_…jpg  a photo the editor changed
///   post_photo_…jpg    a photo from the gallery, made ready to post
///   devf_music/…       the songs downloaded to put under a video
///
/// So every post left two or three full copies of its video on the phone.
/// The phone clears this folder itself when it runs low on space, which is
/// the only reason nobody noticed. Until then it just grows.
///
/// WHAT IT WILL NOT TOUCH
///
/// Anything a post that has not finished still needs, and every upload
/// working folder while an upload is running — both asked of
/// [UploadJobManager]. And nothing that does not match a name above: the
/// folder is shared with the saved-video cache and with other plugins, and
/// only these names are known to be ours to delete.
///
/// On iPhone the camera and the picker write to a different folder from
/// this one, which iOS empties on its own while the app is closed, so only
/// our own `devf_` copies are found there.
class LeftoverFiles {
  LeftoverFiles._();
  static final LeftoverFiles instance = LeftoverFiles._();

  /// Where to look: the app's temporary folder, or a scratch one in tests.
  @visibleForTesting
  static Future<Directory> Function() folder = getTemporaryDirectory;

  /// Android's camera names its recordings `REC` + digits + `.mp4`
  /// (camera_android_camerax, SystemServicesManager.getTempFilePath).
  static final RegExp _cameraRecording = RegExp(r'^REC\d+\.mp4$');

  /// Where the Music button keeps the songs it downloads.
  static const musicFolder = 'devf_music';

  /// Folders of separate things, each judged on its own. See [_units].
  static const _lookInside = {'file_picker', musicFolder};

  /// Whether a thing called [name], sitting directly in the temporary
  /// folder, is a leftover of ours.
  ///
  /// `file_picker` and [musicFolder] are not on this list on purpose. Each
  /// is a folder of separate things, and one pick can belong to a post that
  /// is still waiting — so they are looked inside, not judged whole. See
  /// [_units].
  static bool isLeftover(String name, {required bool isFolder}) {
    if (isFolder) return name.startsWith('devf_upload_');
    return name.startsWith('devf_record_') ||
        name.startsWith('devf_trim_') ||
        name.startsWith('devf_edit_') ||
        name.startsWith('devf_cut_') ||
        name.startsWith('edited_photo_') ||
        name.startsWith('post_photo_') ||
        _cameraRecording.hasMatch(name);
  }

  /// Delete [paths] — copies an editor made that were not posted — unless
  /// a post that has not finished still needs one. Returns the bytes freed.
  ///
  /// The editors call this as they close, rather than leaving a full copy
  /// of a remade video to wait for the next start of the app. Only names
  /// [isLeftover] knows are touched, so a caller that passes the original
  /// video or photo by mistake still cannot delete it.
  Future<int> forget(Iterable<String> paths) async {
    final needed = UploadJobManager.instance.filesStillNeeded;
    var freed = 0;
    for (final path in paths) {
      final name = path.split(Platform.pathSeparator).last;
      if (needed.contains(path) || !isLeftover(name, isFolder: false)) {
        continue;
      }
      final f = File(path);
      try {
        if (!f.existsSync()) continue;
        final size = f.lengthSync();
        f.deleteSync();
        freed += size;
      } on FileSystemException catch (e) {
        debugPrint('Free up space: could not delete $path: $e');
      }
    }
    if (freed > 0) {
      debugPrint(
        'Free up space: an editor\'s unposted copies freed '
        '${(freed / (1024 * 1024)).toStringAsFixed(1)} MB',
      );
    }
    return freed;
  }

  /// How much the leftovers take up, and how much of that has to stay.
  Future<LeftoverScan> scan() async {
    var bytes = 0;
    var kept = 0;
    for (final u in await _units()) {
      final size = _sizeOf(u.entity);
      bytes += size;
      if (u.keep) kept += size;
    }
    return LeftoverScan(bytes: bytes, keptBytes: kept);
  }

  /// Clear leftovers once, as the app starts. Returns the bytes freed.
  ///
  /// Without this they piled up until someone found the button: every post
  /// leaves its copies behind, and the phone only empties this folder when
  /// it is nearly full.
  ///
  /// [restored] is the upload list coming back from the last run. It is
  /// waited for first, because until it lands a post waiting for "tap to
  /// retry" is not on the list, and its video would look like a leftover.
  /// If it fails, nothing is deleted: not knowing is a reason to keep.
  ///
  /// Only files from before this launch are touched. Somebody who opens
  /// the app and records straight away must not lose that recording to a
  /// cleanup that happened to run a moment later.
  Future<int> clearAtStartup(Future<void> restored) async {
    final launchedAt = DateTime.now();
    try {
      await restored;
    } catch (e) {
      debugPrint(
        'Free up space: skipped the startup cleanup, the unsent '
        'posts could not be read back: $e',
      );
      return 0;
    }
    return clear(olderThan: launchedAt);
  }

  /// Delete every leftover that nothing still needs. Returns the bytes freed.
  ///
  /// With [olderThan], only leftovers last changed before then.
  Future<int> clear({DateTime? olderThan}) async {
    var freed = 0;
    var stuck = 0;
    for (final u in await _units()) {
      if (u.keep) continue;
      if (olderThan != null && !_changedBefore(u.entity, olderThan)) continue;
      final size = _sizeOf(u.entity);
      try {
        u.entity.deleteSync(recursive: true);
        freed += size;
      } on FileSystemException catch (e) {
        stuck++;
        debugPrint('Free up space: could not delete ${u.entity.path}: $e');
      }
    }
    debugPrint(
      'Free up space: leftovers freed '
      '${(freed / (1024 * 1024)).toStringAsFixed(1)} MB'
      '${stuck > 0 ? ", $stuck would not delete" : ""}',
    );
    return freed;
  }

  /// Every leftover, each marked with whether it has to stay.
  ///
  /// A "unit" is what gets deleted in one go: a file, an upload folder, or
  /// one pick inside the picker's folder.
  Future<List<_Unit>> _units() async {
    final Directory dir;
    try {
      dir = await folder();
    } catch (e) {
      debugPrint('Free up space: no temporary folder to look in: $e');
      return const [];
    }
    final needed = UploadJobManager.instance.filesStillNeeded;
    final running = UploadJobManager.instance.anyRunning;

    bool holdsNeeded(FileSystemEntity e) => needed.any(
      (p) => p == e.path || (e is Directory && p.startsWith('${e.path}/')),
    );

    final units = <_Unit>[];
    final List<FileSystemEntity> top;
    try {
      top = dir.listSync();
    } on FileSystemException catch (e) {
      debugPrint('Free up space: could not list ${dir.path}: $e');
      return const [];
    }
    for (final e in top) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final isFolder = e is Directory;
      if (isFolder && _lookInside.contains(name)) {
        try {
          for (final pick in e.listSync()) {
            units.add(_Unit(pick, keep: holdsNeeded(pick)));
          }
        } on FileSystemException catch (err) {
          debugPrint('Free up space: could not look inside ${e.path}: $err');
        }
        continue;
      }
      if (!isLeftover(name, isFolder: isFolder)) continue;
      final keep = holdsNeeded(e) || (isFolder && running);
      units.add(_Unit(e, keep: keep));
    }
    return units;
  }

  static bool _changedBefore(FileSystemEntity e, DateTime when) {
    try {
      return e.statSync().modified.isBefore(when);
    } on FileSystemException {
      return false; // cannot tell, so keep it
    }
  }

  static int _sizeOf(FileSystemEntity e) {
    try {
      if (e is File) return e.lengthSync();
      if (e is Directory) {
        var total = 0;
        for (final f in e.listSync(recursive: true)) {
          if (f is File) {
            try {
              total += f.lengthSync();
            } on FileSystemException {
              // Gone between the listing and the size check. Gone files
              // take no space, so leaving it out is the right answer.
            }
          }
        }
        return total;
      }
    } on FileSystemException {
      // The same: it went away while we were looking.
    }
    return 0;
  }
}

class _Unit {
  _Unit(this.entity, {required this.keep});
  final FileSystemEntity entity;
  final bool keep;
}

/// What [LeftoverFiles.scan] found.
class LeftoverScan {
  const LeftoverScan({required this.bytes, required this.keptBytes});

  /// Everything the leftovers take up, including what has to stay.
  final int bytes;

  /// The part a post that has not finished still needs.
  final int keptBytes;

  /// What pressing Clear would actually give back.
  int get freeable => bytes - keptBytes;
}
