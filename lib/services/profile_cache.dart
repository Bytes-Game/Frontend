import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/explore_grid_cache.dart';

/// What a profile showed last time, kept for the next time it opens.
///
/// Search opens on its videos at once because it keeps its grid between
/// visits. The profile asked the server for everything every time it
/// opened — videos, record, every battle tab, saved, liked — and showed
/// placeholders and spinners until each answered. Now each answer is kept
/// here, the page opens on what is kept, and the fresh answers replace it
/// as they arrive. Your own profile is filled in the background soon after
/// the app opens, so even the first visit is instant.
///
/// Your own videos are also written down on the phone, with the pictures of
/// the first screen of them ([restore]). Memory alone was not enough: the
/// app fills it in a few seconds after it opens and then waits for the
/// server, which one log timed at over eight seconds. Opening your profile
/// in that time showed empty boxes. Now it opens on last time's videos and
/// pictures, read before the first frame, and the fresh list replaces them.
///
/// Signing out empties it, on the phone too.
class ProfileCache {
  ProfileCache._();
  static final ProfileCache instance = ProfileCache._();

  /// How many of your videos are written down, and how many of their
  /// pictures: about one screen of the grid.
  static const int keptVideos = 60;
  static const int keptPosters = 12;

  /// A list written down longer ago than this is not opened on.
  static const Duration keptMaxAge = Duration(days: 7);

  static const String _fileName = 'own_profile.json';
  static const String _posterDirName = 'own_profile_posters';

  /// Where it is written down. A seam: tests point it at a folder.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  /// How a picture is fetched to keep. A seam for tests.
  @visibleForTesting
  static Future<Uint8List?> Function(String url) download =
      ExploreGridCache.fetchPicture;

  Future<void>? _reading;
  List<ChallengeModel> _kept = const [];
  String _keptOwner = '';

  /// Bumped by [clear], so a write still on its way after signing out is
  /// taken back.
  int _generation = 0;

  /// The last write to the phone, so a test can wait for it.
  @visibleForTesting
  Future<void>? debugLastSave;

  /// Read what the last run wrote down. Started in main(), before the first
  /// frame, so it is in hand long before anybody opens their profile.
  Future<void> restore() => _reading ??= _restore();

