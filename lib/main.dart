import 'dart:io' show Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/connection_prewarm_service.dart';
import 'package:myapp/services/device_capabilities.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/pages/onboarding_interests_page.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/screens/main_shell.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/widgets/upload_status_overlay.dart';

/// Sentry DSN — read at compile time from `--dart-define=SENTRY_DSN=...`.
/// Empty string disables Sentry cleanly (SentryFlutter.init returns
/// immediately, errors are still printed to console but not uploaded).
///
/// To enable in production:
///   1. Sign up at sentry.io (free tier — 5k events/month)
///   2. Create a project, copy its DSN ("https://xxx@oNNNNNN.ingest.sentry.io/NNN")
///   3. Build with `flutter build --dart-define=SENTRY_DSN=<your-dsn>`
///      (or pass `--dart-define-from-file=.env`)
///
/// We use --dart-define so the DSN is baked into the release build but
/// stays out of source control. Empty DSN in debug runs means crashes
/// print to the console (via FlutterError.dumpErrorToConsole) but
/// don't ship to Sentry — convenient during local dev.
const String _sentryDsn = String.fromEnvironment('SENTRY_DSN');

Future<void> main() async {
  // Sentry needs Flutter binding initialized before its native channels
  // wire up, so call it first. video_player doesn't need any explicit
  // init — the plugin registers itself via Flutter's plugin registry
  // and ExoPlayer/AVPlayer/HTMLVideoElement are lazily constructed on
  // the first VideoPlayerController.
  WidgetsFlutterBinding.ensureInitialized();
  // HTTP/3 (QUIC) for API calls: swap the shared API client to a
  // Cronet-backed one on Android. Render's Cloudflare edge advertises
  // h3, so after the boot-time prewarm performs alt-svc discovery,
  // every API call rides QUIC — faster handshakes, loss-resilient
  // multiplexing, and connection migration across wifi<->cellular.
  // Fail-open: devices without Play Services Cronet (or any init
  // error) silently keep the default Dart client.
  if (!kIsWeb && Platform.isAndroid) {
    try {
      final engine = CronetEngine.build(
        cacheMode: CacheMode.disabled,
        enableQuic: true,
        enableHttp2: true,
        userAgent: 'BattleArena/1.0',
      );
      ApiService.useClient(CronetClient.fromCronetEngine(engine));
    } catch (e) {
      debugPrint('Cronet unavailable, using default HTTP client: $e');
    }
  }
  // Cap the image cache so Flutter's default 100 MB allowance doesn't eat
  // into the heap budget shared with ExoPlayer MediaCodec instances. On
  // Android the app gets ~512 MB total (largeHeap=true); ExoPlayer needs
  // ~150-250 MB at peak pool, Dart isolate ~50 MB, leaving ~200 MB. A 50 MB
  // image cache is more than enough for the feed's thumbnails — the rest
  // we'd rather give to video buffers.
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;
  // Probe device RAM and size the video player pool accordingly. Low-
  // RAM devices get a smaller pool (no OOM), high-RAM devices get a
  // bigger one (deeper prefetch, more reels feel instant). Fire-and-
  // forget — until probe resolves the service uses
  // VideoPoolConfig.fallback, which matches the pre-rewrite default.
  // ignore: discarded_futures
  DeviceCapabilities.instance.probe();
  // Kick off the connectivity listener early so by the time the first
  // reel renders the player can already pick a variant matching the
  // user's network. start() is idempotent and self-contained — if the
  // OS hasn't reported connectivity yet, we fall back to medium.
  // ignore: discarded_futures
  NetworkQualityService.instance.start();
  // Prewarm the DNS + TLS connection to the backend (and R2/CDN if
  // configured via env / build flag). This makes the FIRST reel the
  // user taps avoid the 200-600ms cold-handshake tax — the OS socket
  // pool already has a hot socket to the origin by the time the
  // player asks for the video URL. Fire-and-forget: if prewarm fails
  // (e.g. captive portal at boot), the first reel pays the cost it
  // would have paid anyway, so we never want this blocking runApp.
  //
  // Add R2 / CDN hostnames to extraOrigins once the R2_PUBLIC_BASE_URL
  // is known to the client (today the client only knows the per-upload
  // URL it receives, so we can't prewarm a specific origin here —
  // populated lazily on first feed fetch from the URLs it sees).
  // ignore: discarded_futures
  ConnectionPrewarmService.instance.start();

  // Crash + uncaught-error reporting via Sentry. The SDK installs:
  //   * FlutterError.onError handler   — catches framework errors
  //   * PlatformDispatcher.onError     — catches uncaught Dart errors
  //   * Native crash interceptors      — Android NDK + iOS Mach
  // …so any unhandled exception across the entire stack lands in the
  // Sentry dashboard with stack trace + breadcrumbs + device metadata.
  //
  // When SENTRY_DSN is empty (default for local dev) the init no-ops
  // and runApp runs directly — no overhead, no console spam.
  // Restore any upload jobs interrupted by an app kill — they surface
  // as tappable-retry entries in the status overlay. Fire-and-forget.
  // ignore: discarded_futures
  UploadJobManager.instance.restorePersisted();

  if (_sentryDsn.isEmpty) {
    runApp(const MyApp());
    return;
  }
  await SentryFlutter.init(
    (options) {
      options.dsn = _sentryDsn;
      // Capture only 25% of transactions by default — keeps us comfortably
      // under the free tier's 5k events/month at small DAU. Bump to 1.0
      // for the first week of a launch when you want every error.
      options.tracesSampleRate = 0.25;
      // Don't ship debug-mode crashes; they're noisy and you see them in
      // your local console anyway.
      options.debug = false;
      // Privacy: redact request bodies from breadcrumbs — they might
      // contain user-typed content. We still get the URL + status code,
      // which is enough to triage 99% of failures.
      options.maxBreadcrumbs = 50;
      options.sendDefaultPii = false;
    },
    appRunner: () => runApp(const MyApp()),
  );
}

