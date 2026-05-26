import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/feed_action_bar.dart'
    show ChallengeCommentSheet, ChallengeShareSheet, showChallengeVoteDialog;

/// Which backend feed endpoint a SmartReelsFeed should pull from. Each one
/// uses a meaningfully different ranking algorithm:
///
///   forYou    → /api/v1/feed/smart      personalized + ML pipeline
///   following → /api/v1/feed/following/v2 chronological from follows (no ML)
///   explore   → /api/v1/feed/explore    discovery-first, non-personalized
///
/// Same JSON shape across all three so this widget reuses the parser.
enum FeedKind { forYou, following, explore }

/// Instagram/TikTok-style paginated reels feed. Switches its data source
/// based on `kind` — same UI, different algorithm.
///
/// What this widget does differently from the stock `ReelsPlayerPage`:
///   * **Paginated**: pulls one page at a time, prefetching the next page
///     when ~3 items from the end. Never loads everything at once.
///   * **Mixed feed**: handles both posts and challenges — both auto-play
///     as reels, challenges get a "View battle" button.
///   * **Algorithm-aware events**: every page change emits trackView (with
///     completion) or trackSkip so the Platt calibrator, user embedding,
///     LTR, and bandit get signal.
///
/// Not responsible for: the AppBar, tab chrome, or nav — the host page wraps
/// it. Drop it into the body of a scaffold and give it a userId + kind.
class SmartReelsFeed extends StatefulWidget {
  final String userId;
  final String fallbackSessionId;
  final FeedKind kind;

  /// Optional starting challenge. When provided, this challenge is shown as
  /// the very first reel and additional pages from `kind` load behind it for
  /// continued scrolling. Use this when the user taps a search/explore
  /// thumbnail and you want the resulting reels viewer to open *on* that
  /// specific video while still allowing them to keep swiping vertically.
  final ChallengeModel? seedChallenge;

  const SmartReelsFeed({
    super.key,
    required this.userId,
    this.fallbackSessionId = '',
    this.kind = FeedKind.forYou,
    this.seedChallenge,
  });

  @override
  State<SmartReelsFeed> createState() => _SmartReelsFeedState();
}

