import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';

/// Manages authentication state: login, signup, cold-start session
/// restore (keystore-backed), and the post-signup onboarding gate.
class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;

  /// True between a successful SIGNUP and the interest picker being
  /// completed/skipped — main.dart routes to onboarding while set.
  bool _needsOnboarding = false;
  bool get needsOnboarding => _needsOnboarding;

  /// True while the cold-start session restore is in flight —
  /// main.dart shows the splash instead of flashing the login screen.
  bool _restoring = true;
  bool get restoring => _restoring;

  /// Attempts login. Returns true on success.
  Future<bool> login(
      BuildContext context, String username, String password) async {
    final result = await ApiService.login(username, password);
    if (result == null) return false;
    // ignore: use_build_context_synchronously
    await _completeAuth(context, result);
    return true;
  }

  /// Attempts signup. On success the user is authenticated immediately
  /// (the backend response mirrors /login) and flagged for onboarding.
  Future<bool> signup(
      BuildContext context, String username, String password) async {
    final result = await ApiService.signup(username, password);
    if (result == null) return false;
    // ignore: use_build_context_synchronously
    await _completeAuth(context, result);
    _needsOnboarding = true;
    notifyListeners();
    return true;
  }

  /// Marks the interest-picker step done (completed OR skipped).
  void completeOnboarding() {
    _needsOnboarding = false;
    notifyListeners();
  }

  /// Cold-start session restore. Called once from main.dart before the
  /// first frame decision. Flow: load keystore session → attach token →
  /// validate/refresh against the backend → hydrate providers from the
  /// stored user snapshot (then refresh from the server in background).
  ///
  /// A dead token (401) or missing session lands on the login screen,
  /// exactly like before persistence existed. Network-down keeps the
  /// stored session optimistically — better to open into a feed that
  /// retries than to demand a login the user can't complete offline.
  Future<void> restoreSession(BuildContext context) async {
    try {
      final stored = await SessionStore.load();
      if (stored == null) return;

      ApiService.authToken = stored.token;
      // Hard 6s cap on the splash screen. A sleeping Render instance
      // holds requests for 30-60s while it cold-boots; without this cap
      // the user stares at the splash that whole time ("app shows
      // nothing"). Timeout == network-down: keep the stored session
      // optimistically and let the feed's own retry take over — the
      // in-flight refresh still completes in the background and
      // installs the fresh token when it lands.
      final fresh = await ApiService.refreshToken()
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
      if (fresh != null) {
        await SessionStore.save(fresh, stored.userJson);
      } else {
        // Distinguish "token rejected" from "network down": a rejected
        // token means any authed call 401s — probe cheaply via profile
        // refresh below; if we can't reach the server at all, keep the
        // session and let normal request retries take over.
        // (refreshToken returns null for both; the profile refresh in
        // _hydrateFromStored surfaces a live user object when the token
        // is actually fine.)
      }

      final user = UserModel.fromJson(stored.userJson);
      // ignore: use_build_context_synchronously
      _hydrateFromStored(context, user);
      _isAuthenticated = true;
    } catch (_) {
      // Any restore failure degrades to the login screen.
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  void _hydrateFromStored(BuildContext context, UserModel user) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    dp.setUser(user);
    dp.setFollowing(List<String>.from(user.followingList));
    _applyTheme(context, user);
    // Background refresh: stored snapshot may be days old.
    // ignore: discarded_futures
    dp.refreshUser();
    // ignore: discarded_futures
    ApiService.getAllUsers().then(dp.setAllUsers);
  }

  /// Shared post-auth population for login and signup responses.
  Future<void> _completeAuth(
      BuildContext context, Map<String, dynamic> result) async {
    final user = UserModel.fromJson(result['user']);
    final dp = Provider.of<DataProvider>(context, listen: false);
    dp.setUser(user);

    // Seed the following-list from the logged-in user's data
    dp.setFollowing(List<String>.from(user.followingList));

    _applyTheme(context, user);

    // Persist the session so the next cold start opens into the feed.
    final token = ApiService.authToken;
    if (token != null && token.isNotEmpty) {
      await SessionStore.save(token, result['user'] as Map<String, dynamic>);
    }

    // Fetch all users separately (backend no longer sends them on login)
    final allUsers = await ApiService.getAllUsers();
    dp.setAllUsers(allUsers);

    _isAuthenticated = true;
    _restoring = false;
    notifyListeners();
    // Belt-and-suspenders refresh: the /login response includes the
    // user, but pulling /profile after surfaces any edits the server
    // applied AFTER the row this login fetched. Fire-and-forget so
    // login UX stays snappy.
    // ignore: discarded_futures
    dp.refreshUser();
  }

  /// Apply the user's saved theme preference so the app paints in the
  /// right mode from first frame after auth. The settings JSON ships
  /// alongside the user record so there's no extra round-trip.
  void _applyTheme(BuildContext context, UserModel user) {
    final tp = Provider.of<ThemeProvider>(context, listen: false);
    final savedTheme = user.settings['theme'];
    if (savedTheme is String) {
      switch (savedTheme) {
        case 'dark':
          tp.setThemeMode(ThemeMode.dark);
          break;
        case 'light':
          tp.setThemeMode(ThemeMode.light);
          break;
        case 'system':
          tp.setThemeMode(ThemeMode.system);
          break;
      }
    }
  }

  /// Clears all state and returns to login screen.
  void logout(BuildContext context) {
    // ignore: use_build_context_synchronously
    Provider.of<DataProvider>(context, listen: false).clearData();
    // Drop the session token so no stale Authorization header lingers for the
    // next user who logs in on this device — and wipe the persisted copy.
    ApiService.clearAuth();
    // ignore: discarded_futures
    SessionStore.clear();
    _isAuthenticated = false;
    _needsOnboarding = false;
    notifyListeners();
  }
}
