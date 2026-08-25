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

  /// The last successfully-read [pageParams], kept so the exit event has
  /// something to carry.
  ///
  /// ## Why the exit event cannot just read pageParams
  ///
  /// Because by then the page is gone. A page's params usually describe
  /// something it looked up while it was open — which profile, whose
  /// conversation — and looking those up means reading from the widget tree
  /// above it. In `dispose()` that page has already been detached, so the
  /// lookup finds nothing and throws.
  ///
  /// It threw for real. Leaving the profile page produced, on every exit:
  ///
  ///     Null check operator used on a null value
  ///     #3  _ProfilePageState.pageParams (profile_page.dart:76)
  ///     #4  PageTracker.dispose (page_tracker.dart:67)
  ///
  /// mid-frame, which loses the `page_exit` event and dumps eighty lines of
  /// stack into the log. Every screen using this mixin was one Provider
  /// lookup away from the same thing.
  ///
  /// So the params are read while the page is alive and remembered. The
  /// snapshot is also the more honest value: an exit event should describe
  /// the page the person was on, not whatever could still be resolved after
  /// it was taken down.
  Map<String, dynamic> _lastParams = const {};

  /// Stable snake_case identifier — used as both contentId and metadata.pageName.
  String get pageName;

  /// Optional per-page parameters carried in metadata. Override when useful.
  ///
  /// Read while the page is on screen, never during teardown — see
  /// [_lastParams].
  Map<String, dynamic> get pageParams => const {};

  /// Read [pageParams] and remember it, keeping the previous value if the
  /// page cannot answer right now.
  ///
  /// The catch is deliberate. Tracking is a side effect of being on a screen;
  /// it must never be the reason a screen fails to open or fails to close.
  void _rememberParams() {
    try {
      _lastParams = pageParams;
    } catch (_) {
      // Keep whatever was last known. An analytics event with slightly stale
      // params beats a crash, and beats no event at all.
    }
  }

  /// The description this page will carry out with it.
  @visibleForTesting
  Map<String, dynamic> get pageParamsAtExit => _lastParams;

  /// Optional referrer (the previous page). Defaults to null. Most pages
  /// don't need to set this — the route observer captures the navigation
  /// chain. Override only if there's specific funnel context worth carrying.
  String? get pageReferrer => null;

  @override
  void initState() {
    super.initState();
    _enteredAt = DateTime.now();
    _rememberParams();
    EventTracker.instance.trackPageView(
      pageName: pageName,
      referrer: pageReferrer,
      params: _lastParams,
    );
  }

  /// Refresh the snapshot whenever the page's surroundings change.
  ///
  /// This is the last moment the page is guaranteed to still be attached, and
  /// it runs once right after [initState] and again on anything that would
  /// change what [pageParams] resolves to — so the value carried into
  /// [dispose] is the one that was true while the page was open.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rememberParams();
  }

  @override
  void dispose() {
    final entered = _enteredAt;
    if (entered != null) {
      // One more attempt at the live value, because some pages fill their
      // params in after opening — a conversation id that arrives from the
      // server, say — and the snapshot would miss it. Pages whose params need
      // the widget tree fail here and keep the snapshot, which is the whole
      // point of having one.
      _rememberParams();
      EventTracker.instance.trackPageExit(
        pageName: pageName,
        dwellMs: DateTime.now().difference(entered).inMilliseconds,
        params: _lastParams,
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
