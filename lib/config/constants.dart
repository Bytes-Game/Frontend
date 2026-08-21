/// Centralized app constants.
///
/// The backend URLs are the only settings that change between environments,
/// and they are read at COMPILE time from `--dart-define` rather than baked
/// in. Everything that talks to the backend reads them from here — nothing
/// should carry its own copy of a hostname.
///
/// ## Pointing the app at a different backend
///
/// ```
/// flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8081 \
///             --dart-define=WS_BASE_URL=ws://10.0.2.2:8081
/// ```
///
/// (`10.0.2.2` is how the Android emulator reaches the host machine's
/// `localhost`. On an iOS simulator use `http://localhost:8081`. On a physical
/// device use your machine's LAN address, and make sure the Go server is
/// listening on it.)
///
/// With neither flag set the app targets the deployed backend, which is what
/// every existing build and every CI invocation does today — so this changes
/// nothing until someone passes a flag.
///
/// The same mechanism already carries `SENTRY_DSN` in main.dart; this follows
/// that pattern rather than inventing a second one.
///
/// Why compile-time rather than a settings screen: a build should not be able
/// to be pointed at a different server after it ships. Baking it in means a
/// release build can only ever talk to production.
class AppConstants {
  AppConstants._(); // prevent instantiation

  /// REST API base URL (the Go backend).
  ///
  /// Override with `--dart-define=API_BASE_URL=...`. No trailing slash —
  /// callers append paths starting with `/`.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://gobackend-9nd8.onrender.com',
  );

  /// WebSocket base URL — same backend, `ws`/`wss` scheme.
  ///
  /// Override with `--dart-define=WS_BASE_URL=...`. Kept as its own setting
  /// rather than derived from [apiBaseUrl] because the two are not always the
  /// same host: a deployment can put the socket behind a different route, and
  /// deriving it would quietly produce a URL nobody is listening on.
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'wss://gobackend-9nd8.onrender.com',
  );

  /// Number of posts loaded per page in the home feed.
  static const int defaultPageSize = 20;

  /// App display name shown in AppBar & titles
  static const String appName = 'Battle Arena';
}
