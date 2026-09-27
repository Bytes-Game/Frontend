import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Your own videos, kept on the phone after you post them, so they play at
/// once instead of being downloaded again.
///
/// ════════════════════════════════════════════════════════════════════════
/// WHY
/// ════════════════════════════════════════════════════════════════════════
///
/// Posting a video uploads it and then forgets it. The file was right there
/// on the phone a moment before, and the next time you opened it from your
/// profile the app fetched it back from the server like anybody else's —
/// the same wait, for a video you made.
///
/// The short-video apps people know keep what you post for a while, so your
/// own videos open straight away. This does the same: when a post finishes,
/// the clip that went up is copied here under its video id, and a reel of
/// yours plays that file.
///
/// Bounded: the newest [maxFiles], within [maxBytes] together. Emptied on
/// sign-out — the next person to use the phone should not find them.
class OwnUploads {
  OwnUploads._();

  static final OwnUploads instance = OwnUploads._();

  static const int maxFiles = 12;
  static const int maxBytes = 300 * 1024 * 1024;

  /// A single video bigger than this is not copied. A long clip picked from
  /// the gallery can be gigabytes, and copying it would take the space it
  /// was meant to save.
  static const int maxOneFile = 150 * 1024 * 1024;

  /// Where the files live. Replaceable for tests.
  @visibleForTesting
  Future<Directory> Function() folder = () async =>
      Directory('${(await getApplicationSupportDirectory()).path}/own_uploads');

  /// video key ("challenge:12", "response:7") → file on the phone, newest
  /// last.
  final Map<String, String> _files = {};
  bool _loaded = false;

  /// For tests: as if the app had just started.
  @visibleForTesting
  void debugForget() {
    _files.clear();
    _loaded = false;
  }

  /// Read what was kept last time. Called once at start-up; until it has
  /// run, [pathFor] knows nothing and videos play from the network as they
  /// always did.
  Future<void> init() async {
    if (_loaded) return;
    try {
      final dir = await folder();
      final index = File('${dir.path}/index.json');
      if (index.existsSync()) {
        final m = json.decode(await index.readAsString()) as Map;
        for (final e in m.entries) {
          final path = '${e.value}';
          if (File(path).existsSync()) _files['${e.key}'] = path;
        }
      }
    } catch (e) {
      debugPrint(
        '[own uploads] could not read what was kept: $e; '
        'your videos play from the server instead',
      );
    }
    _loaded = true;
  }

  /// The copy of [key] on this phone, if there is one.
  String? pathFor(String key) {
    final p = _files[key];
    if (p == null) return null;
    if (!File(p).existsSync()) {
      _files.remove(key);
      return null;
    }
    return p;
  }

  /// Keep a copy of [source] as [key]. Never throws: a copy that fails
  /// means the video plays from the server, as before.
  Future<void> keep(String key, String source) async {
    try {
      final from = File(source);
      if (!from.existsSync()) {
        debugPrint(
          '[own uploads] $key: the posted file is already gone; '
          'it will play from the server',
        );
        return;
      }
      final size = from.lengthSync();
      if (size > maxOneFile) {
        debugPrint(
          '[own uploads] $key: ${size ~/ (1024 * 1024)} MB is too '
          'big to keep a copy of; it will play from the server',
        );
        return;
      }
      final dir = await folder();
      await dir.create(recursive: true);
      final safe = key.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
      final ext = source.contains('.') ? source.split('.').last : 'mp4';
      final to = await from.copy('${dir.path}/$safe.$ext');
      _files.remove(key);
      _files[key] = to.path;
      await _trim();
      await _save(dir);
    } catch (e) {
      debugPrint(
        '[own uploads] could not keep $key: $e; '
        'it will play from the server',
      );
    }
  }

  /// Oldest out first, until within [maxFiles] and [maxBytes].
  Future<void> _trim() async {
    int size(String p) {
      try {
        return File(p).lengthSync();
      } catch (_) {
        return 0;
      }
    }

    var total = _files.values.fold<int>(0, (a, p) => a + size(p));
    while (_files.length > 1 &&
        (_files.length > maxFiles || total > maxBytes)) {
      final oldest = _files.keys.first;
      final p = _files.remove(oldest)!;
      total -= size(p);
      try {
        await File(p).delete();
      } catch (e) {
        debugPrint('[own uploads] could not delete $p: $e');
      }
    }
  }

  Future<void> _save(Directory dir) async {
    await File('${dir.path}/index.json').writeAsString(json.encode(_files));
  }

  /// How much the copies take up. For Settings → Free up space.
  Future<int> bytesOnDisk() async {
    var total = 0;
    try {
      final dir = await folder();
      if (!dir.existsSync()) return 0;
      for (final f in dir.listSync()) {
        if (f is File) total += f.lengthSync();
      }
    } catch (e) {
      debugPrint('[own uploads] could not measure the folder: $e');
    }
    return total;
  }

  /// Everything, gone: on sign-out, and from Free up space. Your posts are
  /// untouched — they play from the server again. Returns the bytes freed.
  Future<int> clear() async {
    final freed = await bytesOnDisk();
    _files.clear();
    try {
      final dir = await folder();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('[own uploads] could not empty the folder: $e');
      return 0;
    }
    return freed;
  }
}

/// A video address that is really a file on this phone — one of your own,
/// kept by [OwnUploads]. Such an address is played straight from disk and
/// never downloaded, cached or sent through the local server.
bool isLocalVideo(String url) => url.startsWith('/');
