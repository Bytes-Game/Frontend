import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/api_service.dart';

/// The grid of videos the Search page opens on, kept between visits.
///
/// ════════════════════════════════════════════════════════════════════════
/// WHY SEARCH USED TO OPEN EMPTY
/// ════════════════════════════════════════════════════════════════════════
///
/// The Search page is built fresh every time its tab is tapped, and it kept
/// its videos in the page. So every visit started from nothing: ask the
/// server, show an empty "Find people and battles" screen while it thinks,
/// then drop thirty tiles in at once, each one downloading its picture. Go
/// to Home and back and all of it happened again, for the same videos.
///
/// The request is not quick, either. The server ranks the whole catalog for
/// it, and even a refused request to it takes a quarter to half a second to
/// come back.
///
/// So the list lives here instead, outside the page:
///
///   * Coming back to Search shows the videos it had, at once, with no
///     request at all.
///   * A few seconds after the app opens, [prefetch] fetches the list and
///     the first screen of pictures quietly, so even the FIRST visit to
///     Search has them ready.
///   * After [maxAge] the videos still show at once, and a new list is
///     fetched behind them.
///   * The list, and the pictures of its first screen, are written down on
///     the phone too ([restore]). So opening the app and going straight to
///     Search shows last time's videos at once, with their pictures, while
///     the new list is fetched behind them — instead of an empty grid while
///     the server answers, which one device log timed at 8.4 seconds.
///
/// Fetching this list records nothing on the server. It asks with
/// markShown=false, so the videos are not counted as watched.
class ExploreGridCache {
  ExploreGridCache._();

  static final ExploreGridCache instance = ExploreGridCache._();

  /// How long a list is shown before a new one is fetched behind it. Going
  /// back and forth between tabs inside this window costs nothing.
  static const Duration maxAge = Duration(minutes: 10);

  /// How many pictures [prefetch] downloads: about one phone screen of the
  /// grid. The rest come in as the grid scrolls, as they always did.
  static const int prefetchPosters = 12;

  /// How wide, in pixels, a grid picture is decoded. A tile is about a
  /// third of the screen; this is that at a typical phone's pixel density.
  /// The server's picture is bigger (540 wide), and decoding all of it for
  /// a tile this size costs time and memory for pixels nobody sees.
  static const int posterDecodeWidth = 360;

  static const String _fileName = 'explore_grid.json';
  static const String _posterDirName = 'explore_grid_posters';

  /// A list written down longer ago than this is not shown: Search should
  /// open on something recent, not on what was there last week.
  static const Duration keptMaxAge = Duration(days: 2);

  /// Where the list is written down. A seam: tests point it at a folder.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  /// How a picture is fetched to keep. A seam for tests.
  @visibleForTesting
  static Future<Uint8List?> Function(String url) download = _download;

  List<ChallengeModel> _items = const [];
  DateTime? _fetchedAt;
  Future<List<ChallengeModel>>? _inFlight;

  /// Counts requests, so only the newest one's answer is kept. An older
  /// request that happens to finish last must not put its older list back,
  /// and one still out when [clear] runs must not bring the last person's
  /// videos back after they signed out.
  int _generation = 0;

  /// Stand-in for the clock, so a test can make a list old.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// The videos in hand, possibly none yet.
  List<ChallengeModel> get items => _items;

  /// The videos to open Search on for [userId]: the ones in hand, or else
  /// the ones written down last time if they were theirs. Never waits: if
  /// the phone has not finished reading them yet, this is empty and Search
  /// loads the way it always did.
  List<ChallengeModel> itemsFor(String userId) {
    if (_items.isEmpty &&
        _kept.isNotEmpty &&
        userId.isNotEmpty &&
        userId == _keptOwner) {
      // Shown, but not fresh: [isStale] stays true, so a new list is
      // fetched behind them.
      _items = _kept;
      debugPrint('[search_page] opening on ${_kept.length} videos kept from '
          'last time, ${_posterFiles.length} with their pictures on the phone');
    }
    _kept = const [];
    return _items;
  }

