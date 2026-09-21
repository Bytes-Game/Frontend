import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:video_player/video_player.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/network_quality_service.dart';
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

  // Monotonic search sequence — package:http can't abort an in-flight
  // request, so instead we DROP stale responses: fast typers fire
  // several debounced searches and the responses can land out of order,
  // which used to let an older query's results overwrite a newer one's.
  int _searchSeq = 0;

  // Server hints from the last search response (search_ctr.go):
  // _related = the results are a trending fallback for a zero-hit query;
  // _intent = "user" | "category:<x>" | "general" for section ordering.
  bool _related = false;
  // WHY the results are related rather than exact. "subjects" means these
  // videos really are about something near the query; "trending" means the
  // server gave up and showed what is popular. Saying "trending now" over a
  // genuine subject match tells the user the wrong thing about their results.
  String _relatedKind = '';
  // Subjects that go with the query, learned from which topics keep turning
  // up on the same videos. Tapping one searches it.
  List<String> _relatedSearches = const [];
  String _intent = 'general';

  // Empty-state suggestion rows (loaded once).
  List<String> _recentSearches = [];
  List<String> _trendingSearches = [];

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
    _loadSearchSuggestions();
  }

  Future<void> _loadSearchSuggestions() async {
    final recent = await ApiService.getRecentSearches();
    final trending = await ApiService.getTrendingSearches();
    if (mounted) {
      setState(() {
        _recentSearches = recent;
        _trendingSearches = trending;
      });
    }
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
  /// (jitters scores, demotes the previous refresh's top-3, resets session
  /// dedup) so the grid visibly changes.
  ///
  /// This request deliberately does NOT record impressions. A grid of 30
  /// thumbnails, refetched every time the tab is opened, is not evidence that
  /// the user watched 30 videos — and stamping them as watched is what let a
  /// couple of visits mark the entire catalog as seen, which then pushed every
  /// other feed surface onto already-watched content.
  Future<void> _loadExploreChallenges({bool refresh = false}) async {
    debugPrint('[search_page] _loadExploreChallenges(refresh: $refresh) fired');
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';
    final list = await ApiService.getExploreChallenges(
      userId, limit: 30, refresh: refresh, markShown: false);
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
    // 150ms: fast enough to feel instant while typing, slow enough that
    // a steady typist doesn't fire a request per keystroke.
    _debounce = Timer(const Duration(milliseconds: 150), () => _search(query));
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) return;
    setState(() => _loading = true);
    final start = DateTime.now();
    final seq = ++_searchSeq;

    // Pass the userId so the backend can apply personalization signals
    // (FoF boost on accounts, category-affinity on challenges, etc.).
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';

    final result = await ApiService.searchAll(query.trim(), userId: userId);
    // A newer search superseded this one while it was in flight — drop
    // this response entirely (results AND analytics).
    if (seq != _searchSeq) return;
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
        _related = result['related'] == true;
        _relatedKind = (result['relatedKind'] as String?) ?? '';
        _relatedSearches = ((result['relatedSearches'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        _intent = (result['intent'] as String?) ?? 'general';
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

    // ONE listener for the whole page, so every scrollable under it counts.
    //
    // Scroll notifications bubble UP, so a single listener here catches the
    // grid, the outer CustomScrollView and the tab views alike. Putting it
    // on the grid alone would miss the outer scroll, which moves the very
    // same tiles — and a preview coordinator that thinks the page is still
    // while it is moving is exactly the churn this is here to stop.
    //
    // This is what replaced a fixed 180ms delay. The framework already
    // knows when the list is moving; asking it costs nothing and, standing
    // still, a preview now opens with no wait at all.
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) {
          _previewCoord.setScrolling(true);
        } else if (n is ScrollEndNotification) {
          _previewCoord.setScrolling(false);
        }
        // Never swallow it: RefreshIndicator and the tab views are listening
        // for these too, and eating them would break pull-to-refresh.
        return false;
      },
      child: _buildScaffold(cs, showTabs),
    );
  }

  Widget _buildScaffold(ColorScheme cs, bool showTabs) {
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
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          if (_recentSearches.isNotEmpty || _trendingSearches.isNotEmpty)
            SliverToBoxAdapter(child: _suggestionRows()),
          SliverFillRemaining(
            hasScrollBody: true,
            child: _challengeGrid(_exploreChallenges, 'explore'),
          ),
        ],
      ),
    );
  }

  /// Recent (yours) + Trending (everyone's) query chips above the
  /// empty-state grid. Tapping one runs the search immediately — the
  /// classic TikTok/IG search entry pattern.
  Widget _suggestionRows() {
    Widget chipRow(String label, IconData icon, List<String> queries) {
      if (queries.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Icon(icon, size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 6,
                children: queries.take(6).map((q) {
                  return ActionChip(
                    label: Text(q, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      EventTracker.instance.trackTap(
                        target: 'search_suggestion_${label.toLowerCase()}',
                        pageName: pageName,
                        params: {'query': q},
                      );
                      _searchCtrl.text = q;
                      _search(q);
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        chipRow('Recent', Icons.history, _recentSearches),
        chipRow('Trending', Icons.trending_up, _trendingSearches),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── Top tab — interleaved best-of-everything ─────────────────────────
  // Only ever rendered after a search has been issued — empty-state goes
  // straight to _buildEmptyStateGrid so no tabs are shown before search.

  /// Says why these results are here when nothing matched the query exactly.
  ///
  /// Two different things used to share one message. A search for "aquarium"
  /// that finds the jellyfish video has genuinely answered the question, and
  /// telling the user those are "trending now" is simply untrue — it reads as
  /// the app not having understood, when it understood perfectly.
  Widget _rescueBanner() {
    final cs = Theme.of(context).colorScheme;
    // Three different things, and each is a different claim about the
    // results. Videos genuinely about something near the query are not the
    // same as popular videos, and neither is the same as "here is what people
    // uploaded most recently" — which is what comes back on a platform with no
    // traffic yet, where the trending list is empty. Calling those popular
    // would invent an engagement signal that does not exist.
    final aboutSubjects = _relatedKind == 'subjects';
    final recent = _relatedKind == 'recent';
    final String message;
    if (aboutSubjects) {
      message = 'Nothing named "$_lastQuery" — here is what is close:';
    } else if (recent) {
      message = 'Nothing for "$_lastQuery" — here is what is new:';
    } else {
      message = 'No exact matches for "$_lastQuery" — trending now:';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Row(
        children: [
          Icon(
              aboutSubjects
                  ? Icons.lightbulb_outline
                  : recent
                      ? Icons.schedule
                      : Icons.trending_up,
              size: 18,
              color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// Subjects that go with what was searched for.
  ///
  /// The server works these out from which topics keep turning up on the same
  /// videos, so they are things this app actually has — never a suggestion
  /// that leads to an empty page.
  Widget _relatedSearchChips() {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Related',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: _relatedSearches.take(5).map((q) {
              return ActionChip(
                label: Text(q, style: const TextStyle(fontSize: 12)),
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  EventTracker.instance.trackTap(
                    target: 'search_related_subject',
                    pageName: pageName,
                    params: {'query': q, 'from': _lastQuery},
                  );
                  _searchCtrl.text = q;
                  _search(q);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

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
            // Suggestions belong here most of all. Somebody who searched a
            // word this app does not have is exactly the person who needs to
            // be told what it does have — an empty page with no way forward
            // is where a search session ends.
            if (_relatedSearches.isNotEmpty) _relatedSearchChips(),
            SizedBox(
              height: MediaQuery.of(context).size.height *
                  (_relatedSearches.isEmpty ? 0.6 : 0.45),
              child: _emptyState(
                icon: Icons.search_off,
                label: 'No results for "$_lastQuery"',
              ),
            ),
          ],
        ),
      );
    }

    // Build the three sections separately so the server's intent hint can
    // order them: username-shaped queries lead with Accounts (default),
    // topic-shaped queries lead with content.
    final accountsSection = <Widget>[
      if (accountsHead.isNotEmpty) ...[
        _sectionHeader('Accounts', onSeeAll: () => _tabCtrl.animateTo(1)),
        ...accountsHead.asMap().entries.map((e) => _accountTile(e.value, e.key)),
      ],
    ];

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
        // Nothing matched exactly. Say WHICH kind of fallback this is —
        // videos genuinely about something near the query are not the same
        // as "here is what is popular", and calling both "trending" tells
        // the user the wrong thing about what they are looking at.
        if (_related) _rescueBanner(),
        // Subjects that go with the query. Tapping one searches it.
        if (_relatedSearches.isNotEmpty) _relatedSearchChips(),
        // Content-intent queries (intent = "category:x") lead with content;
        // everything else keeps Accounts first.
        if (!_intent.startsWith('category:')) ...accountsSection,
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
        // Content-intent ordering: accounts trail the content sections.
        if (_intent.startsWith('category:')) ...accountsSection,
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

  /// Whether a preview may open RIGHT NOW, or has to wait for the finger.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// STARTING A PREVIEW IS EXPENSIVE. SCROLLING USED TO DO IT PER FRAME.
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// Every tile reports its visibility on every frame it moves, and the rule
  /// below is "switch to whoever is most visible, immediately". So a fast
  /// flick down the grid handed the active slot to tile after tile, and each
  /// handover opened a hardware video decoder and threw the previous one
  /// away — several times a second, for videos nobody saw a frame of.
  ///
  /// A device log shows what that costs. Eight separate decoders logged
  /// "sending message to a Handler on a dead thread", which is a decoder
  /// still reporting back after the thread it belonged to was torn down —
  /// the signature of being disposed mid-startup. The two biggest bursts,
  /// twenty warnings between them, land immediately after the search grid
  /// appears. The system also took decoders back off the app five times
  /// ("Released by resource manager"), which it only does when too many are
  /// held at once.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// AND THE ANSWER IS NOT A DELAY
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// The first attempt waited a fixed 180ms after the last visibility report
  /// before opening anything. It stopped the churn and it was the wrong fix:
  /// it charged EVERY viewer a fifth of a second, including the one who was
  /// not scrolling at all, to solve a problem that only exists while the
  /// finger is moving. A fixed delay is a guess at the thing the framework
  /// will simply tell you.
  ///
  /// So ask instead. Flutter announces when a list starts and stops moving,
  /// and [setScrolling] passes that through. Standing still, a preview opens
  /// the instant it is picked — no timer, no wait. Mid-flick, the pick is
  /// remembered and opened the moment the list comes to rest.
  ///
  /// Twenty tiles flicked past now cost one decoder instead of twenty, and
  /// somebody who simply stops scrolling waits for nothing at all.
  bool _isScrolling = false;

  /// The tile to open as soon as the grid stops. Only used while scrolling.
  String? _pendingActive;

  /// Last-resort timer, and it should never be the thing that fires.
  ///
  /// [setScrolling] is what normally opens the pending preview, at the exact
  /// moment the list stops. This exists for the case where that notification
  /// never arrives — a scroll cancelled by a route change, a platform quirk,
  /// a gesture stolen mid-flick. Without it a lost end-of-scroll would mean
  /// the grid never plays anything again, which reads as a dead page rather
  /// than a slow one, and that is a far worse failure than the churn.
  ///
  /// Deliberately long. It is a safety net, not a policy: if it is firing
  /// often, the scroll notifications are not arriving and THAT is the bug.
  static const Duration _kScrollLost = Duration(milliseconds: 600);
  Timer? _settleTimer;

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

  /// tileId -> what that tile would play. Kept so the coordinator can warm
  /// the ones about to take a turn; see [_warmVisible].
  final Map<String, String> _urls = {};

  /// Tile reports its visibility. The coordinator picks/repicks the active
  /// tile and notifies listeners only when the active id changes.
  void report(String tileId, double fraction, {String url = ''}) {
    if (fraction <= 0.01) {
      _fractions.remove(tileId);
      _urls.remove(tileId);
    } else {
      _fractions[tileId] = fraction;
      if (url.isNotEmpty) _urls[tileId] = url;
    }
    _maybePick();
    _warmVisible();
  }

  /// How many previews ahead to fetch the opening bytes for.
  ///
  /// Three. Previews take turns rather than being swiped through, so the
  /// order is known and shallow depth is enough — and the same measurement
  /// that set the feed's window applies: bytes spent ahead are bytes the
  /// preview playing right now does not get.
  static const int _warmAhead = 3;

  /// The last list handed to the cache, so an unchanged one is not handed
  /// over again. See [_warmVisible].
  List<String> _lastWarmed = const [];

  /// Ask the cache for the opening bytes of the previews about to play.
  ///
  /// Without this the grid was starting every preview against the network
  /// from byte zero. The feed has not done that for a while; this page was
  /// never connected to any of it.
  ///
  /// Ordered by how visible each tile is, so the one about to take its turn
  /// is first in the queue rather than behind two the user is scrolling past.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// AND ONLY WHEN THE LIST ACTUALLY CHANGES
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// [report] fires continuously while a finger is moving — every tile, every
  /// frame. warm() cancels whatever has dropped out of the list it is given,
  /// so calling it on every one of those reports cancels and restarts the
  /// same downloads over and over. Measured on device, before and after this
  /// guard was missing:
  ///
  ///	before the grid warmed at all   80% of starts warm   1 of 32 cancelled
  ///	warming on every report         50% of starts warm  17 of 33 cancelled
  ///
  /// Warming made it WORSE than not warming. The fetches never got far
  /// enough to be worth anything, and they took the bandwidth from the
  /// preview that was playing.
  ///
  /// Visibility changes constantly; the ranked list of three does not. So the
  /// list is the trigger, not the report.
  void _warmVisible() {
    final ranked = _fractions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final urls = <String>[];
    for (final e in ranked) {
      final u = _urls[e.key];
      if (u == null || u.isEmpty) continue;
      urls.add(u);
      if (urls.length >= _warmAhead) break;
    }
    if (urls.isEmpty) return;
    if (_sameList(urls, _lastWarmed)) return;
    _lastWarmed = urls;
    VideoCacheService.instance.warm(urls);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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
      _wantActive(null);
      return;
    }

    // First-time activation: pick whatever's most visible and start
    // a fresh cycle.
    if (_activeId == null) {
      _consumedThisCycle.clear();
      _wantActive(mostVisible);
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
      _wantActive(mostVisible);
      return;
    }

    // Active tile scrolled completely out — pick a fresh one even if
    // hysteresis would otherwise hold.
    if (!_fractions.containsKey(_activeId)) {
      _wantActive(mostVisible);
    }
  }

  /// Open now if the grid is still; otherwise remember it for the moment it
  /// stops. See [_isScrolling].
  void _wantActive(String? id) {
    // Stopping is always immediate, scrolling or not. It hands a decoder
    // back, which is the scarce thing here — there is nothing to protect by
    // delaying it.
    if (id == null) {
      _cancelSettle();
      _setActive(null);
      return;
    }
    // Already playing it.
    if (id == _activeId) {
      _cancelSettle();
      return;
    }
    // THE COMMON CASE: nobody is scrolling, so there is nothing to wait for.
    // No timer is even created.
    if (!_isScrolling) {
      _cancelSettle();
      _setActive(id);
      return;
    }
    // Mid-scroll. Remember it; setScrolling(false) will open it the instant
    // the list stops.
    _pendingActive = id;
    // Arm the safety net once, and do NOT push it further away on every
    // frame — a flick that keeps reporting would otherwise keep resetting
    // the one thing that can recover a lost end-of-scroll.
    _settleTimer ??= Timer(_kScrollLost, _openPending);
  }

  /// Called by the page when the grid starts or stops moving.
  void setScrolling(bool scrolling) {
    if (scrolling == _isScrolling) return;
    _isScrolling = scrolling;
    if (!scrolling) {
      // The list has come to rest. Open what we chose, right now.
      _openPending();
    }
  }

  void _openPending() {
    _settleTimer?.cancel();
    _settleTimer = null;
    final want = _pendingActive;
    _pendingActive = null;
    if (want != null && want != _activeId) _setActive(want);
  }

  void _cancelSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _pendingActive = null;
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
    _cancelSettle();
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
    _cancelSettle();
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
    // Same job as going inactive: give the decoder back. One copy of that
    // code, so the two paths cannot drift apart.
    _releasePlayer();
    super.dispose();
  }

  void _onCoordinatorChanged() {
    final shouldBeActive = widget.coordinator.activeId == _id;
    if (shouldBeActive == _isActive) return;
    _isActive = shouldBeActive;
    if (_isActive) {
      _ensurePlayerAndPlay();
    } else {
      // Let the decoder GO, not just stop.
      //
      // ══════════════════════════════════════════════════════════════════
      // THIS TILE USED TO KEEP ITS HARDWARE DECODER FOR EVER
      // ══════════════════════════════════════════════════════════════════
      //
      // It paused, which stops playback and keeps everything else: the
      // controller, and with it one of the phone's video decoders. The
      // controller was only let go when the WIDGET was disposed, and a grid
      // keeps tiles alive well past the edge of the screen.
      //
      // The coordinator gives every visible tile a turn. So every tile that
      // had ever taken one held a decoder, and they piled up. From a device
      // log:
      //
      //   video decoders created over the session : 112
      //   PEAK alive at the same time             :  16
      //   still alive at the end                  :  15
      //
      // The feed's pool is capped at FOUR, deliberately, because that is
      // what the screen needs and what the hardware is comfortable with.
      // This page had no cap at all.
      //
      // What sixteen looks like in the same log: 71 "codec sleep" events,
      // where the chip powers down a decoder it thinks is idle, and nine
      // outright "Decoder failed: c2.mtk.avc.decoder" crashes when one was
      // asked to wake up again. Three quarters of all decoders were
      // rendering slower than 100ms a frame; a quarter slower than three
      // SECONDS a frame. They were starving each other.
      //
      // Exactly one preview plays at a time — the coordinator guarantees
      // it — so exactly one decoder is needed for the whole grid.
      //
      // The cost is rebuilding the player if this tile takes another turn.
      // That is a fraction of a second, against a page where nothing plays
      // at all.
      _releasePlayer();
    }
    if (mounted) setState(() {});
  }

  /// What this preview should actually stream.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// IT WAS STREAMING THE RAW UPLOAD
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// [ChallengeModel.videoUrl] is the file the phone sent, before the server
  /// re-encoded it. The feed has never played that — it picks a rendition
  /// sized for the connection. This grid played the original, and the
  /// difference is not small. Measured across ten videos in this app:
  ///
  ///   video 43     1.0 MB raw     1.0 MB chosen     same
  ///   video 48     3.6 MB raw     2.0 MB chosen     1.8x
  ///   video 49    13.9 MB raw     2.4 MB chosen     5.8x
  ///   video 38    57.8 MB raw     4.5 MB chosen    12.9x
  ///
  /// On the link this app actually sees, 2 to 4 Mbps, 57 MB is not a video
  /// that plays. That is "every video on the search page sticks".
  ///
  /// Two lines, both reusing what the feed already does: pick the rendition
  /// the measured connection can carry, then ask the cache whether it is
  /// already holding the opening bytes.
  ///
  /// Note this deliberately does NOT route through VideoPlayerService. The
  /// comment below explains why — it is about the shared pool's volume
  /// handling, and it still stands. The cache is a different thing: it
  /// answers "which bytes", not "which player", and has no opinion on audio.
  /// A preview plays the ORIGIN, not the cache's loopback address.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// THE GRID USED TO PAY FOR ITS HEAD START AND THEN THROW IT AWAY
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// _warmVisible downloads the opening of every visible preview onto the
  /// phone. Then this played the ORIGIN url, so the player went to the
  /// network and downloaded those same bytes a second time. The grid paid
  /// for the head start twice and used it never. That is exactly what "the
  /// preview sticks for a few seconds and then plays" is: the bytes are
  /// already on the disk, and the tile is waiting for the network to send
  /// them again.
  ///
  /// It DID go through the proxy for one build, and previews stopped playing
  /// altogether. That was blamed on the proxy at the time, with the honest
  /// note that it could not be proved. It has since been proved to be
  /// something else: the grid was holding fifteen of the phone's video
  /// decoders, and there were none left to open anything with. With that
  /// fixed the same device log shows 93 decoders asked for and 93 granted,
  /// and not one playback failure. The proxy was not the cause.
  ///
  /// Belt and braces anyway: if a proxied open fails, _ensurePlayerAndPlay
  /// retries the same tile on the origin url. A preview can now be slow, but
  /// it cannot go back to not playing at all.
  String _previewUrl() =>
      VideoCacheService.instance.playbackUrlFor(_originUrl());


  /// The same choice, before the cache is asked about it.
  ///
  /// Warming is keyed by the ORIGIN url — that is the name the cache files
  /// bytes under. Handing it the proxy address instead would store them
  /// under something nothing ever looks up: a warm that costs the bandwidth
  /// and helps nobody.
  ///
  /// So [_previewUrl] is built FROM this rather than repeating the choice.
  /// Two copies of "which rendition" could disagree, and then the tile would
  /// warm one file and play another.
  String? _origin;

  /// Enough of a url to tell which file failed, without filling the log
  /// with query strings and hashes.
  static String _shortUrl(String u) {
    final i = u.indexOf('/hls/');
    if (i > -1) return u.substring(i);
    return u.length > 60 ? '...${u.substring(u.length - 60)}' : u;
  }

  String _originUrl() {
    // Worked out once per tile. This is called from the visibility report,
    // which fires every frame a finger is moving, and the picker is not
    // free — it reads device capabilities and walks a preference order, and
    // it counts every answer for the diagnostics. On one scroll through the
    // grid it was called four hundred times and gave the same answer each
    // time.
    //
    // A tile is short-lived, so a connection that changes mid-scroll is
    // picked up by the tiles built after it.
    final cached = _origin;
    if (cached != null) return cached;
    final c = widget.challenge;
    final picked = NetworkQualityService.instance.pickVariantUrl(c.videoVariants);
    final chosen = (picked != null && picked.isNotEmpty) ? picked : c.videoUrl;
    _origin = chosen;
    return chosen;
  }

  /// Hand back the decoder. The poster is what the tile shows without one.
  void _releasePlayer() {
    final c = _controller;
    if (c == null) return;
    final ref = _listenerRef;
    _controller = null;
    _listenerRef = null;
    _completionReported = false;
    if (ref != null) c.removeListener(ref);
    ReelDiagnostics.instance.recordPreviewReleased();
    // ignore: discarded_futures
    c.dispose();
  }

  Future<void> _ensurePlayerAndPlay() async {
    await _openAndPlay(_previewUrl());
  }

  /// Open [url] and start it, falling back to the origin once if the
  /// cache's loopback address will not open.
  ///
  /// The fallback is the whole reason previews can be routed through the
  /// proxy at all. A proxied open that fails used to mean the tile showed
  /// nothing, for ever — the page looked broken rather than slow, and it
  /// took two rounds of diagnosis to tell those apart. Now the worst a bad
  /// proxy can do is cost one open and put a line in the log.
  Future<void> _openAndPlay(String url) async {
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
      // Counted so a log can say whether the grid or the feed is holding
      // the phone's decoders. See ReelDiagnostics.recordPreviewOpened.
      ReelDiagnostics.instance.recordPreviewOpened();

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
      } catch (e) {
        // Init failed (404, codec issue, etc.). Leave the thumbnail
        // visible — the coordinator will move on after its watchdog
        // timer fires.
        //
        // SAY SO. This used to swallow the reason entirely, and a page
        // where every preview fails looked exactly like a page where every
        // preview was slow: no error, no log line, nothing to tell the two
        // apart. A whole round of diagnosis went into guessing at it.
        ReelDiagnostics.instance
            .log('search preview failed to open ${_shortUrl(url)}: $e');
        // Hand the decoder back before trying again, or the retry competes
        // with the player that just failed for one of the few decoders the
        // phone has.
        _releasePlayer();
        final origin = _originUrl();
        if (url != origin && mounted && _isActive) {
          ReelDiagnostics.instance
              .log('search preview retrying from origin ${_shortUrl(origin)}');
          await _openAndPlay(origin);
        }
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
        widget.coordinator.report(_id, info.visibleFraction, url: _originUrl());
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