class _SmartReelsFeedState extends State<SmartReelsFeed>
    with WidgetsBindingObserver {
  // Pagination state — matches backend SmartFeedHandler contract. _items is
  // polymorphic: most entries are _ReelItem (videos), but the backend now
  // interleaves _AccountsCard tiles every ~8 items. Use `is` checks at the
  // sites that need to differentiate.
  final List<_FeedEntry> _items = [];
  int _page = 0; // 0 = nothing loaded yet
  bool _hasMore = true;
  bool _loadingFirstPage = true;
  bool _loadingMore = false;

  // Last error message from the API (null means success or genuinely empty).
  String? _lastError;

  // Active reel tracking.
  late final PageController _pageController;
  int _currentIndex = 0;

  // Per-index reel state (player + controller).
  final Map<int, _ReelPlayerState> _playerStates = {};

  // View-duration accounting for trackView on item exit.
  DateTime? _currentItemStart;

  // Content IDs for which a watch_event has already been recorded
  // within this widget's lifetime. Used to ensure each reel-view
  // generates at most ONE row in the backend's watch_events table —
  // both the 1.5s safety-net timer (_initialWatchTimer) and the
  // scroll-transition handler (_flushCurrentItemEvent) consult this
  // set before firing the API call. The public view counter and the
  // recommender's feed_events are deduped on their own paths, but
  // the raw watch_events table would otherwise accumulate dupes that
  // (while harmless to current consumers) muddy any future analytics
  // joins. Cleared on dispose; intentionally NOT cleared between
  // pages so scrolling back to a previously-watched reel doesn't
  // record a second event for the same session.
  final Set<String> _watchEventRecorded = <String>{};

  // Threshold: if user swipes before this many ms, we call it a skip.
  static const int _skipThresholdMs = 2500;

  // How close to the end before we pre-fetch the next page.
  static const int _prefetchPagesWhenLeft = 3;

  // Max items we keep in memory before trimming the *head* of the list so
  // long infinite scroll sessions don't balloon RAM. Keep well above the
  // viewport + prefetch horizon.
  static const int _maxCachedItems = 60;

  // ── Manual pull-to-refresh state ─────────────────────────────────────
  // Material's RefreshIndicator does NOT work on a vertical PageView with
  // PageScrollPhysics — that physics clamps at boundary 0 with no
  // overscroll, so dragging down on the first page generates no scroll
  // notification past the edge and the indicator's gesture-arena threshold
  // is never crossed. We do it by hand: a Listener at the top of the
  // Stack watches raw pointer events; if a downward drag starts in the
  // top ~120px of the screen WHILE we're on page 0, accumulate the delta
  // and trigger a refresh once it crosses _refreshTriggerPx.
  static const double _topPullZoneHeight = 120;
  static const double _refreshTriggerPx = 80;
  double? _pullStartY; // Y of the pointer-down event that armed a pull.
  double _pullDistance = 0; // accumulated downward distance, reset on lift.
  bool _isRefreshing = false;

  // Last-seen value of DataProvider.feedRefreshTick. When this widget's
  // build sees a higher value than this, it means an upload (or other
  // refresh-triggering action) happened since the last build and the
  // feed should re-pull page 1 to surface the new content. Stored here
  // so we don't spuriously re-fetch on every build.
  int _lastSeenRefreshTick = 0;

  // Cached DataProvider reference set in initState(). Used by
  // _flushCurrentItemEvent, which is called from dispose() where the
  // widget's Element is already deactivated — Provider.of(context) would
  // throw "Looking up a deactivated widget's ancestor is unsafe" there.
  DataProvider? _cachedDp;

  // ─── Velocity-aware prefetch state ───────────────────────────────────
  // Rolling window of the last few _onPageChanged timestamps. When 3+
  // swipes land inside [_burstWindow], the user is binge-scrolling and
  // we expand the prefetch window from `prefetchAhead` to
  // `prefetchAheadBurst` so even rapid thumb-flicks land on warm
  // controllers. Outside the burst, normal prefetch — keeps pool
  // pressure low when the user is actually watching reels.
  final List<DateTime> _recentSwipes = [];
  static const int _velocitySamples = 4;
  static const Duration _burstWindow = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: 0);
    // Seed the tick at the current value so we don't trigger an immediate
    // refresh on the very first build (the initial _loadInitialPage call
    // below is already pulling page 1).
    _cachedDp = Provider.of<DataProvider>(context, listen: false);
    _lastSeenRefreshTick = _cachedDp!.feedRefreshTick;
    _loadInitialPage();
  }

  @override
  void dispose() {
    _initialWatchTimer?.cancel();
    _flushCurrentItemEvent(isSkip: false); // best-effort save on leave
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    for (final st in _playerStates.values) {
      st.dispose();
    }
    _playerStates.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      VideoPlayerService.instance.pauseAll();
      _flushCurrentItemEvent(isSkip: false);
    } else if (state == AppLifecycleState.resumed) {
      _currentItemStart = DateTime.now();
      _playCurrent();
    }
  }

  // ─── Pagination ──────────────────────────────────────────────────────

  Future<void> _loadInitialPage({bool refresh = false}) async {
    // Seed-first: when a starting challenge was provided (search-result tap
    // path), prepend it before paginating so the user opens *on* the video
    // they tapped, not on whatever the explore feed serves first. Crucially,
    // we DON'T flip _loadingFirstPage when there's a seed — the user already
    // has content to play; making them stare at a spinner while the next
    // page loads in the background would defeat the point of the seed.
    //
    // On REFRESH: we always clear and re-pull from page 1. Trying to
    // stale-while-revalidate by keeping the existing items visible
    // would have new items dropped at the END of the list (the page
    // appender dedupes against existing keys, so freshly-published
    // items land below the stale ones) — which defeats the point of
    // refresh. The skeleton + the pull-refresh badge above it together
    // make the brief blank state feel intentional rather than broken.
    if (refresh) {
      // Stop any audio from the previous feed BEFORE clearing items.
      // Without this, the old reel's controller keeps playing through
      // the skeleton frame.
      VideoPlayerService.instance.pauseAll();
      // Drop stale (index → controller) mappings — after refresh,
      // index 0 maps to a DIFFERENT challenge. Pool entries are
      // released (paused, left warm); if the same URL reappears in
      // the refreshed feed, _getPlayerState will pull it back from
      // the pool. Without this clear, the old controller for the
      // old index-0 URL is the one that plays after refresh —
      // exactly the "refresh doesn't work" symptom.
      for (final st in _playerStates.values) {
        st.dispose();
      }
      _playerStates.clear();
      // Reset velocity tracking — fast scrolling in the old feed
      // shouldn't keep the burst-prefetch window open against the
      // new (cold) one.
      _recentSwipes.clear();
    }
    final hasSeed = widget.seedChallenge != null;
    setState(() {
      _loadingFirstPage = !hasSeed;
      _items.clear();
      _page = 0;
      _hasMore = true;
      if (hasSeed) {
        final seed = _ReelItem.fromChallengeModel(widget.seedChallenge!);
        if (seed != null) _items.add(seed);
      }
    });
    await _loadNextPage(refresh: refresh);
    if (!mounted) return;
    setState(() {
      _loadingFirstPage = false;
      _currentItemStart = DateTime.now();
    });
    // Snap back to the first reel after a refresh — otherwise the page
    // controller stays at whatever index the user was at and they see
    // newly-loaded content out of order.
    if (refresh && _pageController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageController.hasClients) {
          _pageController.jumpToPage(0);
          _currentIndex = 0;
        }
      });
    }
    // Kick off autoplay on the first real item.
    WidgetsBinding.instance.addPostFrameCallback((_) => _playCurrent());
  }

  Future<void> _loadNextPage({bool refresh = false}) async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final nextPage = _page + 1;
    final sessionId = _sessionId();
    final data = await _fetchPage(nextPage, sessionId, refresh: refresh && nextPage == 1);
    if (!mounted) {
      _loadingMore = false;
      return;
    }
    final raw = (data['items'] as List?) ?? const [];
    final parsed = <_FeedEntry>[];
    // Dedup against already-loaded items by (type, id). Catches the case
    // where seedChallenge is also the first item the explore page returns.
    final existingKeys = <String>{
      for (final e in _items) '${e.type}:${e.id}',
    };
    for (final x in raw) {
      final item = _FeedEntry.fromJson(x as Map<String, dynamic>);
      if (item == null) continue;
      final key = '${item.type}:${item.id}';
      if (existingKeys.contains(key)) continue;
      existingKeys.add(key);
      parsed.add(item);
    }
    final errorMsg = (data['_ok'] == false) ? data['_error'] as String? : null;
    setState(() {
      _items.addAll(parsed);
      _page = nextPage;
      _hasMore = data['hasMore'] == true;
      _loadingMore = false;
      // Only set error if this is the first page AND we got nothing.
      // Subsequent page errors don't blank the existing feed.
      if (errorMsg != null && _items.isEmpty) {
        _lastError = errorMsg;
      } else {
        _lastError = null;
      }
    });
    _trimMemoryIfNeeded();
  }

  /// Dispatches to the right backend endpoint based on widget.kind. Each
  /// endpoint runs a different ranking algorithm — see FeedKind doc.
  Future<Map<String, dynamic>> _fetchPage(int page, String sessionId,
      {bool refresh = false}) {
    switch (widget.kind) {
      case FeedKind.forYou:
        return ApiService.getSmartFeed(
          widget.userId,
          page: page,
          sessionId: sessionId,
          refresh: refresh,
        );
      case FeedKind.following:
        return ApiService.getFollowingFeedV2(widget.userId, page: page);
      case FeedKind.explore:
        return ApiService.getExploreFeed(widget.userId, page: page);
    }
  }

  // Trim earlier items once we've scrolled far past them. Avoids unbounded
  // growth in marathon sessions while keeping a fat buffer in view.
  void _trimMemoryIfNeeded() {
    if (_items.length <= _maxCachedItems) return;
    final keepFrom = _currentIndex - 10;
    if (keepFrom <= 0) return;
    final drop = keepFrom;
    _items.removeRange(0, drop);
    // Re-key player states for the new indices.
    final newStates = <int, _ReelPlayerState>{};
    _playerStates.forEach((k, v) {
      final nk = k - drop;
      if (nk >= 0) {
        newStates[nk] = v;
      } else {
        v.dispose();
      }
    });
    _playerStates
      ..clear()
      ..addAll(newStates);
    _currentIndex -= drop;
    if (_currentIndex < 0) _currentIndex = 0;
    // Jump the controller silently so it doesn't animate.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageController.hasClients) {
        _pageController.jumpToPage(_currentIndex);
      }
    });
  }

  String _sessionId() {
    final s = EventTracker.instance.sessionId;
    return s.isNotEmpty ? s : widget.fallbackSessionId;
  }

  // ─── Per-page playback ───────────────────────────────────────────────

  void _onPageChanged(int index) {
    final prevIndex = _currentIndex;
    if (index == prevIndex) return;

    // Sample this swipe's timestamp into the velocity window before
    // anything else — _prefetchUpcomingVideos below consults it.
    _recordSwipe();

    // Record the exit of the *previous* item.
    _flushCurrentItemEvent(isSkip: _wasQuickSkip());

    EventTracker.instance.trackSwipe(
      target: 'home_reels_scroll',
      direction: index > prevIndex ? 'up' : 'down',
      pageName: 'home_page',
      params: {
        'fromIndex': prevIndex,
        'toIndex': index,
        if (index < _items.length) 'contentId': _items[index].id,
        if (index < _items.length) 'contentType': _items[index].type,
      },
    );

    setState(() {
      _currentIndex = index;
      _currentItemStart = DateTime.now();
    });

    _playCurrent();
    _prefetchUpcomingVideos();
    _maybePrefetchNextPage();
  }

  bool _wasQuickSkip() {
    if (_currentItemStart == null) return false;
    final ms = DateTime.now().difference(_currentItemStart!).inMilliseconds;
    return ms < _skipThresholdMs;
  }

  // Push either a view or a skip event for the item we just left.
  void _flushCurrentItemEvent({required bool isSkip}) {
    if (_currentItemStart == null) return;
    if (_currentIndex < 0 || _currentIndex >= _items.length) return;
    final item = _items[_currentIndex];
    final state = _playerStates[_currentIndex];
    final watched = DateTime.now().difference(_currentItemStart!).inMilliseconds;
    final totalMs = state?.controller.value.duration.inMilliseconds ?? 0;

    if (isSkip) {
      EventTracker.instance.trackSkip(
        contentId: item.id,
        contentType: item.type,
        watchDurationMs: watched,
        totalDurationMs: totalMs,
      );
    } else if (watched >= 300) {
      EventTracker.instance.trackView(
        contentId: item.id,
        contentType: item.type,
        watchDurationMs: watched,
        totalDurationMs: totalMs,
      );
      // Also fire a watch_event so challenges.views grows in lockstep
      // with the displayed counter. The backend's RecordWatchEvent
      // dedupes per-user-per-day, so rewatching the same reel won't
      // inflate the number — only first views in a 24h window count.
      // Without this leg the view count only ever moved when someone
      // opened the challenge detail page, which made the home reels
      // show stale numbers for the most-watched format on the platform.
      if (item is _ReelItem && item.type == 'challenge' && item.id.isNotEmpty) {
        final dp = _cachedDp;
        final userId = dp?.user?.id ?? '';
        if (userId.isNotEmpty &&
            _watchEventRecorded.add(item.id)) {
          // Set.add returns true only when the id is brand-new for
          // this session — that's our dedup gate against the 1.5s
          // safety-net timer in _scheduleInitialWatchEvent. Either
          // the timer beat us here (in which case .add returns
          // false and we skip the duplicate POST) or we beat the
          // timer (in which case we mark recorded so the timer's
          // own .add returns false when it eventually fires).
          //
          // Fire-and-forget — failure shouldn't drop the view event,
          // just means the displayed count won't tick on this reel.
          ApiService.recordWatchEvent(
            userId: userId,
            contentId: item.id,
            contentType: item.type,
            watchTime: watched,
            completed: totalMs > 0 && watched >= (totalMs * 0.9),
          );
          // Optimistic local bump so the right-rail number ticks
          // immediately. Cap to once-per-session-per-item by piggybacking
          // on the same setState — re-watches in the same session won't
          // increment because we wipe _currentItemStart on every page
          // change and only fire when watched>=300ms.
          if (mounted) {
            setState(() => item.views = item.views + 1);
          }
        }
      }
    }
    _currentItemStart = null;
  }

  void _playCurrent() {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return;
    final item = _items[_currentIndex];
    // Account-suggestion cards are non-video tiles — pause everything and
    // skip player allocation so we don't leak audio onto a static card.
    if (item is! _ReelItem) {
      VideoPlayerService.instance.pauseAll();
      return;
    }
    final url = item.videoUrl;
    if (url.isEmpty) {
      // Image-only post or missing URL — pause everything so we don't leak audio.
      VideoPlayerService.instance.pauseAll();
      return;
    }
    final state = _getPlayerState(_currentIndex);
    if (state == null) return;
    VideoPlayerService.instance.pauseAllExcept(url);
    // Belt-and-suspenders: pool-promoted controllers should already be
    // at volume 1.0 via getController(), but setting it right before
    // play guarantees audible output in case a prefetch entry was
    // muted mid-promote.
    // ignore: discarded_futures
    state.controller.setVolume(1.0);
    // ignore: discarded_futures
    state.controller.play();

    // Record an initial watch event after a brief "are they still here?"
    // delay so the WatchHistoryPage has a row to show even when the user
    // doesn't transition to the next reel. Without this, single-reel
    // sessions never generate watch_events (the existing transition
    // record only fires on _onPageChanged), which is what the user
    // reported as "history is empty even though I watched stuff."
    //
    // The transition record in _flushCurrentItemEvent still fires on
    // scroll and overwrites duration via a fresh row — the history
    // SELECT uses DISTINCT ON (content_id) to keep the most recent
    // event per challenge so dupes don't clutter the timeline.
    _scheduleInitialWatchEvent(item);
  }

  /// Timer registered when a reel starts playing. Fires at 1500 ms to
  /// record a "started watching" event with watchTime=1500. Cancelled
  /// when the user scrolls or backgrounds before reaching that
  /// threshold (so quick skim-scrolls don't generate noise).
  Timer? _initialWatchTimer;

  void _scheduleInitialWatchEvent(_ReelItem item) {
    _initialWatchTimer?.cancel();
    if (item.type != 'challenge' || item.id.isEmpty) return;
    // Capture dp before the timer fires — calling Provider.of(context) inside
    // the callback can throw if the element has been deactivated by then.
    final dp = Provider.of<DataProvider>(context, listen: false);
    _initialWatchTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      final userId = dp.user?.id ?? '';
      if (userId.isEmpty) return;
      // Gate against the dedupe set so we never write a second row
      // for a reel the scroll-transition has already recorded. .add
      // returns true only when the id is fresh; same gate as the
      // transition handler in _flushCurrentItemEvent.
      if (!_watchEventRecorded.add(item.id)) return;
      // Fire-and-forget. Exactly one watch_events row per reel-view
      // — whichever path fires first wins, the other one no-ops.
      ApiService.recordWatchEvent(
        userId: userId,
        contentId: item.id,
        contentType: item.type,
        watchTime: 1500,
        completed: false,
      );
    });
  }

  /// Fetch (or build) the player state for a reel index. Returns null when
  /// the entry at `index` is a non-video tile (e.g. an accounts card) — the
  /// caller has to handle nullability rather than try to instantiate a
  /// player against an empty URL.
  ///
  /// IMPORTANT: validates the cached entry against the pool before
  /// returning it. The pool LRU-evicts (and disposes) controllers when
  /// it's full and a new URL is requested, but `_playerStates` lives as
  /// long as the widget — so a cached entry can outlive its underlying
  /// controller. Returning a stale entry leads to "A
  /// VideoPlayerController was used after being disposed" the next time
  /// the tile builds. We re-fetch from the pool in that case (pool
  /// returns a fresh controller; getController is idempotent on URL).
  _ReelPlayerState? _getPlayerState(int index) {
    if (index < 0 || index >= _items.length) return null;
    final item = _items[index];
    if (item is! _ReelItem) return null;
    final url = item.videoUrl;
    if (url.isEmpty) return null;

    final cached = _playerStates[index];
    if (cached != null &&
        cached.url == url &&
        VideoPlayerService.instance.hasController(url)) {
      return cached;
    }

    // Either no cache, the cached URL is stale (item at this index
    // changed — e.g. after _trimMemoryIfNeeded re-keyed), or the
    // pool has evicted the controller. Build a fresh state.
    final controller = VideoPlayerService.instance.getController(url);
    // ignore: discarded_futures
    controller.setLooping(true);
    final s = _ReelPlayerState(controller: controller, url: url);
    _playerStates[index] = s;
    return s;
  }

  /// Add `now` to the rolling swipe-velocity window, trimming the
  /// oldest entry once we've sampled more than [_velocitySamples].
  void _recordSwipe() {
    _recentSwipes.add(DateTime.now());
    while (_recentSwipes.length > _velocitySamples) {
      _recentSwipes.removeAt(0);
    }
  }

  /// True when the user has been binge-scrolling: 3 or more swipes
  /// landed inside the [_burstWindow]. We use this to decide whether
  /// to expand the prefetch window from base → burst. Without it, a
  /// rapid thumb-flick past 3-4 reels would overshoot the warm pool
  /// and the user would land on a cold controller with a loading
  /// spinner. With it, we widen the runway and they land warm.
  bool _isBurstScrolling() {
    if (_recentSwipes.length < 3) return false;
    final span = _recentSwipes.last.difference(
      _recentSwipes[_recentSwipes.length - 3],
    );
    return span <= _burstWindow;
  }

  void _prefetchUpcomingVideos() {
    final cfg = VideoPlayerService.instance.config;
    // Pick window width based on swipe velocity. Burst mode widens
    // the upcoming-prefetch reach so a fast scroller doesn't overshoot
    // the warm pool. Back-prefetch doesn't widen — back-swipes are
    // bursty too, but the previous reel they land on is almost
    // always at currentIndex-1, so the depth doesn't help.
    final aheadCount =
        _isBurstScrolling() ? cfg.prefetchAheadBurst : cfg.prefetchAhead;
    final backCount = cfg.prefetchBack;

    final upcoming = <String>[];
    for (int i = _currentIndex + 1;
        i < _items.length && i <= _currentIndex + aheadCount;
        i++) {
      final entry = _items[i];
      if (entry is! _ReelItem) continue; // skip cards
      final u = entry.videoUrl;
      if (u.isNotEmpty) upcoming.add(u);
    }
    // Also warm a small back-buffer. TikTok-style scrubbing is bi-
    // directional — users often flick back to the previous reel right
    // after committing to a new one. Without this leg, the previous
    // reel's controller has often been evicted by the time the
    // back-swipe lands, forcing a fresh open + first-byte fetch +
    // decoder warm-up (~700ms-1.5s of "loading…" on cellular). With
    // both directions warmed, the back-swipe hits the in-pool
    // controller and starts in <30ms.
    final back = <String>[];
    for (int i = _currentIndex - 1;
        i >= 0 && i >= _currentIndex - backCount;
        i--) {
      final entry = _items[i];
      if (entry is! _ReelItem) continue;
      final u = entry.videoUrl;
      if (u.isNotEmpty) back.add(u);
    }
    VideoPlayerService.instance.prefetch([...upcoming, ...back]);
  }

  void _maybePrefetchNextPage() {
    if (!_hasMore || _loadingMore) return;
    final remaining = _items.length - _currentIndex - 1;
    if (remaining <= _prefetchPagesWhenLeft) {
      // Fire and forget.
      _loadNextPage();
    }
  }

  // ─── Actions ─────────────────────────────────────────────────────────

  /// Toggle a like on the reel at [index]. Uses an optimistic flip + count
  /// update so the heart turns red instantly, then reconciles with the
  /// server response (which is the source of truth — it knows whether
  /// the user had already liked, the dedup'd total, etc.). Mirrors the
  /// pattern in feed_action_bar.dart's [_onLike] so both surfaces feel
  /// identical to a thumbing user.
  void _onLike(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return; // cards aren't likeable
    if (item.type != 'challenge' || item.id.isEmpty) return; // posts retired
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';
    if (userId.isEmpty) {
      _toast('Sign in to like');
      return;
    }
    EventTracker.instance.trackLike(
      contentId: item.id,
      contentType: item.type,
    );
    // Optimistic — flip the icon and bump the count immediately so the
    // tap feels instant on slow networks.
    final wasLiked = item.isLiked;
    setState(() {
      item.isLiked = !wasLiked;
      item.likes = (item.likes + (wasLiked ? -1 : 1)).clamp(0, 1 << 31);
    });
    final result = await ApiService.likeChallenge(
      challengeId: item.id,
      userId: userId,
    );
    // Server reconciliation — the backend may disagree (e.g. user had
    // already liked from another device). Apply its truth so the UI
    // converges to the right state.
    if (result != null && mounted) {
      setState(() {
        item.isLiked = result['liked'] == true;
        final serverLikes = result['likes'];
        if (serverLikes is int) item.likes = serverLikes;
      });
    }
  }

  /// Open the share sheet for the reel at [index]. Uses the same
  /// [ChallengeShareSheet] the FeedActionBar shows, so the in-app
  /// chat-share + copy-link UX is identical from either surface.
  void _onShare(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return;
    if (item.type != 'challenge' || item.id.isEmpty) return;
    EventTracker.instance.trackShare(
      contentId: item.id,
      contentType: item.type,
    );
    // The share sheet expects a full ChallengeModel — we synthesize one
    // from the lighter _ReelItem since that's all the feed payload
    // gives us. Only the fields the share UI reads (id, title, video
    // URL, creator) need to be populated; defaults are fine for the
    // rest. Keeps us off a /challenges/{id} fetch on every tap.
    final synthetic = ChallengeModel(
      id: item.id,
      creatorId: '',
      creatorUsername: item.creatorUsername,
      creatorLeague: item.creatorLeague,
      videoUrl: item.videoUrl,
      thumbnailUrl: item.thumbnailUrl,
      prefix: '',
      subject: item.caption,
      visibility: 'arena',
      status: 'open',
      likes: item.likes,
      views: item.views,
      createdAt: '',
      responseCount: 0,
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeShareSheet(challenge: synthetic),
    );
  }

  /// Open the vote dialog for a battle reel. No-op on plain shorts
  /// (those don't have an opponent to vote against). Picking a side
  /// fires [ApiService.voteChallenge] and flips local hasVoted state
  /// so the trophy icon turns green.
  void _onVote(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return;
    if (!item.isBattle) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';
    if (userId.isEmpty) {
      _toast('Sign in to vote');
      return;
    }
    EventTracker.instance.trackTap(
      target: 'reel_open_vote_dialog',
      pageName: 'home_page',
      params: {'contentId': item.id, 'contentType': item.type},
    );
    await showChallengeVoteDialog(
      context: context,
      challengeTitle: item.caption,
      challengeId: item.id,
      creatorUsername: item.creatorUsername,
      opponentResponseId: item.opponentResponseId,
      opponentUsername: item.opponentUsername,
      voted: item.hasVoted,
      votedFor: item.votedFor,
      onVote: (responseId, username) async {
        // Optimistic UI flip so the trophy icon turns green and the
        // label switches to the picked side immediately.
        if (mounted) {
          setState(() {
            item.hasVoted = true;
            item.votedFor = username;
          });
        }
        final res = await ApiService.voteChallenge(
          challengeId: item.id,
          responseId: responseId,
          voterId: userId,
        );
        if (!mounted) return;
        if (res == null) {
          // Roll back the optimistic flip on a failed vote so the
          // user can retry instead of believing their vote landed.
          setState(() {
            item.hasVoted = false;
            item.votedFor = '';
          });
          _toast('Vote failed. Try again.');
        } else {
          _toast('Voted for $username!');
        }
      },
    );
  }

  /// Toggle save/bookmark on the reel at [index]. Same optimistic +
  /// server-reconciliation pattern as [_onLike].
  void _onSave(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return;
    if (item.type != 'challenge' || item.id.isEmpty) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';
    if (userId.isEmpty) {
      _toast('Sign in to save');
      return;
    }
    EventTracker.instance.trackSave(
      contentId: item.id,
      contentType: item.type,
    );
    setState(() => item.isSaved = !item.isSaved);
    final result = await ApiService.toggleSaveChallenge(
      userId: userId,
      challengeId: item.id,
    );
    if (!mounted) return;
    if (result != null) {
      setState(() {
        item.isSaved = result['saved'] == true;
      });
      _toast(item.isSaved ? 'Saved to collection' : 'Removed from saved');
    }
  }

  /// Snackbar helper. Defined once so the four action handlers above
  /// don't each duplicate the floating-snack-bar boilerplate.
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _onOpenDetail(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return; // cards have their own per-row taps
    EventTracker.instance.trackTap(
      target: item.type == 'challenge' ? 'home_open_challenge' : 'home_open_post',
      pageName: 'home_page',
      params: {'contentId': item.id, 'contentType': item.type},
    );
    if (item.type == 'challenge' && item.id.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChallengeDetailPage(challengeId: item.id),
        ),
      );
    }
    // Posts already shown full-bleed — no separate detail page needed for now.
  }

  /// Open the comment sheet for the reel at [index]. Wired into the
  /// right-rail comment icon — previously this was a no-op handler
  /// (`onTap: () {}`) so the entire comment surface was unreachable
  /// from the home reels. The sheet itself lives in feed_action_bar.dart
  /// (ChallengeCommentSheet) and is shared with the battle detail page so
  /// both surfaces stay in sync.
  void _onComment(int index) {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return;
    if (item.type != 'challenge' || item.id.isEmpty) return; // posts retired
    EventTracker.instance.trackTap(
      target: 'reel_open_comments',
      pageName: 'home_page',
      params: {'contentId': item.id, 'contentType': item.type},
    );
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeCommentSheet(challengeId: item.id),
    );
  }

  /// Owner-only delete from inside the reel. Mirrors the confirmation +
  /// delete flow on [ChallengeDetailPage._delete] so deleting from
  /// either surface behaves identically (cascade through responses/
  /// votes/likes/comments/saves on the backend, bump feedRefreshTick so
  /// every feed surface refetches). Difference here: instead of popping
  /// a route, we splice the item out of the local list in-place so the
  /// user keeps swiping without a flash to a refreshed feed.
  Future<void> _onDelete(int index) async {
    if (index < 0 || index >= _items.length) return;
    final item = _items[index];
    if (item is! _ReelItem) return;
    if (item.type != 'challenge' || item.id.isEmpty) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final uid = dp.user?.id ?? '';
    if (uid.isEmpty || uid != item.creatorId) return;

    EventTracker.instance.trackTap(
      target: 'reel_delete_open_confirm',
      pageName: 'home_page',
      params: {'contentId': item.id, 'contentType': item.type},
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete challenge?'),
        content: const Text(
          'This permanently removes the challenge, every response, '
          'and all votes/likes/comments on it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    EventTracker.instance.track(
      eventType: 'challenge_delete_confirmed',
      contentId: item.id,
      contentType: 'challenge',
    );

    final ok = await ApiService.deleteChallenge(
      challengeId: item.id,
      userId: uid,
    );
    if (!mounted) return;
    if (!ok) {
      _toast('Could not delete. Try again.');
      return;
    }

    // Splice out + release the player for the deleted reel, then re-key
    // the player-state map so every entry past the removed slot still
    // maps to its tile. The PageController stays on the same numeric
    // index, which now points at whatever was the next reel — exactly
    // the TikTok behavior of "swipe to the next one after delete."
    final removedState = _playerStates.remove(index);
    removedState?.dispose();
    setState(() {
      _items.removeAt(index);
      final reKeyed = <int, _ReelPlayerState>{};
      _playerStates.forEach((k, v) {
        if (k < index) {
          reKeyed[k] = v;
        } else if (k > index) {
          reKeyed[k - 1] = v;
        }
      });
      _playerStates
        ..clear()
        ..addAll(reKeyed);
      if (_currentIndex >= _items.length && _items.isNotEmpty) {
        _currentIndex = _items.length - 1;
      }
    });

    // Tell every other feed surface (profile grid, explore page) to
    // refetch — same signal challenge_detail_page sends after a delete.
    dp.bumpFeedRefresh();

    _toast('Challenge deleted');

    // Resume autoplay on whatever reel is now under the viewport.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playCurrent();
    });
  }

  // ─── Manual pull-to-refresh ──────────────────────────────────────────
  //
  // Why this exists at all: Material's `RefreshIndicator` requires the host
  // scrollable to emit `OverscrollNotification` past the leading edge, and a
  // vertical `PageView` with `PageScrollPhysics` does not — the physics
  // clamps at boundary 0 and swallows excess drag. Wrapping with
  // `AlwaysScrollableScrollPhysics` only guarantees the gesture starts; it
  // doesn't synthesize the overscroll the indicator needs. So we route raw
  // pointer events through a `Listener` that sits above the PageView in the
  // Stack and detect the pull ourselves.

  void _handlePointerDown(PointerDownEvent e) {
    if (_isRefreshing) return;
    if (_currentIndex != 0) return;
    if (e.localPosition.dy > _topPullZoneHeight) return;
    // Only arm if the PageView itself is at the very top — otherwise a
    // user who has scrolled mid-feed and dragged briefly to land back at
    // page 0 would falsely trigger a refresh.
    if (_pageController.hasClients && _pageController.offset > 1) return;
    _pullStartY = e.localPosition.dy;
    _pullDistance = 0;
  }

  void _handlePointerMove(PointerMoveEvent e) {
    if (_pullStartY == null) return;
    if (_currentIndex != 0) {
      _resetPull();
      return;
    }
    // The user might have flicked the PageView during the gesture; if it
    // moved past page 0 mid-drag, abandon the pull.
    if (_pageController.hasClients && _pageController.offset > 1) {
      _resetPull();
      return;
    }
    final dy = e.localPosition.dy - _pullStartY!;
    // Ignore upward drags — those should pass through to PageView so the
    // user can swipe up to the next reel without first satisfying our
    // gesture state machine.
    if (dy <= 0) {
      if (_pullDistance != 0) setState(() => _pullDistance = 0);
      return;
    }
    // Light damping past the trigger so the badge doesn't hyperextend on
    // an over-enthusiastic flick.
    final damped = dy <= _refreshTriggerPx ? dy : _refreshTriggerPx + (dy - _refreshTriggerPx) * 0.4;
    setState(() => _pullDistance = damped);
  }

  void _handlePointerUp(PointerUpEvent e) {
    _resolvePull();
  }

  void _handlePointerCancel(PointerCancelEvent e) {
    _resolvePull();
  }

  void _resolvePull() {
    if (_pullStartY == null) return;
    final fired = _pullDistance >= _refreshTriggerPx;
    _pullStartY = null;
    if (fired && !_isRefreshing) {
      _doManualRefresh();
    } else {
      setState(() => _pullDistance = 0);
    }
  }

  void _resetPull() {
    if (_pullStartY == null && _pullDistance == 0) return;
    _pullStartY = null;
    setState(() => _pullDistance = 0);
  }

  Future<void> _doManualRefresh() async {
    if (_isRefreshing) return;
    EventTracker.instance.trackTap(
      target: 'home_reels_pull_refresh',
      pageName: 'home_page',
      params: {'feedKind': widget.kind.name},
    );
    setState(() {
      _isRefreshing = true;
      _pullDistance = _refreshTriggerPx;
    });
    try {
      await _loadInitialPage(refresh: true);
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshing = false;
          _pullDistance = 0;
        });
      }
    }
  }

  // ─── UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watch the upload-refresh tick. When a new upload completes,
    // DataProvider bumps this counter — we notice on the next rebuild
    // and re-pull page 1 so the user sees their just-posted challenge.
    // Done here (build) instead of didChangeDependencies so the read is
    // implicit-watched and rebuilds happen the moment the tick changes.
    final tick = context.watch<DataProvider>().feedRefreshTick;
    if (tick != _lastSeenRefreshTick) {
      _lastSeenRefreshTick = tick;
      // Schedule outside build — calling setState/_loadInitialPage from
      // inside build() throws "setState during build".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isRefreshing) _doManualRefresh();
      });
    }
    if (_loadingFirstPage) {
      return const _FullScreenLoader();
    }
    if (_items.isEmpty) {
      return _EmptyState(onRetry: _loadInitialPage, errorMessage: _lastError);
    }
    final topInset = MediaQuery.of(context).padding.top;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Pointer-event observer wrapping the PageView. Listener uses
        // `HitTestBehavior.translucent` so the events ALSO reach the
        // PageView underneath — we observe, never consume.
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerUp,
          onPointerCancel: _handlePointerCancel,
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: {
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.trackpad,
              },
            ),
            child: PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              // PageScrollPhysics is the right choice for snap-feel even
              // though it doesn't power refresh — refresh is handled by
              // the Listener above this widget.
              physics: const PageScrollPhysics(),
              onPageChanged: _onPageChanged,
              itemCount: _items.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                // Tail spinner slot while the next page loads.
                if (index >= _items.length) return const _FullScreenLoader();
                final entry = _items[index];
                // Polymorphic dispatch: video tiles for reels, a static card
                // tile for the suggested-accounts entries the backend
                // interleaves into the feed.
                if (entry is _AccountsCard) {
                  return _AccountsCardTile(card: entry);
                }
                final reel = entry as _ReelItem;
                final state = _getPlayerState(index);
                // _getPlayerState should always return non-null for a _ReelItem
                // with a real video URL; the fallback placeholder keeps the
                // page renderable in the rare empty-URL edge case.
                if (state == null) {
                  return _Placeholder(item: reel);
                }
                final currentUserId =
                    context.read<DataProvider>().user?.id ?? '';
                final isOwner = reel.type == 'challenge' &&
                    reel.creatorId.isNotEmpty &&
                    currentUserId.isNotEmpty &&
                    reel.creatorId == currentUserId;
                return _ReelTile(
                  item: reel,
                  state: state,
                  isActive: index == _currentIndex,
                  isOwner: isOwner,
                  onLike: () => _onLike(index),
                  onComment: () => _onComment(index),
                  onShare: () => _onShare(index),
                  onSave: () => _onSave(index),
                  onVote: () => _onVote(index),
                  onOpenDetail: () => _onOpenDetail(index),
                  onDelete: () => _onDelete(index),
                );
              },
            ),
          ),
        ),
        // Pull-to-refresh badge. Slides down from the top inset as the
        // user drags; locks at the trigger row + spinner once a refresh
        // is in flight. Pointer-ignoring so the user can keep dragging
        // the PageView underneath.
        if (_pullDistance > 0 || _isRefreshing)
          Positioned(
            top: topInset,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: _PullRefreshBadge(
                distance: _pullDistance,
                triggerPx: _refreshTriggerPx,
                isRefreshing: _isRefreshing,
              ),
            ),
          ),
      ],
    );
  }
}

