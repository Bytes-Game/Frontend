import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';

/// Manages authentication state
/// Calls [ApiService.login] and populates [DataProvider] on success.
class AuthProvider with ChangeNotifier {
  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;

  /// Attempts login. Returns true on success.
  Future<bool> login(
      BuildContext context, String username, String password) async {
    final result = await ApiService.login(username, password);
    if (result == null) return false;

    final user = UserModel.fromJson(result['user']);
    // ignore: use_build_context_synchronously
    final dp = Provider.of<DataProvider>(context, listen: false);
    dp.setUser(user);

    // Seed the following-list from the logged-in user's data
    dp.setFollowing(List<String>.from(user.followingList));

    // Apply the user's saved theme preference so the app paints in
    // the right mode from first frame after login. Without this the
    // theme picker in AppearancePage would only take effect on the
    // NEXT app launch, which feels broken. The settings JSON ships
    // alongside the user record so there's no extra round-trip.
    // ignore: use_build_context_synchronously
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

    // Fetch all users separately (backend no longer sends them on login)
    final allUsers = await ApiService.getAllUsers();
    dp.setAllUsers(allUsers);

    _isAuthenticated = true;
    notifyListeners();
    // Belt-and-suspenders refresh: the /login response includes the
    // user, but pulling /profile after surfaces any edits the server
    // applied AFTER the row this login fetched (e.g. a background
    // job that bumped wins/league between IsValidUser and the
    // GetUserByUsername read). Fire-and-forget so login UX stays
    // snappy; refreshUser notifies listeners when (if) it finishes.
    // ignore: discarded_futures
    dp.refreshUser();
    return true;
  }

    /// Clears all state and returns to login screen.
    void logout(BuildContext context) {
    // ignore: use_build_context_synchronously
    Provider.of<DataProvider>(context, listen: false).clearData();
    _isAuthenticated = false;
    notifyListeners();
  }
}