/// Root Widget.
///
/// Sets up the three ChangeNotifier providers (Auth, Data, Theme),
/// installs the global [AnalyticsRouteObserver] so navigations to anonymous
/// routes still emit page_view events, and swaps between [LoginScreen] and
/// [MainShell] based on auth state.
///
/// (FeedProvider was removed when posts/legacy-feed were retired — the
/// SmartReelsFeed widget now manages its own paged state per FeedKind.)
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  /// Single shared instance — re-exported so nested Navigators can attach
  /// the same observer (otherwise they'd miss events on inner stacks).
  static final AnalyticsRouteObserver routeObserver = AnalyticsRouteObserver();

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Also trim aggressively on image-cache eviction events from the
    // framework itself, e.g. when a Navigator pushes a heavy new route.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Called by Flutter when the platform (Android `onLowMemory`, iOS
  /// `applicationDidReceiveMemoryWarning`) signals memory pressure. Drop
  /// every prefetched video controller and shrink the image cache. The
  /// active reel keeps playing; the next swipe pays a re-open cost.
  /// Cheaper than getting OOM-killed.
  @override
  void didHaveMemoryPressure() {
    VideoPlayerService.instance.trimPrefetched();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  /// Drop prefetched controllers and shrink the image cache when the app
  /// goes to the background. Android's low-memory killer prioritises
  /// processes by RSS, so the smaller we are while inactive the longer
  /// we survive in the recents stack. EventTracker's lifecycle events
  /// are emitted from _WebSocketWrapper — this handler is purely about
  /// reclaiming RAM, not analytics.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      VideoPlayerService.instance.trimPrefetched();
      PaintingBinding.instance.imageCache.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => DataProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer2<AuthProvider, ThemeProvider>(
        builder: (context, auth, theme, _) {
          return MaterialApp(
            title: 'Battle Arena',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: theme.themeMode,
            navigatorObservers: [MyApp.routeObserver],
            // UploadStatusOverlay is mounted INSIDE the WebSocket wrapper
            // so the floating "Posting…" banner sits above every routed
            // page in the authenticated app. It's outside the Navigator's
            // route tree, so navigating away from the upload page (or
            // anywhere else) leaves the banner visible until the job
            // completes. UploadJobManager keeps job state alive
            // independent of any widget's lifecycle, so the banner
            // survives full page rebuilds.
            builder: auth.isAuthenticated
                ? (context, child) => _WebSocketWrapper(
                      child: UploadStatusOverlay(child: child!),
                    )
                : null,
            home: auth.restoring
                // Cold-start session restore in flight (fast: one
                // keystore read + one refresh call). A branded splash
                // beats flashing the login screen at returning users.
                ? const _RestoreSplash()
                : auth.isAuthenticated
                    ? (auth.needsOnboarding
                        ? const OnboardingInterestsPage()
                        : const MainShell())
                    : const LoginScreen(),
          );
        },
      ),
    );
  }
}