// ─── Domain model — normalized from the /feed/smart payload ──────────

/// A single feed entry as seen by the reels widget. Polymorphic because the
/// backend now interleaves non-video tiles (account suggestion cards) into
/// the same stream of items. Use `is _ReelItem` / `is _AccountsCard` at the
/// site that needs to differentiate.
abstract class _FeedEntry {
  String get id;
  String get type;

  /// Factory dispatch on the JSON `type` field. Returns null for entries we
  /// don't know how to render — the parser drops those silently rather than
  /// blocking the page.
  static _FeedEntry? fromJson(Map<String, dynamic> entry) {
    final type = entry['type'] as String? ?? '';
    if (type == 'suggestedAccounts') {
      return _AccountsCard.fromJson(entry);
    }
    if (type == 'post' || type == 'challenge') {
      return _ReelItem.fromFeedEntry(entry);
    }
    return null;
  }
}

class _ReelItem implements _FeedEntry {
  @override
  final String id;
  @override
  final String type; // "post" | "challenge"
  final String videoUrl;
  final String thumbnailUrl;
  final String caption;
  /// Stable creator user id. Required to check ownership for the
  /// owner-only delete affordance on the reel — comparing usernames
  /// is unsafe because they can collide / change. Empty for legacy
  /// payloads where the backend hasn't been updated yet; downstream
  /// readers MUST treat empty as "not the current user."
  final String creatorId;
  final String creatorUsername;
  final String creatorLeague;
  // Opponent (responder) fields. Only populated for challenges with at least
  // one accepted response — populateTopResponses on the backend fills these
  // at the feed-handler boundary so the client can swap to the opponent's
  // video on a left-swipe without an extra round-trip.
  /// Response id of the opponent. Needed by the right-rail vote button so
  /// we can call ApiService.voteChallenge without a follow-up
  /// /challenges/{id} round trip.
  final String opponentResponseId;
  final String opponentVideoUrl;
  final String opponentThumbnailUrl;
  final String opponentUsername;
  final String opponentLeague;
  int likes;
  int views;
  int comments;
  bool isLiked;
  /// Local optimistic save state. Backend-truth is the response of
  /// ApiService.toggleSaveChallenge; we surface this immediately so the
  /// bookmark icon flips on tap without waiting for the round trip.
  /// Always starts false — the feed payload doesn't carry per-user save
  /// state today, and re-fetching the saves list per page would cost a
  /// round trip per scroll. Live correctness can land later via a
  /// `savedIds` set on the feed handler.
  bool isSaved = false;
  /// Locally tracked "the user has voted on this battle" pair. Used to
  /// switch the trophy icon to "voted (green)" and tag the post-vote
  /// toast with the right username. Same per-session-only caveat as
  /// [isSaved] above — the feed payload doesn't carry vote history yet.
  bool hasVoted = false;
  String votedFor = '';

