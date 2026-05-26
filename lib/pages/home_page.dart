import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// Full-screen TikTok-style home: video plays edge-to-edge, top filters
/// (For You / Following / Explore) and a single right-side notifications
/// icon float as translucent overlays on top of the reel. Messages and
/// the Create-challenge action both live in the bottom NavigationBar now,
/// not up here.
///
/// Each tab uses a meaningfully different ranking algorithm:
///
///   For You    → /api/v1/feed/smart      personalized + ML pipeline
///                (cohort weights, LTR, two-tower embeddings, MMR,
///                 anti-loop, bandit, hour-routing — all the peaks)
///   Following  → /api/v1/feed/following/v2  zero algorithm; chronological
///                from accounts the user follows. No ranking, just newest.
///   Explore    → /api/v1/feed/explore    discovery-first; non-personalized.
///                Trending-realtime + recent only, aggressive MMR (λ=0.40),
///                always-on wildcard injection. Designed for breadth, not
///                engagement maximization.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin, PageTracker<HomePage> {
  late TabController _tabController;
  int _lastTabIndex = 0;
  static const _tabLabels = ['For You', 'Following', 'Explore'];

  @override
  String get pageName => 'home_page';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabLabels.length, vsync: this);
    _tabController.addListener(_onHomeTabChanged);
  }

  void _onHomeTabChanged() {
    if (_tabController.indexIsChanging) return;
    final idx = _tabController.index;
    if (idx == _lastTabIndex) return;
    EventTracker.instance.trackTabSwitch(
      fromIndex: _lastTabIndex,
      toIndex: idx,
      fromLabel: _tabLabels[_lastTabIndex],
      toLabel: _tabLabels[idx],
    );
    _lastTabIndex = idx;
  }

  @override
  void dispose() {
    _tabController.removeListener(_onHomeTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';

    // Edge-to-edge: no AppBar, video fills the entire screen including the
    // status-bar area. The top overlay sits inside SafeArea so text/buttons
    // don't collide with the notch / camera cutout.
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // —— Video layer (full screen) ——
          TabBarView(
            controller: _tabController,
            children: [
              SmartReelsFeed(userId: userId, kind: FeedKind.forYou),
              SmartReelsFeed(userId: userId, kind: FeedKind.following),
              SmartReelsFeed(userId: userId, kind: FeedKind.explore),
            ],
          ),

          // —— Top overlay: floating tab strip + action icons ——
          // Pinned to the top of the safe area. Without an explicit Align
          // here the Row would vertical-center inside the Stack and the
          // controls would appear in the middle of the screen.
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, left: 8, right: 8),
                child: Row(
                  children: [
                    // Left spacer balances the right-side icon so the tab
                    // strip stays visually centered.
                    const SizedBox(width: 40),
                    Expanded(
                      child: _TopTabStrip(
                        controller: _tabController,
                        labels: _tabLabels,
                      ),
                    ),
                    _TopActionIcons(
                      onNotificationsTap: () {
                        EventTracker.instance.trackTap(
                          target: 'home_notifications_icon',
                          pageName: 'home_page',
                          params: {'unreadCount': dp.unreadNotifications},
                        );
                        dp.clearUnreadNotifications();
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const NotificationsPage()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Top filter tabs floating over the reel — text-only, no underline drawn
/// on the AppBar (because there is no AppBar). Active tab is bold + brighter;
/// inactive tabs are faded white. A small dot under the active label hints
/// at the indicator without the visual weight of a full underline.
class _TopTabStrip extends StatefulWidget {
  final TabController controller;
  final List<String> labels;
  const _TopTabStrip({required this.controller, required this.labels});

  @override
  State<_TopTabStrip> createState() => _TopTabStripState();
}

class _TopTabStripState extends State<_TopTabStrip> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.labels.length, (i) {
        final active = widget.controller.index == i;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.controller.animateTo(i),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.labels[i],
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white60,
                    fontSize: 16,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    shadows: const [
                      Shadow(blurRadius: 6, color: Colors.black54),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 3,
                  width: active ? 22 : 0,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// Right-side single notification icon floating over the reel, with an
/// unread-count badge. Soft shadow keeps it legible over any video frame.
/// (Messages and Create both live in the bottom NavigationBar, not up here.)
class _TopActionIcons extends StatelessWidget {
  final VoidCallback onNotificationsTap;

  const _TopActionIcons({required this.onNotificationsTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<DataProvider>(
      builder: (context, dp, _) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            _OverlayIconButton(
              icon: Icons.favorite_border_rounded,
              tooltip: 'Notifications',
              onTap: onNotificationsTap,
            ),
            if (dp.unreadNotifications > 0)
              Positioned(
                top: 6,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.redAccent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.black54, width: 1),
                  ),
                  constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                  child: Text(
                    dp.unreadNotifications > 9 ? '9+' : '${dp.unreadNotifications}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Translucent floating icon button — designed to sit over the reel video
/// without an opaque background. Drop shadow on the icon keeps it legible
/// over bright frames.
class _OverlayIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _OverlayIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(
          icon,
          color: Colors.white,
          size: 26,
          shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
        ),
        onPressed: onTap,
        splashRadius: 22,
      ),
    );
  }
}
