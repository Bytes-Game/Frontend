import 'package:flutter/widgets.dart';

/// Tells a page when another page opens on top of it, and when it is the
/// page on top again. Sheets, menus and dialogs do not count: only pages.
///
/// ════════════════════════════════════════════════════════════════════════
/// WHY NOT FLUTTER'S OWN RouteObserver
/// ════════════════════════════════════════════════════════════════════════
///
/// It nearly does this, but it only speaks up when a page opens STRAIGHT on
/// top of another page. Open the list of who liked a reel — a sheet — and tap
/// a name: the profile opens on top of the sheet, and the reel underneath is
/// never told. It played on behind the profile, the same as it did behind
/// the notifications page before anything listened at all.
///
/// So this keeps its own copy of the navigator's stack and works out which
/// page is on top after every change, however it happened: a page opened
/// from a sheet, a page closed, one swapped for another, or one taken out
/// from under the others (a call that ends while something is on top of it).
///
/// Subscribers are [RouteAware], and hear [RouteAware.didPushNext] when their
/// page stops being the page on top and [RouteAware.didPopNext] when it is
/// the page on top again.
///
/// For one navigator: the app's (main.dart installs [instance]).
class PageCoverObserver extends NavigatorObserver {
  static final PageCoverObserver instance = PageCoverObserver();

  /// The navigator's routes, oldest first.
  final List<Route<dynamic>> _stack = [];

  /// The page on top, as last worked out.
  Route<dynamic>? _top;

  final Map<Route<dynamic>, Set<RouteAware>> _listeners = {};

  /// Tell [listener] when [route] is covered by another page, and when it is
  /// on top again.
  void subscribe(RouteAware listener, PageRoute<dynamic> route) {
    _listeners.putIfAbsent(route, () => <RouteAware>{}).add(listener);
  }

  void unsubscribe(RouteAware listener) {
    for (final set in _listeners.values) {
      set.remove(listener);
    }
    _listeners.removeWhere((_, set) => set.isEmpty);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A navigator that has gone (a test's app, torn down) leaves its routes
    // behind with no navigator; they are nobody's page on top.
    _stack
      ..removeWhere((r) => r.navigator == null)
      ..add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (newRoute != null) {
      if (at >= 0) {
        _stack[at] = newRoute;
      } else {
        _stack.add(newRoute);
      }
    } else if (at >= 0) {
      _stack.removeAt(at);
    }
    _changed();
  }

  void _changed() {
    Route<dynamic>? top;
    for (final r in _stack.reversed) {
      if (r is PageRoute) {
        top = r;
        break;
      }
    }
    if (identical(top, _top)) return;
    final was = _top;
    _top = top;
    // A page that has gone is not covered, it is gone: only one still on
    // the stack hears it.
    if (was != null && _stack.contains(was)) {
      for (final l in [...?_listeners[was]]) {
        l.didPushNext();
      }
    }
    if (top != null) {
      for (final l in [...?_listeners[top]]) {
        l.didPopNext();
      }
    }
  }
}