  /// True iff this item is a battle — i.e. there's an opponent video to
  /// swipe to. Plain shorts and image posts return false.
  bool get isBattle => opponentVideoUrl.isNotEmpty;

  _ReelItem({
    required this.id,
    required this.type,
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.caption,
    this.creatorId = '',
    required this.creatorUsername,
    required this.creatorLeague,
    this.opponentResponseId = '',
    this.opponentVideoUrl = '',
    this.opponentThumbnailUrl = '',
    this.opponentUsername = '',
    this.opponentLeague = '',
    required this.likes,
    required this.views,
    required this.comments,
    required this.isLiked,
  });

  static _ReelItem? fromFeedEntry(Map<String, dynamic> entry) {
    final type = entry['type'] as String? ?? '';
    if (type == 'post') {
      final p = entry['post'] as Map<String, dynamic>?;
      if (p == null) return null;
      return _ReelItem(
        id: p['id']?.toString() ?? '',
        type: 'post',
        videoUrl: (p['contentUrl'] as String?) ?? '',
        thumbnailUrl: (p['thumbnailUrl'] as String?) ?? '',
        caption: (p['caption'] as String?) ?? '',
        creatorId: (p['authorId'] as String?) ?? '',
        creatorUsername: (p['authorUsername'] as String?) ?? '',
        creatorLeague: (p['authorLeague'] as String?) ?? '',
        likes: p['likes'] as int? ?? 0,
        views: p['views'] as int? ?? 0,
        comments: p['comments'] as int? ?? 0,
        isLiked: p['isLiked'] == true,
      );
    }
    if (type == 'challenge') {
      final c = entry['challenge'] as Map<String, dynamic>?;
      if (c == null) return null;
      final title =
          '${c['prefix'] ?? ''} ${c['subject'] ?? ''}'.trim();
      final fallbackUrl = (c['videoUrl'] as String?) ?? '';
      // Prefer HLS when the server-side transcode worker has produced
      // the segmented manifest for this challenge — drops first-frame
      // latency from ~2-4s (whole-MP4 seek + buffer) to ~300-500ms
      // (tiny manifest + 1st segment), and unlocks ExoPlayer's /
      // AVPlayer's built-in adaptive bitrate so mid-reel network dips
      // don't stall playback.
      //
      // Manifest URL is the SAME for every viewer — the .m3u8 lists
      // every quality + every segment, and the native player picks
      // per-segment. So the NetworkQualityService variant-picker
      // (which only knows about the legacy 480p/720p/1080p MP4 split)
      // doesn't apply here.
      //
      // Empty hlsManifestUrl means the worker hasn't finished yet (or
      // isn't deployed) — fall back to the per-bitrate MP4 picker.
      final hlsUrl = (c['hlsManifestUrl'] as String?) ?? '';
      final String chosenVideoUrl;
      if (hlsUrl.isNotEmpty) {
        chosenVideoUrl = hlsUrl;
      } else {
        final variantPick = NetworkQualityService.instance.pickVariantUrl(
          _coerceVariantsMap(c['videoVariants']),
        );
        chosenVideoUrl =
            variantPick?.isNotEmpty == true ? variantPick! : fallbackUrl;
      }
      // Same logic for the opponent video — picks the right bitrate
      // for the user's current network so a battle left-swipe doesn't
      // suddenly stutter on cellular even though the challenger
      // played fine.
      final opponentFallback = (c['topResponseVideoUrl'] as String?) ?? '';
      final opponentVariantPick = NetworkQualityService.instance.pickVariantUrl(
        _coerceVariantsMap(c['topResponseVideoVariants']),
      );
      return _ReelItem(
        id: c['id']?.toString() ?? '',
        type: 'challenge',
        videoUrl: chosenVideoUrl,
        thumbnailUrl: (c['thumbnailUrl'] as String?) ?? '',
        caption: title,
        creatorId: (c['creatorId'] as String?) ?? '',
        creatorUsername: (c['creatorUsername'] as String?) ?? '',
        creatorLeague: (c['creatorLeague'] as String?) ?? '',
        opponentResponseId: (c['topResponseId'] as String?) ?? '',
        opponentVideoUrl: opponentVariantPick?.isNotEmpty == true
            ? opponentVariantPick!
            : opponentFallback,
        opponentThumbnailUrl: (c['topResponseThumbnailUrl'] as String?) ?? '',
        opponentUsername: (c['topResponseUsername'] as String?) ?? '',
        opponentLeague: (c['topResponseLeague'] as String?) ?? '',
        likes: c['likes'] as int? ?? 0,
        views: c['views'] as int? ?? 0,
        // commentCount lands on the wire alongside likes/views — populated
        // by the backend's populateChallengeCommentCounts so we don't
        // have to hit /challenges/{id} just to render the right number.
        comments: c['commentCount'] as int? ?? 0,
        isLiked: false,
      );
    }
    return null;
  }

