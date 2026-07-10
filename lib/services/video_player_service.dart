import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// Tier-matched pool sizing. Set once at app start by
/// [DeviceCapabilities.probe] based on physical RAM, and read by both
/// [VideoPlayerService] and any reels surface that wants to know how
/// aggressively it can prefetch.
///
/// - [maxPoolSize] = hard cap on simultaneously-alive controllers.
///   Includes the active controller plus any prefetched spares.
/// - [prefetchAhead] = how many upcoming reels to keep warm when the
///   user is scrolling normally.
/// - [prefetchAheadBurst] = how many upcoming reels to keep warm when
///   the user is binge-scrolling (rapid swipes). Always <=
///   maxPoolSize - 1 (one slot reserved for the active controller).
/// - [prefetchBack] = how many previous reels to keep warm for
///   instant back-swipe.
class VideoPoolConfig {
  final int maxPoolSize;
  final int prefetchAhead;
  final int prefetchAheadBurst;
  final int prefetchBack;

  const VideoPoolConfig({
    required this.maxPoolSize,
    required this.prefetchAhead,
    required this.prefetchAheadBurst,
    required this.prefetchBack,
  });

  /// Pick a config that matches the device's physical RAM.
  ///
  /// IMPORTANT: physical RAM is necessary but NOT sufficient. Android caps
  /// each app's Java heap independently of physical RAM — 256 MB default,
  /// ~512 MB with largeHeap=true. Each live ExoPlayer holds ~20-30 MB of
  /// Java-heap MediaCodec + AudioTrack wrappers in addition to its native
  /// decoder buffers. We size tiers for the HEAP budget, not the RAM
  /// number, then floor to what RAM can support.
  factory VideoPoolConfig.forRam(double ramGb) {
    if (ramGb < 2.0) {
      // Sub-2GB devices (very old / very budget Android). 1 active + 1
      // ahead, no back. Anything more risks OOM on a constrained heap.
      return const VideoPoolConfig(
        maxPoolSize: 2,
        prefetchAhead: 1,
        prefetchAheadBurst: 1,
        prefetchBack: 0,
      );
    }
    if (ramGb < 3.0) {
      // 2-3GB low-tier Android. Tight pool; back-swipe pays a re-open.
      return const VideoPoolConfig(
        maxPoolSize: 2,
        prefetchAhead: 1,
        prefetchAheadBurst: 1,
        prefetchBack: 0,
      );
    }
    if (ramGb < 5.0) {
      // 3-5GB mid-tier. Modest forward prefetch, single back spare.
      return const VideoPoolConfig(
        maxPoolSize: 3,
        prefetchAhead: 1,
        prefetchAheadBurst: 2,
        prefetchBack: 1,
      );
    }
    if (ramGb < 8.0) {
      // 5-8GB flagship. Enough for double-prefetch + back spare.
      return const VideoPoolConfig(
        maxPoolSize: 4,
        prefetchAhead: 2,
        prefetchAheadBurst: 3,
        prefetchBack: 1,
      );
    }
    // 8GB+ high-end. Deeper prefetch fits because largeHeap gives us
    // ~512 MB Java heap — 5 ExoPlayers @ ~30 MB each ≈ 150 MB, leaves
    // room for Flutter image cache + Dart isolate.
    return const VideoPoolConfig(
      maxPoolSize: 5,
      prefetchAhead: 2,
      prefetchAheadBurst: 4,
      prefetchBack: 1,
    );
  }

  /// Conservative default used until [DeviceCapabilities.probe]
  /// finishes. Matches the old static behaviour so app startup
  /// behaves identically to before the runtime-config rewrite.
  static const VideoPoolConfig fallback = VideoPoolConfig(
    maxPoolSize: 4,
    prefetchAhead: 2,
    prefetchAheadBurst: 4,
    prefetchBack: 1,
  );
}

/// Production-ready video player service with:
/// - VideoPlayerController pooling (reuse a fixed number of controllers)
/// - Prefetching (preload next N videos for instant swipe)
/// - Play/pause lifecycle management
/// - Centralized cleanup
///
/// Backed by `video_player` — ExoPlayer (Media3) on Android, AVPlayer on
/// iOS, HTML5 <video> on web. Pool size is set at startup by
/// [DeviceCapabilities.probe] based on physical RAM.
class VideoPlayerService {
  VideoPlayerService._();
  static final VideoPlayerService instance = VideoPlayerService._();