/// Shown while AuthProvider.restoreSession validates the stored token.
/// Kicks the restore off exactly once from the first build.
class _RestoreSplash extends StatefulWidget {
  const _RestoreSplash();

  @override
  State<_RestoreSplash> createState() => _RestoreSplashState();
}

class _RestoreSplashState extends State<_RestoreSplash> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // ignore: discarded_futures
      Provider.of<AuthProvider>(context, listen: false)
          .restoreSession(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

// ——————————————————————————————————————————————————————————————————————————————
// WebSocket wrapper — creates the WS connection once after login and
// provides it to widget tre via provider<WebSocketService>.
// Separated from MyApp to keep concerns clean and avoid re-creating
// the connection on every rebuild
// ——————————————————————————————————————————————————————————————————————————————
class _WebSocketWrapper extends StatefulWidget {
  final Widget child;
  const _WebSocketWrapper({required this.child});

  @override
  State<_WebSocketWrapper> createState() => _WebSocketWrapperState();
}

class _WebSocketWrapperState extends State<_WebSocketWrapper>
    with WidgetsBindingObserver {
  late WebSocketService _ws;

  @override
  void initState() {
    super.initState();
    // App-root lifecycle observer — fires app_background/app_foreground regardless
    // of which page the user is on. Per-page observers keep doing local work
    // (impression flush, dwell timer reset) but no longer send duplicate
    // lifecycle events. This is the single source of truth.
    WidgetsBinding.instance.addObserver(this);

    final dp = Provider.of<DataProvider>(context, listen: false);
    final username = dp.user?.username ?? '';
    _ws = WebSocketService('wss://gobackend-9nd8.onrender.com', username);
    if (username.isNotEmpty) {
      _ws.connect();
      _ws.notificationStream.listen((n) {
        // next_reel_hint is an invisible prefetch trigger pushed by the
        // backend ranker — the server thinks this URL is what the user
        // is about to swipe to, so we warm the controller now. Suppress
        // the notification from the user-facing list (no UI badge, no
        // toast, no inbox row).
        if (n.type == 'next_reel_hint') {
          final url = n.videoUrl;
          if (url != null && url.isNotEmpty) {
            VideoPlayerService.instance.prefetch([url]);
          }
          return;
        }
        dp.addNotification(n);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ws.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // User is leaving the app entirely (home button, app switcher, screen off,
      // or process being torn down). Backend uses this to compute true session
      // length and persist AvgSessionSec.
      EventTracker.instance.trackAppBackground();
    } else if (state == AppLifecycleState.resumed) {
      // User came back. EventTracker.trackAppForeground rotates the session ID
      // if they were away >30min, so a long absence becomes a fresh session
      // with full DopamineBudget.
      EventTracker.instance.trackAppForeground();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Provider<WebSocketService>.value(
      value: _ws,
      child: widget.child,
    );
  }
}