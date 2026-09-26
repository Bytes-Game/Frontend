import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/blocked_users_page.dart';
import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/create_challenge_page.dart';
import 'package:myapp/pages/edit_profile_page.dart';
import 'package:myapp/pages/followers_page.dart';
import 'package:myapp/pages/following_page.dart';
import 'package:myapp/pages/free_up_space_page.dart';
import 'package:myapp/pages/liked_videos_page.dart';
import 'package:myapp/pages/notification_settings_page.dart';
import 'package:myapp/pages/preferences_pages.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/pages/two_factor_setup_page.dart';
import 'package:myapp/pages/watch_history_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/battle_record_panel.dart';
import 'package:myapp/widgets/battles_tab.dart';
import 'package:myapp/widgets/profile_arena_header.dart';
import 'package:myapp/widgets/scroll_reveal.dart';
import 'package:myapp/widgets/shimmer_loading.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// A profile built around the person's battles.
///
/// From the top, and moved by the scroll rather than by timers:
///   - an arena in their league's colours; the avatar shrinks into the top
///     bar as the page goes up, and the lights behind drift slower than the
///     page (see ArenaHeroHeader),
///   - who they are: stats, bio, and follow / message / challenge,
///   - their battle record: league, rating, how close the next league is,
///     wins, losses and draws, streak — tilting into place as it scrolls
///     into view (see ScrollReveal),
///   - tabs: Shorts (their videos), Open (challenges nobody has accepted
///     yet), Live (battles being voted on, with who is ahead), Won and Lost
///     — a lost battle says by how much and to whom, so there is something
///     to work on. Your own profile adds Liked and Saved.
///
/// [isEmbedded] = true  -> shown as a tab inside MainShell (no AppBar
///                         on the Scaffold — the SliverAppBar inside
///                         the NestedScrollView provides chrome).
/// [isEmbedded] = false -> pushed via Navigator (own Scaffold/AppBar).
class ProfilePage extends StatefulWidget {
  final UserModel user;
  final bool isEmbedded;