  Future<void> _restore() async {
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (!file.existsSync()) return;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return;
      final saved = DateTime.tryParse('${data['savedAt'] ?? ''}');
      if (saved == null || DateTime.now().difference(saved) > keptMaxAge) {
        debugPrint('[profile] the kept profile is too old to open on');
        return;
      }
      final kept = <ChallengeModel>[];
      for (final m in (data['items'] as List? ?? const [])) {
        if (m is Map<String, dynamic>) kept.add(ChallengeModel.fromJson(m));
      }
      final posters = <String, String>{};
      final names = data['posters'];
      if (names is Map) {
        names.forEach((url, name) {
          final f = File('${dir.path}/$_posterDirName/$name');
          if (f.existsSync()) posters['$url'] = f.path;
        });
      }
      ExploreGridCache.instance.addKeptPosters(posters);
      _keptOwner = '${data['owner'] ?? ''}';
      _kept = kept;
      debugPrint('[profile] read ${kept.length} of your videos and '
          '${posters.length} pictures kept from last time');
    } catch (e) {
      // Losing this costs one ordinary open, the way every open was before.
      debugPrint('[profile] could not read the kept profile: $e');
    }
  }

  /// Write your own [raw] videos down for the next time the app opens, with
  /// the pictures of the first screen of them.
  Future<void> keepOwn(String userId, List<Map<String, dynamic>> raw) {
    _ownId = userId;
    _ownRaw = raw;
    final generation = _generation;
    return debugLastSave = _save(userId, raw, generation);
  }

  /// Whose videos [keepOwn] last wrote down, and exactly as the server sent
  /// them, so a video deleted from the page comes off the phone's copy too.
  String _ownId = '';
  List<Map<String, dynamic>> _ownRaw = const [];

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
      final items = raw.take(keptVideos).toList();
      final posters = <String, String>{};
      for (final m in items.take(keptPosters)) {
        final url = '${m['thumbnailUrl'] ?? ''}';
        if (!url.startsWith('http') || posters.containsKey(url)) continue;
        final name = ExploreGridCache.posterFileName(url);
        final f = File('${posterDir.path}/$name');
        if (!f.existsSync()) {
          final bytes = await download(url);
          if (bytes == null || bytes.isEmpty) continue;
          await f.writeAsBytes(bytes, flush: true);
        }
        posters[url] = name;
      }
      if (generation != _generation) return;
      for (final f in posterDir.listSync().whereType<File>()) {
        if (!posters.containsValue(f.uri.pathSegments.last)) {
          try {
            f.deleteSync();
          } catch (e) {
            debugPrint('[profile] could not delete an old picture: $e');
          }
        }
      }
      await File('${dir.path}/$_fileName').writeAsString(
        json.encode({
          'owner': userId,
          'savedAt': DateTime.now().toUtc().toIso8601String(),
          'items': items,
          'posters': posters,
        }),
        flush: true,
      );
      if (generation != _generation) await _forgetKept();
    } catch (e) {
      debugPrint('[profile] could not keep your profile for next time: $e');
    }
  }

  Future<void> _forgetKept() async {
    try {
      final dir = await directory();
      final file = File('${dir.path}/$_fileName');
      if (file.existsSync()) await file.delete();
      final posters = Directory('${dir.path}/$_posterDirName');
      if (posters.existsSync()) await posters.delete(recursive: true);
    } catch (e) {
      debugPrint('[profile] could not empty the kept profile: $e');
    }
  }

  final Map<String, List<ChallengeModel>> _shorts = {};
  final Map<String, List<ChallengeModel>> _saved = {};
  final Map<String, List<ChallengeModel>> _liked = {};
  final Map<String, BattleRecord> _record = {};
  final Map<String, List<BattleCard>> _battles = {};

  /// What is in hand for [userId]'s videos: this run's, or else the ones
  /// written down last time if they are theirs.
  List<ChallengeModel>? shorts(String userId) {
    final got = _shorts[userId];
    if (got != null) return got;
    if (_kept.isNotEmpty && userId.isNotEmpty && userId == _keptOwner) {
      _shorts[userId] = _kept;
      _kept = const [];
      return _shorts[userId];
    }
    return null;
  }
  List<ChallengeModel>? saved(String userId) => _saved[userId];
  List<ChallengeModel>? liked(String userId) => _liked[userId];
  BattleRecord? record(String userId) => _record[userId];
  List<BattleCard>? battles(String userId, String tab) =>
      _battles['$userId/$tab'];

  /// Keep [list]. An empty answer does not replace a list that had videos
  /// in it: an empty list is also what a failed request looks like, and
  /// keeping it would show "No posts" on a profile that has some. A video
  /// deleted from the page is taken out of the kept list by the page.
  void keepShorts(String userId, List<ChallengeModel> list) =>
      _keep(_shorts, userId, list);
  void keepSaved(String userId, List<ChallengeModel> list) =>
      _keep(_saved, userId, list);
  void keepLiked(String userId, List<ChallengeModel> list) =>
      _keep(_liked, userId, list);
  void keepRecord(String userId, BattleRecord record) =>
      _record[userId] = record;
  void keepBattles(String userId, String tab, List<BattleCard> cards) =>
      _keep(_battles, '$userId/$tab', cards);

  /// The page changed a list itself (a post, a delete): keep exactly that.
  void replaceShorts(String userId, List<ChallengeModel> list) {
    _shorts[userId] = List.of(list);
    // A deleted video must not come back from the phone's copy the next
    // time the app opens.
    if (userId.isNotEmpty && userId == _ownId) {
      final ids = {for (final c in list) c.id};
      final left = [
        for (final m in _ownRaw)
          if (ids.contains('${m['id']}')) m,
      ];
      if (left.length != _ownRaw.length) unawaited(keepOwn(userId, left));
    }
  }

  static void _keep<T>(Map<String, List<T>> map, String key, List<T> list) {
    final had = map[key];
    if (list.isEmpty && had != null && had.isNotEmpty) return;
    map[key] = List.of(list);
  }

  /// Fill in [userId]'s profile in the background: videos, record, battle
  /// tabs, saved and liked, and the pictures of the first videos. Called
  /// for your own profile a few seconds after the app opens.
  Future<void> prefetch(BuildContext context, String userId) async {
    if (userId.isEmpty) return;
    final started = DateTime.now();
    await Future.wait([
      ApiService.getUserChallengeMaps(userId).then((raw) {
        if (raw == null) return;
        keepShorts(userId, [for (final m in raw) ChallengeModel.fromJson(m)]);
        unawaited(keepOwn(userId, raw));
      }),
      for (final tab in const ['open', 'live', 'won', 'lost'])
        ApiService.getUserBattles(userId: userId, tab: tab).then((p) {
          if (p == null) return;
          keepRecord(userId, p.record);
          keepBattles(userId, tab, p.battles);
        }),
      ApiService.getSavedChallenges(userId).then((l) => keepSaved(
          userId, [for (final m in l) ChallengeModel.fromJson(m)])),
      ApiService.getLikedChallenges(userId: userId, limit: 24).then((r) =>
          keepLiked(userId, [
            for (final m in (r['items'] as List?) ?? const [])
              if (m is Map<String, dynamic>) ChallengeModel.fromJson(m),
          ])),
    ]);
    debugPrint('[profile] kept your profile for an instant open in '
        '${DateTime.now().difference(started).inMilliseconds}ms: '
        '${_shorts[userId]?.length ?? 0} videos, '
        '${_saved[userId]?.length ?? 0} saved');
    if (!context.mounted) return;
    // The first screen of pictures, so the grid opens with them.
    final first = (_shorts[userId] ?? const <ChallengeModel>[]).take(9);
    for (final c in first) {
      final url = c.thumbnailUrl;
      if (url == null || url.isEmpty) continue;
      unawaited(precacheImage(ExploreGridCache.posterImage(url), context)
          .catchError((Object _) {}));
    }
  }

  /// Signing out: nothing of theirs is kept for the next person.
  void clear() {
    _generation++;
    _kept = const [];
    _keptOwner = '';
    _ownId = '';
    _ownRaw = const [];
    unawaited(_forgetKept());
    _shorts.clear();
    _saved.clear();
    _liked.clear();
    _record.clear();
    _battles.clear();
  }

  /// Forget what is in memory, as a new run of the app would — what is on
  /// the phone stays.
  @visibleForTesting
  void debugReset() {
    _shorts.clear();
    _saved.clear();
    _liked.clear();
    _record.clear();
    _battles.clear();
    _kept = const [];
    _keptOwner = '';
    _ownId = '';
    _ownRaw = const [];
    _reading = null;
    debugLastSave = null;
  }
}
