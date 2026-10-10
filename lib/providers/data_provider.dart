import 'package:flutter/material.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/models/notification_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/services/avatar_book.dart';

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
  ///
  /// [fromPhone]: [u] is the copy kept on the phone since the last sign-in,
  /// which can be days old. Its photo is not taught to the AvatarBook: the
  /// book kept a newer one, and refreshUser fetches the real one.
  void setUser(UserModel? u, {bool fromPhone = false}) {
    _user = u;
    // Your own photo, so it changes everywhere the moment you change it.
    if (!fromPhone) AvatarBook.instance.learnUser(u);
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

  /// Brings your profile up to date from the server: the app opens on the
  /// copy kept from your last sign-in, which can be days old — from before
  /// a new photo, tag or bio set on this phone or another. Called after
  /// opening and on every visit to your profile page.
  ///
  /// This used to ask /profile, which answers with the feed's picture of
  /// your tastes, not your account. That has no "id", so every refresh was
  /// quietly dropped and the kept copy was never brought up to date.
  ///
  /// Best-effort: when the server cannot be reached the profile on screen
  /// stays as it is, and the log says so.
  Future<void> refreshUser() async {
    final me = _user;
    if (me == null || me.username.isEmpty) return;
    final fresh = await ApiService.getUserByUsername(me.username);
    if (fresh == null) {
      debugPrint('[profile] could not bring your profile up to date; '
          'showing the copy kept from sign-in');
      return;
    }
    // Signed out, or someone else signed in, while this was out.
    if (_user?.id != me.id || fresh.id != me.id) return;
    // Only what that answer carries. It does not say whether two-step
    // sign-in is on, and settings only change through this app, so those
    // stay as they are.
    _user = _user!.copyWith(
      fullName: fresh.fullName,
      bio: fresh.bio,
      visibility: fresh.visibility,
      league: fresh.league,
      wins: fresh.wins,
      losses: fresh.losses,
      avatarUrl: fresh.avatarUrl,
      profileTag: fresh.profileTag,
    );
    notifyListeners();
  }

  // —— Follow / Unfollow ——————————————————————————————————————————————

  Future<bool> followUser(UserModel target) async =>
      await follow(target) == FollowOutcome.followed;

  /// [followUser], saying why when it did not happen. A screen with a
  /// Follow button goes through followFromScreen (follow_flow.dart), which
  /// turns "you blocked them" into an offer to unblock.
  Future<FollowOutcome> follow(UserModel target) async {
    if (_user == null || _following.contains(target.id)) {
      return FollowOutcome.failed;
    }

    // Optimistic: update UI immediately
    _following.add(target.id);
    notifyListeners();

    final outcome = await ApiService.followUserOutcome(
      followerId: _user!.id,
      followerUsername: _user!.username,
      followingId: target.id,
      followingUsername: target.username,
    );

    if (outcome != FollowOutcome.followed) {
      // Revert on failure
      _following.remove(target.id);
      notifyListeners();
    }
    return outcome;
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