  /// Build a reel from an already-parsed ChallengeModel. Used by the
  /// search-result viewer path so the tapped video opens immediately
  /// without re-fetching the challenge from the API.
  ///
  /// Opponent fields land through ChallengeModel's topResponse* fields,
  /// which the backend populates via populateTopResponses on every endpoint
  /// that surfaces a Challenge (smart feed, explore feed, /search). When
  /// they're empty the challenge has no responses yet (plain short) and the
  /// battle indicator pill stays hidden — exactly the behavior `isBattle`
  /// already encodes against opponentVideoUrl.isNotEmpty.
  static _ReelItem? fromChallengeModel(ChallengeModel c) {
    if (c.id.isEmpty || c.videoUrl.isEmpty) return null;
    // Same HLS preference as fromFeedEntry above — when the worker has
    // produced the segmented manifest, use it; else fall back to the
    // per-bitrate MP4 selection.
    final variantPick =
        NetworkQualityService.instance.pickVariantUrl(c.videoVariants);
    final opponentVariantPick = NetworkQualityService.instance
        .pickVariantUrl(c.topResponseVideoVariants);
    final chosenVideoUrl = c.hlsManifestUrl.isNotEmpty
        ? c.hlsManifestUrl
        : (variantPick?.isNotEmpty == true ? variantPick! : c.videoUrl);
    return _ReelItem(
      id: c.id,
      type: 'challenge',
      videoUrl: chosenVideoUrl,
      thumbnailUrl: c.thumbnailUrl ?? '',
      caption: c.title,
      creatorId: c.creatorId,
      creatorUsername: c.creatorUsername,
      creatorLeague: c.creatorLeague,
      opponentResponseId: c.topResponseId,
      opponentVideoUrl: opponentVariantPick?.isNotEmpty == true
          ? opponentVariantPick!
          : c.topResponseVideoUrl,
      opponentThumbnailUrl: c.topResponseThumbnailUrl,
      opponentUsername: c.topResponseUsername,
      opponentLeague: c.topResponseLeague,
      likes: c.likes,
      views: c.views,
      comments: c.commentCount,
      isLiked: false,
    );
  }
}