  /// Pool of reusable controllers, one per URL.
  final List<_PoolEntry> _pool = [];

  /// Active config — replaced once at startup by [configure].
  VideoPoolConfig _config = VideoPoolConfig.fallback;

  /// Read-only view of the current pool config. Reels surfaces use
  /// this to compute their own velocity-aware prefetch windows.
  VideoPoolConfig get config => _config;

  /// URLs that have been prefetched (initialized but paused, volume=0).
  final Set<String> _prefetchedUrls = {};

  /// Session-wide feed mute state. UI toggles it (speaker icon on each
  /// reel); every code path that restores "audible" volume routes
  /// through [activeVolume] so a muted session stays muted across
  /// swipes, promotions, and battle side-switches. Unmuting fires the
  /// `unmute` ranking signal at the toggle site.
  final ValueNotifier<bool> feedMuted = ValueNotifier(false);

  /// The volume an ACTIVE (visible, playing) controller should get.
  double get activeVolume => feedMuted.value ? 0.0 : 1.0;

  /// Set the runtime pool config. Safe to call after the app is
  /// already running — if the new maxPoolSize is smaller, excess
  /// entries are evicted immediately.
  void configure(VideoPoolConfig config) {
    _config = config;
    while (_pool.length > config.maxPoolSize) {
      _evictLru();
    }
  }

  /// Get or create a controller for a given URL.
  ///
  /// Returns the controller immediately; callers should `await
  /// controller.initialize()` if `controller.value.isInitialized` is
  /// false. If a controller for this URL already exists in the pool,
  /// return it (already-initialized prefetched controllers are
  /// promoted to active and have their volume restored).
  VideoPlayerController getController(String url) {
    final existing = _pool.where((e) => e.url == url).firstOrNull;
    if (existing != null) {
      existing.lastUsed = DateTime.now();
      // Promote: once a prefetched entry has been requested as the
      // active controller, it's no longer a "spare" — the LRU eviction
      // sorter prefers killing prefetch entries first, so leaving this
      // flag set would make the just-watched reel the FIRST thing
      // evicted on the next prefetch, defeating instant scroll-back.
      existing.isPrefetch = false;
      _prefetchedUrls.remove(url);
      // Restore audible volume on promotion. Prefetched controllers
      // are created muted so a paused, off-screen video can't fight
      // the active reel for AudioFocus.
      existing.controller.setVolume(activeVolume);
      return existing.controller;
    }

    // If pool is full, evict LRU before creating a new entry.
    if (_pool.length >= _config.maxPoolSize) {
      _evictLru();
    }

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    // Fire-and-forget initialize — caller can also await the same
    // future via `controller.initialize()` (it's a no-op the second
    // time). Pre-kicking here means by the time a caller actually
    // needs the first frame, the network handshake is already in
    // flight.
    // ignore: discarded_futures
    controller.initialize().then((_) {
      // Default to audible; reels feed will mute prefetch via prefetch().
      controller.setVolume(activeVolume);
    }).catchError((_) {
      // Swallowed — caller can inspect controller.value.hasError when
      // they actually try to use the controller. Throwing here would
      // crash the fire-and-forget chain.
    });
    _pool.add(_PoolEntry(controller: controller, url: url));
    return controller;
  }

  /// Prefetch videos around the current swipe position so they're
  /// ready when the user swipes either forward OR back. Caller
  /// typically passes the combined window — `[currentIndex+1 .. +ahead]`
  /// concatenated with `[currentIndex-1 .. -prefetchBack]`. The
  /// number of urls to pass is up to the caller (it picks base vs.
  /// burst based on swipe velocity); this method just caps at what
  /// the pool can hold.
  void prefetch(List<String> urls) {
    final requested = urls.toSet();
    for (final url in urls) {
      if (url.isEmpty) continue;
      if (_prefetchedUrls.contains(url)) continue;
      if (_pool.any((e) => e.url == url)) continue;

      // Always leave a slot for the active controller — don't let
      // prefetch alone fill the pool.
      if (_pool.length >= _config.maxPoolSize - 1) {
        // The pool is full — but often with STALE spares (reels the
        // user scrolled past minutes ago). The old behavior was to
        // give up here, which silently disabled forward-prefetch for
        // the rest of the session once the pool filled: every swipe
        // after that landed on a cold controller (worst on the 2-slot
        // low-RAM tiers). Instead, evict the oldest prefetch entry
        // that is NOT part of the window we're warming right now.
        // Non-prefetch (active/promoted) entries are never touched.
        final evictable = _pool
            .where((e) => e.isPrefetch && !requested.contains(e.url))
            .toList()
          ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
        if (evictable.isEmpty) break; // genuinely no room — stop
        final victim = evictable.first;
        _pool.remove(victim);
        _prefetchedUrls.remove(victim.url);
        // ignore: discarded_futures
        victim.controller.dispose();
      }

      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      // ignore: discarded_futures
      controller.initialize().then((_) {
        // Prefetched controllers are silent. AudioFocus on Android is
        // exclusive — multiple unmuted players fight for it and the
        // active reel's audio cuts in and out. Mute prefetch; the
        // promote path in getController restores volume to 1.0.
        controller.setVolume(0);
      }).catchError((_) {
        // Same rationale as getController — caller surfaces the error
        // when they actually try to use this URL.
      });
      _pool.add(_PoolEntry(
        controller: controller,
        url: url,
        isPrefetch: true,
      ));
      _prefetchedUrls.add(url);
    }
  }

