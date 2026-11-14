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

  /// Private accounts you have asked to follow that have not answered yet.
  /// Their button says "Requested", and tapping it takes the request back.
  final Set<String> _requested = {};

  /// People asking to follow you (only a private account is asked), newest
  /// first. The notifications page shows them with Accept and Decline.
  List<UserModel> _followRequests = [];

  /// Goes up with every follow, unfollow and request made from this phone.
  /// refreshUser reads the list you follow from the server; an answer that
  /// was asked for before a tap must not undo that tap.
  int _followEdits = 0;
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
  Set<String> get requested => _requested;

  /// You follow account [id], or have asked to and are waiting. Either
  /// way the button no longer says "Follow", and tapping it undoes it.
  bool followsOrAsked(String id) =>
      _following.contains(id) || _requested.contains(id);
  List<UserModel> get followRequests => _followRequests;
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
    final editsBefore = _followEdits;
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
    // Who you follow, as the server has it now. The copy on the phone is
    // from your last sign-in: everybody followed since then showed
    // "Follow" again after the app was closed and opened, and a request a
    // private account accepted while you were away never showed at all.
    // Left alone if you followed or unfollowed while this was out: that
    // answer is older than your tap.
    if (_followEdits == editsBefore) {
      _following = List<String>.from(fresh.followingList);
      _requested.removeWhere(_following.contains);
    }
    notifyListeners();
  }

  // —— Follow / Unfollow ——————————————————————————————————————————————

  Future<bool> followUser(UserModel target) async =>
      await follow(target) == FollowOutcome.followed;

  /// [followUser], saying why when it did not happen. A screen with a
  /// Follow button goes through followFromScreen (follow_flow.dart), which
  /// turns "you blocked them" into an offer to unblock.
  ///
  /// A private account is not followed by tapping: it is asked, and the
  /// answer here is [FollowOutcome.requested]. The button then says
  /// "Requested" until its owner says yes or no.
  Future<FollowOutcome> follow(UserModel target) async {
    if (_user == null || _following.contains(target.id)) {
      return FollowOutcome.failed;
    }

    // The button changes at once, to what the server will most likely
    // say: "Requested" for an account the app knows is private,
    // "Following" for any other.
    final private = target.visibility == 'friends';
    _followEdits++;
    if (private) {
      _requested.add(target.id);
    } else {
      _following.add(target.id);
    }
    notifyListeners();

    final outcome = await ApiService.followUserOutcome(
      followerId: _user!.id,
      followerUsername: _user!.username,
      followingId: target.id,
      followingUsername: target.username,
    );

    // Then to what it did say. The app's copy of the account can be old:
    // it may have gone private, or public, since.
    _followEdits++;
    _following.remove(target.id);
    _requested.remove(target.id);
    if (outcome == FollowOutcome.followed) _following.add(target.id);
    if (outcome == FollowOutcome.requested) _requested.add(target.id);
    notifyListeners();
    return outcome;
  }

  /// Stops following [target], or takes back a request to follow them that
  /// has not been answered.
  Future<bool> unfollowUser(UserModel target) async {
    if (_user == null) return false;
    final wasFollowing = _following.contains(target.id);
    final wasRequested = _requested.contains(target.id);
    if (!wasFollowing && !wasRequested) return false;

    _followEdits++;
    _following.remove(target.id);
    _requested.remove(target.id);
    notifyListeners();

    final ok = await ApiService.unfollowUser(
      unfollowerId: _user!.id,
      unfollowerUsername: _user!.username,
      unfollowedId: target.id,
      unfollowedUsername: target.username,
    );

    if (!ok) {
      _followEdits++;
      if (wasFollowing) _following.add(target.id);
      if (wasRequested) _requested.add(target.id);
      notifyListeners();
    }
    return ok;
  }

  /// What the server just said about your request to follow account [id]:
  /// still waiting, or not. Called when their profile is read.
  ///
  /// "Not waiting" for a request this phone made means it was answered. A
  /// yes puts them among the people you follow, so that list is read
  /// again; a no leaves the Follow button as it was.
  void noteFollowRequest(String id, {required bool waiting}) {
    if (id.isEmpty) return;
    if (waiting) {
      if (_requested.add(id)) notifyListeners();
      return;
    }
    if (_requested.remove(id)) {
      notifyListeners();
      // ignore: discarded_futures
      refreshUser();
    }
  }

  // —— People asking to follow you ————————————————————————————————————

  /// Reads who is asking to follow you. Kept as it was when the server
  /// cannot be asked.
  Future<void> loadFollowRequests() async {
    final got = await ApiService.followRequests();
    if (got == null) return;
    _followRequests = got;
    notifyListeners();
  }

  /// Says yes or no to [asker]. The row goes at once and comes back if the
  /// server did not take the answer. True when it did.
  Future<bool> answerFollowRequest(UserModel asker,
      {required bool accept}) async {
    final at = _followRequests.indexWhere((u) => u.id == asker.id);
    if (at < 0) return false;
    final row = _followRequests.removeAt(at);
    notifyListeners();
    final ok = await ApiService.answerFollowRequest(asker.id, accept: accept);
    if (!ok) {
      _followRequests.insert(at.clamp(0, _followRequests.length), row);
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
    // A private account said yes to your request: you follow them now, and
    // their button says so without the page being opened again.
    if (n.type == 'follow_accepted' && n.actorId.isNotEmpty) {
      _followEdits++;
      _requested.remove(n.actorId);
      if (!_following.contains(n.actorId)) _following.add(n.actorId);
    }
    // Somebody is asking to follow you: on the list to answer, at once.
    if (n.type == 'follow_request' &&
        n.actorId.isNotEmpty &&
        !_followRequests.any((u) => u.id == n.actorId)) {
      _followRequests = [
        UserModel(
          id: n.actorId,
          username: n.actorUsername,
          league: n.actorLeague.isEmpty ? 'Unranked' : n.actorLeague,
          wins: 0,
          losses: 0,
          followersCount: 0,
          followingCount: 0,
        ),
        ..._followRequests,
      ];
    }
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
    _requested.clear();
    _followRequests = [];
    _followEdits++;
    _notifications.clear();
    _unreadNotifications = 0;
    notifyListeners();
  }
}