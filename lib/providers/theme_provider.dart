import 'package:flutter/material.dart';

/// Light or dark. Dark until the person picks otherwise in Settings →
/// Appearance; their pick is kept with their account and put back each
/// time they sign in (AuthProvider._applyTheme).
class ThemeProvider with ChangeNotifier {
  /// What a new install, and an account that never picked, starts in.
  static const ThemeMode defaultMode = ThemeMode.dark;

  /// The same, as Settings → Appearance and the account store it.
  static const String defaultSetting = 'dark';

  ThemeMode _themeMode = defaultMode;

  ThemeMode get themeMode => _themeMode;

  bool get isDark => _themeMode == ThemeMode.dark;

  void toggleTheme() {
    _themeMode =
        _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  /// The mode for a stored choice ("system", "light" or "dark"). Nothing
  /// stored, or something this version does not know, is the default.
  static ThemeMode modeFor(Object? setting) {
    switch (setting) {
      case 'system':
        return ThemeMode.system;
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return defaultMode;
    }
  }
}
