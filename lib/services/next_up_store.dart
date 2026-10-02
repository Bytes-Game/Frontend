import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The next few videos on Home, kept on the phone between runs.
///
/// Opening the app used to show a black screen with a loading shimmer
/// while the server was asked for videos — several seconds on ours. TikTok
/// and Instagram open straight onto a video because they already have the
/// next ones from last time. This does the same: when you leave the app (or
/// leave Home), the videos you had not reached yet are written down here,
/// with their pictures, and the next open starts on them at once while a
/// fresh page is fetched behind.
///
/// Only videos you had not watched yet are kept, so the open still feels
/// new. They are for one person: another account signing in on this phone
/// gets nothing from here, and signing out empties it.
class NextUpStore {
  NextUpStore._();
  static final NextUpStore instance = NextUpStore._();

  static const String _fileName = 'next_up.json';
  static const String _posterDirName = 'next_up_posters';

  /// How many videos are kept.
  static const int keep = 8;

  /// Older than this and they are not shown: a video from days ago is not
  /// what "open the app" should land on.
  static const Duration maxAge = Duration(days: 2);

  /// Where the file lives. A seam: tests point it at a temporary folder.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  /// How a picture is fetched. A seam for tests.
  @visibleForTesting
  static Future<Uint8List?> Function(String url) download = _download;

  @visibleForTesting
  DateTime Function() now = DateTime.now;

  Future<void>? _loading;
  bool _ready = false;
  List<Map<String, dynamic>> _entries = const [];
  String _owner = '';

  /// Picture address → the copy on the phone.
  final Map<String, String> _posters = {};

  /// Read what the last run kept. Started in main(), before the first
  /// frame, so it is in hand by the time Home asks.
  Future<void> load() => _loading ??= _load();

  /// The kept videos, for [userId] only, handed over once — the store is
  /// empty afterwards, so the same videos are never the start of two opens.
  Future<List<Map<String, dynamic>>> take(String userId) async {
    await load();
    return takeReady(userId);
  }

  /// [take], without waiting: empty if the file has not been read yet.
  /// Home asks this way, so it never waits on the phone's storage — the
  /// read starts in main() and is done long before Home asks, and if it is
  /// not, Home simply loads as it always did.
  List<Map<String, dynamic>> takeReady(String userId) {
    if (!_ready) {
      debugPrint('[next_up] not read yet; Home loads as usual');
      return const [];
    }
    if (userId.isEmpty || userId != _owner || _entries.isEmpty) {
      return const [];
    }
    final out = _entries;
    _entries = const [];
    return out;
  }

  /// The copy on the phone of the picture at [url], if there is one. Shown
  /// instead of fetching it, so the first video has its picture at once.
  File? posterFile(String url) {
    final path = _posters[url];
    return path == null ? null : File(path);
  }

  /// Keep [entries] — feed items exactly as the server sent them — for
  /// [userId]'s next open. An empty list clears what was kept.
  Future<void> save(String userId, List<Map<String, dynamic>> entries) async {
    if (userId.isEmpty) return;
    final kept = entries.take(keep).toList();
    debugLastSaved = kept;
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (kept.isEmpty) {
        if (file.existsSync()) await file.delete();
        return;
      }
      final posterDir = Directory('${dir.path}/$_posterDirName');
      if (!posterDir.existsSync()) await posterDir.create(recursive: true);
      final posters = <String, String>{};
      for (final url in _pictures(kept)) {
        final name = '${_hash(url)}.img';
        final f = File('${posterDir.path}/$name');
        if (!f.existsSync()) {
          final bytes = await download(url);
          if (bytes == null || bytes.isEmpty) continue;
          await f.writeAsBytes(bytes, flush: true);
        }
        posters[url] = name;
      }
      // Pictures nothing kept refers to any more go.
      for (final f in posterDir.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!posters.containsValue(name)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
      await file.writeAsString(
        json.encode({
          'owner': userId,
          'savedAt': now().toUtc().toIso8601String(),
          'entries': kept,
          'posters': posters,
        }),
        flush: true,
      );
    } catch (e) {
      // Losing this costs one ordinary open with the loading shimmer, which
      // is what every open was before. Said, not hidden.
      debugPrint('[next_up] could not keep the next videos: $e');
    }
  }

  /// Signing out: nothing of theirs is left for the next person.
  Future<void> clear() async {
    _entries = const [];
    _owner = '';
    _posters.clear();
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) await file.delete();
      final posterDir = Directory('${dir.path}/$_posterDirName');
      if (posterDir.existsSync()) await posterDir.delete(recursive: true);
    } catch (e) {
      debugPrint('[next_up] could not empty the kept videos: $e');
    }
  }

  /// What [save] was last handed, for tests: the write itself is real file
  /// work that a widget test cannot wait for.
  @visibleForTesting
  List<Map<String, dynamic>>? debugLastSaved;

  /// For tests: whether videos are waiting to be opened on.
  @visibleForTesting
  bool get debugHasEntries => _entries.isNotEmpty;

  @visibleForTesting
  void debugReset() {
    debugLastSaved = null;
    _loading = null;
    _ready = false;
    _entries = const [];
    _owner = '';
    _posters.clear();
    now = DateTime.now;
  }

  Future<void> _load() async {
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (!file.existsSync()) return;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return;
      final saved = DateTime.tryParse('${data['savedAt'] ?? ''}');
      if (saved == null || now().difference(saved) > maxAge) {
        debugPrint('[next_up] the kept videos are too old to open on');
        return;
      }
      _owner = '${data['owner'] ?? ''}';
      _entries = [
        for (final e in (data['entries'] as List? ?? const []))
          if (e is Map<String, dynamic>) e,
      ];
      final posters = data['posters'];
      if (posters is Map) {
        posters.forEach((url, name) {
          final f = File('${dir.path}/$_posterDirName/$name');
          if (f.existsSync()) _posters['$url'] = f.path;
        });
      }
      debugPrint('[next_up] ${_entries.length} videos kept from last time, '
          '${_posters.length} with their pictures on the phone');
    } catch (e) {
      debugPrint('[next_up] could not read the kept videos: $e');
    } finally {
      _ready = true;
    }
  }

  /// Every picture a kept video shows first: the video's, and on a battle
  /// the answer's, which it may open on.
  static Iterable<String> _pictures(List<Map<String, dynamic>> entries) sync* {
    final seen = <String>{};
    for (final e in entries) {
      final c = (e['challenge'] ?? e['post']);
      if (c is! Map) continue;
      for (final k in ['thumbnailUrl', 'topResponseThumbnailUrl']) {
        final url = '${c[k] ?? ''}';
        if (url.startsWith('http') && seen.add(url)) yield url;
      }
    }
  }

  /// A short, stable name for a picture's file (FNV-1a).
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final unit in utf8.encode(s)) {
      h ^= unit;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static Future<Uint8List?> _download(String url) async {
    try {
      final res =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) return res.bodyBytes;
      debugPrint('[next_up] picture $url answered ${res.statusCode}');
    } catch (e) {
      debugPrint('[next_up] could not fetch picture $url: $e');
    }
    return null;
  }
}
