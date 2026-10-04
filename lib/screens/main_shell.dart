import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/profile_cache.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/pages/home_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/services/create_flow.dart';
import 'package:myapp/widgets/create_burst.dart';

/// Root shell — 5-slot bottom nav using standard Material 3 NavigationBar.
/// 0 - Home      (TikTok-style reels: challenges + unaccepted-as-shorts mix)
/// 1 - Messages  (chat list)
/// 2 - Create    (NOT a tab — the "+" opens the Create pop-out on top of
///                whatever tab is active: tap it, or hold it and slide to
///                Record or Upload. Selecting it never updates
///                _currentIndex.)
/// 3 - Search
/// 4 - Profile
///
/// The center "+" follows the TikTok / Instagram convention: it's a colored
/// pill that reads as a primary action rather than another navigation tab,
/// so users immediately understand it does something different.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  // Index 2 is the create-challenge action, intentionally not a tab. The
  // labels list still has an entry there so EventTracker logging stays
  // index-aligned with the destinations list below.
  static const _tabLabels = ['Home', 'Messages', 'Create', 'Search', 'Profile'];
  static const _createIndex = 2;

  /// The + button, so the pop-out can open exactly where it is.
  final _plusKey = GlobalKey();

  /// Bumped when Home is tapped while Home is already showing: the feed on
  /// screen goes back to the top with fresh videos.
  final _homeTappedAgain = ValueNotifier<int>(0);
  final _searchTappedAgain = ValueNotifier<int>(0);
  CreateBurstHandle? _burst;

  /// Fetches Search's videos in the background, once Home has had its
  /// turn. See [prefetchDelay].
  Timer? _searchPrefetch;

  /// How long after the app opens Search's videos are fetched. Home is
  /// what is on screen, and its first videos come first: this waits until
  /// they have had the connection to themselves.
  static const prefetchDelay = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    // Initial tab = home — fire a page_view so the session starts with a
    // known surface context.
    EventTracker.instance.trackPageView(
      pageName: 'home_tab',
      params: {'tabIndex': 0, 'tabLabel': _tabLabels[0]},
    );
    // Get Search's grid ready before anyone opens it, so the first visit
    // opens on videos instead of waiting for the server.
    _searchPrefetch = Timer(prefetchDelay, () {
      if (!mounted) return;
      final dp = Provider.of<DataProvider>(context, listen: false);
      unawaited(
        ExploreGridCache.instance.prefetch(context, dp.user?.id ?? ''),
      );
      // And your own profile, so opening it is instant too.
      unawaited(ProfileCache.instance.prefetch(context, dp.user?.id ?? ''));
      // And your chats, so Messages is up to date when it opens.
      unawaited(ChatCache.instance.prefetch(dp.user?.id ?? ''));
    });
  }

  @override
  void dispose() {
    _searchPrefetch?.cancel();
    _homeTappedAgain.dispose();
    _searchTappedAgain.dispose();
    super.dispose();
  }

  void _onDestination(int index) {
    // The center "+" is not a tab — it's a launcher. Tapping it opens the
    // Create pop-out over the current tab and leaves _currentIndex
    // untouched, so closing it lands back on whatever tab they were on.
    if (index == _createIndex) {
      _openBurst(fromHold: false);
      return;
    }

    if (index == _currentIndex) {
      // Home again, on Home: refresh it, as TikTok and Instagram do. The
      // same for Search.
      if (index == 0) _homeTappedAgain.value++;
      if (index == 3) _searchTappedAgain.value++;
      return;
    }
    final from = _currentIndex;
    // Kill the reels feed audio BEFORE we rebuild — the dispose chain
    // on SmartReelsFeed pauses players via release(url) but that
    // races with the new tab's first frame, leaving an audible "tail"
    // of whatever was playing. pauseAll() here is synchronous and
    // happens before setState fires, so the audio cuts the moment
    // the user taps another tab.
    //
    // Cheap to call when leaving a non-home tab too — pauseAll
    // iterates the (small) pool and skips any player that's already
    // paused.
    VideoPlayerService.instance.pauseAll();
    EventTracker.instance.trackTabSwitch(
      fromIndex: from,
      toIndex: index,
      fromLabel: _tabLabels[from],
      toLabel: _tabLabels[index],
    );
    setState(() => _currentIndex = index);
  }

  /// Open the Create pop-out over the + button. From a hold, the finger
  /// that is still down keeps steering it: see the pill's gesture below.
  void _openBurst({required bool fromHold}) {
    if (_burst != null && !_burst!.isClosed) return;
    // Mute the reels feed while the pop-out sits on top — the home tab is
    // still mounted underneath, but nobody is watching it. Whether it was
    // playing is kept, so it can start again when the pop-out closes, or
    // when recording or uploading is over: nothing used to, and the video
    // behind stayed stopped.
    final wasPlaying = VideoPlayerService.instance.activeIsPlaying;
    VideoPlayerService.instance.pauseAll();
    EventTracker.instance.trackTap(
      target: 'nav_create_challenge',
      pageName: '${_tabLabels[_currentIndex].toLowerCase()}_tab',
      params: {'how': fromHold ? 'hold' : 'tap'},
    );
    final box = _plusKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? Offset(MediaQuery.sizeOf(context).width / 2,
            MediaQuery.sizeOf(context).height - 40)
        : box.localToGlobal(box.size.center(Offset.zero));
    _burst = CreateBurst.show(
      context,
      anchor: anchor,
      fromHold: fromHold,
      onChoose: (choice) async {
        if (!mounted) return;
        // Even if recording or uploading fails part-way, the video behind
        // starts again when the person is back here.
        try {
          switch (choice) {
            case CreateChoice.record:
              await CreateFlow.record(context, from: 'create_burst');
            case CreateChoice.upload:
              await CreateFlow.upload(context, from: 'create_burst');
            case CreateChoice.photo:
              await CreateFlow.photo(context, from: 'create_burst');
          }
        } finally {
          _resumeIf(wasPlaying);
        }
      },
      onDismiss: () => _resumeIf(wasPlaying),
    );
  }

  /// Start the video that was playing before the pop-out covered it.
  void _resumeIf(bool wasPlaying) {
    if (!mounted || !wasPlaying) return;
    // ignore: discarded_futures
    VideoPlayerService.instance.resumeActive();
  }

  /// The + itself. A tap goes through the bar and opens the pop-out; a
  /// hold opens it at once and then follows the finger, so sliding onto
  /// Record or Upload and letting go picks it in one movement.
  Widget get _createPill => GestureDetector(
        key: _plusKey,
        onLongPressStart: (_) {
          HapticFeedback.mediumImpact();
          _openBurst(fromHold: true);
        },
        onLongPressMoveUpdate: (d) => _burst?.pointerMoved(d.globalPosition),
        onLongPressEnd: (d) => _burst?.pointerReleased(d.globalPosition),
        child: const _CreatePill(),
      );

  Widget _body() {
    final dp = Provider.of<DataProvider>(context, listen: false);
    // Index 2 is the create-action launcher and never owns the body — only
    // the four real tabs do.
    switch (_currentIndex) {
      case 0:
        return HomePage(tappedAgain: _homeTappedAgain);
      case 1:
        return const ChatListPage();
      case 3:
        return SearchPage(tappedAgain: _searchTappedAgain);
      case 4:
        return ProfilePage(user: dp.user!);
      default:
        return HomePage(tappedAgain: _homeTappedAgain);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Whole shell sits on a black backdrop so the nav bar reads as part
      // of the dark TikTok-style chrome rather than a stark light strip.
      backgroundColor: Colors.black,
      body: _body(),
      // Dark NavigationBar, TikTok-styled. White-on-black icons + labels
      // with a subtle indicator pill behind the active destination so the
      // selection still reads at a glance against the dark background.
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          // No pill behind the chosen tab: it is simply white, the others
          // grey, the way an iPhone's tab bar says where you are.
          indicatorColor: Colors.transparent,
          height: 60,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return TextStyle(
              color: active ? Colors.white : const Color(0xFF8E8E93),
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return IconThemeData(
              color: active ? Colors.white : const Color(0xFF8E8E93),
              size: 26,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _onDestination,
          // The chosen tab's icon fills in; the rest stay outlines.
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            const NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded),
              label: 'Messages',
            ),
            // Center create action. Custom pill so it reads as a primary
            // action rather than another nav tab. selectedIcon == icon so
            // there's no "selected" state to render — pressing it always
            // launches the create sheet, never marks itself active.
            NavigationDestination(
              icon: _createPill,
              selectedIcon: _createPill,
              label: 'Create',
            ),
            const NavigationDestination(
              icon: Icon(Icons.search_rounded),
              selectedIcon: Icon(Icons.search_rounded),
              label: 'Search',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
          ],
        ),
      ),
    );
  }
}

/// The "+" in the middle of the bar: a white key with a black plus, so it
/// reads as the one thing to do rather than another place to go.
class _CreatePill extends StatelessWidget {
  const _CreatePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 30,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm + 1),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.add_rounded,
        color: Colors.black,
        size: 24,
      ),
    );
  }
}
