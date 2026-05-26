import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:video_player/video_player.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/pages/search_reels_viewer_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

/// Search page — TikTok / Instagram style with four tabs:
///   * Top      — interleaved best of accounts + battles + shorts
///   * Accounts — ranked users (lex + social proof + popularity)
///   * Battles  — challenges with at least one accepted response
///   * Shorts   — challenges nobody has responded to yet
///
/// Backed by /search which returns three sections in one round-trip and
/// applies multi-signal re-ranking (engagement, recency, personalization)
/// on top of the Meilisearch lexical score.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin, PageTracker<SearchPage> {
  late TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;

  // Tabs are indexed 0..3 in this order. Used by event-tracking labels and
  // by the analytics pipeline downstream.
  static const _tabLabels = ['Top', 'Accounts', 'Battles', 'Shorts'];

  List<UserModel> _accounts = [];
  List<ChallengeModel> _battles = [];
  List<ChallengeModel> _shorts = [];
  // Empty-state grid feed. Backed by /api/v1/feed/explore — same algorithm
  // as the Explore tab (see architectural note above). We render only the
  // challenge-typed entries so the grid stays a pure video surface.
  List<ChallengeModel> _exploreChallenges = [];
  bool _loading = false;
  bool _hasSearched = false;

  // One previewing tile at a time across the whole search surface. Bounded
  // by construction so the media_kit pool never blows up regardless of how
  // far the user scrolls.
  late final _PreviewCoordinator _previewCoord;

  // Track last submitted query so we can fire search_abandoned if the user
  // leaves the page without tapping any result.
  String _lastQuery = '';
  bool _lastQueryHadResultTap = false;

  @override
  String get pageName => 'search_page';

  @override
  void initState() {
    super.initState();
    _previewCoord = _PreviewCoordinator();
    _tabCtrl = TabController(length: _tabLabels.length, vsync: this);
    _tabCtrl.addListener(() {
      if (!_tabCtrl.indexIsChanging) return;
      EventTracker.instance.trackTap(
        target: 'search_tab_${_tabLabels[_tabCtrl.index].toLowerCase()}',
        pageName: pageName,
      );
      // Tab switch — the active preview tile is no longer visible. Clear so
      // the new tab can claim a fresh active tile based on its own scroll.
      _previewCoord.clearActive();
    });
    _loadExploreChallenges();
  }

  @override
  void dispose() {
    // If user typed a query and never tapped a result, count it as abandoned.
    if (_lastQuery.isNotEmpty && !_lastQueryHadResultTap) {
      EventTracker.instance.trackSearchAbandoned(
        query: _lastQuery,
        reason: 'no_result_tap',
      );
    }
    _previewCoord.dispose();
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// Loads the empty-state grid using the Explore algorithm (same one the
  /// Explore tab uses). Architectural note: search-page-default and
  /// Explore are the same surface intent — discovery without query — so
  /// they share an algorithm. We just filter to challenge entries here.
  ///
  /// When [refresh] is true, the backend treats this as a pull-to-refresh
  /// (clears the seen-set, jitters scores, demotes the previous refresh's
  /// top-3) so the grid visibly changes.
  Future<void> _loadExploreChallenges({bool refresh = false}) async {
    debugPrint('[search_page] _loadExploreChallenges(refresh: $refresh) fired');
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';
    final list = await ApiService.getExploreChallenges(userId, limit: 30, refresh: refresh);
    debugPrint('[search_page] got ${list.length} explore items back');
    if (mounted) {
      setState(() => _exploreChallenges = list);
    }
    // Fallback: if Explore came back empty (cold platform / first user),
    // fall through to the legacy arena-trending list so the grid is never
    // dead. This shouldn't happen at scale but is cheap insurance.
    if (list.isEmpty) {
      final fallback = await ApiService.getArenaChallenges();
      if (mounted && _exploreChallenges.isEmpty) {
        setState(() => _exploreChallenges = fallback);
      }
    }
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _hasSearched = false;
        _accounts = [];
        _battles = [];
        _shorts = [];
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(query));
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _loading = true);
    final start = DateTime.now();

    // Pass the userId so the backend can apply personalization signals
    // (FoF boost on accounts, category-affinity on challenges, etc.).
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';

    final result = await ApiService.searchAll(query.trim(), userId: userId);
    if (mounted) {
      final accounts = (result['accounts'] as List? ?? [])
          .map((j) => UserModel.fromJson(j as Map<String, dynamic>))
          .toList();
      final battles = (result['battles'] as List? ?? [])
          .map((j) => ChallengeModel.fromJson(j as Map<String, dynamic>))
          .toList();
      final shorts = (result['shorts'] as List? ?? [])
          .map((j) => ChallengeModel.fromJson(j as Map<String, dynamic>))
          .toList();

      // Record search intent + result count + latency. If the previous query
      // went unchased, log it as abandoned before overwriting.
      if (_lastQuery.isNotEmpty &&
          _lastQuery != query.trim() &&
          !_lastQueryHadResultTap) {
        EventTracker.instance.trackSearchAbandoned(
          query: _lastQuery,
          reason: 'no_result_tap',
        );
      }
      EventTracker.instance.trackSearchQuery(
        query: query.trim(),
        scope: 'all',
        resultCount: accounts.length + battles.length + shorts.length,
      );
      EventTracker.instance.trackPerf(
        operation: 'search_api',
        durationMs: DateTime.now().difference(start).inMilliseconds,
        surface: pageName,
      );
      _lastQuery = query.trim();
      _lastQueryHadResultTap = false;

      setState(() {
        _accounts = accounts;
        _battles = battles;
        _shorts = shorts;
        _loading = false;
        _hasSearched = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // Tabs only appear once the user has searched — Instagram-style. The
    // empty state is just a video grid below the search bar with no
    // category filters cluttering the surface.
    final showTabs = _hasSearched;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        centerTitle: true,
        bottom: PreferredSize(
          // Collapse the bottom area to just the search bar when no tabs
          // are visible. Saves ~46pt of vertical space pre-search.
          preferredSize: Size.fromHeight(showTabs ? 100 : 56),
          child: Column(
            children: [
              // Search bar
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: 'Search challenges, users...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                  ),
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _search,
                ),
              ),
              // Tabs — only after a search has been issued.
              if (showTabs)
                TabBar(
                  controller: _tabCtrl,
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  indicatorColor: cs.primary,
                  labelColor: cs.primary,
                  unselectedLabelColor: cs.onSurfaceVariant,
                  tabs: const [
                    Tab(text: 'Top'),
                    Tab(text: 'Accounts'),
                    Tab(text: 'Battles'),
                    Tab(text: 'Shorts'),
                  ],
                ),
            ],
          ),
        ),
      ),
      body: _loading
          ? (showTabs
              ? TabBarView(
                  controller: _tabCtrl,
                  children: const [
                    ChatListSkeleton(count: 5),
                    ChatListSkeleton(count: 5),
                    SearchGridSkeleton(),
                    SearchGridSkeleton(),
                  ],
                )
              : const SearchGridSkeleton())
          : (showTabs
              ? TabBarView(
                  controller: _tabCtrl,
                  children: [
                    _buildTopTab(cs),
                    _buildAccountsTab(cs),
                    _buildChallengeGridTab(
                      items: _battles,
                      emptyLabel: 'No battles found',
                      resultType: 'battle',
                    ),
                    _buildChallengeGridTab(
                      items: _shorts,
                      emptyLabel: 'No shorts found',
                      resultType: 'short',
                    ),
                  ],
                )
              : _buildEmptyStateGrid(cs)),
    );
  }

  /// Pre-search body: just the Explore-algorithm video grid. No tabs, no
  /// section headers — Instagram-style "type to filter, scroll to discover".
  Widget _buildEmptyStateGrid(ColorScheme cs) {
    if (_exploreChallenges.isEmpty) {
      // Even with nothing loaded, the user should still be able to pull to
      // retry. Wrap the empty-state in a ListView with always-scrollable
      // physics so RefreshIndicator gets the pull gesture.
      return RefreshIndicator(
        onRefresh: () => _loadExploreChallenges(refresh: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _emptyState(
                icon: Icons.search,
                label: 'Search anything — accounts, battles, shorts',
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadExploreChallenges(refresh: true),
      child: _challengeGrid(_exploreChallenges, 'explore'),
    );
  }

  // ── Top tab — interleaved best-of-everything ─────────────────────────
  // Only ever rendered after a search has been issued — empty-state goes
  // straight to _buildEmptyStateGrid so no tabs are shown before search.

  Widget _buildTopTab(ColorScheme cs) {
    final accountsHead = _accounts.take(3).toList();
    final battlesHead = _battles.take(4).toList();
    final shortsHead = _shorts.take(4).toList();

    if (accountsHead.isEmpty && battlesHead.isEmpty && shortsHead.isEmpty) {
      return RefreshIndicator(
        onRefresh: () async {
          if (_lastQuery.isNotEmpty) await _search(_lastQuery);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _emptyState(
                icon: Icons.search_off,
                label: 'No results for "$_lastQuery"',
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      // Pull-to-refresh re-runs the active query so the user can shake
      // up the result ordering — same TikTok/IG behavior as the home reels.
      onRefresh: () async {
        if (_lastQuery.isNotEmpty) await _search(_lastQuery);
      },
      child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (accountsHead.isNotEmpty) ...[
          _sectionHeader('Accounts', onSeeAll: () => _tabCtrl.animateTo(1)),
          ...accountsHead
              .asMap()
              .entries
              .map((e) => _accountTile(e.value, e.key)),
        ],
        if (battlesHead.isNotEmpty) ...[
          _sectionHeader('Battles', onSeeAll: () => _tabCtrl.animateTo(2)),
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: battlesHead.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 110,
                  child: _PreviewableTile(
                    challenge: battlesHead[i],
                    coordinator: _previewCoord,
                    onTap: () => _onChallengeTap(battlesHead[i], i, 'battle'),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (shortsHead.isNotEmpty) ...[
          _sectionHeader('Shorts', onSeeAll: () => _tabCtrl.animateTo(3)),
          SizedBox(
            height: 160,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: shortsHead.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 110,
                  child: _PreviewableTile(
                    challenge: shortsHead[i],
                    coordinator: _previewCoord,
                    onTap: () => _onChallengeTap(shortsHead[i], i, 'short'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
      ),
    );
  }

  Widget _sectionHeader(String label, {VoidCallback? onSeeAll}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (onSeeAll != null)
            TextButton(
              onPressed: onSeeAll,
              child: const Text('See all'),
            ),
        ],
      ),
    );
  }

  // ── Battles / Shorts grid ────────────────────────────────────────────

  Widget _buildChallengeGridTab({
    required List<ChallengeModel> items,
    required String emptyLabel,
    required String resultType,
  }) {
    Future<void> onRefresh() async {
      if (_lastQuery.isNotEmpty) await _search(_lastQuery);
    }
    if (items.isEmpty) {
      // Wrap the no-results placeholder in a scrollable so the user can
      // still pull to retry the active query.
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: _emptyState(icon: Icons.search_off, label: emptyLabel),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      // Search-result refresh re-runs the active query. The earlier
      // implementation called _loadExploreChallenges here which was a
      // bug — pulling to refresh on a search-results tab silently
      // replaced state with explore content.
      onRefresh: onRefresh,
      child: _challengeGrid(items, resultType),
    );
  }

  Widget _challengeGrid(List<ChallengeModel> items, String resultType) {
    return GridView.builder(
      // AlwaysScrollableScrollPhysics is required for the parent
      // RefreshIndicator to fire its pull gesture even when the grid
      // contents fit on a single screen. Without it, a short result list
      // makes the pull-to-refresh silently drop.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 0.75,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) => _PreviewableTile(
        challenge: items[i],
        coordinator: _previewCoord,
        onTap: () => _onChallengeTap(items[i], i, resultType),
      ),
    );
  }

  // ── Tap handlers — share tracking across tabs ────────────────────────

  void _onChallengeTap(ChallengeModel ch, int position, String resultType) {
    if (_hasSearched) {
      EventTracker.instance.trackSearchResultTap(
        query: _lastQuery,
        resultId: ch.id,
        resultType: resultType,
        position: position,
      );
      _lastQueryHadResultTap = true;
    }
    // Open a fullscreen reels viewer that starts on the tapped video and
    // lets the user keep swiping vertically through more discovery content
    // — Instagram-style search-grid → vertical-feed transition. Includes
    // the battle indicator + opponent-swipe gesture from SmartReelsFeed,
    // plus a back button to return to the search grid.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchReelsViewerPage(seedChallenge: ch),
      ),
    );
  }

  Widget _accountTile(UserModel user, int position) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        child: Text(
          user.username.isNotEmpty ? user.username[0].toUpperCase() : '?',
          style: TextStyle(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      title: Text(user.username,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(user.league,
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      trailing: Text('${user.wins}W ${user.losses}L',
          style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
      onTap: () {
        EventTracker.instance.trackSearchResultTap(
          query: _lastQuery,
          resultId: user.id,
          resultType: 'user',
          position: position,
        );
        _lastQueryHadResultTap = true;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ProfilePage(user: user, isEmbedded: false),
          ),
        );
      },
    );
  }

  Widget _emptyState({required IconData icon, required String label}) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(label, style: TextStyle(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  // Accounts tab — full list of ranked users from the search response.
  Widget _buildAccountsTab(ColorScheme cs) {
    Future<void> onRefresh() async {
      if (_lastQuery.isNotEmpty) await _search(_lastQuery);
    }
    Widget wrapEmpty(Widget inner) => RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.6,
                child: inner,
              ),
            ],
          ),
        );
    if (!_hasSearched) {
      return wrapEmpty(_emptyState(
        icon: Icons.person_search,
        label: 'Search for users',
      ));
    }
    if (_accounts.isEmpty) {
      return wrapEmpty(_emptyState(
        icon: Icons.search_off,
        label: 'No accounts found',
      ));
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8),
        itemCount: _accounts.length,
        itemBuilder: (_, i) => _accountTile(_accounts[i], i),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREVIEW COORDINATOR
//
// Instagram-style: as the user scrolls, ONE tile at a time auto-plays a
// muted preview. The active tile gets a long enough turn to actually convey
// what the clip is about (typically the full video, since most short-form
// content is shorter than the safety-net timer in `_PreviewCoordinator`),
// then the cursor advances to the next visible tile so the user gets a tour
// of the visible block instead of one looping clip. Scroll movement always
// wins — when a different tile becomes most-visible, that tile claims the
// cursor immediately and the cycle restarts from there.
//
// Why bound to ONE active at a time:
//   - keeps media_kit's decoder count to 1 on mid-tier Android (multiple
//     parallel decodes drop frames and crater battery)
//   - matches the user's mental model — the eye can only watch one tile
//
// Cycling happens via two triggers:
//   1) auto-advance timer fires after kPreviewDuration
//   2) the active tile's video ends naturally (we don't loop)
//
// Either trigger calls _autoAdvance(), which picks the next visible tile
// not yet shown in this cycle. When all visible tiles have been shown,
// the cycle resets and starts over from the most-visible one.
// ─────────────────────────────────────────────────────────────────────────────

class _PreviewCoordinator extends ChangeNotifier {
  // Hard ceiling on a single tile's turn. The natural advance comes from the
  // video's `stream.completed` event — for any short-form clip (typically
  // 8–15s) the video ends and we move on before this timer fires. The timer
  // only matters as a safety net so a stalled or unusually long clip can't
  // freeze the carousel on one tile. 25s gives the user a real chance to
  // see what the video is about (Instagram-style long preview) while still
  // guaranteeing we eventually advance.
  static const Duration _kPreviewDuration = Duration(seconds: 25);
  static const double _kActivateAt = 0.55;

  String? _activeId;
  String? get activeId => _activeId;

  // tileId -> last reported visible fraction. Insertion order is preserved
  // by Dart's LinkedHashMap so we get a stable visit order for advancing.
  final Map<String, double> _fractions = {};

  // Tiles that have already taken a turn in the current cycle. Cleared
  // when the user scrolls (most-visible changes) OR when every visible
  // tile has been consumed.
  final Set<String> _consumedThisCycle = {};

  Timer? _advanceTimer;

  /// Tile reports its visibility. The coordinator picks/repicks the active
  /// tile and notifies listeners only when the active id changes.
  void report(String tileId, double fraction) {
    if (fraction <= 0.01) {
      _fractions.remove(tileId);
    } else {
      _fractions[tileId] = fraction;
    }
    _maybePick();
  }

  /// Called by a tile when its video ends. If it's still active, advance.
  /// (We don't loop — Instagram doesn't either; each tile gets a turn.)
  void onPlaybackComplete(String tileId) {
    if (tileId == _activeId) {
      _autoAdvance();
    }
  }

  void _maybePick() {
    // Find the most-visible tile right now.
    String? mostVisible;
    double bestFraction = 0;
    for (final e in _fractions.entries) {
      if (e.value < _kActivateAt) continue;
      if (e.value > bestFraction) {
        bestFraction = e.value;
        mostVisible = e.key;
      }
    }

    // Nothing visible enough — clear active.
    if (mostVisible == null) {
      _setActive(null);
      return;
    }

    // First-time activation: pick whatever's most visible and start
    // a fresh cycle.
    if (_activeId == null) {
      _consumedThisCycle.clear();
      _setActive(mostVisible);
      return;
    }

    // Already the right one — keep playing.
    if (mostVisible == _activeId) return;

    // Instagram-style follow: the user is looking at a different tile
    // than the one currently playing. Switch immediately — don't wait
    // for the old active to fall below the visibility floor. Hysteresis
    // of +5% prevents thrash when two adjacent tiles oscillate around
    // similar visibility during a slow drag. Clear the consumed-cycle
    // set so a tile the user scrolls back to can replay (Instagram does
    // this — scroll back, the preview restarts).
    final activeFrac = _fractions[_activeId!] ?? 0;
    if (bestFraction >= activeFrac + 0.05) {
      _consumedThisCycle.clear();
      _setActive(mostVisible);
      return;
    }

    // Active tile scrolled completely out — pick a fresh one even if
    // hysteresis would otherwise hold.
    if (!_fractions.containsKey(_activeId)) {
      _setActive(mostVisible);
    }
  }

  void _setActive(String? id) {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    if (id == _activeId) return;
    _activeId = id;
    if (id != null) {
      _consumedThisCycle.add(id);
      _advanceTimer = Timer(_kPreviewDuration, _autoAdvance);
    }
    notifyListeners();
  }

  void _autoAdvance() {
    // Pick the most-visible tile NOT yet shown in this cycle.
    String? next;
    double bestFraction = 0;
    for (final e in _fractions.entries) {
      if (e.value < _kActivateAt) continue;
      if (_consumedThisCycle.contains(e.key)) continue;
      if (e.value > bestFraction) {
        bestFraction = e.value;
        next = e.key;
      }
    }
    if (next != null) {
      _setActive(next);
      return;
    }
    // All visible tiles consumed — reset cycle and play the most-visible
    // one (which is most likely the one the user is currently looking at).
    _consumedThisCycle.clear();
    String? mostVisible;
    bestFraction = 0;
    for (final e in _fractions.entries) {
      if (e.value < _kActivateAt) continue;
      if (e.value > bestFraction) {
        bestFraction = e.value;
        mostVisible = e.key;
      }
    }
    _setActive(mostVisible);
  }

  /// Forcibly clear the active tile — used on tab switch so the new tab
  /// can claim its own active without inheriting the prior tab's state.
  void clearActive() {
    _advanceTimer?.cancel();
    _advanceTimer = null;
    _consumedThisCycle.clear();
    _fractions.clear();
    if (_activeId != null) {
      _activeId = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _advanceTimer?.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREVIEWABLE TILE
//
// Renders a thumbnail by default; when this tile becomes the coordinator's
// active id, lazily creates a muted, looping media_kit Player and overlays
// the Video on top of the thumbnail. When deactivated, pauses the player
// (kept around for fast reactivation if the user scrolls back). Disposed
// fully on widget dispose, so GridView.builder's recycling is what bounds
// total memory — once a tile scrolls out of cacheExtent, the Player goes
// with it.
// ─────────────────────────────────────────────────────────────────────────────

class _PreviewableTile extends StatefulWidget {
  final ChallengeModel challenge;
  final _PreviewCoordinator coordinator;
  final VoidCallback onTap;

  const _PreviewableTile({
    required this.challenge,
    required this.coordinator,
    required this.onTap,
  });

  @override
  State<_PreviewableTile> createState() => _PreviewableTileState();
}

class _PreviewableTileState extends State<_PreviewableTile> {
  VideoPlayerController? _controller;
  bool _isActive = false;
  // Used to detect single-pass completion. video_player has no
  // "completed" event; we sample position via addListener and fire
  // the coordinator callback when playback ends naturally.
  bool _completionReported = false;
  VoidCallback? _listenerRef;

  String get _id => widget.challenge.id;

  @override
  void initState() {
    super.initState();
    widget.coordinator.addListener(_onCoordinatorChanged);
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_onCoordinatorChanged);
    widget.coordinator.report(_id, 0);
    final c = _controller;
    final ref = _listenerRef;
    _controller = null;
    _listenerRef = null;
    if (c != null) {
      if (ref != null) c.removeListener(ref);
      // Dedicated per-tile controller — not pooled — so dispose
      // fully. Fire-and-forget; the engine cleans up async.
      // ignore: discarded_futures
      c.dispose();
    }
    super.dispose();
  }

  void _onCoordinatorChanged() {
    final shouldBeActive = widget.coordinator.activeId == _id;
    if (shouldBeActive == _isActive) return;
    _isActive = shouldBeActive;
    if (_isActive) {
      _ensurePlayerAndPlay();
    } else {
      // ignore: discarded_futures
      _controller?.pause();
    }
    if (mounted) setState(() {});
  }

  Future<void> _ensurePlayerAndPlay() async {
    final url = widget.challenge.videoUrl;
    if (url.isEmpty) return;
    if (_controller == null) {
      // Dedicated controller per preview tile, NOT routed through
      // VideoPlayerService — the shared pool's setVolume(1.0) on
      // cache hit would unmute the preview if the user navigates to
      // the full reels feed and the same URL gets reclaimed.
      // Isolating preview state here keeps the audio model
      // unambiguous: search previews are always silent.
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      _controller = c;
      _completionReported = false;

      void onUpdate() {
        if (!mounted) return;
        final v = c.value;
        if (!v.isInitialized) return;
        // Single-pass complete: position has reached duration AND we
        // aren't playing any more (looping is OFF on this controller).
        // Coordinator advances to the next visible tile. The first-frame
        // fade is handled by the ValueListenableBuilder in build(), not
        // here — this listener only owns completion detection.
        if (!_completionReported &&
            v.duration > Duration.zero &&
            v.position >= v.duration &&
            !v.isPlaying) {
          _completionReported = true;
          widget.coordinator.onPlaybackComplete(_id);
        }
      }

      _listenerRef = onUpdate;
      c.addListener(onUpdate);

      try {
        await c.initialize();
      } catch (_) {
        // Init failed (404, codec issue, etc.). Leave the thumbnail
        // visible — the coordinator will move on after its watchdog
        // timer fires.
        return;
      }
      // Guard: the widget may have been disposed (and c.dispose()
      // already called) while we were awaiting init.
      if (!mounted || _controller != c) return;
      await c.setVolume(0); // silent — Instagram does the same
      if (!mounted || _controller != c) return;
      // No loop. Each preview gets a single pass; coordinator advances
      // when it ends naturally OR when the timer expires (whichever first).
      await c.setLooping(false);
      if (!mounted || _controller != c) return;
      await c.play();
    } else {
      if (!mounted) return;
      _completionReported = false;
      await _controller!.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.challenge;
    final hasThumbnail =
        ch.thumbnailUrl != null && ch.thumbnailUrl!.isNotEmpty;
    final isBattle = ch.responseCount > 0;

    return VisibilityDetector(
      key: Key('preview_${ch.id}'),
      onVisibilityChanged: (info) {
        if (!mounted) return;
        widget.coordinator.report(_id, info.visibleFraction);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail (always present — instant tile content while video
            // buffers, and the only thing visible for non-active tiles).
            if (hasThumbnail)
              Image.network(
                ch.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _gradientBg(context),
              )
            else
              _gradientBg(context),

            // Live preview overlays the thumbnail when active. We bind
            // to the controller's value via ValueListenableBuilder so
            // the rebuild fires automatically the moment isInitialized
            // flips — no listener-and-flag dance. Positioned.fill +
            // ClipRect keep the painted texture strictly inside the
            // tile's bounds — without ClipRect, FittedBox(cover) on a
            // small grid cell with a large source video lets the
            // texture bleed into adjacent tiles (RenderFittedBox does
            // NOT clip its scaled child by default).
            if (_isActive && _controller != null)
              Positioned.fill(
                child: ClipRect(
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: _controller!,
                    builder: (context, value, _) {
                      if (!value.isInitialized) return const SizedBox.shrink();
                      return FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: value.size.width,
                          height: value.size.height,
                          child: VideoPlayer(_controller!),
                        ),
                      );
                    },
                  ),
                ),
              ),

            // Gradient scrim for text legibility.
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                  stops: const [0.4, 1.0],
                ),
              ),
            ),

            if (isBattle)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('VS',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800)),
                ),
              ),

            // Muted-while-previewing badge — gives users a visual cue this
            // is a silent preview, matching Instagram explore convention.
            // Placed bottom-right so it doesn't fight the VS badge for the
            // top-right corner.
            if (_isActive)
              const Positioned(
                bottom: 6,
                right: 6,
                child: _MutedBadge(),
              ),

            Positioned(
              bottom: 6,
              left: 6,
              child: Row(
                children: [
                  const Icon(Icons.play_arrow,
                      color: Colors.white, size: 14),
                  const SizedBox(width: 2),
                  Text(_formatCount(ch.views),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),

            Positioned(
              bottom: 22,
              left: 6,
              right: 6,
              child: Text(ch.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),

            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(ch.creatorUsername,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gradientBg(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.3),
            cs.secondary.withValues(alpha: 0.2),
          ],
        ),
      ),
    );
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

class _MutedBadge extends StatelessWidget {
  const _MutedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.volume_off, color: Colors.white, size: 11),
    );
  }
}
