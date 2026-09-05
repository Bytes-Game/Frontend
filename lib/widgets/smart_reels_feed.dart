import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:video_player/video_player.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/connection_prewarm_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/feed_paging.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/playback_reporter.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
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
/// Which feed this widget is showing.
///
/// The first three pick a RANKING — a different algorithm decides what you
/// see. The last two pick a KIND: the same For You ranking with one sort of
/// video left out. [shorts] shows only challenges nobody has answered yet;
/// [battles] shows only the head-to-head ones.
///
/// The SERVER does the leaving out, not this widget. That is not an
/// efficiency choice — the backend writes down what it served the moment it
/// builds a page, so anything hidden here would still be recorded as watched
/// and would quietly corrupt what the feed learns about this person.
enum FeedKind { forYou, following, explore, shorts, battles }

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

/// Re-aim the warm window anyway once it has been pointed at the same
/// place for this long. A sustained fling would otherwise defer it for as
/// long as the fling lasted, and warming that never re-aims is warming
/// that has stopped.
const Duration prefetchMaxStale = Duration(milliseconds: 1200);

/// Whether a page change should re-aim the warm window immediately, or
/// wait for the scrolling to settle.
///
/// Pure, and lifted out of the widget because it is the whole of the
/// decision — everything around it is a [Timer] and a mounted check. The
/// two answers it has to get right pull in opposite directions:
///
///   * Re-aiming on every page of a fling is what made warming churn.
///     `VideoCacheService.warm` cancels downloads for URLs that have left
///     the window, so eight re-aims in four seconds spend the download
///     slots killing each other's work — a device profile saw 18 of 22
///     downloads cancelled while the reels the user landed on opened cold.
///
///   * Never re-aiming is worse. A fling that lasts is a window that has
///     stopped following the user, so warming quietly stops being about
///     anything. [maxStale] is the backstop: however fast the scrolling,
///     the window is re-pointed at least this often.
///
/// [lastPrefetchAt] is null before the first re-aim of a feed, which is
/// always immediate — there is nothing warm yet to protect.
bool shouldReaimPrefetchNow({
  required bool bursting,
  required DateTime? lastPrefetchAt,
  required DateTime now,
  Duration maxStale = prefetchMaxStale,
}) {
  if (!bursting) return true;
  if (lastPrefetchAt == null) return true;
  return now.difference(lastPrefetchAt) >= maxStale;
}

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

  // Automatic recovery from a failed FIRST page. The dominant cause is
  // Render's free-tier cold start: the instance sleeps after ~15min idle
  // and takes 30-60s to wake, so the opening fetch times out exactly when
  // the user launches the app after a break. Three spaced retries ride
  // out the wake window without the user ever tapping Retry.
  int _autoRetries = 0;
  static const _maxAutoRetries = 3;

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

  // Items requested per page. Passed explicitly rather than left to the
  // endpoint defaults, because [_loadNextPage] infers end-of-feed from a
  // short page and that inference is wrong the moment the two disagree.
  static const int _pageLimit = 20;

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

  // ─── Re-aiming the warm window ───────────────────────────────────────
  // Warming is aimed at where the user is standing, so in principle every
  // page change should re-aim it. In a fling that is the wrong trade.
  //
  // VideoCacheService.warm() cancels the download of any URL that has
  // dropped out of the window, which is right when the window moves once
  // and self-defeating when it moves eight times in four seconds: each
  // re-aim kills fetches the previous one started, so the slots churn and
  // little is ever warmed. A device profile caught it exactly — 22 URLs
  // seen, 18 downloads cancelled — while the reels the user actually
  // landed on opened cold.
  //
  // So during a burst the re-aim is deferred until the scrolling settles,
  // which is the moment the window is worth pointing anywhere. Downloads
  // already in flight are left alone to finish, for the same reason
  // [VideoCacheService.cancelGraceBytes] exists: past a certain point,
  // abandoning work costs more than completing it.
  Timer? _prefetchDebounce;
  DateTime? _lastPrefetchAt;

  /// How long after the last page change a burst is considered settled.
  /// Comfortably shorter than the time a user spends on a reel they have
  /// chosen to watch, so a deliberate swipe never waits on it.
  static const Duration _prefetchSettleDelay = Duration(milliseconds: 300);

  // ─── Rich playback signals (complete / loop / rewatch / impression) ──
  // The backend has dedicated ranking pipelines for these events
  // (completion & loop caches, impression bounce-classification,
  // scroll-back boosts) that previously only received data from the
  // retired HomeFeedPage — the live feed emitted view/skip only. The
  // listener below watches the ACTIVE reel's controller and derives:
  //   * complete — playhead crossed 95% of duration (once per reel-view)
  //   * loop     — position wrapped back to the start after looping
  // Impressions (with true dwell) and scroll-backs are emitted from the
  // page-transition path since they're about navigation, not playback.
  VideoPlayerController? _listenedController;
  VoidCallback? _playbackListener;
  bool _completeTracked = false;
  int _loopCount = 0;
  Duration _lastPlaybackPos = Duration.zero;
  // Did somebody drag this reel to a different spot while it was on screen?
  //
  // Both signals below are worked out by watching where the playhead is, and
  // dragging the bar breaks both readings. Drag near the end and the app
  // would report "watched the whole thing". Drag backwards and it would
  // report "watched it twice". Neither happened, and both are strong
  // positives the ranker acts on, so a reel-view that was dragged stops
  // reporting them. See _attachPlaybackListener.
  bool _scrubbedThisView = false;
  // What the app-wide drag counter read when this reel came on screen.
  // Any change to it means a finger moved a video.
  int _seekCountAtAttach = 0;
  // Cap loop events per reel-view so a video left running in a pocket
  // doesn't flood the queue — the ranker's loop cache counts rows, and
  // 3 loops already saturates the "they love it" signal.
  static const int _maxLoopEvents = 3;
  // Content IDs that already emitted a `view` this widget lifetime —
  // a second qualifying watch of the same reel emits `rewatch` instead
  // (stronger positive for the LTR/embedding label mapping).
  final Set<String> _viewTracked = <String>{};

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
    _prefetchDebounce?.cancel();
    _detachPlaybackListener();
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
      // Paused controllers stop emitting position ticks, but detach
      // anyway so a resume-into-a-different-reel can't double-listen.
      _detachPlaybackListener();
      _flushCurrentItemEvent(isSkip: false);
    } else if (state == AppLifecycleState.resumed) {
      _currentItemStart = DateTime.now();
      _playCurrent(); // re-attaches the playback listener
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
      // new (cold) one. The deferred re-aim goes with it: it was
      // pointed at indices in a list that no longer exists.
      _recentSwipes.clear();
      _prefetchDebounce?.cancel();
      _lastPrefetchAt = null;
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
    // Kick off autoplay on the first real item — and warm the prefetch
    // window immediately. Prefetch previously only ran on page CHANGES,
    // so the very first swipe of every session always landed on a cold
    // controller (fresh socket + init + decoder warm-up) no matter how
    // long the user watched reel 0.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _playCurrent();
      _prefetchUpcomingVideos();
    });
    // Cut the cold-connection tax for the media origin: the app can't
    // know the R2/CDN hostname until real video URLs arrive, so the
    // boot-time prewarm only covers the API host. Warm the video
    // origin(s) as soon as a page lands — for page 1 this overlaps the
    // first controller's own handshake, but every later-session origin
    // (CDN switch, custom domain) gets covered for free.
    for (final entry in _items.take(4)) {
      if (entry is _ReelItem && entry.videoUrl.isNotEmpty) {
        ConnectionPrewarmService.instance.prewarmUrlOrigin(entry.videoUrl);
      }
    }
  }

  Future<void> _loadNextPage({bool refresh = false}) async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    final nextPage = _page + 1;
    final sessionId = _sessionId();
    final data = await _fetchPage(
      nextPage,
      sessionId,
      refresh: refresh && nextPage == 1,
    );
    if (!mounted) {
      _loadingMore = false;
      return;
    }
    final raw = (data['items'] as List?) ?? const [];
    final parsed = <_FeedEntry>[];
    // We render what the server sent us.
    //
    // This used to throw away anything already on screen, which sounds
    // obviously right and was the cause of the worst thing in the feed. The
    // server does not hide videos you have seen — it ranks them down and
    // serves them once nothing fresher is left, deliberately, because a hard
    // filter used to make the feed announce it had ended when it had not. So
    // the server was sending repeats on purpose and the app was deleting them
    // on purpose, and between the two of them a device run got pages of 7, 16
    // and finally 0 items out of 21 sent — a whole round trip for nothing, and
    // no fresh video ready by the time the user arrived.
    //
    // Two systems answering "has this person seen this?" and disagreeing. Only
    // one of them can see the whole picture, and it is not this one: the app's
    // memory is whatever is in this scroll list right now and dies when the
    // screen does, while the server's is attached to the account and follows
    // you to a new phone. So the server decides, and a repeat now arrives
    // labelled (see [_ReelItem.isRepeat]) rather than inferred.
    //
    // The one thing still dropped is a duplicate WITHIN a single response.
    // That is not a repeat, it is the same row sent twice in one page, which
    // is a bug rather than a decision — and it would put two tiles on screen
    // that fight over one video's playback state.
    final seenInThisPage = <String>{};
    for (final x in raw) {
      final item = _FeedEntry.fromJson(x as Map<String, dynamic>);
      if (item == null) continue;
      if (!seenInThisPage.add('${item.type}:${item.id}')) continue;
      parsed.add(item);
    }
    final more = FeedPaging.hasMoreAfter(
      declared: data['hasMore'],
      rawCount: raw.length,
      newItems: parsed.length,
      limit: _pageLimit,
    );
    _logPageComposition(nextPage, parsed, raw.length, data['hasMore'], more);
    final errorMsg = (data['_ok'] == false) ? data['_error'] as String? : null;
    setState(() {
      _items.addAll(parsed);
      _page = nextPage;
      _hasMore = more;
      _loadingMore = false;
      // Only set error if this is the first page AND we got nothing.
      // Subsequent page errors don't blank the existing feed.
      if (errorMsg != null && _items.isEmpty) {
        _lastError = errorMsg;
      } else {
        _lastError = null;
        if (parsed.isNotEmpty) _autoRetries = 0;
      }
    });
    _trimMemoryIfNeeded();
    // Self-heal a failed first load: back off 4s/8s/16s and re-pull.
    // Combined with the 30s request timeout this spans the full cold-
    // start wake, so the feed appears on its own once the server is up.
    if (_lastError != null &&
        _items.isEmpty &&
        _autoRetries < _maxAutoRetries) {
      _autoRetries++;
      final delay = Duration(seconds: 4 * (1 << (_autoRetries - 1)));
      Future.delayed(delay, () {
        if (mounted && _items.isEmpty && !_loadingMore) {
          _loadInitialPage();
        }
      });
    }
  }

  /// Print what a freshly-parsed page actually contained.
  ///
  /// This widget applies no filtering of its own — every item the backend
  /// returns is rendered — so when the feed "looks wrong" there is no way
  /// to tell from the client logs whether the server sent the wrong set or
  /// the client dropped something. These four counters settle it:
  ///
  ///   * `mine`   — challenges whose creator is the signed-in user. Own
  ///     content is supposed to be excluded server-side, so anything above
  ///     0 is a backend filter miss, not a rendering bug. Note this counts
  ///     only the CREATOR side: your video also appears as the opponent
  ///     leg of a battle you responded to, and that item legitimately
  ///     belongs to whoever created the challenge, so it is not counted.
  ///   * `shorts` — challenges with no top response, i.e. the plain-short
  ///     case. Near-zero means the ranker is returning battles almost
  ///     exclusively; nothing was filtered out on the way in.
  ///   * `battles` — the complement, for the ratio.
  ///   * `noCreatorId` — payloads that omitted `creatorId`. Those make
  ///     `mine` undercount (and silently disable the owner-only delete
  ///     affordance), so a non-zero value invalidates the `mine` reading
  ///     rather than confirming it.
  ///
  /// Plus the paging trio, which says whether a feed that stopped growing
  /// was out of content or gave up early: `raw` is what arrived before
  /// dedup, `said` is the server's own `hasMore` (`null` when it sent
  /// none), and `more` is what this widget concluded — see
  /// [_decideHasMore].
  void _logPageComposition(
    int page,
    List<_FeedEntry> parsed,
    int rawCount,
    Object? declaredHasMore,
    bool hasMore,
  ) {
    var battles = 0;
    var shorts = 0;
    var mine = 0;
    var noCreatorId = 0;
    var repeats = 0;
    var newHere = 0;
    for (final e in parsed) {
      if (e is! _ReelItem || e.type != 'challenge') continue;
      if (e.isBattle) {
        battles++;
      } else {
        shorts++;
      }
      if (e.creatorId.isEmpty) {
        noCreatorId++;
      } else if (e.creatorId == widget.userId) {
        mine++;
      }
      // Whether THIS page is new content or the same videos coming round
      // again. The server has always said so per item; nothing read it.
      if (e.isRepeat) {
        repeats++;
      } else {
        newHere++;
      }
      // Second opinion, from this session alone. See below.
      if (!_shownThisSession.add('${e.type}:${e.id}')) {
        _seenAgainThisSession++;
      }
    }
    ReelDiagnostics.instance.log(
      'feed ${widget.kind.name} page $page: ${parsed.length} items  '
      'battles=$battles shorts=$shorts  mine=$mine noCreatorId=$noCreatorId  '
      'new=$newHere repeat=$repeats againThisRun=$_seenAgainThisSession  '
      'raw=$rawCount/$_pageLimit said=$declaredHasMore more=$hasMore  '
      // Which quality is actually being served. "The video looks soft" and
      // "the video keeps stopping" arrive as the same complaint, and without
      // this there is no way to tell being handed 480p from being handed
      // 720p and stalling through it.
      'quality{${NetworkQualityService.variantPicksSummary()}}',
    );
  }

  /// Every video id this tab has been sent since the app started, and how many
  /// arrived more than once.
  ///
  /// ## Why two counters that look like the same thing
  ///
  /// `repeat` is the SERVER's answer: it marks an item when its own record
  /// says this account has already been shown it. `againThisRun` is what this
  /// screen watched happen with its own eyes.
  ///
  /// Apart, neither settles anything. Together they name the problem:
  ///
  ///   repeat high, againThisRun high  the catalogue ran out. The server knows
  ///                                   you have seen these and is serving them
  ///                                   anyway, on purpose, because an empty
  ///                                   feed is worse than a repeat.
  ///   repeat ZERO, againThisRun high  the server does not know. Its memory of
  ///                                   what you have watched is not being
  ///                                   written, so the same top-ranked videos
  ///                                   win every page forever.
  ///
  /// Those two need completely different fixes, and a page count alone cannot
  /// tell them apart — which is exactly where a real investigation stalled.
  ///
  /// Per SCREEN, not per app: each tab has its own, and they reset when the
  /// tab is rebuilt. That is the right scope, because the question being
  /// answered is "did THIS list repeat itself".
  final Set<String> _shownThisSession = <String>{};
  int _seenAgainThisSession = 0;

  /// Dispatches to the right backend endpoint based on widget.kind. Each
  /// endpoint runs a different ranking algorithm — see FeedKind doc.
  Future<Map<String, dynamic>> _fetchPage(
    int page,
    String sessionId, {
    bool refresh = false,
  }) {
    switch (widget.kind) {
      case FeedKind.forYou:
        return ApiService.getSmartFeed(
          widget.userId,
          page: page,
          limit: _pageLimit,
          sessionId: sessionId,
          refresh: refresh,
        );
      case FeedKind.following:
        return ApiService.getFollowingFeedV2(
          widget.userId,
          page: page,
          limit: _pageLimit,
        );
      case FeedKind.explore:
        return ApiService.getExploreFeed(
          widget.userId,
          page: page,
          limit: _pageLimit,
        );
      case FeedKind.shorts:
      case FeedKind.battles:
        // Same ranking as For You; the backend leaves out the other kind.
        // Asking the smart feed with a filter rather than adding another
        // algorithm means these tabs keep improving as For You does.
        return ApiService.getSmartFeed(
          widget.userId,
          page: page,
          limit: _pageLimit,
          sessionId: sessionId,
          refresh: refresh,
          kind: widget.kind == FeedKind.shorts ? 'shorts' : 'battles',
        );
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

    // Stop watching the outgoing reel's playback before its exit event
    // fires — otherwise its controller can emit one more position tick
    // and log a loop/complete attributed to a reel we already left.
    _detachPlaybackListener();

    // Record the exit of the *previous* item.
    _flushCurrentItemEvent(isSkip: _wasQuickSkip());

    // Back-swipe = the user actively sought out earlier content. One of
    // the strongest positive signals the ranker consumes (scroll-back
    // cache feeds a dedicated score bonus).
    if (index < prevIndex && index < _items.length) {
      final target = _items[index];
      if (target is _ReelItem) {
        EventTracker.instance.trackScrollBack(
          contentId: target.id,
          contentType: target.type,
        );
      }
    }

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
    _schedulePrefetch();
    _maybePrefetchNextPage();
  }

  /// Re-aim the warm window, now or once the scrolling settles.
  ///
  /// See the note on [_prefetchDebounce] for why a fling defers instead of
  /// re-aiming per page.
  void _schedulePrefetch() {
    _prefetchDebounce?.cancel();
    if (shouldReaimPrefetchNow(
      bursting: _isBurstScrolling(),
      lastPrefetchAt: _lastPrefetchAt,
      now: DateTime.now(),
    )) {
      _prefetchUpcomingVideos();
      return;
    }
    _prefetchDebounce = Timer(_prefetchSettleDelay, () {
      if (mounted) _prefetchUpcomingVideos();
    });
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
    final watched = DateTime.now()
        .difference(_currentItemStart!)
        .inMilliseconds;
    final totalMs = state?.controller.value.duration.inMilliseconds ?? 0;

    // Impression with true dwell — one per reel exit, INCLUDING quick
    // skips. The backend diverts these into its Redis impression
    // aggregator, which classifies dwell (<500ms bounce / 500-1500
    // curiosity / >3000 interest) and nudges CategoryAffinity + bounce
    // penalties. It deliberately doesn't hit Postgres, so volume is fine.
    if (item is _ReelItem && item.id.isNotEmpty) {
      EventTracker.instance.trackImpression(
        contentId: item.id,
        contentType: item.type,
        dwellMs: watched,
      );
    }

    if (isSkip) {
      EventTracker.instance.trackSkip(
        contentId: item.id,
        contentType: item.type,
        watchDurationMs: watched,
        totalDurationMs: totalMs,
      );
    } else if (watched >= 300) {
      // Second+ qualifying watch of the same reel this session is a
      // rewatch — a stronger positive label for the LTR/embedding
      // pipelines than a plain view.
      if (!_viewTracked.add(item.id)) {
        EventTracker.instance.trackRewatch(
          contentId: item.id,
          contentType: item.type,
          watchDurationMs: watched,
          totalDurationMs: totalMs,
        );
      } else {
        EventTracker.instance.trackView(
          contentId: item.id,
          contentType: item.type,
          watchDurationMs: watched,
          totalDurationMs: totalMs,
        );
      }
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
        if (userId.isNotEmpty && _watchEventRecorded.add(item.id)) {
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

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _items.length) return;
    final index = _currentIndex;
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
    // The one place a player is opened. Everything else — every tile the
    // pager builds on the way past — takes one that already exists or
    // renders its poster, which is what stops a fling costing a decoder
    // per reel. See "who may open a player" on [_getPlayerState].
    final had = _playerStates[index];
    final state = _getPlayerState(index, create: true);
    if (state == null) return;
    // A reel that had no player until a moment ago is currently painting
    // its poster with nothing bound to a controller, so nothing would
    // repaint it when the first frame lands. Ask for the rebuild that
    // hands the tile its new controller.
    if (!identical(had, state)) {
      // ignore: no-empty-block
      setState(() {});
    }
    // One call, because declaring which reel is on screen and starting it are
    // the same act — see [VideoPlayerService.showAndPlay]. It stops the
    // outgoing players before starting this one (play() is what requests
    // AudioFocus, and taking focus while the old player is still decoding is
    // the audible chop on every swipe) and it declines to start anything if
    // the user swiped on during that handover.
    await VideoPlayerService.instance.showAndPlay(url);
    // The service guards its own half of that race; this guards ours, so a
    // watch event is not recorded against a reel that is no longer on screen.
    if (!mounted || _currentIndex != index) return;

    // Watch this reel's playback for complete/loop signals.
    _attachPlaybackListener(item, state.controller);

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
  /// the entry at `index` is a non-video tile (e.g. an accounts card), and
  /// when the reel at `index` is not on screen and has no player already —
  /// the caller renders its poster instead. See "who may open a player".
  ///
  /// WHO MAY OPEN A PLAYER
  /// ---------------------
  /// Only the reel on screen. Everything else takes a player that already
  /// exists or does without one.
  ///
  /// This method is reached from `itemBuilder`, so it runs for every tile
  /// the PageView materialises — which during a fling is every reel the
  /// user passes. It used to call [VideoPlayerService.getController] for
  /// all of them, and that method creates on miss, so a fast scroll opened
  /// an ExoPlayer and a hardware decoder per reel flown past and evicted it
  /// again a moment later.
  ///
  /// The read-ahead path was already careful about this — a cold spare
  /// waits out [VideoPlayerService.spareWarmGrace] and is dropped if the
  /// user moves on, so a fling opens no spares — and the comment in
  /// [_prefetchUpcomingVideos] says as much. It was true and it did not
  /// matter: the build path went straight around it. A device profile
  /// showed the result plainly, 40 opens and 36 retirements for 21 distinct
  /// reels, decoder ids climbing to 81 in ninety seconds, `MediaCodec::
  /// reclaim` three times, and ~800ms to first frame on every swipe.
  ///
  /// So the rule is now the same on both paths, and the tile is the one
  /// that enforces it. A neighbour still shows live video the moment the
  /// spare exists — that is the common case for an ordinary swipe, because
  /// read-ahead opened it while the user was watching — and shows its
  /// poster when it does not, which is exactly the reel nobody is going to
  /// look at for more than a few frames anyway.
  ///

  /// IMPORTANT: validates the cached entry against the pool before
  /// returning it. The pool LRU-evicts (and disposes) controllers when
  /// it's full and a new URL is requested, but `_playerStates` lives as
  /// long as the widget — so a cached entry can outlive its underlying
  /// controller. Returning a stale entry leads to "A
  /// VideoPlayerController was used after being disposed" the next time
  /// the tile builds. We re-fetch from the pool in that case (pool
  /// returns a fresh controller; getController is idempotent on URL).
  /// [create] opens a player when the pool does not already have one, and
  /// is the caller asserting it is NOT inside a build.
  ///
  /// [VideoPlayerService.getController] promotes on a hit, and promotion
  /// calls `setVolume`, and that notifies the controller's listeners
  /// synchronously — every [ValueListenableBuilder] bound to it, which
  /// then calls setState. From inside `itemBuilder` that is the
  /// `setState() or markNeedsBuild() called during build` crash already
  /// documented on [_ReelTileState._ensureOpponentState], reached by a
  /// different road. So the build path never creates: `itemBuilder` takes
  /// the default and gets a player only if one already exists, and
  /// [_playCurrent] — which runs from a page change or a post-frame
  /// callback, both outside build — is the one caller that passes true.
  _ReelPlayerState? _getPlayerState(int index, {bool create = false}) {
    if (index < 0 || index >= _items.length) return null;
    final item = _items[index];
    if (item is! _ReelItem) return null;
    final url = item.videoUrl;
    if (url.isEmpty) return null;

    final cached = _playerStates[index];
    // Identity, not URL. Checking by URL leaves a hole: the pool can
    // evict this state's controller and then create a NEW controller for
    // the same URL, and the URL check reports "alive" while `cached`
    // still points at the disposed one.
    if (cached != null &&
        cached.url == url &&
        VideoPlayerService.instance.isLive(cached.controller)) {
      return cached;
    }

    // Either no cache, the cached URL is stale (item at this index
    // changed — e.g. after _trimMemoryIfNeeded re-keyed), or the
    // pool has evicted the controller. Build a fresh state.
    //
    // `peek` unless the caller is opening this reel deliberately: it
    // adopts a player read-ahead has already built and returns null
    // rather than building one itself. Null is not a failure here — the
    // tile renders its poster and picks the video up on the rebuild
    // [_playCurrent] schedules once this reel becomes current, which is
    // the moment it is allowed to cost a decoder. See "who may open a
    // player" above.
    final controller = create
        ? VideoPlayerService.instance.getController(url)
        : VideoPlayerService.instance.peekController(url);
    if (controller == null) {
      // Drop any state we were holding for this index so the next build
      // re-asks rather than handing back a controller the pool has since
      // disposed.
      _playerStates.remove(index);
      return null;
    }
    // ignore: discarded_futures
    controller.setLooping(true);
    final s = _ReelPlayerState(controller: controller, url: url);
    _playerStates[index] = s;
    _armSourceFallback(item, controller);
    return s;
  }

  /// Self-healing for a dead HLS source. If the manifest the backend
  /// advertised can't actually be loaded (storage access revoked,
  /// rendition deleted, malformed transcode), the controller surfaces
  /// hasError — we swap the item to its direct-MP4 fallback and rebuild
  /// the player, instead of leaving the user staring at a black reel.
  /// One-shot per item: after the swap videoUrl == fallbackVideoUrl and
  /// re-arming no-ops, so an MP4 that ALSO fails just lands in the
  /// tile's normal error UI (no retry loop).
  void _armSourceFallback(_ReelItem item, VideoPlayerController controller) {
    if (item.fallbackVideoUrl.isEmpty ||
        item.videoUrl == item.fallbackVideoUrl) {
      // Nothing to fall back TO. If this one fails the user is left looking at
      // a black reel, so it is the more serious of the two failures and the
      // one we most need told about — report it and stop.
      _reportUnrecoverableFailure(item, controller);
      return;
    }
    void swap() {
      if (!mounted || item.videoUrl == item.fallbackVideoUrl) return;
      // Name the actual direction. This used to read "HLS source failed,
      // falling back to MP4", which is backwards for the common case: MP4 is
      // the PRIMARY whenever one exists and HLS is the fallback, so the usual
      // meaning of this line is the opposite of what it claimed. The wrong
      // message cost a real misdiagnosis — a device log was read as proof that
      // MP4-first had missed a path, when it had not. Derive the labels rather
      // than hardcode them so this cannot drift again.
      String kind(String u) => u.contains('.m3u8') ? 'HLS' : 'MP4';
      debugPrint(
        'reel ${item.id}: ${kind(item.videoUrl)} source failed, '
        'falling back to ${kind(item.fallbackVideoUrl)}',
      );
      // Tell Sentry a video would not play. The user is about to stop
      // noticing — the backup copy loads and the feed carries on — which is
      // exactly why this needs recording: without it, a phone that cannot
      // decode what other people upload fails silently and forever. Guarded
      // against flooding; see PlaybackReporter.
      PlaybackReporter.instance.reportPlaybackFailure(
        videoUrl: item.videoUrl,
        error: controller.value.errorDescription,
        recovered: true,
      );
      item.videoUrl = item.fallbackVideoUrl;
      // Drop every player state bound to the dead manifest — indices can
      // shift under trimming, so match by URL rather than position.
      _playerStates.removeWhere((_, st) {
        final stale = st.controller == controller;
        if (stale) st.dispose();
        return stale;
      });
      setState(() {});
      // If the broken reel is the one on screen, restart playback so the
      // fallback controller spins up immediately.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playCurrent();
      });
    }

    // A prefetched controller may have already failed before this reel
    // became current — the listener below would never fire (no value
    // change), so check the current state first.
    if (controller.value.hasError) {
      swap();
      return;
    }
    late final VoidCallback onChange;
    onChange = () {
      if (item.videoUrl == item.fallbackVideoUrl) {
        controller.removeListener(onChange);
        return;
      }
      if (!controller.value.hasError) return;
      controller.removeListener(onChange);
      swap();
    };
    controller.addListener(onChange);
  }

  /// Report a failure the app cannot paper over.
  ///
  /// Separate from the recovered path because the two mean different things: a
  /// swap the user never noticed is a warning, while this one is a reel that
  /// stays black. Both are worth knowing; only this one is worth waking up for.
  void _reportUnrecoverableFailure(
      _ReelItem item, VideoPlayerController controller) {
    void report() {
      PlaybackReporter.instance.reportPlaybackFailure(
        videoUrl: item.videoUrl,
        error: controller.value.errorDescription,
        recovered: false,
      );
    }

    // A player handed over from the warm pool may have failed before this reel
    // ever reached the screen, in which case no further change is coming and
    // a listener would wait forever.
    if (controller.value.hasError) {
      report();
      return;
    }
    late final VoidCallback onChange;
    onChange = () {
      if (!controller.value.hasError) return;
      controller.removeListener(onChange);
      report();
    };
    controller.addListener(onChange);
  }

  // ─── Playback-derived signals ────────────────────────────────────────

  /// Watch the active reel's controller for completion and loops.
  /// Attached in _playCurrent, detached on page change / dispose /
  /// background. Only ever one listener at a time — prefetch-pool
  /// controllers are NOT watched (their positions don't move).
  void _attachPlaybackListener(_ReelItem item, VideoPlayerController c) {
    _detachPlaybackListener();
    _completeTracked = false;
    _loopCount = 0;
    _scrubbedThisView = false;
    _seekCountAtAttach = VideoPlayerService.instance.seekCount;
    _lastPlaybackPos = c.value.position;
    void listener() {
      final v = c.value;
      if (!v.isInitialized) return;
      final dur = v.duration;
      if (dur <= Duration.zero) return;
      final pos = v.position;

      // Once somebody has dragged the bar on this reel, stop reporting how
      // far they got. Both checks below read the playhead, and a finger
      // moves the playhead in ways watching never does: drag to the end and
      // the 95% check fires, drag back to the start and the wrap check fires.
      // The backend treats a completion as a full watch and a loop as
      // "they liked it enough to sit through it twice", so a fake one of
      // either teaches the feed the wrong thing about this person.
      //
      // Going quiet is the cautious choice, and it is deliberate. A person
      // who drags back to a moment and then genuinely watches to the end
      // loses a completion we would have counted. The other way round — one
      // drag manufacturing a full watch — pollutes the ranking, and the
      // drag itself already sends its own signal from the bar.
      if (!_scrubbedThisView &&
          VideoPlayerService.instance.seekCount != _seekCountAtAttach) {
        _scrubbedThisView = true;
      }
      if (_scrubbedThisView) {
        _lastPlaybackPos = pos;
        return;
      }

      // Completion: playhead reached 95%. Fires once per reel-view; a
      // wrap-detected loop below also implies completion, so mark there
      // too in case the position listener never samples the tail.
      if (!_completeTracked &&
          pos.inMilliseconds >= dur.inMilliseconds * 0.95) {
        _completeTracked = true;
        EventTracker.instance.trackComplete(
          contentId: item.id,
          contentType: item.type,
          totalDurationMs: dur.inMilliseconds,
        );
      }

      // Loop: position jumped backwards by more than half the video —
      // setLooping(true) wraps silently, so a big negative delta from
      // the tail is the only observable. Ignore small backward jitter
      // (seek precision) via the half-duration threshold.
      if (_lastPlaybackPos.inMilliseconds - pos.inMilliseconds >
          dur.inMilliseconds ~/ 2) {
        if (!_completeTracked) {
          _completeTracked = true;
          EventTracker.instance.trackComplete(
            contentId: item.id,
            contentType: item.type,
            totalDurationMs: dur.inMilliseconds,
          );
        }
        _loopCount++;
        if (_loopCount <= _maxLoopEvents) {
          EventTracker.instance.trackLoop(
            contentId: item.id,
            contentType: item.type,
            loopNumber: _loopCount,
          );
        }
      }
      _lastPlaybackPos = pos;
    }

    _playbackListener = listener;
    _listenedController = c;
    c.addListener(listener);
  }

  void _detachPlaybackListener() {
    final c = _listenedController;
    final l = _playbackListener;
    if (c != null && l != null) {
      c.removeListener(l);
    }
    _listenedController = null;
    _playbackListener = null;
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
    _lastPrefetchAt = DateTime.now();
    final cfg = VideoPlayerService.instance.config;
    // Pick window width based on swipe velocity. Burst mode widens
    // the upcoming-prefetch reach so a fast scroller doesn't overshoot
    // the warm pool. Back-prefetch doesn't widen — back-swipes are
    // bursty too, but the previous reel they land on is almost
    // always at currentIndex-1, so the depth doesn't help.
    // Forward reach is now set by the CACHE, not the player pool.
    // Warming a reel costs a download, not a decoder, so the window can
    // be far deeper than the pool ever allowed — VideoCacheService picks
    // the depth from the connection (deep on wifi, shallow on cellular
    // where an unwatched warm reel is wasted data). The pool's
    // prefetchAhead now only governs the single live spare that
    // VideoPlayerService.prefetch keeps.
    final cacheDepth = VideoCacheService.instance.prefetchDepth;
    final aheadCount = _isBurstScrolling()
        ? cacheDepth + cfg.prefetchAheadBurst
        : cacheDepth;
    final backCount = cfg.prefetchBack;

    // A battle has TWO videos and the user can flip to the second one at
    // any moment, with no swipe to give us warning, so opponents have to be
    // warmed too. But WHERE they sit in the queue decides how the feed
    // feels, because only maxConcurrentDownloads fetches run at once.
    //
    // Pairing each opponent directly behind its own challenger (the first
    // version of this) halves the forward reach in REELS on a
    // battle-heavy page: the two download slots go to reel+1's challenger
    // and reel+1's opponent, and reel+2 is not touched until one of them
    // finishes. On-device diagnostics after that change showed warming
    // improving per-file but network starts going UP, 65% -> 80%, on a
    // fast-scrolling session — the warmer could no longer stay ahead of
    // the thumb.
    //
    // Swipes massively outnumber flips, so challengers come first, all of
    // them, nearest first. The one exception is the CURRENT reel's
    // opponent, which is genuinely one gesture away right now; it sits at
    // position 2, behind only the next reel (which a forward swipe needs
    // first, and which owns the single live spare controller). Everything
    // else's opponent is warmed after every challenger in the window.
    final challengers = <String>[];
    final opponents = <String>[];
    for (
      int i = _currentIndex + 1;
      i < _items.length && i <= _currentIndex + aheadCount;
      i++
    ) {
      final entry = _items[i];
      if (entry is! _ReelItem) continue; // skip cards
      final u = entry.videoUrl;
      if (u.isNotEmpty) challengers.add(u);
      final opp = entry.opponentVideoUrl;
      if (opp.isNotEmpty) opponents.add(opp);
    }

    final upcoming = <String>[...challengers, ...opponents];
    final current = _currentIndex >= 0 && _currentIndex < _items.length
        ? _items[_currentIndex]
        : null;
    if (current is _ReelItem && current.opponentVideoUrl.isNotEmpty) {
      upcoming.remove(current.opponentVideoUrl);
      upcoming.insert(upcoming.isEmpty ? 0 : 1, current.opponentVideoUrl);
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
    for (
      int i = _currentIndex - 1;
      i >= 0 && i >= _currentIndex - backCount;
      i--
    ) {
      final entry = _items[i];
      if (entry is! _ReelItem) continue;
      final u = entry.videoUrl;
      if (u.isNotEmpty) back.add(u);
    }
    // ONE url gets a live player: the next reel, which a vertical swipe
    // reaches.
    //
    // ════════════════════════════════════════════════════════════════════
    // WHY THE OPPONENT IS NOT IN THIS LIST ANY MORE
    // ════════════════════════════════════════════════════════════════════
    //
    // It used to be, on the argument that a flip is one gesture away just
    // like a swipe is. The argument is sound and the cost turned out to be
    // wrong, because what runs out is not the pool — it is the phone's
    // decoders, and the platform takes them back without asking:
    //
    //     D/MediaCodec: MediaCodec::reclaim(0x...) c2.mtk.avc.decoder
    //     E/MediaCodec: Released by resource manager
    //
    // Four of those in one session on a device holding its full working
    // set of four. Whichever reel lost its decoder froze until a new one
    // was built. The set is already the minimum the screen can run on —
    // the reel being watched, one up, one down, and the opponent during a
    // turn — so the only way down is to stop asking for the fourth before
    // the gesture that needs it.
    //
    // The flip does not pay for this. The opponent's BYTES are still
    // warmed, at position 2 in the window above, so the decoder that
    // _ensureOpponentState opens on the first dragged frame opens against
    // a file already on disk. The turn animation covers building it, and
    // the opponent's poster holds the face until its first frame lands.
    // What is given up is a decoder standing ready for a gesture most
    // battles never receive; what is bought is one fewer live decoder on
    // every battle on screen.
    //
    // Nothing here fires for a reel being scrolled past. prefetch holds a
    // cold spare until its opening bytes land, and by then a fast scroller
    // has moved on and the url is no longer claimed — so the battles in a
    // fling open no players at all.
    final live = <(SpareLane, String)>[
      if (challengers.isNotEmpty) (SpareLane.nextReel, challengers.first),
    ];
    VideoPlayerService.instance.prefetch([...upcoming, ...back], live: live);
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
    EventTracker.instance.trackLike(contentId: item.id, contentType: item.type);
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
    EventTracker.instance.trackSave(contentId: item.id, contentType: item.type);
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
      target: item.type == 'challenge'
          ? 'home_open_challenge'
          : 'home_open_post',
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
    final damped = dy <= _refreshTriggerPx
        ? dy
        : _refreshTriggerPx + (dy - _refreshTriggerPx) * 0.4;
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
                // A reel with no video at all is not a tile — there is
                // nothing to play and no controls worth showing.
                if (reel.videoUrl.isEmpty) {
                  return _Placeholder(item: reel);
                }
                // Null here means "no player yet", not "no video": this
                // reel is off screen and read-ahead has not opened it.
                // _ReelTile renders its poster and the rest of the reel
                // furniture, and picks up the video on the rebuild that
                // follows this reel becoming current. See the note on
                // _getPlayerState.
                final state = _getPlayerState(index);
                final currentUserId =
                    context.read<DataProvider>().user?.id ?? '';
                final isOwner =
                    reel.type == 'challenge' &&
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
  /// Playback URL. Mutable on purpose: starts as the HLS manifest when
  /// the transcode worker has produced one, and _armSourceFallback
  /// rewrites it to [fallbackVideoUrl] if that manifest fails to load
  /// (expired storage access, deleted rendition, bad transcode). Every
  /// consumer — player, prefetch, prewarm — reads this field, so one
  /// swap heals them all.
  String videoUrl;

  /// The non-HLS (direct MP4) URL to retry with when [videoUrl] is an
  /// HLS manifest that fails to load. Empty when videoUrl is already
  /// the MP4 (no second fallback — the tile's error UI takes over).
  final String fallbackVideoUrl;
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

  /// True when the server says it has shown this to us before.
  ///
  /// The feed does not hide what you have already seen — it ranks it down and
  /// serves it once there is nothing fresher. This flag is how the server says
  /// which is which, and it exists because the app used to decide for itself by
  /// deleting every duplicate. That disagreed with the ranking decision made on
  /// the server: it would send twenty-one videos and the app would keep none,
  /// costing a round trip and leaving the page empty.
  ///
  /// Read-only as far as the feed is concerned. It may be used to LABEL a reel
  /// or to space repeats out. It must never be used to drop one — what the
  /// viewer sees is the server's decision alone.
  final bool isRepeat;

  /// True iff this item is a battle — i.e. there's an opponent video to
  /// swipe to. Plain shorts and image posts return false.
  bool get isBattle => opponentVideoUrl.isNotEmpty;

  _ReelItem({
    required this.id,
    required this.type,
    required this.videoUrl,
    this.fallbackVideoUrl = '',
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
    this.isRepeat = false,
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
      final title = '${c['prefix'] ?? ''} ${c['subject'] ?? ''}'.trim();
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
      final variantPick = NetworkQualityService.instance.pickVariantUrl(
        _coerceVariantsMap(c['videoVariants']),
      );
      final mp4Url = variantPick?.isNotEmpty == true
          ? variantPick!
          : fallbackUrl;
      // MP4 first, HLS only as a fallback — the reverse of what this
      // used to do.
      //
      // HLS earns its keep on long video, where it can drop quality
      // mid-playback instead of stalling. On a sub-90s reel there is no
      // time for that to matter, and it costs the thing that does: HLS
      // needs THREE sequential round-trips before a frame appears
      // (master playlist → variant playlist → first segment) where an
      // MP4 needs one — and a cache-warmed MP4 needs none. It also can't
      // be pre-downloaded as a single file, which is what
      // VideoCacheService relies on.
      //
      // The HLS pipeline is not retired: the manifest is still produced
      // and is still the right source for the detail page and anything
      // longer, and it remains the fallback here for legacy challenges
      // that predate multi-bitrate MP4s.
      final chosenVideoUrl = mp4Url.isNotEmpty ? mp4Url : hlsUrl;
      // Same logic for the opponent video — HLS manifest first (the
      // worker transcodes battle responses too), then the network-
      // appropriate MP4 variant, then the canonical URL. Keeps a battle
      // left-swipe from stuttering on cellular even though the
      // challenger played fine.
      final opponentHls = (c['topResponseHlsManifestUrl'] as String?) ?? '';
      final opponentFallback = (c['topResponseVideoUrl'] as String?) ?? '';
      final opponentVariantPick = NetworkQualityService.instance.pickVariantUrl(
        _coerceVariantsMap(c['topResponseVideoVariants']),
      );
      return _ReelItem(
        id: c['id']?.toString() ?? '',
        type: 'challenge',
        videoUrl: chosenVideoUrl,
        // Only meaningful when we chose HLS — if the manifest turns out
        // to be unreachable the player retries with the direct MP4.
        // Primary is MP4 now, so the manifest becomes the retry.
        fallbackVideoUrl: mp4Url.isNotEmpty ? hlsUrl : '',
        thumbnailUrl: (c['thumbnailUrl'] as String?) ?? '',
        caption: title,
        creatorId: (c['creatorId'] as String?) ?? '',
        creatorUsername: (c['creatorUsername'] as String?) ?? '',
        creatorLeague: (c['creatorLeague'] as String?) ?? '',
        opponentResponseId: (c['topResponseId'] as String?) ?? '',
        // Same MP4-first ordering as the challenger side, so a battle
        // side-switch is cache-warmable too.
        opponentVideoUrl: opponentVariantPick?.isNotEmpty == true
            ? opponentVariantPick!
            : (opponentFallback.isNotEmpty ? opponentFallback : opponentHls),
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
        // The server says whether it has shown us this one before. Absent
        // means fresh, which is the usual case.
        isRepeat: c['repeat'] as bool? ?? false,
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
    final variantPick = NetworkQualityService.instance.pickVariantUrl(
      c.videoVariants,
    );
    final opponentVariantPick = NetworkQualityService.instance.pickVariantUrl(
      c.topResponseVideoVariants,
    );
    final mp4Url = variantPick?.isNotEmpty == true ? variantPick! : c.videoUrl;
    final chosenVideoUrl = mp4Url.isNotEmpty ? mp4Url : c.hlsManifestUrl;
    return _ReelItem(
      id: c.id,
      type: 'challenge',
      videoUrl: chosenVideoUrl,
      fallbackVideoUrl: mp4Url.isNotEmpty ? c.hlsManifestUrl : '',
      thumbnailUrl: c.thumbnailUrl ?? '',
      caption: c.title,
      creatorId: c.creatorId,
      creatorUsername: c.creatorUsername,
      creatorLeague: c.creatorLeague,
      opponentResponseId: c.topResponseId,
      opponentVideoUrl: opponentVariantPick?.isNotEmpty == true
          ? opponentVariantPick!
          : (c.topResponseHlsManifestUrl.isNotEmpty
                ? c.topResponseHlsManifestUrl
                : c.topResponseVideoUrl),
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

  _ReelPlayerState({required this.controller, required this.url});

  void dispose() {
    // We don't own the controller — VideoPlayerService does. release()
    // pauses it and leaves it warm in the pool for back-swipe.
    VideoPlayerService.instance.release(url);
  }
}

// ─── Single reel tile ────────────────────────────────────────────────

class _ReelTile extends StatefulWidget {
  final _ReelItem item;

  /// The reel's player, or null while it has none.
  ///
  /// Null is the ordinary state for an off-screen neighbour: only the reel
  /// on screen may open a player, so a tile the pager built on the way
  /// past has one only if read-ahead happened to get there first. The
  /// poster carries the tile until then — see [_videoFace], which already
  /// paints the video over the poster only once a controller has a frame,
  /// so "no controller" and "controller with no frame yet" look the same
  /// to the user.
  final _ReelPlayerState? state;
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

class _ReelTileState extends State<_ReelTile> with TickerProviderStateMixin {
  bool _showHeart = false;
  bool _isPaused = false;
  late final AnimationController _heartCtl;
  late final Animation<double> _heartAnim;

  // Battle swipe state. _showingOpponent flips on horizontal swipe-left for
  // challenges that carry an opponent video.
  //
  // _opponentState is built ON THE GESTURE — the first horizontal drag, or
  // a programmatic flip — and never before. A battle is two videos, and a
  // second live player is a second video decoder plus, on content with an
  // audio track, a second audio decoder whose output is discarded unheard
  // because the opponent is muted until it is the visible side. Opening
  // that ahead of time spends both on every battle that scrolls past,
  // which on a battle-heavy feed is most of them, to save a fraction of a
  // second for the few flips that actually happen.
  //
  // So the opponent starts when the user goes to it, the same way a reel
  // starts when the user scrolls to it. Its bytes are already on the
  // device — _prefetchUpcomingVideos puts the active reel's opponent near
  // the front of the warm window — so opening is a local file read, not a
  // network round trip.
  bool _showingOpponent = false;
  _ReelPlayerState? _opponentState;

  // 3D cube turn between the challenger and opponent videos — the
  // Instagram-stories cube, around the vertical axis. _cubeCtl.value is
  // the continuous cube position: 0.0 = challenger face front, 1.0 =
  // opponent face front, anything between = mid-turn. While the finger
  // is down the value tracks the drag 1:1 in screen-widths (the cube
  // follows the finger, forward or backward, and freezes if the finger
  // stops); on release it settles to whichever side won — by fling
  // velocity if the user flicked, else by whichever face is more than
  // half turned — exactly the IG-highlights feel.
  late final AnimationController _cubeCtl;
  bool _cubeDragging = false;
  static const double _cubePerspective = 0.0012;
  // Fling faster than this (px/s) settles in the fling direction even
  // if the cube is less than half-turned.
  static const double _cubeFlingVelocity = 300;

  // ── Dragging the video to a different spot ─────────────────────────────
  // True while a finger is on the bar at the bottom of the reel. While it
  // is true the bar paints _scrubTarget instead of where the video actually
  // is, so the line follows the finger exactly even though the picture
  // catches up a moment later.
  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;
  // Where the video was when the finger went down, and whether it was
  // playing. The first is half of the "they moved it from here to there"
  // signal; the second decides whether letting go starts it again — a reel
  // the user had already paused stays paused.
  Duration _scrubStartedAt = Duration.zero;
  bool _resumeAfterScrub = false;
  DateTime _lastScrubSeekAt = DateTime.fromMillisecondsSinceEpoch(0);
  // How often the video is actually moved while the finger slides.
  //
  // The bar follows the finger every frame, but the VIDEO does not. Every
  // move makes the player go and fetch a different part of the file, and
  // asking for a hundred different parts during one drag is how you get a
  // bar that glides and a picture that never settles. Four times a second
  // is often enough to feel like the picture is following you.
  static const Duration _scrubSeekInterval = Duration(milliseconds: 250);
  // Moves smaller than this don't count as "they went looking for
  // something" — that's a tap that landed near where the video already was.
  static const Duration _scrubSignalFloor = Duration(milliseconds: 250);

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
    // Unbounded-duration controller: the value is set directly while the
    // finger drags and animated via animateTo (which supplies its own
    // duration) on release, so no fixed duration is configured here.
    _cubeCtl = AnimationController(vsync: this, value: 0.0);
  }

  @override
  void didUpdateWidget(covariant _ReelTile old) {
    super.didUpdateWidget(old);
    // Reset to the primary video whenever this tile loses focus, so the
    // user always re-enters a battle on the challenger's side. Avoids the
    // confusing "opponent video frozen + primary audio playing" race that
    // happens if we leave _showingOpponent set while the parent's
    // _playCurrent unconditionally starts the primary URL on re-entry.
    if (old.isActive && !widget.isActive) {
      _cubeDragging = false;
      // Drop any half-finished drag on the bar. Normally the gesture is
      // cancelled for us when the pager takes the touch, but a reel can also
      // leave the screen without that happening — a video the user tapped
      // away from, a notification, code that jumps the feed. Leaving the
      // flag set would hold this reel still and show its clock over it when
      // the user came back.
      _scrubbing = false;
      _resumeAfterScrub = false;
      if (_showingOpponent) {
        _setShowOpponent(false, track: false, animate: false);
      } else if (_cubeCtl.value != 0) {
        // Mid-drag or mid-settle when the tile scrolled away: snap the
        // cube back to the challenger face instantly.
        _cubeCtl.stop();
        _cubeCtl.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _opponentState?.dispose();
    _heartCtl.dispose();
    _cubeCtl.dispose();
    super.dispose();
  }

  void _togglePause() {
    final activeController = _activeState?.controller;
    if (activeController == null) return;
    // Through the service, like every other start and stop — see
    // [VideoPlayerService.showAndPlay]. A deliberate pause does not change
    // which reel is on screen, so this pair does not touch that.
    if (_isPaused) {
      // ignore: discarded_futures
      VideoPlayerService.instance.resumeActive();
    } else {
      // ignore: discarded_futures
      VideoPlayerService.instance.pauseActive();
    }
    setState(() => _isPaused = !_isPaused);
    // Deliberate pauses are retention signals (reading a caption,
    // studying the frame) — the ranker maps video_pause/video_play to
    // dwell-intent. Fired after the flip so isPaused reflects the NEW
    // state.
    EventTracker.instance.trackPauseToggle(
      contentId: widget.item.id,
      contentType: widget.item.type,
      isPaused: _isPaused,
      positionMs: activeController.value.position.inMilliseconds,
    );
  }

  // ── Dragging the video to a different spot ─────────────────────────────
  //
  // The bar along the bottom of a reel used to only report progress. Now it
  // is also the handle: press it and drag sideways to move through the
  // video, or tap a point on it to jump there.
  //
  // It has its own narrow strip of the screen and claims every touch that
  // lands in it, which is what keeps it out of the way of everything else
  // the tile listens for. A sideways drag anywhere ELSE on a battle still
  // turns the cube to the other side, taps still pause, double taps still
  // like. Up-and-down swipes that start on the bar still move to the next
  // reel, because that gesture belongs to the pager above this widget and
  // the bar only ever claims sideways ones.

  /// Finger down on the bar.
  void _onScrubStart() {
    final st = _activeState;
    if (st == null) return;
    final v = st.controller.value;
    if (!v.isInitialized || v.duration <= Duration.zero) return;
    HapticFeedback.selectionClick();
    _scrubStartedAt = v.position;
    // Hold the video still while the finger is down. Sound played over a
    // moving playhead is a mess, and a video that keeps advancing fights
    // the finger for where the bar should be.
    _resumeAfterScrub = v.isPlaying;
    if (v.isPlaying) {
      // ignore: discarded_futures
      VideoPlayerService.instance.pauseActive();
    }
    setState(() {
      _scrubbing = true;
      _scrubTarget = v.position;
    });
  }

  /// Finger sliding along the bar. [target] is where in the video the
  /// finger currently is.
  void _onScrubUpdate(Duration target) {
    if (!_scrubbing) return;
    setState(() => _scrubTarget = target);
    final now = DateTime.now();
    if (now.difference(_lastScrubSeekAt) < _scrubSeekInterval) return;
    _lastScrubSeekAt = now;
    _seekActiveTo(target);
  }

  /// Finger lifted. Land exactly where they let go, start playing again if
  /// it was playing before, and tell the backend once that they went
  /// looking for a different part of the video.
  ///
  /// Where they let go is read from [_scrubTarget] rather than passed in by
  /// the bar. The bar knows it too, but only as of its last rebuild, and a
  /// finger can lift in the same frame as its last movement — which would
  /// land the video a few pixels short of where they actually let go.
  void _onScrubEnd() {
    if (!_scrubbing) return;
    final from = _scrubStartedAt;
    final target = _scrubTarget;
    setState(() => _scrubbing = false);
    _seekActiveTo(target);
    if (_resumeAfterScrub) {
      // ignore: discarded_futures
      VideoPlayerService.instance.resumeActive();
    }
    _resumeAfterScrub = false;

    // ONE event for one drag, not one per step.
    //
    // The backend already understands these: going back to rewatch a moment
    // counts as real interest, going forward counts as impatient but still
    // watching. What it was never built for is the dozens of little moves a
    // single slide of a finger makes. Reporting where the finger went down
    // and where it came up describes what the person actually did.
    if ((target - from).abs() < _scrubSignalFloor) return;
    EventTracker.instance.trackSeek(
      contentId: widget.item.id,
      contentType: widget.item.type,
      fromMs: from.inMilliseconds,
      toMs: target.inMilliseconds,
    );
  }

  /// The touch was taken away mid-drag (the pager won an up-and-down
  /// swipe). Leave the video where it is and let it play again — no event,
  /// because the person did not finish the gesture.
  void _onScrubCancel() {
    if (!_scrubbing) return;
    setState(() => _scrubbing = false);
    if (_resumeAfterScrub) {
      // ignore: discarded_futures
      VideoPlayerService.instance.resumeActive();
    }
    _resumeAfterScrub = false;
  }

  /// Move whichever side of the reel is facing the user. Through the
  /// service, like every other start and stop — it is the only thing that
  /// knows a person moved a video by hand rather than it moving itself.
  void _seekActiveTo(Duration target) {
    final st = _activeState;
    if (st == null) return;
    // ignore: discarded_futures
    VideoPlayerService.instance.seekTo(st.url, target);
  }

  void _doubleTapLike() {
    HapticFeedback.lightImpact();
    widget.onLike();
    setState(() => _showHeart = true);
    _heartCtl.forward(from: 0);
  }

  /// Flip session-wide feed mute. Unmuting fires trackUnmute — a
  /// top-tier positive ranking signal ("I explicitly want to hear
  /// this") the backend has supported all along.
  void _toggleMute() {
    final svc = VideoPlayerService.instance;
    final nowMuted = !svc.feedMuted.value;
    // The service owns the session-wide mute AND applying it to the reel on
    // screen. Doing the second half here meant this tile's idea of "the
    // active controller" had to agree with the service's, and on a battle
    // flip it did not — see [VideoPlayerService.showAndPlay].
    // ignore: discarded_futures
    svc.setFeedMuted(nowMuted);
    if (!nowMuted) {
      EventTracker.instance.trackUnmute(
        contentId: widget.item.id,
        contentType: widget.item.type,
      );
    }
  }

  /// Long-press sheet: the explicit-negative affordance ("Not
  /// interested" — a strong ranking signal with no UI entry point until
  /// now) plus save/share/playback-speed.
  void _showLongPressMenu() {
    HapticFeedback.mediumImpact();
    EventTracker.instance.trackLongPress(
      contentId: widget.item.id,
      contentType: widget.item.type,
    );
    final currentSpeed =
        _activeState?.controller.value.playbackSpeed ?? 1.0;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Not interested'),
              subtitle: const Text("You'll see less like this"),
              onTap: () {
                EventTracker.instance.trackNotInterested(
                  contentId: widget.item.id,
                  contentType: widget.item.type,
                );
                Navigator.of(sheetCtx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Got it — you'll see less like this."),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('Save'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                widget.onSave();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                widget.onShare();
              },
            ),
            ListTile(
              leading: const Icon(Icons.speed_rounded),
              title: const Text('Playback speed'),
              trailing: Text('${currentSpeed}x'),
              onTap: () {
                final next = switch (currentSpeed) {
                  1.0 => 1.5,
                  1.5 => 2.0,
                  _ => 1.0,
                };
                // ignore: discarded_futures
                _activeState?.controller.setPlaybackSpeed(next);
                Navigator.of(sheetCtx).pop();
                EventTracker.instance.trackTap(
                  target: 'playback_speed',
                  pageName: 'home_page',
                  params: {'speed': next, 'contentId': widget.item.id},
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The player state currently driving the visible video — primary by
  /// default, opponent when the user has swiped left on a battle.
  ///
  /// Null only when this tile has no player at all, which for an ACTIVE
  /// tile does not happen: the reel on screen is the one index allowed to
  /// open one, so [_getPlayerState] creates rather than peeks for it. The
  /// callers below are all gestures on the active tile and would be within
  /// their rights to assume that; they handle null anyway, because "the
  /// user cannot pause a reel that has not loaded" is a better failure
  /// than a null check that was correct until someone made a neighbour
  /// interactive.
  _ReelPlayerState? get _activeState =>
      _showingOpponent && _opponentState != null
      ? _opponentState!
      : widget.state;

  /// Build the opponent's controller. Mirrors the parent's
  /// _getPlayerState so the same VideoPlayerService cache is shared.
  ///
  /// CALLED FROM GESTURES ONLY, and that is load-bearing in two ways.
  ///
  /// The first is cost, and it is the reason this is not called earlier:
  /// see the note on [_opponentState]. A player opened before the gesture
  /// is a decoder pair spent on a battle that may well scroll past.
  ///
  /// The second is that it cannot safely be called during a build. It
  /// reaches VideoPlayerService.getController, which calls setVolume on a
  /// promoted pooled controller. setVolume notifies the controller's
  /// listeners; every ValueListenableBuilder bound to it then calls
  /// setState, mid-build, and Flutter throws:
  ///
  ///   setState() or markNeedsBuild() called during build.
  ///   #6  VideoPlayerController.setVolume
  ///   #7  VideoPlayerService.getController
  ///   #8  _ReelTileState._ensureOpponentState
  ///
  /// Seen on device back when a battle scrolling into view opened its
  /// opponent from initState. Gesture callbacks run between frames, so
  /// every current caller is clear of that — but a future caller reached
  /// from build(), initState or didUpdateWidget would reintroduce it and
  /// would need a post-frame callback.
  _ReelPlayerState _ensureOpponentState() {
    if (_opponentState != null) return _opponentState!;
    final url = widget.item.opponentVideoUrl;
    // This IS the flip's cost now, so this is where it gets counted.
    //
    // The read-ahead used to open the opponent ahead of time and record
    // warm/cold there; it stopped, to hold one fewer decoder — see the
    // long note beside `live` in _prefetchAround. The question the counter
    // answers is the same one and it still matters: when somebody flips,
    // are the opponent's bytes already down? Warm means the decoder is all
    // the turn has to build. Cold means it is fetching as well, which is
    // what a flip feels like sticking, and says the read-ahead is not
    // reaching opponents in time.
    if (VideoCacheService.instance.isReady(url)) {
      ReelDiagnostics.instance.recordSpareWarm(SpareLane.opponent);
    } else {
      ReelDiagnostics.instance.recordSpareCold(SpareLane.opponent);
    }
    final controller = VideoPlayerService.instance.getController(url);
    // ignore: discarded_futures
    controller.setLooping(true);
    _opponentState = _ReelPlayerState(controller: controller, url: url);
    return _opponentState!;
  }

  /// Flip between challenger and opponent video. No-op on non-battles or on
  /// a repeat-toggle to the same side. Entry point for the battle-indicator
  /// taps and the offscreen reset.
  ///
  /// `animate: false` (offscreen reset path) swaps instantly; otherwise the
  /// cube turns from wherever it currently is to the requested face.
  void _setShowOpponent(bool show, {bool track = true, bool animate = true}) {
    if (!widget.item.isBattle) return;

    if (!animate) {
      _cubeCtl.stop();
      _cubeCtl.value = show ? 1.0 : 0.0;
      if (show != _showingOpponent) _commitSide(show, track: track);
      return;
    }

    if (show == _showingOpponent && !_cubeCtl.isAnimating) return;
    // Make sure the opponent's player exists BEFORE the first frame of the
    // turn — both cube faces render live video during the animation.
    if (show) _ensureOpponentState();
    _settleTo(show, track: track);
  }

  /// Side-effect half of a side switch: make [show] the front side, swap
  /// playback + audio to its controller, and (optionally) emit the swipe
  /// and battle_switch events. Cube geometry is driven separately by
  /// [_cubeCtl] — callers pair this with a snap or a settle animation.
  void _commitSide(bool show, {bool track = true}) {
    setState(() {
      _showingOpponent = show;
      _isPaused = false; // resume on swap so the new side autoplays
    });

    // ignore: discarded_futures
    _startSide(show);

    if (track) {
      EventTracker.instance.trackSwipe(
        target: show ? 'reel_swipe_to_opponent' : 'reel_swipe_to_challenger',
        direction: show ? 'left' : 'right',
        pageName: 'home_page',
        params: {'contentId': widget.item.id, 'contentType': widget.item.type},
      );
      // Dedicated battle_switch event alongside the generic swipe —
      // the backend's content-event taxonomy scores it as active
      // engagement with the battle format (side 1 = opponent).
      EventTracker.instance.trackBattleSwitch(
        challengeId: widget.item.id,
        side: show ? 1 : 0,
      );
    }
  }

  /// Playback half of a side switch: stop the face going away, start the
  /// face coming in, and — the part that used to be missing — tell
  /// VideoPlayerService which URL is now the one on screen.
  ///
  /// The old version paused one controller and played the other directly,
  /// never routing through [VideoPlayerService.pauseAllExcept]. The
  /// service therefore still believed the CHALLENGER was on screen for the
  /// whole time the user spent watching the opponent, and it acts on that
  /// belief in two places that both end in a frozen picture:
  ///
  ///   - Eviction protects only the URL the service thinks is active, so
  ///     the opponent — visible, playing, unprotected — was a legal victim
  ///     the next time the pool needed a slot. Being evicted means being
  ///     disposed, and a disposed player stops on its last frame.
  ///   - [VideoPlayerService.getController] mutes and pauses a controller
  ///     that finishes initialising while some other URL is active. An
  ///     opponent whose first frame landed after the flip was therefore
  ///     silenced and stopped by the service moments after this method
  ///     started it — a still picture with no sound.
  ///
  /// Going through pauseAllExcept fixes both, because it sets the active
  /// URL synchronously before it awaits anything.
  Future<void> _startSide(bool show) async {
    // A tile that has scrolled away runs this too: didUpdateWidget resets
    // a battle to its challenger face on the way out, and that reset lands
    // here with `show` false. It must not start the video — it is off
    // screen — and it must not claim the active URL, which by then belongs
    // to whichever reel the user swiped to. Doing either was the old
    // "opponent frozen while the wrong audio plays" race, just from the
    // other direction.
    //
    // Checked before _ensureOpponentState because that reset arrives
    // during a build, and building an opponent there would reach
    // getController → setVolume → setState mid-build. Today's reset only
    // ever asks for the challenger, so the call below is unreachable from
    // that path; the order is what keeps it unreachable.
    if (!widget.isActive) {
      final opponentUrl = _opponentState?.url;
      if (opponentUrl != null) {
        // ignore: discarded_futures
        VideoPlayerService.instance.release(opponentUrl);
      }
      final url = widget.state?.url;
      if (url != null) {
        // ignore: discarded_futures
        VideoPlayerService.instance.release(url);
      }
      return;
    }

    // No player and not the opponent means this reel has not been opened
    // yet — there is nothing to show or play, and the poster is already
    // what the tile is rendering.
    final incoming = show ? _ensureOpponentState() : widget.state;
    if (incoming == null) return;
    // Same call the vertical swipe makes. That is the point: a flip is a
    // change of which reel is on screen, and it goes through the one place
    // that records that, rather than starting a player behind the service's
    // back — which is exactly what used to leave the opponent unprotected
    // from eviction and muted by its own initialisation callback.
    await VideoPlayerService.instance.showAndPlay(incoming.url);
  }

  /// Animate the cube from wherever it currently is to fully showing
  /// [opponent]. Commits the side change (audio + events) up front so the
  /// new side's video is already playing as its face swings in — the same
  /// "commit at release" behaviour IG stories has.
  void _settleTo(bool opponent, {bool track = true}) {
    if (opponent != _showingOpponent) _commitSide(opponent, track: track);
    final target = opponent ? 1.0 : 0.0;
    final distance = (target - _cubeCtl.value).abs();
    if (distance == 0) return;
    // Duration scales with the remaining arc so a nearly-finished drag
    // snaps shut quickly while a barely-started one takes the full turn.
    // ignore: discarded_futures
    _cubeCtl.animateTo(
      target,
      duration: Duration(milliseconds: (120 + 260 * distance).round()),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Finger-driven cube gestures ────────────────────────────────────────
  // The cube position tracks the finger 1:1 (one full screen-width of drag
  // = one quarter-turn). Dragging left turns toward the opponent, dragging
  // right turns back; the user can reverse mid-gesture and the cube follows.

  void _onHorizontalDragStart(DragStartDetails d) {
    if (!widget.item.isBattle) return;
    _cubeDragging = true;
    // Grab the cube wherever it is — interrupting a settle animation
    // mid-turn hands control straight back to the finger.
    _cubeCtl.stop();
    // Both faces render during the turn, so the opponent's player must
    // exist from the very first dragged frame (poster shows until its
    // controller has a frame).
    _ensureOpponentState();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (!widget.item.isBattle || !_cubeDragging) return;
    final w = context.size?.width ?? MediaQuery.of(context).size.width;
    if (w <= 0) return;
    // Finger left (negative dx) → progress toward the opponent face.
    // Clamped hard at the ends: a two-face cube has nowhere further to
    // turn, and the clamp is what keeps the geometry inside the tile.
    _cubeCtl.value = (_cubeCtl.value - d.delta.dx / w).clamp(0.0, 1.0);
  }

  /// Release: pick the winning side. A real fling settles in the fling's
  /// direction regardless of how far the cube has turned; a slow release
  /// settles to whichever face is currently more than half showing.
  void _onHorizontalDragEnd(DragEndDetails d) {
    if (!widget.item.isBattle || !_cubeDragging) return;
    _cubeDragging = false;
    final vx = d.primaryVelocity ?? 0;
    final bool toOpponent;
    if (vx.abs() >= _cubeFlingVelocity) {
      toOpponent = vx < 0;
    } else {
      toOpponent = _cubeCtl.value >= 0.5;
    }
    _settleTo(toOpponent);
  }

  void _onHorizontalDragCancel() {
    if (!widget.item.isBattle || !_cubeDragging) return;
    _cubeDragging = false;
    // Gesture arena took the pointer away (e.g. the vertical pager won a
    // diagonal drag) — settle to whichever side is closest, no events.
    _settleTo(_cubeCtl.value >= 0.5, track: false);
  }

  /// One side of the reel — poster behind, live video on top once its
  /// controller has a frame. Extracted from build so the cube flip can
  /// render BOTH sides simultaneously as the two turning faces.
  ///
  /// The poster stays in the tree while the video buffers (no black
  /// screen on slow networks) and doubles as the whole face when the
  /// opponent's controller hasn't produced a frame yet mid-turn.
  Widget _videoFace({required bool opponent}) {
    final item = widget.item;
    final url = opponent ? item.opponentVideoUrl : item.videoUrl;
    final poster = opponent && item.opponentThumbnailUrl.isNotEmpty
        ? item.opponentThumbnailUrl
        : item.thumbnailUrl;
    final st = opponent ? _opponentState : widget.state;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (poster.isNotEmpty)
          Image.network(
            poster,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // Don't show a broken-image icon if the CDN burps — we'd
            // rather fall through to a black background and let the
            // video load on top of it.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          )
        else
          const ColoredBox(color: Colors.black),
        if (url.isNotEmpty && st != null)
          // ValueListenableBuilder binds the rebuild DIRECTLY to the
          // controller's value: as soon as isInitialized flips true the
          // VideoPlayer paints over the poster. FittedBox(cover) gives
          // reels the edge-to-edge crop the format demands.
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: st.controller,
            builder: (context, value, _) {
              if (!value.isInitialized) return const SizedBox.shrink();
              // The pool can LRU-evict — and dispose — this controller at
              // any time. `st` was captured when the PARENT built, but
              // this builder re-runs on its own (every controller value
              // tick, every frame of a cube turn), so by the time it runs
              // the native player behind `st.controller` may already be
              // released. Handing that to VideoPlayer throws
              //
              //   Bad state: No active player with ID 5.
              //   #0 AndroidVideoPlayer._playerWith
              //   #1 AndroidVideoPlayer.buildViewWithOptions
              //   #2 _VideoPlayerState.build
              //
              // from inside build(), which replaces the reel with an
              // error box and then floods the log with follow-on
              // "Another exception was thrown" lines. Seen on device.
              //
              // Falling back to SizedBox.shrink leaves the poster
              // underneath showing, and the parent's _getPlayerState
              // rebuilds a live controller on its next pass — so a reel
              // that hits this recovers instead of dying.
              if (!VideoPlayerService.instance.isLive(st.controller)) {
                return const SizedBox.shrink();
              }
              return SizedBox.expand(
                child: FittedBox(
                  key: ValueKey(
                    'reel-video-${item.id}-${opponent ? 'opp' : 'pri'}',
                  ),
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: value.size.width,
                    height: value.size.height,
                    child: VideoPlayer(st.controller),
                  ),
                ),
              );
            },
          )
        else if (url.isEmpty && !opponent)
          _Placeholder(item: item),
      ],
    );
  }

  /// Position + rotate one cube face. `delta` is the face's virtual pager
  /// offset (0 = centered, ±1 = fully turned away): translate it by
  /// delta·width so the hinge tracks the seam, rotate 90°·delta around
  /// the seam-side edge, and shade it progressively as it turns — the
  /// same recipe IG stories use, around the vertical axis.
  Widget _cubeFace(double delta, double width, Widget face) {
    final shade = (delta.abs() * 0.45).clamp(0.0, 0.45);
    return Transform.translate(
      offset: Offset(delta * width, 0),
      child: Transform(
        alignment: delta > 0 ? Alignment.centerLeft : Alignment.centerRight,
        transform: Matrix4.identity()
          ..setEntry(3, 2, _cubePerspective)
          ..rotateY(-delta * math.pi / 2),
        // ClipRect sits INSIDE the transform, so it clips in face-local
        // coordinates before the 3D projection is applied. This is what
        // stops the "photo leaking to the other side" mid-turn: the
        // cover-fit video inside _videoFace lives in a FittedBox, and
        // FittedBox does NOT clip its overflow — without this clip a
        // wide video paints past the face's edge straight across the
        // seam onto the neighbouring face.
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              face,
              IgnorePointer(
                child: ColoredBox(color: Color.fromRGBO(0, 0, 0, shade)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final activeUrl = _showingOpponent ? item.opponentVideoUrl : item.videoUrl;
    final hasVideo = activeUrl.isNotEmpty;
    final isChallenge = item.type == 'challenge';
    // The player for the side facing the user — the one the bar reports on
    // and the one a drag moves.
    final playerState = _activeState;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Media layer: poster + video for the visible side. When settled
        // this is a single plain face (zero transform cost); mid-turn it
        // becomes two live faces of a 3D cube rotating around the
        // vertical axis, position driven directly by _cubeCtl (finger or
        // settle animation) — see _videoFace/_cubeFace.
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _cubeCtl,
            builder: (context, _) {
              final p = _cubeCtl.value;
              // Fully settled on either face → plain single-face layout.
              if (p <= 0.001) return _videoFace(opponent: false);
              if (p >= 0.999) return _videoFace(opponent: true);
              return LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  // Challenger sits at pager offset -p (sliding out to the
                  // left as p grows), opponent at 1-p (sliding in from the
                  // right); _cubeFace turns each around the shared seam
                  // edge to complete the cube illusion. The black
                  // ColoredBox behind them is what shows through the
                  // perspective gaps at the receding edges — the "3D space
                  // with black borders" around the turning cube — and the
                  // outer ClipRect guarantees nothing paints outside the
                  // tile.
                  return ClipRect(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _cubeFace(-p, w, _videoFace(opponent: false)),
                          _cubeFace(1 - p, w, _videoFace(opponent: true)),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),

        // Gesture catcher (translucent — vertical swipes still reach the
        // parent PageView; on battles, horizontal drags drive the cube
        // continuously, finger-following, and settle on release).
        //
        // The horizontal handlers are registered even on non-battles
        // (where they no-op): the tile has always claimed horizontal
        // drags so they don't fall through to the home page's
        // TabBarView and yank the user between For You / Following /
        // Explore mid-reel. Tab switching stays on the tap strip.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _togglePause,
            onDoubleTap: _doubleTapLike,
            onLongPress: _showLongPressMenu,
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: _onHorizontalDragUpdate,
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onHorizontalDragCancel: _onHorizontalDragCancel,
          ),
        ),

        // Mute toggle — top-right, out of the action rail's way. This
        // is what makes the backend's `unmute` ranking signal reachable
        // at all: the feed used to be permanently unmuted, so the
        // strongest "I actively want to hear this" signal never fired.
        Positioned(
          top: 12,
          right: 12,
          child: SafeArea(
            child: ValueListenableBuilder<bool>(
              valueListenable: VideoPlayerService.instance.feedMuted,
              builder: (_, muted, _) => IconButton(
                icon: Icon(
                  muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  color: Colors.white,
                  shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
                onPressed: _toggleMute,
              ),
            ),
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
        if (_isPaused) const Center(child: IgnorePointer(child: _PauseBadge())),

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
        // Anchored just above the bar with a small breathing margin and
        // safe-area padding so the home indicator on iOS / nav-gesture hint
        // on Android doesn't overlap the text.
        //
        // The gap clears the bar's whole touch strip, not just the painted
        // line. The strip has to be far taller than the line to be hittable
        // at all, and it swallows every touch inside it — so anything
        // tappable that overlapped it (the "View battle" button sits at the
        // bottom of this column) would quietly stop responding.
        Positioned(
          bottom:
              MediaQuery.of(context).padding.bottom + _ScrubBar.stripHeight,
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
        // Same clearance as the caption block, and for the same reason: the
        // lowest icon in this rail must not fall inside the bar's touch
        // strip, or it stops responding to taps.
        Positioned(
          right: 10,
          bottom:
              MediaQuery.of(context).padding.bottom + _ScrubBar.stripHeight,
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

        // The bar along the bottom: where you are in the video, and the
        // handle for moving somewhere else in it. Sits at the very bottom
        // but lifted above the safe-area inset so it isn't clipped by the
        // home indicator.
        //
        // Bound to the side that is FACING THE USER, not always the
        // challenger. On a battle the two sides are two different videos of
        // two different lengths, so a bar reading the challenger while the
        // opponent plays shows a stranger's progress — and, now that the
        // bar can be dragged, would move the wrong video.
        //
        // Gated on there being a player, not just a video: an off-screen
        // tile showing its poster has no position to report, and a bar
        // stuck at zero reads as a video that failed rather than one that
        // has not been opened.
        if (hasVideo && playerState != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom,
            child: _ScrubBar(
              controller: playerState.controller,
              scrubbing: _scrubbing,
              scrubTarget: _scrubTarget,
              onScrubStart: _onScrubStart,
              onScrubUpdate: _onScrubUpdate,
              onScrubEnd: _onScrubEnd,
              onScrubCancel: _onScrubCancel,
            ),
          ),

        // Big centered clock while a finger is on the bar — the only way to
        // know where you are landing, since the video itself is held still
        // and a 5-pixel line is not a readout.
        if (_scrubbing && playerState != null)
          Center(
            child: IgnorePointer(
              child: _ScrubTimeBadge(
                position: _scrubTarget,
                duration: playerState.controller.value.duration,
              ),
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

/// The line along the bottom of a reel: how far through the video you are,
/// and the handle for going somewhere else in it.
///
/// ════════════════════════════════════════════════════════════════════════
/// WHY IT IS ITS OWN STRIP INSTEAD OF THE WHOLE SCREEN
/// ════════════════════════════════════════════════════════════════════════
///
/// The obvious way to let people move through a video is to let them drag
/// anywhere on it. That slot is taken. A sideways drag on a battle turns the
/// reel over to the other person's video, which is the main thing you do
/// with a battle, and it would be a bad trade to lose it.
///
/// So the handle is the bar itself, the way it works in most video apps.
/// The catch is that the bar is two pixels tall and nobody can hit two
/// pixels. The fix is an invisible strip [stripHeight] tall sitting on top
/// of it that catches the touch — you aim at the line, you hit the strip.
///
/// The strip claims every touch that lands in it, so nothing underneath
/// fires by accident: no pausing, no accidental likes, no turning a battle
/// over. It only ever claims SIDEWAYS drags, so flicking up or down from
/// the bar still moves to the next reel — that gesture belongs to the pager
/// this whole tile sits inside, which is not underneath the strip but
/// around it.
///
/// Because the strip covers the bottom [stripHeight] of the tile, nothing
/// tappable may sit inside it — see where the caption block and the action
/// rail are anchored.
class _ScrubBar extends StatelessWidget {
  const _ScrubBar({
    required this.controller,
    required this.scrubbing,
    required this.scrubTarget,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    required this.onScrubCancel,
  });

  final VideoPlayerController controller;

  /// True while a finger is down. Changes what the bar reads (the finger,
  /// not the video) and makes it thick enough to see under a thumb.
  final bool scrubbing;
  final Duration scrubTarget;

  final VoidCallback onScrubStart;
  final ValueChanged<Duration> onScrubUpdate;

  /// Takes no position: the tile it reports to already holds the live one,
  /// and the copy this widget has is only as fresh as its last rebuild.
  final VoidCallback onScrubEnd;
  final VoidCallback onScrubCancel;

  /// Height of the invisible touch strip. Comfortably hittable with a
  /// thumb, and small enough that it does not eat into the reel.
  static const double stripHeight = 24;

  /// How far above the bottom of the strip the line is painted. Leaves the
  /// round handle somewhere to sit without hanging off the bottom of the
  /// screen, and keeps the line clear of the home indicator.
  static const double _lineBottom = 5;

  static const double _restingThickness = 2;
  static const double _draggingThickness = 5;
  static const double _thumbSize = 14;

  /// Turn a horizontal touch position into a point in the video.
  Duration _positionFor(double dx, double width, Duration total) {
    if (width <= 0 || total <= Duration.zero) return Duration.zero;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return Duration(
      milliseconds: (total.inMilliseconds * fraction).round(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, v, _) {
            final total = v.duration;
            // While a finger is down the bar shows where the FINGER is, not
            // where the video is. The video is a moment behind — it has to
            // go and fetch that part of the file — and a bar that waited
            // for it would stutter and lag under the thumb.
            final shown = scrubbing ? scrubTarget : v.position;
            final progress = total.inMilliseconds > 0
                ? (shown.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                : 0.0;
            final thickness = scrubbing
                ? _draggingThickness
                : _restingThickness;

            return GestureDetector(
              // Opaque: this strip takes the touch and nothing under it
              // sees it. That is the whole reason the battle flip and the
              // tap-to-pause don't fire when you reach for the bar.
              behavior: HitTestBehavior.opaque,
              onTapUp: total <= Duration.zero
                  ? null
                  : (d) {
                      // A tap is a drag with no middle: press, aim, let go.
                      onScrubStart();
                      onScrubUpdate(
                        _positionFor(d.localPosition.dx, width, total),
                      );
                      onScrubEnd();
                    },
              onHorizontalDragStart: (_) => onScrubStart(),
              onHorizontalDragUpdate: (d) => onScrubUpdate(
                _positionFor(d.localPosition.dx, width, total),
              ),
              onHorizontalDragEnd: (_) => onScrubEnd(),
              onHorizontalDragCancel: onScrubCancel,
              child: SizedBox(
                height: stripHeight,
                width: double.infinity,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: _lineBottom,
                      height: thickness,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(color: Colors.white24),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: progress,
                              heightFactor: 1,
                              child: ColoredBox(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The handle, only while a finger is down. Clamped so
                    // it stays on screen at both ends instead of hanging
                    // half off the edge.
                    if (scrubbing)
                      Positioned(
                        left: (progress * width - _thumbSize / 2).clamp(
                          0.0,
                          math.max(0.0, width - _thumbSize),
                        ),
                        bottom: _lineBottom + thickness / 2 - _thumbSize / 2,
                        width: _thumbSize,
                        height: _thumbSize,
                        child: const DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(blurRadius: 6, color: Colors.black54),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The clock that appears in the middle of the reel while a finger is on
/// the bar — "0:07 / 0:15". Without it there is no way to tell where you
/// are landing, because the video is held still while you drag and a
/// five-pixel line is not a readout.
class _ScrubTimeBadge extends StatelessWidget {
  const _ScrubTimeBadge({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  static String _clock(Duration d) {
    final safe = d < Duration.zero ? Duration.zero : d;
    final minutes = safe.inMinutes;
    final seconds = safe.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: _clock(position),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: ' / ${_clock(duration)}',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
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
              Text('Delete', style: TextStyle(color: Colors.redAccent)),
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
                color: hasVoted
                    ? Colors.green.shade300
                    : Colors.orange.shade300,
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
                    horizontal: 6,
                    vertical: 3,
                  ),
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
                const Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white70,
                  size: 12,
                ),
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
                const Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.white70,
                  size: 12,
                ),
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
              children: List.generate(
                5,
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: i == 0 ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: i == 0 ? null : BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
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
                child: Icon(
                  Icons.group_add_rounded,
                  color: cs.primary,
                  size: 24,
                ),
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
                            fontWeight: FontWeight.w500,
                          ),
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
              separatorBuilder: (_, _) =>
                  const Divider(color: Colors.white12, height: 16),
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
                Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: Colors.white38,
                  size: 18,
                ),
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
  const _AccountSuggestionRow({required this.user, required this.cardId});

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
            builder: (_) =>
                ProfilePage(user: user.toUserModel(), isEmbedded: false),
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
                            horizontal: 5,
                            vertical: 1,
                          ),
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
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        Text('No video available', style: TextStyle(color: Colors.white54)),
      ],
    );
  }
}
