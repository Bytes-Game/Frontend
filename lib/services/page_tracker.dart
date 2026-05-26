import 'package:flutter/widgets.dart';
import 'package:myapp/services/event_tracker.dart';

/// PageTracker is a mixin that any [State] can apply to a screen widget to
/// automatically emit `page_view` and `page_exit` events to [EventTracker].
///
/// ## Why a mixin (not just a NavigatorObserver)
///
/// A NavigatorObserver only sees route push/pop. It cannot tell us:
///   - The semantic name of the page (route names aren't always set).
///   - Per-page params (e.g. which user's profile, which conversation).
///   - Whether the page was actually visible (e.g. tab content under a TabBarView
///     is "in the route" but not visible).
///
/// The mixin gives each screen explicit control: it provides its own
/// [pageName] and [pageParams], and the dwell timer is anchored to its
/// own widget lifecycle. We still install the observer below for defense
/// in depth (catches anonymous routes), but the mixin is the canonical signal.
///
/// ## Usage
///
/// ```dart
/// class _ProfilePageState extends State<ProfilePage>
///     with PageTracker<ProfilePage> {
///   @override
///   String get pageName => 'profile_page';
///
///   @override
///   Map<String, dynamic> get pageParams =>
///       {'profileUserId': widget.user.id, 'isSelf': widget.user.id == myId};
///
///   // ... build() etc
/// }
/// ```
mixin PageTracker<T extends StatefulWidget> on State<T> {
  DateTime? _enteredAt;

  /// Stable snake_case identifier — used as both contentId and metadata.pageName.
  String get pageName;

  /// Optional per-page parameters carried in metadata. Override when useful.
  Map<String, dynamic> get pageParams => const {};

  /// Optional referrer (the previous page). Defaults to null. Most pages
  /// don't need to set this — the route observer captures the navigation
  /// chain. Override only if there's specific funnel context worth carrying.
  String? get pageReferrer => null;

  @override
  void initState() {
    super.initState();
    _enteredAt = DateTime.now();
    EventTracker.instance.trackPageView(
      pageName: pageName,
      referrer: pageReferrer,
      params: pageParams,
    );
  }

  @override
  void dispose() {
    final entered = _enteredAt;
    if (entered != null) {
      EventTracker.instance.trackPageExit(
        pageName: pageName,
        dwellMs: DateTime.now().difference(entered).inMilliseconds,
        params: pageParams,
      );
    }
    super.dispose();
  }
}

/// AnalyticsRouteObserver is a defensive net that catches navigation events
/// for routes whose State doesn't use [PageTracker] (anonymous dialogs,
/// modal sheets, third-party screens). It infers a page name from the route's
/// settings and fires `page_view`.
///
/// Install in MaterialApp.navigatorObservers and pass to `Navigator.of(...)`
/// when pushing nested navigators.
class AnalyticsRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  void _firePageViewIfRoute(Route<dynamic>? route, {String? referrer}) {
    if (route is! PageRoute) return;
    final name = route.settings.name;
    if (name == null || name.isEmpty) return;
    EventTracker.instance.trackPageView(
      pageName: 'route:$name',
      referrer: referrer == null ? null : 'route:$referrer',
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _firePageViewIfRoute(route, referrer: previousRoute?.settings.name);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _firePageViewIfRoute(newRoute, referrer: oldRoute?.settings.name);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _firePageViewIfRoute(previousRoute, referrer: route.settings.name);
  }
}
