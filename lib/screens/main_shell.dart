import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/pages/home_page.dart';
import 'package:myapp/pages/chat_list_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/create_challenge_page.dart';

/// Root shell — 5-slot bottom nav using standard Material 3 NavigationBar.
/// 0 - Home      (TikTok-style reels: challenges + unaccepted-as-shorts mix)
/// 1 - Messages  (chat list)
/// 2 - Create    (NOT a tab — special prominent "+" that pushes the
///                CreateChallengePage on top of whatever tab is active.
///                Selecting it never updates _currentIndex.)
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

  @override
  void initState() {
    super.initState();
    // Initial tab = home — fire a page_view so the session starts with a
    // known surface context.
    EventTracker.instance.trackPageView(
      pageName: 'home_tab',
      params: {'tabIndex': 0, 'tabLabel': _tabLabels[0]},
    );
  }

  void _onDestination(int index) {
    // The center "+" is not a tab — it's a launcher. Tapping it pushes the
    // create page on top of the current tab and leaves _currentIndex
    // untouched, so when the user dismisses the create sheet they land
    // back on whatever tab they were on.
    if (index == _createIndex) {
      // Mute the reels feed while the create page sits on top — even
      // though the home tab is still mounted underneath, the user is
      // not looking at it and shouldn't hear it.
      VideoPlayerService.instance.pauseAll();
      EventTracker.instance.trackTap(
        target: 'nav_create_challenge',
        pageName: '${_tabLabels[_currentIndex].toLowerCase()}_tab',
      );
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CreateChallengePage()),
      );
      return;
    }

    if (index == _currentIndex) return;
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

  Widget _body() {
    final dp = Provider.of<DataProvider>(context, listen: false);
    // Index 2 is the create-action launcher and never owns the body — only
    // the four real tabs do.
    switch (_currentIndex) {
      case 0:
        return const HomePage();
      case 1:
        return const ChatListPage();
      case 3:
        return const SearchPage();
      case 4:
        return ProfilePage(user: dp.user!);
      default:
        return const HomePage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
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
          indicatorColor: Colors.white.withValues(alpha: 0.18),
          height: 64,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return TextStyle(
              color: active ? Colors.white : Colors.white60,
              fontSize: 11,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return IconThemeData(
              color: active ? Colors.white : Colors.white70,
              size: 26,
            );
          }),
        ),
        child: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: _onDestination,
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
              icon: _CreatePill(color: cs.primary),
              selectedIcon: _CreatePill(color: cs.primary),
              label: 'Create',
            ),
            const NavigationDestination(
              icon: Icon(Icons.search_outlined),
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

/// Filled "+" pill used as the center nav slot. Sized to fit inside the
/// 64-px NavigationBar with a touch of breathing room so it visually
/// dominates without breaking the bar's proportions.
class _CreatePill extends StatelessWidget {
  final Color color;
  const _CreatePill({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 28,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.add_rounded,
        color: Colors.white,
        size: 22,
      ),
    );
  }
}
