import 'package:flutter/material.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/models/notification_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';

/// Central state holder for user data, following list, and notifications.
///
/// Follow / unfollow use **optimistic updates**: the UI changes instantly
/// and reverts if the backend returns an error.
class DataProvider with ChangeNotifier {
  UserModel? _user;
  List<UserModel> _allUsers =[];
  List<String>_following = [];
  final List<NotificationModel> _notifications =[];
  int _unreadNotifications = 0;

  /// Monotonic counter that bumps every time content the user just
  /// produced should force the home/explore/search surfaces to refresh.
  /// Subscribers (SmartReelsFeed, SearchPage) compare to a stored
  /// previous value and re-fetch when it changes. We use a counter
  /// instead of a boolean flag because multiple listeners reset
  /// independently — a single bool would only fire for whichever
  /// listener consumed it first.
  int _feedRefreshTick = 0;

  // —— Getters ——————————————————————————————————————————————————————————
  UserModel? get user => _user;
  List<UserModel> get allUsers => _allUsers;
  List<String> get following => _following;
  List<NotificationModel> get notifications => _notifications;
  int get unreadNotifications => _unreadNotifications;
  int get feedRefreshTick => _feedRefreshTick;

  /// Bump the refresh counter. Called from upload-completion paths so
  /// the home feed picks up the just-posted challenge on next visit
  /// rather than displaying stale paginated state.
  void bumpFeedRefresh() {
    _feedRefreshTick++;
    notifyListeners();
  }

  // —— Setters (used by AuthProvider on login) ——————————————————————————
  void setUser(UserModel? u) {
    _user = u;
    // Initialize event tracker for the recommendation engine
    if (u != null) {
      EventTracker.instance.init(u.id);
    } else {
      EventTracker.instance.dispose();
    }
    notifyListeners();
  }

  void setAllUsers(List<UserModel> list) {
    _allUsers = list;
    notifyListeners();
  }

  void setFollowing(List<String> ids) {
    _following = ids;
    notifyListeners();
  }

  /// Pulls the canonical user document from the server and replaces the
  /// local one. Called after login + on every profile-page open so a
  /// user who edited their profile, restarted the app, and logged back
  /// in sees their latest changes without an extra tap.
  ///
  /// Best-effort: a network hiccup just leaves the existing [_user]
  /// untouched — better than blanking the profile because /profile was
  /// slow on the first request.
  Future<void> refreshUser() async {
    final id = _user?.id;
    if (id == null || id.isEmpty) return;
    final raw = await ApiService.getUserProfile(id);
    if (raw == null) return;
    // /profile sometimes wraps under a "user" key, sometimes returns
    // the raw user object — accept both shapes so the route can evolve
    // without forcing a coordinated client roll-out.
    final candidate = (raw['user'] as Map<String, dynamic>?) ?? raw;
    try {
      final fresh = UserModel.fromJson(candidate);
      if (fresh.id.isEmpty) return; // malformed payload, drop
      _user = fresh;
      notifyListeners();
    } catch (_) {
      // Bad JSON shape — keep the previous user rather than crash.
    }
  }

  // —— Follow / Unfollow ——————————————————————————————————————————————

  Future<bool> followUser(UserModel target) async {
    if (_user == null || _following.contains(target.id)) return false;

    // Optimistic: update UI immediately
    _following.add(target.id);
    notifyListeners();

    final ok = await ApiService.followUser(
      followerId: _user!.id,
      followerUsername: _user!.username,
      followingId: target.id,
      followingUsername: target.username,
    );

    if (!ok) {
      // Revert on failure
      _following.remove(target.id);
      notifyListeners();
    }
      return ok;
  }

  Future<bool> unfollowUser(UserModel target) async {
    if (_user == null || !_following.contains(target.id)) return false;

      _following.remove(target.id);
      notifyListeners();

      final ok = await ApiService.unfollowUser(
        unfollowerId: _user!.id,
        unfollowerUsername: _user!.username,
        unfollowedId: target.id,
        unfollowedUsername: target.username,
      );

      if (!ok) {
        _following.add(target.id);
        notifyListeners();
      }
      return ok;
  }

  // —— Notifications ————————————————————————————————————————————————————————

  /// A notification that arrived live. Chat messages are not notifications
  /// — they have their own list and badge — and one the list already has
  /// (same server id) is not added twice.
  void addNotification(NotificationModel n) {
    // Chat messages live in the chats; the live signals ("Seen", typing, a
    // call ringing) are moments, not things to list.
    if (n.type == 'chat' || WebSocketService.liveSignals.contains(n.type)) {
      return;
    }
    if (n.id.isNotEmpty && _notifications.any((x) => x.id == n.id)) return;
    _notifications.insert(0, n);
    _unreadNotifications++;
    notifyListeners();
  }

  /// Load the list from the server: what the page shows, and the count on
  /// the bell. Kept on the server now, so it survives the app closing.
  Future<void> loadNotifications() async {
    final got = await ApiService.getNotifications();
    if (got == null) return;
    _notifications
      ..clear()
      ..addAll(got.items);
    _unreadNotifications = got.unread;
    notifyListeners();
  }

  /// Everything seen: the bell's count goes, here and on the server.
  void clearUnreadNotifications() {
    final had = _unreadNotifications > 0 ||
        _notifications.any((n) => !n.read);
    _unreadNotifications = 0;
    notifyListeners();
    if (had) ApiService.markNotificationsRead();
  }

  // 一 Reset —————————————————————————————————————————————————————————————

  void clearData(){
    _user = null;
    _allUsers = [];
    _following =[];
    _notifications.clear();
    _unreadNotifications = 0;
    notifyListeners();
  }
}