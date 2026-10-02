import 'dart:async';

import 'package:flutter/material.dart';

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
/// Signing out empties it.
class ProfileCache {
  ProfileCache._();
  static final ProfileCache instance = ProfileCache._();

  final Map<String, List<ChallengeModel>> _shorts = {};
  final Map<String, List<ChallengeModel>> _saved = {};
  final Map<String, List<ChallengeModel>> _liked = {};
  final Map<String, BattleRecord> _record = {};
  final Map<String, List<BattleCard>> _battles = {};

  List<ChallengeModel>? shorts(String userId) => _shorts[userId];
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
  void replaceShorts(String userId, List<ChallengeModel> list) =>
      _shorts[userId] = List.of(list);

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
      ApiService.getUserChallenges(userId).then((l) => keepShorts(userId, l)),
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
    _shorts.clear();
    _saved.clear();
    _liked.clear();
    _record.clear();
    _battles.clear();
  }
}