  const ProfilePage({
    super.key,
    required this.user,
    this.isEmbedded = true,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with PageTracker<ProfilePage>, SingleTickerProviderStateMixin {
  // ── Data ───────────────────────────────────────────────────────────
  List<Map<String, dynamic>> _savedChallenges = [];
  List<ChallengeModel> _myChallenges = [];
  bool _isLoadingSaved = false;
  bool _isLoadingMyChallenges = false;

  /// Their battle record, from the server. Until it arrives the page draws
  /// one from what the user model already carries.
  BattleRecord? _record;

  // ── Tabs ───────────────────────────────────────────────────────────
  late final TabController _tabs;

  @override
  String get pageName => 'profile_page';

  @override
  Map<String, dynamic> get pageParams {
    final dp = Provider.of<DataProvider>(context, listen: false);
    return {
      'profileUserId': widget.user.id,
      'isSelf': dp.user?.id == widget.user.id,
      'isEmbedded': widget.isEmbedded,
    };
  }

  @override
  void initState() {
    super.initState();
    final dp = Provider.of<DataProvider>(context, listen: false);
    final isOwn = dp.user?.id == widget.user.id;
    // Own profile has 3 tabs (Posts, Liked, Saved). Other profiles get
    // 2 — saved isn't anyone's business but the owner's. The tab count
    // has to match the children count in TabBarView so we branch here
    // and reuse the same controller across rebuilds.
    _tabs = TabController(length: isOwn ? 7 : 5, vsync: this);

    EventTracker.instance.trackProfileView(
      profileUserId: widget.user.id,
      isSelf: isOwn,
      source: widget.isEmbedded ? 'profile_tab' : 'navigation',
    );

    // Pull the canonical user from the server every time the profile
    // page opens. Catches the "edited via web, log into mobile, see
    // stale data" case AND the "logged out + back in, the /login
    // response was slow to propagate" edge case. Fire-and-forget —
    // the page renders with whatever's in DataProvider now, and
    // refreshUser notifies once the fetch lands so the header updates
    // in place when fresh data arrives.
    if (isOwn) {
      // ignore: discarded_futures
      dp.refreshUser();
    }

    _fetchMyChallenges();
    _fetchRecord();
    if (isOwn) _fetchSavedChallenges();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  // ── Network ────────────────────────────────────────────────────────

  Future<void> _fetchSavedChallenges() async {
    setState(() => _isLoadingSaved = true);
    final saved = await ApiService.getSavedChallenges(widget.user.id);
    if (mounted) {
      setState(() {
        _savedChallenges = saved;
        _isLoadingSaved = false;
      });
    }
  }

  Future<void> _fetchRecord() async {
    final page = await ApiService.getUserBattles(
        userId: widget.user.id, tab: 'live', limit: 1);
    if (mounted && page != null) setState(() => _record = page.record);
  }

  BattleRecord get _shownRecord =>
      _record ??
      BattleRecord(
        rating: widget.user.rating,
        league: widget.user.league,
        wins: widget.user.wins,
        losses: widget.user.losses,
        draws: widget.user.draws,
      );

  void _openBattle(String challengeId) {
    EventTracker.instance.trackTap(
      target: 'profile_open_battle_card',
      pageName: pageName,
      params: {'challengeId': challengeId, 'profileUserId': widget.user.id},
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChallengeDetailPage(challengeId: challengeId),
      ),
    );
  }

  Future<void> _fetchMyChallenges() async {
    setState(() => _isLoadingMyChallenges = true);
    final list = await ApiService.getUserChallenges(widget.user.id);
    if (mounted) {
      setState(() {
        _myChallenges = list;
        _isLoadingMyChallenges = false;
      });
    }
  }

  // ── Actions ────────────────────────────────────────────────────────

  /// Owner-only destructive action triggered by long-press on a grid
  /// tile. Confirms → cascade-deletes via backend → removes the
  /// challenge from the in-memory grid + bumps the global feed-refresh
  /// counter so home reels also drops it.
  Future<void> _confirmDeletePost(ChallengeModel c) async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final uid = dp.user?.id;
    if (uid == null) return;

    EventTracker.instance.trackTap(
      target: 'profile_post_delete_open_confirm',
      pageName: pageName,
      params: {'challengeId': c.id},
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete post?'),
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
      eventType: 'profile_post_delete_confirmed',
      contentId: c.id,
      contentType: 'challenge',
    );

    final ok = await ApiService.deleteChallenge(
      challengeId: c.id,
      userId: uid,
    );
    if (!mounted) return;
    if (!ok) {
      _toast('Could not delete. Try again.');
      return;
    }
    setState(() => _myChallenges.removeWhere((x) => x.id == c.id));
    dp.bumpFeedRefresh();
    _toast('Post deleted');
  }

  /// Open a challenge in the full-screen reels viewer (explore feed
  /// underneath as the continuation stream).
  void _openChallengeReels(ChallengeModel c) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final viewerId = dp.user?.id ?? '';
    EventTracker.instance.trackTap(
      target: 'profile_open_post',
      pageName: pageName,
      params: {
        'contentId': c.id,
        'contentType': 'challenge',
        'profileUserId': widget.user.id,
      },
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: SmartReelsFeed(
            userId: viewerId,
            kind: FeedKind.explore,
            seedChallenge: c,
          ),
        ),
      ),
    );
  }

  /// "Share profile" — copies the canonical profile URL to the
  /// clipboard. We use the clipboard rather than `share_plus` so we
  /// don't pull a new package in for one feature; once we ship
  /// share_plus for other surfaces this can be upgraded in place.
  Future<void> _shareProfile() async {
    final url = 'https://devf.app/u/${widget.user.username}';
    final text = '@${widget.user.username} on devf — $url';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    EventTracker.instance.trackTap(
      target: 'profile_share_copy_link',
      pageName: pageName,
      params: {'profileUserId': widget.user.id},
    );
    _toast('Profile link copied to clipboard');
  }

  void _openEditProfile() {
    EventTracker.instance.trackTap(
      target: 'profile_open_edit',
      pageName: pageName,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const EditProfilePage()),
    );
  }

  void _openFollowers() {
    EventTracker.instance.trackTap(
      target: 'profile_followers_stat',
      pageName: pageName,
      params: {'profileUserId': widget.user.id},
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FollowersPage(username: widget.user.username),
      ),
    );
  }

  void _openFollowing() {
    EventTracker.instance.trackTap(
      target: 'profile_following_stat',
      pageName: pageName,
      params: {'profileUserId': widget.user.id},
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FollowingPage(username: widget.user.username),
      ),
    );
  }

  // ── Settings & options sheet ──────────────────────────────────────

  void _showSettingsSheet() {
    EventTracker.instance.trackTap(
      target: 'settings_menu_open',
      pageName: pageName,
    );
    // Read the provider HERE, not inside the sheet's builder. The builder
    // captured this page's `context` and ran a provider lookup on every
    // rebuild of the sheet — and an inherited-widget lookup against an
    // element that is no longer mounted returns null, which Provider reports
    // as "Could not find the correct Provider<DataProvider> above this
    // ProfilePage Widget". That is the crash seen on device: the message
    // points at a missing provider, but the provider is installed above
    // MaterialApp and was never missing; the context had simply gone away.
    // Resolving the value up front means the sheet holds a plain bool and
    // cannot outlive anything.
    final twoFactorEnabled =
        Provider.of<DataProvider>(context, listen: false)
                .user
                ?.twoFactorEnabled ==
            true;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SettingsSheet(
        twoFactorEnabled: twoFactorEnabled,
        onEditProfile: () {
          Navigator.pop(ctx);
          _openEditProfile();
        },
        onShareProfile: () {
          Navigator.pop(ctx);
          _shareProfile();
        },
        onSaved: () {
          Navigator.pop(ctx);
          _tabs.animateTo(6); // Saved tab index
        },
        onHistory: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const WatchHistoryPage()),
          );
        },
        onLiked: () {
          Navigator.pop(ctx);
          _tabs.animateTo(5); // Liked tab
        },
        onNotifications: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const NotificationSettingsPage(),
            ),
          );
        },
        onPrivacy: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BlockedUsersPage()),
          );
        },
        onAppearance: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AppearancePage()),
          );
        },
        onLanguage: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LanguagePage()),
          );
        },
        onFreeUpSpace: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FreeUpSpacePage()),
          );
        },
        onTwoFactor: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TwoFactorSetupPage()),
          );
        },
        onHelp: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HelpCenterPage()),
          );
        },
        onReportBug: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const BugReportPage()),
          );
        },
        onTerms: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TermsOfServicePage()),
          );
        },
        onPrivacyPolicy: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
          );
        },
        onAbout: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AboutPage()),
          );
        },
        onLogout: () {
          Navigator.pop(ctx);
          Provider.of<AuthProvider>(context, listen: false)
              .logout(context);
        },
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  String _formatViews(int n) {
    if (n < 1000) return n.toString();
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
    return '${(n / 1000000).toStringAsFixed(n < 10000000 ? 1 : 0)}M';
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    final isOwn = dp.user?.id == widget.user.id;
    final isFollowing = dp.following.contains(widget.user.id);
    // Pushed as its own page, the arena runs up under the status bar and
    // leaves room for it; inside the main tabs a SafeArea already has.
    final topInset =
        widget.isEmbedded ? 0.0 : MediaQuery.paddingOf(context).top;
    final record = _shownRecord;
    ({IconData? icon, String label}) tab(IconData icon, String label,
        [String? countKey]) {
      final n = countKey == null ? 0 : (record.counts[countKey] ?? 0);
      return (icon: icon, label: n > 0 ? '$label $n' : label);
    }

    final body = NestedScrollView(
      headerSliverBuilder: (context, _) {
        return [
          // The arena: moves with the scroll. See ArenaHeroHeader.
          SliverPersistentHeader(
            pinned: true,
            delegate: ArenaHeroHeader(
              user: widget.user,
              record: record,
              topInset: topInset,
              leading: widget.isEmbedded ? null : const BackButton(),
              // Everything that used to be a row of buttons under the
              // stats lives up here as icons, so the page below is all
              // about the person.
              actions: [
                if (isOwn)
                  _barAction(Icons.edit_rounded, 'Edit profile',
                      _openEditProfile),
                _barAction(Icons.share_rounded, 'Share profile', _shareProfile),
                if (isOwn)
                  _barAction(Icons.settings_rounded, 'Settings',
                      _showSettingsSheet)
                else
                  _barAction(Icons.more_horiz_rounded, 'More',
                      () => _showOtherUserSheet(dp, isFollowing)),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: ScrollReveal(
              child: _ProfileHeader(
                user: widget.user,
                isOwn: isOwn,
                isFollowing: isFollowing,
                postsCount: _myChallenges.length,
                onTapFollowers: _openFollowers,
                onTapFollowing: _openFollowing,
                onEditProfile: _openEditProfile,
                onFollowToggle: () {
                  if (isFollowing) {
                    EventTracker.instance.trackFollowToggle(
                      targetUserId: widget.user.id,
                      becameFollowing: false,
                      fromPage: pageName,
                    );
                    dp.unfollowUser(widget.user);
                  } else {
                    EventTracker.instance.trackFollowToggle(
                      targetUserId: widget.user.id,
                      becameFollowing: true,
                      fromPage: pageName,
                    );
                    dp.followUser(widget.user);
                  }
                },
                onMessage: () {
                  EventTracker.instance.trackTap(
                    target: 'profile_open_dm',
                    pageName: pageName,
                    params: {'targetUserId': widget.user.id},
                  );
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatConversationPage(
                        otherUserId: widget.user.id,
                        otherUsername: widget.user.username,
                      ),
                    ),
                  );
                },
                onChallenge: () {
                  EventTracker.instance.trackTap(
                    target: 'profile_open_battle',
                    pageName: pageName,
                    params: {'targetUserId': widget.user.id},
                  );
                  // The create-challenge flow doesn't yet accept a
                  // pre-filled opponent — it lets the user open a
                  // challenge that anyone can respond to. We open the
                  // page directly; targeted-opponent deep-linking is a
                  // future task. Toast so the user knows.
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CreateChallengePage(),
                    ),
                  );
                },
                compact: _compact,
              ),
            ),
          ),
          // Their battle record, tilting into place as it scrolls in.
          SliverToBoxAdapter(
            child: ScrollReveal(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: BattleRecordPanel(record: record, isOwn: isOwn),
              ),
            ),
          ),
          // Pinned tabs. Sliver wrapper so it sticks to the top edge as the
          // user scrolls past the header.
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedTabBarDelegate(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ArenaPillTabs(
                  controller: _tabs,
                  scrollable: true,
                  tabs: [
                    tab(Icons.grid_view_rounded, 'Shorts'),
                    tab(Icons.flag_rounded, 'Open', 'open'),
                    tab(Icons.bolt_rounded, 'Live', 'live'),
                    tab(Icons.emoji_events_rounded, 'Won', 'won'),
                    tab(Icons.trending_down_rounded, 'Lost', 'lost'),
                    if (isOwn) tab(Icons.favorite_rounded, 'Liked'),
                    if (isOwn) tab(Icons.bookmark_rounded, 'Saved'),
                  ],
                ),
              ),
              height: 52,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
        ];
      },
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildPostsTab(isOwn: isOwn),
          for (final t in const ['open', 'live', 'won', 'lost'])
            BattlesTab(
              userId: widget.user.id,
              tab: t,
              isOwn: isOwn,
              onOpen: _openBattle,
            ),
          // Liked reads the signed-in person's likes, so it is only
          // meaningful on their own profile.
          if (isOwn) const LikedVideosPage(embedded: true),
          if (isOwn) _buildSavedTab(),
        ],
      ),
    );

    // When embedded in MainShell, MainShell's Scaffold forces a black
    // background (intentional for the home tab). Wrap in a Material
    // with the theme's scaffoldBackgroundColor so the profile owns its
    // own surface and text contrast is correct in both light and dark.
    if (widget.isEmbedded) {
      return Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(bottom: false, child: body),
      );
    }
    return Scaffold(body: body);
  }

  /// One round icon in the arena's top bar.
  Widget _barAction(IconData icon, String tooltip, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: IconBubble(
        icon: icon,
        tooltip: tooltip,
        size: 36,
        onTap: onTap,
      ),
    );
  }

  // ── Tab bodies ─────────────────────────────────────────────────────

  Widget _buildPostsTab({required bool isOwn}) {
    if (_isLoadingMyChallenges) {
      // SliverFillRemaining wrapper so the NestedScrollView still
      // coordinates header collapse over the shimmer.
      return const CustomScrollView(slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox(
            height: 200,
            child: ShimmerLoading(child: GridSkeleton()),
          ),
        ),
      ]);
    }
    if (_myChallenges.isEmpty) {
      return _EmptyTab(
        icon: Icons.videocam_outlined,
        title: isOwn ? 'No posts yet' : 'No posts',
        subtitle: isOwn
            ? 'Tap the + tab to post your first video.'
            : 'When @${widget.user.username} posts a video, it will appear here.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 9 / 16,
      ),
      itemCount: _myChallenges.length,
      itemBuilder: (_, i) {
        final c = _myChallenges[i];
        return _GridTile(
          thumbnailUrl: c.thumbnailUrl ?? '',
          overlayCount: c.views,
          overlayIcon: Icons.play_arrow_rounded,
          formatCount: _formatViews,
          onTap: () => _openChallengeReels(c),
          // Long-press is destructive for own posts only.
          onLongPress: isOwn ? () => _confirmDeletePost(c) : null,
          fallbackIcon: Icons.videocam_outlined,
        );
      },
    );
  }

  Widget _buildSavedTab() {
    if (_isLoadingSaved) {
      return const CustomScrollView(slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox(
            height: 200,
            child: ShimmerLoading(child: GridSkeleton()),
          ),
        ),
      ]);
    }
    if (_savedChallenges.isEmpty) {
      return const _EmptyTab(
        icon: Icons.bookmark_outline,
        title: 'No saved videos',
        subtitle: 'Tap the bookmark icon on any video to save it here.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 9 / 16,
      ),
      itemCount: _savedChallenges.length,
      itemBuilder: (_, i) {
        final c = _savedChallenges[i];
        final thumb = c['thumbnailUrl'] as String? ?? '';
        final title = '${c['prefix'] ?? ''} ${c['subject'] ?? ''}'.trim();
        return _GridTile(
          thumbnailUrl: thumb,
          captionOverlay: title,
          topRightIcon: Icons.bookmark,
          fallbackIcon: Icons.videocam_outlined,
          onTap: () => _toast(title.isNotEmpty ? title : 'Saved video'),
        );
      },
    );
  }

  /// Confirms + invokes the block flow on the currently-viewed user.
  /// On success: tears down the follow edge in both directions
  /// (handled server-side), removes the target from the local
  /// following list so the UI flips, and pops the profile page since
  /// you can't view a blocked user's profile content meaningfully.
  Future<void> _confirmAndBlock(DataProvider dp) async {
    final me = dp.user;
    if (me == null) return;
    final target = widget.user;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block @${target.username}?'),
        content: Text(
          'They won\'t be able to message you and you\'ll stop seeing '
          'their content. Any follow between you will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    EventTracker.instance.track(
      eventType: 'block',
      contentId: target.id,
      contentType: 'user',
    );

    final ok = await ApiService.blockUser(
      blockerId: me.id,
      blockedId: target.id,
    );
    if (!mounted) return;
    if (!ok) {
      _toast('Could not block. Try again.');
      return;
    }
    // Mirror the backend's follow-cleanup in local DataProvider state
    // so the Follow button on related surfaces flips immediately —
    // the server tore down both directions, so we drop the target
    // from `following`. We don't have a `followers` list locally to
    // mutate.
    if (dp.following.contains(target.id)) {
      await dp.unfollowUser(target);
    }
    if (!mounted) return;
    _toast('@${target.username} blocked');
    if (context.mounted && Navigator.canPop(context)) {
      Navigator.of(context).pop(true);
    }
  }

  // ── Other-user overflow sheet ─────────────────────────────────────

  void _showOtherUserSheet(DataProvider dp, bool isFollowing) {
    EventTracker.instance.trackTap(
      target: 'other_profile_menu_open',
      pageName: pageName,
      params: {'profileUserId': widget.user.id},
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetGrabber(),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share profile'),
              onTap: () {
                Navigator.pop(ctx);
                _shareProfile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Copy profile link'),
              onTap: () {
                Navigator.pop(ctx);
                _shareProfile();
              },
            ),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.block, color: Colors.redAccent),
              title: const Text(
                'Block',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                await _confirmAndBlock(dp);
              },
            ),
            ListTile(
              leading: const Icon(Icons.flag_outlined,
                  color: Colors.redAccent),
              title: const Text(
                'Report',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _toast(
                  'Use the report flow on a specific post for now.',
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────
// Header
// ────────────────────────────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final UserModel user;
  final bool isOwn;
  final bool isFollowing;
  final int postsCount;
  final VoidCallback onTapFollowers;
  final VoidCallback onTapFollowing;
  final VoidCallback onEditProfile;
  final VoidCallback onFollowToggle;
  final VoidCallback onMessage;
  final VoidCallback onChallenge;
  final String Function(int) compact;

  const _ProfileHeader({
    required this.user,
    required this.isOwn,
    required this.isFollowing,
    required this.postsCount,
    required this.onTapFollowers,
    required this.onTapFollowing,
    required this.onEditProfile,
    required this.onFollowToggle,
    required this.onMessage,
    required this.onChallenge,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space16,
        AppTheme.space16,
        AppTheme.space16,
        AppTheme.space16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Stats in one card across the full width. The avatar, name and
          // league are up in the arena, and wins and losses in the record
          // panel below.
          Container(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.space12),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  Expanded(
                    child: _StatPill(
                      value: compact(postsCount),
                      label: 'Videos',
                    ),
                  ),
                  _divider(cs),
                  Expanded(
                    child: _StatPill(
                      value: compact(user.followersCount),
                      label: 'Followers',
                      onTap: onTapFollowers,
                    ),
                  ),
                  _divider(cs),
                  Expanded(
                    child: _StatPill(
                      value: compact(user.followingCount),
                      label: 'Following',
                      onTap: onTapFollowing,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bio. Three states:
          //   * Non-empty → the bio text, on every profile.
          //   * Empty + own profile → a small "Add a bio" chip that opens
          //     the edit form.
          //   * Empty + other profile → nothing (no awkward dead row).
          if (user.bio.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, AppTheme.space12, 4, 0),
              child: Text(
                user.bio,
                textAlign: TextAlign.center,
                style: tt.bodyMedium,
              ),
            )
          else if (isOwn)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.space12),
              child: Center(
                child: Pressable(
                  onTap: onEditProfile,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, size: 17, color: kAccent),
                        SizedBox(width: 4),
                        Text(
                          'Add a bio',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: kAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Someone else's profile: follow, message, battle. Your own has
          // nothing here — edit, share and settings are icons in the bar.
          if (!isOwn) ...[
            const SizedBox(height: AppTheme.space12),
            _OtherActionRow(
              isFollowing: isFollowing,
              onFollowToggle: onFollowToggle,
              onMessage: onMessage,
              onChallenge: onChallenge,
            ),
          ],
        ],
      ),
    );
  }

  Widget _divider(ColorScheme cs) => VerticalDivider(
        width: 1,
        thickness: 1,
        indent: 6,
        endIndent: 6,
        color: cs.onSurface.withValues(alpha: 0.1),
      );
}

class _StatPill extends StatelessWidget {
  final String value;
  final String label;
  final VoidCallback? onTap;
  const _StatPill({
    required this.value,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final col = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
    if (onTap == null) return col;
    return Pressable(onTap: onTap, child: col);
  }
}

/// Follow as the one big button; message and battle as round icons beside
/// it, so the row says three things without three labels.
class _OtherActionRow extends StatelessWidget {
  final bool isFollowing;
  final VoidCallback onFollowToggle;
  final VoidCallback onMessage;
  final VoidCallback onChallenge;

  const _OtherActionRow({
    required this.isFollowing,
    required this.onFollowToggle,
    required this.onMessage,
    required this.onChallenge,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isFollowing
                ? Pressable(
                    key: const ValueKey('following'),
                    onTap: onFollowToggle,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: quietFill(context),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMd),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_rounded,
                              size: 18, color: cs.onSurface),
                          const SizedBox(width: 6),
                          Text(
                            'Following',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: cs.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : PrimaryButton(
                    key: const ValueKey('follow'),
                    label: 'Follow',
                    height: 44,
                    onPressed: onFollowToggle,
                  ),
          ),
        ),
        const SizedBox(width: AppTheme.space8),
        IconBubble(
          icon: Icons.chat_bubble_rounded,
          tooltip: 'Message',
          size: 44,
          onTap: onMessage,
        ),
        const SizedBox(width: AppTheme.space8),
        IconBubble(
          icon: Icons.bolt_rounded,
          tooltip: 'Challenge to a battle',
          size: 44,
          onTap: onChallenge,
        ),
      ],
    );
  }
}