  /// Read what the last run wrote down. Started in main(), before the first
  /// frame, so it is in hand long before anyone opens Search.
  Future<void> restore() => _reading ??= _restore();

  Future<void>? _reading;
  List<ChallengeModel> _kept = const [];
  String _keptOwner = '';

  /// Picture address → its copy on the phone, from the last run. Only these
  /// are shown from the phone. Pictures kept during THIS run are for the
  /// next one: switching a tile that already has its picture to a different
  /// source would make it load again.
  final Map<String, String> _posterFiles = {};

  /// No list, or one older than [maxAge].
  bool get isStale {
    final at = _fetchedAt;
    return at == null || now().difference(at) > maxAge;
  }

  /// The picture a grid tile shows for [url]. The tile and [prefetch] must
  /// ask for exactly the same thing, or the one [prefetch] downloaded is
  /// filed under a different name and the tile downloads it again.
  ///
  /// The copy on the phone when there is one, so the grid kept from last
  /// time opens with its pictures instead of fetching each one.
  static ImageProvider posterImage(String url) {
    final path = instance._posterFiles[url];
    return ResizeImage(
      path != null ? FileImage(File(path)) : NetworkImage(url),
      width: posterDecodeWidth,
    );
  }

  /// Fetch a new list from the server. Two callers at once share one
  /// request: the page opening while [prefetch] is still waiting for its
  /// answer should not ask the server a second time.
  Future<List<ChallengeModel>> load(String userId, {bool refresh = false}) {
    final pending = _inFlight;
    if (pending != null && !refresh) return pending;
    final started = now();
    final generation = ++_generation;
    final request = _fetch(userId, refresh: refresh).then((answer) {
      final (list, raw) = answer;
      final ms = now().difference(started).inMilliseconds;
      debugPrint(
        '[search_page] explore: ${list.length} videos from the server '
        'in ${ms}ms${refresh ? ' (pull to refresh)' : ''}',
      );
      // An empty answer is not kept. It is what a failed request looks
      // like too, and keeping it would hold the grid empty for ten minutes.
      if (list.isNotEmpty && generation == _generation) {
        _items = list;
        _fetchedAt = now();
        if (raw != null) debugLastSave = _save(userId, raw, generation);
      }
      return list;
    });
    _inFlight = request;
    request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    }).ignore();
    return request;
  }

  /// The list, and the videos exactly as the server sent them so they can
  /// be written down. The arena fallback is not written down: it is a
  /// stand-in for a list that did not come.
  Future<(List<ChallengeModel>, List<Map<String, dynamic>>?)> _fetch(
    String userId, {
    required bool refresh,
  }) async {
    final raw = await ApiService.getExploreChallengeMaps(
      userId,
      limit: 30,
      refresh: refresh,
      markShown: false,
    );
    if (raw.isNotEmpty) {
      return ([for (final m in raw) ChallengeModel.fromJson(m)], raw);
    }
    // Explore came back empty (a new platform, or the request failed): fall
    // back to the arena's trending list so the grid is not left dead.
    debugPrint(
      '[search_page] explore came back empty; '
      'showing the arena list instead',
    );
    return (await ApiService.getArenaChallenges(), null);
  }

  /// Fetch the list and the first screen of pictures in the background, so
  /// Search has them before anyone opens it. Does nothing if a fresh list
  /// is already in hand.
  Future<void> prefetch(BuildContext context, String userId) async {
    if (!isStale) return;
    final list = await load(userId);
    if (!context.mounted) return;
    var n = 0;
    for (final c in list) {
      final url = c.thumbnailUrl;
      if (url == null || url.isEmpty) continue;
      unawaited(
        precacheImage(
          posterImage(url),
          context,
          onError: (e, _) =>
              debugPrint('[search_page] picture prefetch failed: $e'),
        ),
      );
      if (++n >= prefetchPosters) break;
    }
    debugPrint(
      '[search_page] prefetched ${list.length} videos '
      'and $n pictures before Search was opened',
    );
  }

  /// Forget everything: a different person may sign in next. What was
  /// written down on the phone goes too.
  void clear() {
    _generation++;
    _items = const [];
    _fetchedAt = null;
    _inFlight = null;
    _kept = const [];
    _keptOwner = '';
    _posterFiles.clear();
    unawaited(_forgetKept());
  }

  Future<void> _forgetKept() async {
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) await file.delete();
      final posters = Directory('${dir.path}/$_posterDirName');
      if (posters.existsSync()) await posters.delete(recursive: true);
    } catch (e) {
      debugPrint('[search_page] could not empty the kept grid: $e');
    }
  }

  Future<void> _restore() async {
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (!file.existsSync()) return;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return;
      final saved = DateTime.tryParse('${data['savedAt'] ?? ''}');
      if (saved == null || now().difference(saved) > keptMaxAge) {
        debugPrint('[search_page] the kept grid is too old to open on');
        return;
      }
      final kept = <ChallengeModel>[];
      for (final m in (data['items'] as List? ?? const [])) {
        if (m is Map<String, dynamic>) kept.add(ChallengeModel.fromJson(m));
      }
      final posters = data['posters'];
      if (posters is Map) {
        posters.forEach((url, name) {
          final f = File('${dir.path}/$_posterDirName/$name');
          if (f.existsSync()) _posterFiles['$url'] = f.path;
        });
      }
      _keptOwner = '${data['owner'] ?? ''}';
      _kept = kept;
    } catch (e) {
      // Losing this costs one ordinary open, the way every open was before.
      debugPrint('[search_page] could not read the kept grid: $e');
    }
  }

  /// Write [raw] down for [userId]'s next open, with the pictures of the
  /// first screen. Skipped if they signed out while it was on its way.
  Future<void> _save(
    String userId,
    List<Map<String, dynamic>> raw,
    int generation,
  ) async {
    if (userId.isEmpty) return;
    try {
      final dir = await directory();
      final posterDir = Directory('${dir.path}/$_posterDirName');
      if (!posterDir.existsSync()) await posterDir.create(recursive: true);
      final posters = <String, String>{};
      for (final m in raw.take(prefetchPosters)) {
        final url = '${m['thumbnailUrl'] ?? ''}';
        if (!url.startsWith('http') || posters.containsKey(url)) continue;
        final name = '${_hash(url)}.img';
        final f = File('${posterDir.path}/$name');
        if (!f.existsSync()) {
          final bytes = await download(url);
          if (bytes == null || bytes.isEmpty) continue;
          await f.writeAsBytes(bytes, flush: true);
        }
        posters[url] = name;
      }
      if (generation != _generation) return;
      // Pictures nothing refers to any more go — except the ones this run
      // is showing from the phone; the next save after this run tidies those.
      final inUse = {
        ...posters.values,
        for (final p in _posterFiles.values) File(p).uri.pathSegments.last,
      };
      for (final f in posterDir.listSync().whereType<File>()) {
        if (!inUse.contains(f.uri.pathSegments.last)) {
          try {
            f.deleteSync();
          } catch (e) {
            debugPrint('[search_page] could not delete an old picture: $e');
          }
        }
      }
      final file = File('${dir.path}/$_fileName');
      await file.writeAsString(
        json.encode({
          'owner': userId,
          'savedAt': now().toUtc().toIso8601String(),
          'items': raw,
          'posters': posters,
        }),
        flush: true,
      );
      // Signed out while it was being written: take it back.
      if (generation != _generation) await _forgetKept();
    } catch (e) {
      debugPrint('[search_page] could not keep the grid for next time: $e');
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
      debugPrint('[search_page] picture $url answered ${res.statusCode}');
    } catch (e) {
      debugPrint('[search_page] could not fetch picture $url: $e');
    }
    return null;
  }

  /// The last write to the phone, so a test can wait for it.
  @visibleForTesting
  Future<void>? debugLastSave;

  /// Forget what is in memory, as a new run of the app would — what is on
  /// the phone stays.
  @visibleForTesting
  void debugReset() {
    _generation++;
    _items = const [];
    _fetchedAt = null;
    _inFlight = null;
    _kept = const [];
    _keptOwner = '';
    _posterFiles.clear();
    _reading = null;
    debugLastSave = null;
    now = DateTime.now;
  }
}