/// Normalize a JSON-decoded videoVariants payload into `Map<String,String>`.
/// The backend returns it as a JSON object (decoded as `Map<String,dynamic>`)
/// — values are always strings (URLs) but the static type is dynamic, so
/// we coerce here once instead of at every consumer.
Map<String, String> _coerceVariantsMap(Object? raw) {
  if (raw is Map) {
    return {
      for (final entry in raw.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }
  return const {};
}

/// Suggested-accounts card injected into the feed by the backend's
/// injectSuggestedAccountsCard. Renders as a non-video tile listing 3-5
/// users to follow, with inline Follow buttons.
class _AccountsCard implements _FeedEntry {
  @override
  final String id;
  @override
  final String type;
  final String title;
  final String reason;
  final List<_AccountSuggestion> users;

  _AccountsCard({
    required this.id,
    required this.title,
    required this.reason,
    required this.users,
  }) : type = 'suggestedAccounts';

  static _AccountsCard? fromJson(Map<String, dynamic> entry) {
    final c = entry['suggestedAccounts'] as Map<String, dynamic>?;
    if (c == null) return null;
    final rawUsers = (c['users'] as List?) ?? const [];
    final parsed = <_AccountSuggestion>[];
    for (final u in rawUsers) {
      if (u is Map<String, dynamic>) {
        parsed.add(_AccountSuggestion.fromJson(u));
      }
    }
    if (parsed.isEmpty) return null;
    return _AccountsCard(
      id: (c['id'] as String?) ?? '',
      title: (c['title'] as String?) ?? 'Accounts you might like',
      reason: (c['reason'] as String?) ?? '',
      users: parsed,
    );
  }
}

/// One row inside an [_AccountsCard].
class _AccountSuggestion {
  final String userId;
  final String username;
  final String fullName;
  final String league;
  final int followers;
  final int wins;
  final int losses;
  // "fof" | "category" | "popular" | "league" — set by the backend ranker.
  final String reason;
  // How many of the recipient's follows already follow this user (0 = no
  // social hint surfaced for this row).
  final int followedByFriends;

  _AccountSuggestion({
    required this.userId,
    required this.username,
    this.fullName = '',
    this.league = '',
    this.followers = 0,
    this.wins = 0,
    this.losses = 0,
    this.reason = '',
    this.followedByFriends = 0,
  });

  factory _AccountSuggestion.fromJson(Map<String, dynamic> j) {
    return _AccountSuggestion(
      userId: (j['id'] as String?) ?? '',
      username: (j['username'] as String?) ?? '',
      fullName: (j['fullName'] as String?) ?? '',
      league: (j['league'] as String?) ?? '',
      followers: j['followers'] as int? ?? 0,
      wins: j['wins'] as int? ?? 0,
      losses: j['losses'] as int? ?? 0,
      reason: (j['reason'] as String?) ?? '',
      followedByFriends: j['followedByFriends'] as int? ?? 0,
    );
  }

  /// Build a UserModel for the existing follow APIs. We only need the fields
  /// that follow/unfollow + profile-navigation actually consume; the rest
  /// stay at sensible defaults.
  UserModel toUserModel() => UserModel(
        id: userId,
        username: username,
        fullName: fullName,
        league: league.isEmpty ? 'Unranked' : league,
        wins: wins,
        losses: losses,
        followersCount: followers,
        followingCount: 0,
      );
}

class _ReelPlayerState {
  /// The pooled controller. Same instance video_player.VideoPlayer uses
  /// directly — no separate "controller wrapper" like media_kit had.
  final VideoPlayerController controller;
  final String url;

  _ReelPlayerState({
    required this.controller,
    required this.url,
  });

  void dispose() {
    // We don't own the controller — VideoPlayerService does. release()
    // pauses it and leaves it warm in the pool for back-swipe.
    VideoPlayerService.instance.release(url);
  }
}

// ─── Single reel tile ────────────────────────────────────────────────

class _ReelTile extends StatefulWidget {
  final _ReelItem item;
  final _ReelPlayerState state;
  final bool isActive;
  /// True when the currently signed-in user is the creator of this
  /// challenge. Drives the owner-only delete affordance — the 3-dot
  /// menu is only painted when this is true so non-owners never see a
  /// destructive control they can't actually invoke.
  final bool isOwner;
  final VoidCallback onLike;
  final VoidCallback onComment;
  /// Open the share sheet (same UI used by FeedActionBar). Wired up
  /// once the right-rail share button became a first-class action.
  final VoidCallback onShare;
  /// Toggle the bookmark/save state.
  final VoidCallback onSave;
  /// Open the vote dialog. Only shown on battles — for plain shorts
  /// the trophy slot in the rail is hidden so the callback is unused
  /// in that case.
  final VoidCallback onVote;
  final VoidCallback onOpenDetail;
  /// Owner-only delete. Confirms via dialog inside the parent state,
  /// then removes the reel in-place. Only invoked when [isOwner] is
  /// true.
  final VoidCallback onDelete;

  const _ReelTile({
    required this.item,
    required this.state,
    required this.isActive,
    required this.isOwner,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onSave,
    required this.onVote,
    required this.onOpenDetail,
    required this.onDelete,
  });

  @override
  State<_ReelTile> createState() => _ReelTileState();
}

class _ReelTileState extends State<_ReelTile>
    with SingleTickerProviderStateMixin {
  bool _showHeart = false;
  bool _isPaused = false;
  late final AnimationController _heartCtl;
  late final Animation<double> _heartAnim;

  // Battle swipe state. _showingOpponent flips on horizontal swipe-left for
  // challenges that carry an opponent video. _opponentState is created
  // lazily on first toggle so plain shorts don't allocate a second player.
  bool _showingOpponent = false;
  _ReelPlayerState? _opponentState;

  @override
  void initState() {
    super.initState();
    _heartCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _heartAnim = CurvedAnimation(parent: _heartCtl, curve: Curves.elasticOut);
    _heartCtl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 250), () {
          if (mounted) setState(() => _showHeart = false);
        });
      }
    });
  }

  @override
  void didUpdateWidget(covariant _ReelTile old) {
    super.didUpdateWidget(old);
    // Reset to the primary video whenever this tile loses focus, so the
    // user always re-enters a battle on the challenger's side. Avoids the
    // confusing "opponent video frozen + primary audio playing" race that
    // happens if we leave _showingOpponent set while the parent's
    // _playCurrent unconditionally starts the primary URL on re-entry.
    if (old.isActive && !widget.isActive && _showingOpponent) {
      _setShowOpponent(false, track: false);
    }
  }

  @override
  void dispose() {
    _opponentState?.dispose();
    _heartCtl.dispose();
    super.dispose();
  }

  void _togglePause() {
    final activeController = _activeState.controller;
    if (_isPaused) {
      // ignore: discarded_futures
      activeController.play();
    } else {
      // ignore: discarded_futures
      activeController.pause();
    }
    setState(() => _isPaused = !_isPaused);
  }

  void _doubleTapLike() {
    widget.onLike();
    setState(() => _showHeart = true);
    _heartCtl.forward(from: 0);
  }

  /// The player state currently driving the visible video — primary by
  /// default, opponent when the user has swiped left on a battle.
  _ReelPlayerState get _activeState =>
      _showingOpponent && _opponentState != null ? _opponentState! : widget.state;

  /// Lazily build the opponent controller. Mirrors the parent's
  /// _getPlayerState so the same VideoPlayerService cache is shared.
  _ReelPlayerState _ensureOpponentState() {
    if (_opponentState != null) return _opponentState!;
    final url = widget.item.opponentVideoUrl;
    final controller = VideoPlayerService.instance.getController(url);
    // ignore: discarded_futures
    controller.setLooping(true);
    _opponentState = _ReelPlayerState(controller: controller, url: url);
    return _opponentState!;
  }

  /// Flip between challenger and opponent video. No-op on non-battles, on a
  /// repeat-toggle to the same side, or while the tile is offscreen.
  void _setShowOpponent(bool show, {bool track = true}) {
    if (!widget.item.isBattle) return;
    if (show == _showingOpponent) return;

    setState(() {
      _showingOpponent = show;
      _isPaused = false; // resume on swap so the new side autoplays
    });

    if (show) {
      final s = _ensureOpponentState();
      // ignore: discarded_futures
      widget.state.controller.pause();
      // ignore: discarded_futures
      s.controller.setVolume(1.0);
      // ignore: discarded_futures
      s.controller.play();
    } else {
      // ignore: discarded_futures
      _opponentState?.controller.pause();
      // ignore: discarded_futures
      widget.state.controller.setVolume(1.0);
      // ignore: discarded_futures
      widget.state.controller.play();
    }

    if (track) {
      EventTracker.instance.trackSwipe(
        target: show ? 'reel_swipe_to_opponent' : 'reel_swipe_to_challenger',
        direction: show ? 'left' : 'right',
        pageName: 'home_page',
        params: {
          'contentId': widget.item.id,
          'contentType': widget.item.type,
        },
      );
    }
  }

  /// Translate horizontal-fling velocity into a side switch. Threshold is
  /// permissive so casual flicks register without triggering on micro
  /// horizontal jitter the user didn't intend.
  void _onHorizontalDragEnd(DragEndDetails d) {
    if (!widget.item.isBattle) return;
    final vx = d.primaryVelocity ?? 0;
    if (vx.abs() < 200) return;
    if (vx < 0) {
      _setShowOpponent(true);
    } else {
      _setShowOpponent(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final activeUrl = _showingOpponent ? item.opponentVideoUrl : item.videoUrl;
    final hasVideo = activeUrl.isNotEmpty;
    final isChallenge = item.type == 'challenge';

    // Pick the right poster for whichever side is currently visible. On a
    // battle, swiping to the opponent should show the opponent's
    // thumbnail behind the buffering frames — using the challenger's
    // poster there would flash the wrong image for a fraction of a
    // second while media_kit decodes the new stream's first frame.
    final posterUrl = _showingOpponent && item.opponentThumbnailUrl.isNotEmpty
        ? item.opponentThumbnailUrl
        : item.thumbnailUrl;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Thumbnail poster behind the video. Shown while media_kit is
        // still buffering / decoding the first frame so the user doesn't
        // stare at a black screen on slow networks. The Video widget
        // paints over this once the first frame lands; we keep the
        // poster in the tree (rather than swapping it out on a "ready"
        // signal) because (a) the Video widget is opaque so there's no
        // visible cost once playback starts, and (b) it gives us a free
        // fallback if media_kit fails to start.
        if (posterUrl.isNotEmpty)
          Positioned.fill(
            child: Image.network(
              posterUrl,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // Don't show a broken-image icon if the CDN burps — we'd
              // rather fall through to a black background and let the
              // video load on top of it.
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          )
        else
          const ColoredBox(color: Colors.black),

        // Background video / placeholder. Re-keyed when toggling to
        // opponent so the VideoPlayer rebuilds against the new
        // controller.
        //
        // ValueListenableBuilder binds the rebuild DIRECTLY to the
        // controller's value, bypassing the previous _firstFrameSeen
        // listener-and-flag dance that had a race window where the
        // surface was ready but no setState had fired yet — leaving the
        // user staring at the thumbnail until they tapped the screen.
        //
        // The builder fires for every value change (init, play, position,
        // size, etc.), so as soon as isInitialized flips true the
        // VideoPlayer paints. No opacity gating — ExoPlayer's surface
        // typically has the first frame ready by initialize() completion,
        // so a brief black flash is rare on Android. iOS / Web behave
        // the same. The thumbnail underneath still shows during the
        // ~50-200ms init handshake before isInitialized is true.
        //
        // FittedBox(cover) gives reels the edge-to-edge crop the
        // format demands (never letterbox).
        if (hasVideo)
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _activeState.controller,
            builder: (context, value, _) {
              if (!value.isInitialized) return const SizedBox.shrink();
              return SizedBox.expand(
                child: FittedBox(
                  key: ValueKey(
                      'reel-video-${item.id}-${_showingOpponent ? 'opp' : 'pri'}'),
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: value.size.width,
                    height: value.size.height,
                    child: VideoPlayer(_activeState.controller),
                  ),
                ),
              );
            },
          )
        else if (!hasVideo)
          _Placeholder(item: item),

        // Gesture catcher (translucent — vertical swipes still reach the
        // parent PageView, horizontal swipes drive the battle side switch).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _togglePause,
            onDoubleTap: _doubleTapLike,
            onHorizontalDragEnd: _onHorizontalDragEnd,
          ),
        ),

        // Top-center battle indicator — only on battles. Tap either side
        // to switch (gives discoverability beyond the swipe gesture).
        if (item.isBattle)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 0,
            right: 0,
            child: Center(
              child: _BattleIndicator(
                challengerUsername: item.creatorUsername,
                opponentUsername: item.opponentUsername,
                showingOpponent: _showingOpponent,
                onTapChallenger: () => _setShowOpponent(false),
                onTapOpponent: () => _setShowOpponent(true),
              ),
            ),
          ),

        // Pause indicator.
        if (_isPaused)
          const Center(
            child: IgnorePointer(
              child: _PauseBadge(),
            ),
          ),

        // Double-tap heart.
        if (_showHeart)
          Center(
            child: IgnorePointer(
              child: ScaleTransition(
                scale: _heartAnim,
                child: const Icon(
                  Icons.favorite,
                  color: Colors.white,
                  size: 110,
                  shadows: [Shadow(blurRadius: 30, color: Colors.black45)],
                ),
              ),
            ),
          ),

        // Bottom gradient for legibility — covers the area where the
        // creator/caption/CTA overlay sits, with a soft fade upward so the
        // text is readable over light video frames without darkening the
        // whole bottom third.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 200 + MediaQuery.of(context).padding.bottom,
          child: const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
          ),
        ),

        // Bottom-left: creator + caption + optional "open" CTA.
        // Anchored just above the progress bar with a small breathing margin
        // and safe-area padding so the home indicator on iOS / nav-gesture
        // hint on Android doesn't overlap the text.
        Positioned(
          bottom: MediaQuery.of(context).padding.bottom + 16,
          left: 16,
          right: 80,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.white24,
                    child: Text(
                      item.creatorUsername.isNotEmpty
                          ? item.creatorUsername[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    item.creatorUsername,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  if (item.creatorLeague.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white54),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.creatorLeague,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              if (item.caption.isNotEmpty)
                Text(
                  item.caption,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              if (isChallenge) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    onPressed: widget.onOpenDetail,
                    icon: const Icon(Icons.sports_kabaddi_rounded, size: 18),
                    label: const Text(
                      'View battle',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),

        // Right-side action rail. Anchored to the same baseline as the
        // caption block so they bottom-align cleanly instead of floating.
        //
        // Order matches TikTok / Reels muscle memory (like → comment →
        // share → save), with the vote button pinned at the top of the
        // rail on battles only — that placement mirrors the FeedActionBar
        // widget on the challenge detail page so users learn one layout.
        Positioned(
          right: 10,
          bottom: MediaQuery.of(context).padding.bottom + 24,
          child: Column(
            children: [
              // Owner-only overflow menu. Lives ABOVE the vote/like
              // stack so the destructive action is visually quarantined
              // from the high-frequency engagement controls — a user
              // double-tapping for "like" will never accidentally land
              // on delete.
              if (widget.isOwner) ...[
                _OwnerMenuButton(onDelete: widget.onDelete),
                const SizedBox(height: 18),
              ],
              if (item.isBattle) ...[
                _VoteAction(
                  hasVoted: item.hasVoted,
                  votedFor: item.votedFor,
                  onTap: widget.onVote,
                ),
                const SizedBox(height: 18),
              ],
              _Action(
                icon: item.isLiked ? Icons.favorite : Icons.favorite_border,
                color: item.isLiked ? Colors.red : Colors.white,
                label: _compact(item.likes),
                onTap: widget.onLike,
              ),
              const SizedBox(height: 18),
              _Action(
                icon: Icons.comment_outlined,
                color: Colors.white,
                // Hide the digit on 0 — looks intentional rather than
                // "broken counter" for brand-new challenges.
                label: item.comments > 0 ? _compact(item.comments) : '',
                onTap: widget.onComment,
              ),
              const SizedBox(height: 18),
              _Action(
                icon: Icons.share_outlined,
                color: Colors.white,
                label: 'Share',
                onTap: widget.onShare,
              ),
              const SizedBox(height: 18),
              _Action(
                icon: item.isSaved ? Icons.bookmark : Icons.bookmark_border,
                color: item.isSaved ? Colors.amber : Colors.white,
                label: item.isSaved ? 'Saved' : '',
                onTap: widget.onSave,
              ),
              const SizedBox(height: 18),
              _Action(
                icon: Icons.visibility_outlined,
                color: Colors.white70,
                label: _compact(item.views),
              ),
            ],
          ),
        ),

        // Thin progress bar — sits at the very bottom but lifted above the
        // safe-area inset so it isn't clipped by the home indicator.
        // video_player's controller is itself a ValueListenable, so
        // ValueListenableBuilder gives us frame-rate-ish rebuilds
        // without manually forwarding position ticks through a Stream.
        if (hasVideo)
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom,
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: widget.state.controller,
              builder: (context, v, _) {
                final pos = v.position;
                final dur = v.duration;
                final p = dur.inMilliseconds > 0
                    ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0;
                return LinearProgressIndicator(
                  value: p,
                  minHeight: 2,
                  backgroundColor: Colors.white24,
                  valueColor: AlwaysStoppedAnimation(
                    Theme.of(context).colorScheme.primary,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _Action({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 30),
          // Skip the label slot entirely when the caller passes an empty
          // string — keeps the rail compact for buttons like share/save
          // that often have no count to surface.
          if (label.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Owner-only overflow menu for the right-rail. A 3-dot icon that opens
/// a PopupMenu with destructive actions (currently just "Delete"). Kept
/// as its own widget so the PopupMenu can anchor against the icon's
/// own RenderBox — anchoring against the parent Column would make the
/// menu pop out far to the left where it visually disconnects from the
/// triggering control.
class _OwnerMenuButton extends StatelessWidget {
  final VoidCallback onDelete;
  const _OwnerMenuButton({required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(
        Icons.more_vert,
        color: Colors.white,
        size: 30,
        shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
      ),
      color: Colors.black87,
      onSelected: (v) {
        if (v == 'delete') onDelete();
      },
      itemBuilder: (_) => const [
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
              SizedBox(width: 10),
              Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Trophy / "Voted" pill for the right-rail vote slot on battle reels.
/// Mirrors the look-and-feel of [_VoteButton] in feed_action_bar.dart so
/// the same UI lives on both the home reels and the challenge detail
/// page. Filled-orange when the user hasn't voted yet, filled-green
/// once they have, with the picked-side username under the icon as a
/// readback so they remember who they voted for at a glance.
class _VoteAction extends StatelessWidget {
  final bool hasVoted;
  final String votedFor;
  final VoidCallback onTap;

  const _VoteAction({
    required this.hasVoted,
    required this.votedFor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: hasVoted ? Colors.green : Colors.orange,
              shape: BoxShape.circle,
            ),
            child: Icon(
              hasVoted ? Icons.how_to_vote : Icons.emoji_events,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(height: 4),
          // Truncate long usernames so the rail width stays predictable —
          // a 24-char gamertag would otherwise overflow into the video.
          SizedBox(
            width: 64,
            child: Text(
              hasVoted ? votedFor : 'Vote',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasVoted ? Colors.green.shade300 : Colors.orange.shade300,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PauseBadge extends StatelessWidget {
  const _PauseBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Colors.black38,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.pause, color: Colors.white, size: 48),
    );
  }
}

/// Top-of-tile chip shown on battle reels. Two pill segments — one for the
/// challenger, one for the responder — with the active side highlighted and
/// a "swipe ←/→" hint underneath. Tapping a segment switches sides directly,
/// for users who don't discover the swipe gesture on their own.
/// Top-of-screen battle bar — a tappable two-sided segmented control with
/// the challenger and opponent usernames. The active side is filled with
/// the primary color and shows an under-the-thumb selection indicator so
/// the user has zero ambiguity about whose video is currently on screen.
///
/// Below the pill we render a small animated arrow hint that pulses in the
/// direction of the inactive side — discoverability for the swipe gesture
/// without needing a tutorial overlay. The hint hides for 4 seconds after
/// any user-initiated switch so it doesn't nag once they've found the UI.
class _BattleIndicator extends StatefulWidget {
  final String challengerUsername;
  final String opponentUsername;
  final bool showingOpponent;
  final VoidCallback onTapChallenger;
  final VoidCallback onTapOpponent;

  const _BattleIndicator({
    required this.challengerUsername,
    required this.opponentUsername,
    required this.showingOpponent,
    required this.onTapChallenger,
    required this.onTapOpponent,
  });

  @override
  State<_BattleIndicator> createState() => _BattleIndicatorState();
}

class _BattleIndicatorState extends State<_BattleIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hintCtrl;
  late final Animation<double> _hintAnim;

  @override
  void initState() {
    super.initState();
    _hintCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _hintAnim = CurvedAnimation(parent: _hintCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _hintCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bigger, segmented two-tab control — clearly looks tappable.
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white38, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Side(
                username: widget.challengerUsername,
                label: 'Challenger',
                active: !widget.showingOpponent,
                onTap: widget.onTapChallenger,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'VS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
              _Side(
                username: widget.opponentUsername,
                label: 'Opponent',
                active: widget.showingOpponent,
                onTap: widget.onTapOpponent,
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Animated swipe hint: arrow points toward the side the user can
        // swipe to. Fades in/out continuously so it's noticed without
        // becoming a steady piece of UI clutter.
        FadeTransition(
          opacity: _hintAnim,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.showingOpponent)
                const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white70, size: 12),
              if (widget.showingOpponent) const SizedBox(width: 4),
              Text(
                widget.showingOpponent
                    ? 'Swipe right for original'
                    : 'Swipe left for opponent',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                ),
              ),
              if (!widget.showingOpponent) const SizedBox(width: 4),
              if (!widget.showingOpponent)
                const Icon(Icons.arrow_forward_ios,
                    color: Colors.white70, size: 12),
            ],
          ),
        ),
      ],
    );
  }
}

/// One side of the [_BattleIndicator] pill — bigger tap target, role label
/// on top, username below, fills with primary color when active.
class _Side extends StatelessWidget {
  final String username;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _Side({
    required this.username,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final display = username.isEmpty ? 'opponent' : '@$username';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 140, minWidth: 70),
        decoration: BoxDecoration(
          color: active ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                color: active
                    ? Colors.white.withValues(alpha: 0.95)
                    : Colors.white60,
                fontSize: 8,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? Colors.white : Colors.white70,
                fontSize: 13,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// First-paint placeholder used while page 1 of the feed is in flight.
///
/// Why this exists in the shape it does: the user's #1 complaint about the
/// home tab was "why is it so slow?". Page 1 against the live Render
/// backend takes 2-4s on cold-start; on a centered-spinner-on-black layout
/// every one of those seconds reads as "the app is broken". This skeleton:
///
///   * Renders the SAME outer chrome the real reel will (a poster surface
///     plus a right-rail action ladder shape) so when the data lands the
///     content slots into the spaces the user's eye already mapped.
///   * Pulses with a SHIFTING shimmer gradient so the page feels alive
///     rather than frozen.
///   * Keeps the bottom 70% reserved for the title block — that's where
///     the user's gaze lands first; placing motion there is more
///     reassuring than a centered spinner.
class _FullScreenLoader extends StatefulWidget {
  const _FullScreenLoader();
  @override
  State<_FullScreenLoader> createState() => _FullScreenLoaderState();
}

class _FullScreenLoaderState extends State<_FullScreenLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Shimmering background — a moving linear gradient that scans
          // down the screen. AnimatedBuilder rebuilds only this Container
          // each frame; the action-ladder + title block above are static
          // and stay out of the rebuild path.
          AnimatedBuilder(
            animation: _ctl,
            builder: (_, _) {
              final t = _ctl.value;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(-1, -1 + 2 * t),
                    end: Alignment(1, 1 + 2 * t),
                    colors: const [
                      Color(0xFF111111),
                      Color(0xFF1E1E1E),
                      Color(0xFF111111),
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              );
            },
          ),
          // Right-side action ladder skeleton (avatar + 4 icon slots).
          // Mirrors the position of the real action bar so when the
          // real reel renders nothing visually jumps.
          Positioned(
            right: 12,
            bottom: 100,
            child: Column(
              children: List.generate(5, (i) => Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    shape: i == 0 ? BoxShape.circle : BoxShape.rectangle,
                    borderRadius: i == 0
                        ? null
                        : BorderRadius.circular(8),
                  ),
                ),
              )),
            ),
          ),
          // Caption / username skeleton blocks bottom-left.
          Positioned(
            left: 16,
            bottom: 90,
            right: 80,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 200,
                  height: 10,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
          // Soft progress dot in the very center as a last-resort
          // "yes the app is doing something" cue. Kept tiny so it
          // doesn't visually compete with the skeleton chrome.
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual feedback for the manual pull-to-refresh in SmartReelsFeed.
///
/// Two states:
///   * **dragging** — `isRefreshing == false`: a chevron rotates from 0° to
///     180° as `distance / triggerPx` climbs from 0 → 1, communicating "pull
///     a bit further to release".
///   * **refreshing** — `isRefreshing == true`: chevron is replaced by a
///     spinner; the chip stays pinned at the trigger row until the parent
///     clears `_isRefreshing`.
///
/// Why a custom widget vs. recycling `RefreshProgressIndicator`: that widget
/// is wired into `RefreshIndicator`'s state machine and expects a parent
/// scrollable to drive its `value`. We're driving it from raw pointer
/// state, so a hand-rolled chip is simpler and avoids fighting Flutter's
/// material refresh internals.
class _PullRefreshBadge extends StatelessWidget {
  final double distance;
  final double triggerPx;
  final bool isRefreshing;

  const _PullRefreshBadge({
    required this.distance,
    required this.triggerPx,
    required this.isRefreshing,
  });

  @override
  Widget build(BuildContext context) {
    final progress = (distance / triggerPx).clamp(0.0, 1.0);
    final ready = progress >= 1.0;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(
                alpha: ready || isRefreshing ? 0.9 : 0.35,
              ),
              width: 1.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Colors.white,
                    ),
                  )
                : Transform.rotate(
                    angle: progress * 3.14159, // 0 → π (chevron flips)
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 22,
                      color: Colors.white.withValues(
                        alpha: 0.4 + 0.6 * progress,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final Future<void> Function() onRetry;
  final String? errorMessage;
  const _EmptyState({required this.onRetry, this.errorMessage});
  @override
  Widget build(BuildContext context) {
    final hasError = errorMessage != null && errorMessage!.isNotEmpty;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError ? Icons.cloud_off : Icons.movie_filter_outlined,
              size: 64,
              color: hasError ? Colors.orange.shade200 : Colors.white70,
            ),
            const SizedBox(height: 12),
            Text(
              hasError ? 'Connection problem' : 'Nothing to play just yet',
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              hasError ? errorMessage! : 'Pull to refresh or check back soon',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white30),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Suggested-accounts card tile ─────────────────────────────────────
//
// Renders an [_AccountsCard] as a full-page entry inside the same vertical
// PageView that holds video reels. Vertical swipes still flow through to
// the parent so users can scroll past the card; per-row Follow buttons and
// row taps consume their own gestures.

class _AccountsCardTile extends StatefulWidget {
  final _AccountsCard card;
  const _AccountsCardTile({required this.card});

  @override
  State<_AccountsCardTile> createState() => _AccountsCardTileState();
}

class _AccountsCardTileState extends State<_AccountsCardTile> {
  bool _impressionTracked = false;

  @override
  void initState() {
    super.initState();
    // Fire one card-impression event so analytics can compute follow-rate
    // per card-impression in the funnel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_impressionTracked || !mounted) return;
      _impressionTracked = true;
      EventTracker.instance.trackTap(
        target: 'suggested_accounts_card_impression',
        pageName: 'home_page',
        params: {
          'cardId': widget.card.id,
          'reason': widget.card.reason,
          'userCount': widget.card.users.length,
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Colors.black,
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 24,
        bottom: MediaQuery.of(context).padding.bottom + 80,
        left: 20,
        right: 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.group_add_rounded,
                    color: cs.primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.card.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (widget.card.reason.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          widget.card.reason,
                          style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 13,
                              fontWeight: FontWeight.w500),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.card.users.length,
              separatorBuilder: (_, _) => const Divider(
                color: Colors.white12,
                height: 16,
              ),
              itemBuilder: (_, i) => _AccountSuggestionRow(
                user: widget.card.users[i],
                cardId: widget.card.id,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.keyboard_arrow_up_rounded,
                    color: Colors.white38, size: 18),
                SizedBox(width: 4),
                Text(
                  'Swipe up to keep watching',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountSuggestionRow extends StatelessWidget {
  final _AccountSuggestion user;
  final String cardId;
  const _AccountSuggestionRow({
    required this.user,
    required this.cardId,
  });

  String get _reasonChipLabel {
    if (user.followedByFriends > 0) {
      return user.followedByFriends == 1
          ? 'Followed by 1 friend'
          : 'Followed by ${user.followedByFriends} friends';
    }
    switch (user.reason) {
      case 'category':
        return 'Matches your interests';
      case 'league':
        return 'Plays in your league';
      case 'popular':
        return 'Popular creator';
      case 'fof':
        return 'In your network';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    final isFollowing = dp.following.contains(user.userId);
    final cs = Theme.of(context).colorScheme;
    final chip = _reasonChipLabel;
    final username = user.username;

    return InkWell(
      onTap: () {
        EventTracker.instance.trackTap(
          target: 'suggested_account_row',
          pageName: 'home_page',
          params: {'cardId': cardId, 'targetUserId': user.userId},
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProfilePage(
              user: user.toUserModel(),
              isEmbedded: false,
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: cs.primaryContainer,
              child: Text(
                username.isNotEmpty ? username[0].toUpperCase() : '?',
                style: TextStyle(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '@$username',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (user.league.isNotEmpty &&
                          user.league.toLowerCase() != 'unranked') ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white38),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            user.league,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_compactInt(user.followers)} followers',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
                  if (chip.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        chip,
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _FollowButton(
              isFollowing: isFollowing,
              onTap: () {
                final target = user.toUserModel();
                if (isFollowing) {
                  EventTracker.instance.trackFollowToggle(
                    targetUserId: user.userId,
                    becameFollowing: false,
                    fromPage: 'home_page',
                  );
                  dp.unfollowUser(target);
                } else {
                  EventTracker.instance.trackFollowToggle(
                    targetUserId: user.userId,
                    becameFollowing: true,
                    fromPage: 'home_page',
                  );
                  dp.followUser(target);
                  // Feed the acceptance signal back to the ranker so future
                  // cards bias toward whichever lane (fof / category /
                  // popular / league) this user keeps engaging with. Fire-
                  // and-forget — UI state already reflects the follow.
                  if (user.reason.isNotEmpty) {
                    ApiService.recordSuggestionAccepted(
                      userId: dp.user?.id ?? '',
                      lane: user.reason,
                      targetUserId: user.userId,
                      cardId: cardId,
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  String _compactInt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _FollowButton extends StatelessWidget {
  final bool isFollowing;
  final VoidCallback onTap;
  const _FollowButton({required this.isFollowing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (isFollowing) {
      return OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white38),
          minimumSize: const Size(96, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: const Text(
          'Following',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      );
    }
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        minimumSize: const Size(96, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      child: const Text(
        'Follow',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final _ReelItem item;
  const _Placeholder({required this.item});
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: item.thumbnailUrl.isNotEmpty
          ? Image.network(
              item.thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fallbackIcon(),
            )
          : _fallbackIcon(),
    );
  }

  Widget _fallbackIcon() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.videocam_off, color: Colors.white38, size: 48),
        SizedBox(height: 6),
        Text(
          'No video available',
          style: TextStyle(color: Colors.white54),
        ),
      ],
    );
  }
}