// ────────────────────────────────────────────────────────────────────
// Tabs
// ────────────────────────────────────────────────────────────────────

/// Pins the tab strip to the top of the scroll once the header has gone
/// past, on the page's own background so nothing shows through it.
class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  final Color backgroundColor;

  _PinnedTabBarDelegate({
    required this.child,
    required this.height,
    required this.backgroundColor,
  });

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    // Fills exactly the height it promised. A child that came out shorter
    // (slimmer tabs, a different font) would otherwise leave the sliver
    // claiming space it does not paint, which Flutter rejects outright.
    return Material(
      color: backgroundColor,
      child: SizedBox.expand(child: Center(child: child)),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedTabBarDelegate oldDelegate) {
    return child != oldDelegate.child ||
        height != oldDelegate.height ||
        backgroundColor != oldDelegate.backgroundColor;
  }
}

/// Empty-state widget for a profile tab. Wraps in CustomScrollView +
/// SliverFillRemaining so that, when this empty state IS the tab body
/// inside NestedScrollView, the outer scroll-coordination machinery
/// can still drive header collapse — a bare Center would ignore drag
/// gestures on the body area.
class _EmptyTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _EmptyTab({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.space24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 48, color: quietText(context)),
                  const SizedBox(height: AppTheme.space16),
                  Text(
                    title,
                    style: tt.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppTheme.space4),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: tt.bodyMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GridTile extends StatelessWidget {
  final String thumbnailUrl;
  final IconData fallbackIcon;
  final int? overlayCount;
  final IconData? overlayIcon;
  final String Function(int)? formatCount;
  final String? captionOverlay;
  final IconData? topRightIcon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _GridTile({
    required this.thumbnailUrl,
    required this.fallbackIcon,
    this.overlayCount,
    this.overlayIcon,
    this.formatCount,
    this.captionOverlay,
    this.topRightIcon,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: 0.97,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailUrl.isNotEmpty)
              Image.network(
                thumbnailUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: cs.surfaceContainerHighest,
                  child: Icon(fallbackIcon,
                      color: cs.onSurfaceVariant, size: 28),
                ),
              )
            else
              Container(
                color: cs.surfaceContainerHighest,
                child: Icon(fallbackIcon,
                    color: cs.onSurfaceVariant, size: 28),
              ),
            if (topRightIcon != null)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(topRightIcon, color: Colors.white, size: 18),
              ),
            if (overlayCount != null && overlayCount! > 0)
              Positioned(
                bottom: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(overlayIcon ?? Icons.play_arrow_rounded,
                          color: Colors.white, size: 12),
                      const SizedBox(width: 2),
                      Text(
                        formatCount != null
                            ? formatCount!(overlayCount!)
                            : '$overlayCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (captionOverlay != null && captionOverlay!.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  color: Colors.black54,
                  child: Text(
                    captionOverlay!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────
// Settings sheet
// ────────────────────────────────────────────────────────────────────

/// Modal bottom sheet listing every account-level action for the
/// owner. Grouped into sections (Profile / Activity / Preferences /
/// Account / Support) so the option list reads as a settings menu,
/// not a dump.
///
/// Many entries are intentionally toasts-only — see the per-call-site
/// comments for the backend work needed to finish each one.
class _SettingsSheet extends StatelessWidget {
  final VoidCallback onEditProfile;
  final VoidCallback onShareProfile;
  final VoidCallback onSaved;
  final VoidCallback onLiked;
  final VoidCallback onHistory;
  final VoidCallback onNotifications;
  final VoidCallback onPrivacy;
  final VoidCallback onAppearance;
  final VoidCallback onLanguage;
  final VoidCallback onFreeUpSpace;
  final VoidCallback onTwoFactor;
  final VoidCallback onHelp;
  final VoidCallback onReportBug;
  final VoidCallback onTerms;
  final VoidCallback onPrivacyPolicy;
  final VoidCallback onAbout;
  final VoidCallback onLogout;
  /// Backend-truth: has the signed-in user enrolled in 2FA? Drives the
  /// "On" subtitle on the Two-step verification row.
  final bool twoFactorEnabled;

  const _SettingsSheet({
    required this.onEditProfile,
    required this.onShareProfile,
    required this.onSaved,
    required this.onLiked,
    required this.onHistory,
    required this.onNotifications,
    required this.onPrivacy,
    required this.onAppearance,
    required this.onLanguage,
    required this.onFreeUpSpace,
    required this.onTwoFactor,
    required this.onHelp,
    required this.onReportBug,
    required this.onTerms,
    required this.onPrivacyPolicy,
    required this.onAbout,
    required this.onLogout,
    required this.twoFactorEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scroll) {
        return Column(
          children: [
            const _SheetGrabber(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space20,
                vertical: AppTheme.space8,
              ),
              child: Row(
                children: [
                  Text(
                    'Settings & Privacy',
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 0),
            Expanded(
              child: ListView(
                controller: scroll,
                children: [
                  _section('Profile', cs),
                  _row(
                    Icons.person_outline,
                    'Edit profile',
                    'Username, name, bio, avatar',
                    onEditProfile,
                  ),
                  _row(
                    Icons.share_outlined,
                    'Share profile',
                    'Copy your profile link',
                    onShareProfile,
                  ),

                  _section('Activity', cs),
                  _row(
                    Icons.bookmark_border,
                    'Saved',
                    'Videos you bookmarked',
                    onSaved,
                  ),
                  _row(
                    Icons.favorite_border,
                    'Liked',
                    'Videos you tapped the heart on',
                    onLiked,
                  ),
                  _row(
                    Icons.history_rounded,
                    'Watch history',
                    'Reels you watched recently',
                    onHistory,
                  ),

                  _section('Preferences', cs),
                  _row(
                    Icons.notifications_outlined,
                    'Notifications',
                    'Push and in-app categories',
                    onNotifications,
                  ),
                  _row(
                    Icons.lock_outline,
                    'Privacy',
                    'Account visibility, blocked accounts',
                    onPrivacy,
                  ),
                  _row(
                    Icons.dark_mode_outlined,
                    'Appearance',
                    'Theme follows your system setting',
                    onAppearance,
                  ),
                  _row(
                    Icons.language_outlined,
                    'Language',
                    'English (default)',
                    onLanguage,
                  ),
                  _row(
                    Icons.cleaning_services_outlined,
                    'Free up space',
                    'Clear saved videos and leftover recordings',
                    onFreeUpSpace,
                  ),

                  _section('Account & security', cs),
                  _row(
                    Icons.shield_outlined,
                    'Two-step verification',
                    twoFactorEnabled
                        ? 'On — managed by an authenticator app'
                        : 'Add an extra layer to sign-in',
                    onTwoFactor,
                  ),
                  _row(
                    Icons.devices_other_outlined,
                    'Login activity',
                    'Where you\'re signed in',
                    () => _stub(context,
                        'Login activity needs session-token issuance + device-list endpoint.'),
                    badge: _BackendStubBadge.coming,
                  ),
                  _row(
                    Icons.account_balance_wallet_outlined,
                    'Personal information',
                    'Email, phone (not collected)',
                    () => _stub(context,
                        'We don\'t collect email or phone today. When we do, this surface manages them.'),
                    badge: _BackendStubBadge.coming,
                  ),

                  _section('Support', cs),
                  _row(
                    Icons.help_outline,
                    'Help center',
                    'Browse FAQs and guides',
                    onHelp,
                  ),
                  _row(
                    Icons.bug_report_outlined,
                    'Report a problem',
                    'Tell us what went wrong',
                    onReportBug,
                  ),
                  _row(
                    Icons.description_outlined,
                    'Terms of service',
                    '',
                    onTerms,
                  ),
                  _row(
                    Icons.privacy_tip_outlined,
                    'Privacy policy',
                    '',
                    onPrivacyPolicy,
                  ),
                  _row(
                    Icons.info_outline,
                    'About',
                    '',
                    onAbout,
                  ),
                  const Divider(),
                  _row(
                    Icons.logout,
                    'Log out',
                    '',
                    onLogout,
                    iconColor: cs.error,
                    textColor: cs.error,
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String title, ColorScheme cs) => Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space20,
          AppTheme.space16,
          AppTheme.space20,
          AppTheme.space4,
        ),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: cs.primary,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget _row(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap, {
    _BackendStubBadge? badge,
    Color? iconColor,
    Color? textColor,
  }) {
    return ListTile(
      // Each setting's icon sits in a small grey square, so the list reads
      // as a set of places to go rather than a wall of text.
      leading: Builder(
        builder: (context) => Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: (iconColor ?? Theme.of(context).colorScheme.onSurface)
                .withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: iconColor),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(color: textColor),
            ),
          ),
          if (badge != null) _BadgeChip(kind: badge),
        ],
      ),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right_rounded, size: 20),
      onTap: onTap,
    );
  }

  void _stub(BuildContext context, String message) {
    EventTracker.instance.trackTap(
      target: 'settings_stub_tapped',
      pageName: 'settings_sheet',
      params: {'message': message},
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

}

enum _BackendStubBadge { coming }

class _BadgeChip extends StatelessWidget {
  final _BackendStubBadge kind;
  const _BadgeChip({required this.kind});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: cs.tertiary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Soon',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: cs.tertiary,
        ),
      ),
    );
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
