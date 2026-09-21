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

  /// The longest video this app takes.
  ///
  /// The same three minutes the server enforces — see maxUploadDuration in
  /// the backend, which refuses anything over it and measures the file
  /// itself rather than trusting what this side reports.
  ///
  /// Kept here, next to the server's address, because it is part of the
  /// contract with the server rather than a preference of the recorder or
  /// the trim screen. Both of those read it; neither owns it. Before this,
  /// the trim screen carried its own copy with the comment "mirrors
  /// processor cap", which is how two numbers that must agree start not
  /// agreeing.
  static const Duration maxVideoDuration = Duration(minutes: 3);

  /// Number of posts loaded per page in the home feed.
  static const int defaultPageSize = 20;

  /// App display name shown in AppBar & titles
  static const String appName = 'Battle Arena';
}

/// What a video can be about.
///
/// ## Why this lives here and not on a page
///
/// The server has this same list (ContentCategories in models.go) and uses
/// it for real work: matching a video to people who like that kind of thing,
/// working out how high-energy it is, and ranking a creator against others
/// in the same category. Two copies of a list that must agree is how two
/// lists that must agree start not agreeing, so there is one copy on this
/// side and it sits next to the server's address, which is the other thing
/// on this side that is part of the deal with the server.
///
/// ## "other" is not a category
///
/// The server reads "other" as *nobody said*. Not as "this video is an
/// other" — as no answer at all. Same for "general". So anything labelled
/// "other" is treated exactly like a video whose creator skipped the
/// question.
///
/// That is the right call on the server's side, and it is why "other" must
/// never be offered as a choice or used as a starting value on this side.
/// It used to be both: the Category dropdown started on "Other", so anyone
/// who did not open it posted a video the server filed as unlabelled. On a
/// real check of the platform, 43 of 44 videos had no creator category. The
/// dropdown looked like it was working. Nothing it produced was ever read.
///
/// So: [choosable] is what a person is offered, and it does not contain
/// "other". [vocabulary] is the full list including "other", kept only so
/// this side can recognise a value that arrives FROM the server.
class ContentCategories {
  ContentCategories._();

  /// Every name the server knows, "other" included.
  ///
  /// Use this to check whether a value coming back from the server is one
  /// we recognise. Do NOT use it to build a picker — see [choosable].
  static const List<String> vocabulary = [
    'comedy',
    'motivation',
    'sports',
    'dance',
    'music',
    'gaming',
    'art',
    'education',
    'story',
    'fashion',
    'food',
    'horror',
    'emotional',
    'lifestyle',
    'tech',
    'prank',
    'news',
    'other',
  ];

  /// What a person is actually offered. Everything in [vocabulary] except
  /// the ones the server reads as "nobody said".
  static const List<String> choosable = [
    'comedy',
    'motivation',
    'sports',
    'dance',
    'music',
    'gaming',
    'art',
    'education',
    'story',
    'fashion',
    'food',
    'horror',
    'emotional',
    'lifestyle',
    'tech',
    'prank',
    'news',
  ];

  /// The names the server throws away. Keeping this written down is what
  /// lets a test prove [choosable] contains none of them.
  static const List<String> meansNobodySaid = ['other', 'general'];

  /// True when [name] is a real answer rather than a shrug.
  ///
  /// Mirrors usableCategory() in the backend's content_tags.go. Send "" for
  /// anything this returns false for — an empty field and a shrug mean the
  /// same thing to the server, and "" at least does not pretend otherwise.
  static bool isRealAnswer(String? name) {
    if (name == null) return false;
    final n = name.trim().toLowerCase();
    return n.isNotEmpty && !meansNobodySaid.contains(n);
  }
}
