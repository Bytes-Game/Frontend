/// Centralized app constants.
/// Change URLs here when switching from dev → production.
/// Every file that needs the API URL imports this instead of hardcoding it.
class AppConstants {
  AppConstants._(); // prevent instantiation

  /// REST API base URL (your Go backend on Render).
  static const String apiBaseUrl = 'https://gobackend-9nd8.onrender.com';

  /// WebSocket base URL (same backend, wss scheme)
  static const String wsBaseurl ='wss://gobackend-9nd8.onrender.com';

  /// Number of posts loaded per page in the home feed.
  static const int defaultPageSize = 20;
  
  /// App display name shown in AppBar & titles
  static const String appName ='Battle Arena';
}