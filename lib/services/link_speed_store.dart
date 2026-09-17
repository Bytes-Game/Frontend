import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Remembers roughly how fast this phone's connection was last time.
///
/// One number, in a one-line file. Not worth a database and not worth a
/// dependency: the value is a hint that the next run replaces within a few
/// downloads, so losing it costs one slightly cautious page of video.
///
/// It exists because the samples that produce it live in memory. Without
/// this, every launch opened blind and re-paid the whole cold start — the
/// first twenty reels committed to the largest files before a single byte
/// had been measured. See [NetworkQualityService.unmeasuredMaxLabel].
class LinkSpeedStore {
  LinkSpeedStore._();
  static final LinkSpeedStore instance = LinkSpeedStore._();

  static const String _fileName = 'link_speed_bps';

  /// Where the number lives. A seam, in the same spirit as the cache
  /// service's: the real implementation needs a platform directory, and
  /// tests want to exercise the reading and writing without one.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  File? _file;

  /// Drop the resolved handle so a test can point [directory] somewhere
  /// else. Without it the first test to run would pin the path for the
  /// whole file, and every test after it would be writing somewhere it did
  /// not choose.
  @visibleForTesting
  void debugForgetFile() => _file = null;

  Future<File?> _open() async {
    final existing = _file;
    if (existing != null) return existing;
    try {
      final dir = await directory();
      return _file = File('${dir.path}/$_fileName');
    } catch (e) {
      // No support directory is not a reason to fail a launch. The app
      // simply starts cautious, which is what it did before this existed.
      if (kDebugMode) debugPrint('link speed store unavailable: $e');
      return null;
    }
  }

  /// The remembered speed, or null if there is none or it is unreadable.
  ///
  /// Anything that is not a plain positive number is treated as absent
  /// rather than repaired: a corrupt hint and no hint lead to exactly the
  /// same behaviour, and pretending to parse it could seed the picker with
  /// nonsense that then decides what quality people are served.
  Future<int?> read() async {
    try {
      final f = await _open();
      if (f == null || !f.existsSync()) return null;
      final bps = int.tryParse((await f.readAsString()).trim());
      if (bps == null || bps <= 0) return null;
      return bps;
    } catch (e) {
      if (kDebugMode) debugPrint('link speed read failed: $e');
      return null;
    }
  }

  /// Keep [bps] for the next run. Failures are swallowed: this is a hint,
  /// and a phone that cannot write it still plays video.
  Future<void> write(int bps) async {
    if (bps <= 0) return;
    try {
      final f = await _open();
      if (f == null) return;
      await f.writeAsString('$bps', flush: true);
    } catch (e) {
      if (kDebugMode) debugPrint('link speed write failed: $e');
    }
  }
}
