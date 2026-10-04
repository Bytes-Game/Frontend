import 'dart:async';

import 'package:flutter/widgets.dart';

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

  /// No list, or one older than [maxAge].
  bool get isStale {
    final at = _fetchedAt;
    return at == null || now().difference(at) > maxAge;
  }

  /// The picture a grid tile shows for [url]. The tile and [prefetch] must
  /// ask for exactly the same thing, or the one [prefetch] downloaded is
  /// filed under a different name and the tile downloads it again.
  static ImageProvider posterImage(String url) =>
      ResizeImage(NetworkImage(url), width: posterDecodeWidth);

  /// Fetch a new list from the server. Two callers at once share one
  /// request: the page opening while [prefetch] is still waiting for its
  /// answer should not ask the server a second time.
  Future<List<ChallengeModel>> load(String userId, {bool refresh = false}) {
    final pending = _inFlight;
    if (pending != null && !refresh) return pending;
    final started = now();
    final generation = ++_generation;
    final request = _fetch(userId, refresh: refresh).then((list) {
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
      }
      return list;
    });
    _inFlight = request;
    request.whenComplete(() {
      if (identical(_inFlight, request)) _inFlight = null;
    }).ignore();
    return request;
  }

  Future<List<ChallengeModel>> _fetch(
    String userId, {
    required bool refresh,
  }) async {
    final list = await ApiService.getExploreChallenges(
      userId,
      limit: 30,
      refresh: refresh,
      markShown: false,
    );
    if (list.isNotEmpty) return list;
    // Explore came back empty (a new platform, or the request failed): fall
    // back to the arena's trending list so the grid is not left dead.
    debugPrint(
      '[search_page] explore came back empty; '
      'showing the arena list instead',
    );
    return ApiService.getArenaChallenges();
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

  /// Forget everything: a different person may sign in next.
  void clear() {
    _generation++;
    _items = const [];
    _fetchedAt = null;
    _inFlight = null;
  }

  /// Start a test from nothing.
  @visibleForTesting
  void debugReset() => clear();
}