  /// Pause all controllers except the one playing the given URL. Also
  /// mutes the paused side as a belt-and-suspenders guard so a
  /// controller that somehow autoplays during init doesn't bleed audio
  /// onto the active reel.
  void pauseAllExcept(String activeUrl) {
    for (final entry in _pool) {
      if (entry.url != activeUrl) {
        entry.controller.pause();
        entry.controller.setVolume(0);
      } else {
        entry.controller.setVolume(activeVolume);
      }
    }
  }

  /// Pause all controllers (e.g., when app goes to background).
  void pauseAll() {
    for (final entry in _pool) {
      entry.controller.pause();
    }
  }

  /// Release a specific controller back to pool (pause it).
  void release(String url) {
    final entry = _pool.where((e) => e.url == url).firstOrNull;
    if (entry != null) {
      entry.controller.pause();
    }
  }

  /// Whether a controller for the given URL is still alive in the pool.
  /// Callers that cached a controller reference outside the pool need
  /// this to know if the controller has been LRU-evicted (and therefore
  /// disposed) — using a disposed controller throws "A
  /// VideoPlayerController was used after being disposed".
  bool hasController(String url) {
    if (url.isEmpty) return false;
    return _pool.any((e) => e.url == url);
  }

  /// Drop every prefetched (non-active) controller. Called from the
  /// memory-pressure handler when Android signals it needs RAM back.
  /// Active controllers stay alive so playback isn't interrupted — only
  /// the prefetched spares die. The next swipe will pay the re-open
  /// cost but the app survives instead of getting OOM-killed.
  void trimPrefetched() {
    final survivors = <_PoolEntry>[];
    for (final entry in _pool) {
      if (entry.isPrefetch) {
        _prefetchedUrls.remove(entry.url);
        // ignore: discarded_futures
        entry.controller.dispose();
      } else {
        survivors.add(entry);
      }
    }
    _pool
      ..clear()
      ..addAll(survivors);
  }

  /// Dispose all controllers — call on app shutdown or logout.
  Future<void> disposeAll() async {
    for (final entry in _pool) {
      await entry.controller.dispose();
    }
    _pool.clear();
    _prefetchedUrls.clear();
  }

  /// Evict the least recently used, non-active controller. Prefetch
  /// entries are preferred for eviction so user-visible playback is
  /// never disturbed by a background prefetch decision.
  void _evictLru() {
    if (_pool.isEmpty) return;
    _pool.sort((a, b) {
      if (a.isPrefetch && !b.isPrefetch) return -1;
      if (!a.isPrefetch && b.isPrefetch) return 1;
      return a.lastUsed.compareTo(b.lastUsed);
    });
    final evicted = _pool.removeAt(0);
    _prefetchedUrls.remove(evicted.url);
    // Fire-and-forget dispose — the controller is no longer reachable
    // from any caller and there's nothing useful to do with the
    // returned Future here.
    // ignore: discarded_futures
    evicted.controller.dispose();
  }
}

class _PoolEntry {
  final VideoPlayerController controller;
  final String url;

  /// Mutable so we can "promote" an entry from prefetch → active when
  /// getController returns an existing prefetched controller.
  bool isPrefetch;
  DateTime lastUsed;

  _PoolEntry({
    required this.controller,
    required this.url,
    this.isPrefetch = false,
  }) : lastUsed = DateTime.now();
}
