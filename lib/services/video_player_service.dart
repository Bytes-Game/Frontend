import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/services/reel_diagnostics.dart';

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

  /// The reel currently on screen, as last declared by [pauseAllExcept].
  ///
  /// Two things need this. Eviction needs it so the pool can never
  /// dispose the player the user is watching. And [_volumeFor] needs it
  /// because "is this controller allowed to make noise?" is a question
  /// about the reel on screen, not about how the controller was created.
  String? _activeUrl;

  /// The volume a freshly-initialised controller for [url] should take.
  ///
  /// Every controller used to come up at [activeVolume] on the theory
  /// that the feed would mute the prefetched ones afterwards. That is a
  /// race, and it loses in the ordinary case: a controller finishes
  /// initialising SOME time after it was created, and [pauseAllExcept]
  /// has usually already run by then, so the mute lands before the thing
  /// it was meant to mute exists. The result is an off-screen player
  /// sitting at full volume — audible in a battle flip, and on Android an
  /// extra claimant on an exclusive AudioFocus.
  ///
  /// Deciding from [_activeUrl] at the moment initialisation completes
  /// removes the ordering question entirely: a controller is audible if
  /// and only if it is the reel on screen right then.
  double _volumeFor(String url) => url == _activeUrl ? activeVolume : 0.0;

  /// Set the runtime pool config. Safe to call after the app is
  /// already running — if the new maxPoolSize is smaller, excess
  /// entries are evicted immediately.
  void configure(VideoPoolConfig config) {
    _config = config;
    while (_pool.length > config.maxPoolSize) {
      if (!_evictOldest()) break;
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
      // Promote: this entry is no longer a read-ahead spare, it is a reel
      // someone asked for by name. The flag now only records how the
      // entry was created — eviction goes by recency — but keeping it
      // accurate matters for [trimPrefetched], which drops spares under
      // memory pressure and must not drop a reel that has been watched.
      existing.isPrefetch = false;
      _prefetchedUrls.remove(url);
      // Restore audible volume on promotion. Prefetched controllers
      // are created muted so a paused, off-screen video can't fight
      // the active reel for AudioFocus.
      existing.controller.setVolume(activeVolume);
      return existing.controller;
    }

    // If pool is full, make room before creating a new entry.
    if (_pool.length >= _config.maxPoolSize) {
      _evictOldest(protect: {url});
    }

    final controller = _controllerFor(url);
    // Fire-and-forget initialize — caller can also await the same
    // future via `controller.initialize()` (it's a no-op the second
    // time). Pre-kicking here means by the time a caller actually
    // needs the first frame, the network handshake is already in
    // flight.
    // ignore: discarded_futures
    controller
        .initialize()
        .then((_) {
          // Audible only if this is still the reel on screen — see
          // [_volumeFor]. The reels PageView builds its neighbours, so this
          // path runs for tiles the user cannot see yet, and those must come
          // up silent rather than relying on a later sweep to quieten them.
          controller.setVolume(_volumeFor(url));
          // And stopped. A tile can call play() on its controller before
          // initialisation lands — the feed does exactly that in
          // _playCurrent — and video_player replays that request the moment
          // the player is ready. If the user swiped on in the meantime, that
          // deferred play would start an off-screen reel decoding.
          if (url != _activeUrl) controller.pause();
        })
        .catchError((_) {
          // Swallowed — caller can inspect controller.value.hasError when
          // they actually try to use the controller. Throwing here would
          // crash the fire-and-forget chain.
        });
    _pool.add(_PoolEntry(controller: controller, url: url));
    return controller;
  }

  /// Build a controller for [url], preferring a copy the cache has
  /// already pulled onto the device.
  ///
  /// A local file is the whole point of [VideoCacheService]: the network
  /// round-trip — which is what actually makes a swipe feel slow — has
  /// already happened, so the player only has to open and decode.
  /// A cache miss falls back to streaming, i.e. exactly the old
  /// behaviour, so a cold cache is never worse than before.
  VideoPlayerController _controllerFor(String url) {
    // Proxy first: the loopback server answers out of the cached opening
    // with no network round-trip, which is the whole point.
    final proxied = VideoCacheService.instance.playbackUrlFor(url);
    if (proxied != url) {
      ReelDiagnostics.instance.recordProxiedStart();
      return VideoPlayerController.networkUrl(Uri.parse(proxied));
    }
    // Then a whole file, if we're in the fallback mode that fetches them.
    final cached = VideoCacheService.instance.pathFor(url);
    if (cached != null) {
      ReelDiagnostics.instance.recordWholeFileStart();
      return VideoPlayerController.file(File(cached));
    }
    // Otherwise stream from origin — the pre-cache behaviour. Counted so a
    // profile log shows at a glance whether the cache is actually carrying
    // the feed or whether every reel is still going to the network.
    ReelDiagnostics.instance.recordOriginStart();
    return VideoPlayerController.networkUrl(Uri.parse(url));
  }

  /// Warm the reels around the current position.
  ///
  /// This used to start a full player per upcoming reel, which is what
  /// made the feed heavy: five ready reels meant five live decoders plus
  /// five audio decoders, and the audio ones decoded buffers that were
  /// thrown away unheard (device logs: 144 decoded, 144 dropped) because
  /// prefetched reels are silent by design.
  ///
  /// Now the work is split by cost:
  ///
  ///   * EVERY url in the window is warmed as BYTES by
  ///     [VideoCacheService] — no player, no decoder, no audio, so the
  ///     window can be much deeper than the old player pool allowed.
  ///   * Only the reels named in [live] also get a live controller, so
  ///     the common one-gesture case still lands on an already-initialised
  ///     player.
  ///
  /// [urls] is nearest-first; the caller supplies forward reels before
  /// backward ones so the cache prioritises where the user is heading.
  ///
  /// [live] names the urls a single gesture can reach from where the user
  /// is standing, in priority order, and defaults to the nearest one in
  /// the window. The reels feed passes two: the next reel, which a
  /// vertical swipe reaches, and the active reel's opponent, which a
  /// horizontal flip reaches. Those are the same kind of thing — one
  /// gesture away — and the point of naming them here is that they get
  /// the same treatment rather than the opponent getting a lookalike of
  /// it somewhere else. Everything else in [urls] stays bytes-only.
  ///
  /// Order matters when the pool cannot hold them all: [_openSpare]
  /// declines rather than evicting a spare already opened for this same
  /// window, so an earlier entry wins the last slot. Swipes vastly
  /// outnumber flips, so the feed puts the next reel first.
  void prefetch(
    List<String> urls, {
    List<(SpareLane, String)> live = const [],
  }) {
    final window = urls.where((u) => u.isNotEmpty).toList();
    if (window.isEmpty) return;

    VideoCacheService.instance.warm(window);

    final wanted = spareTargets(window, live);

    // Anything we were holding a deferred spare for that is no longer one
    // gesture away has left the window — drop it, so the wait below
    // resolves into nothing instead of opening a player for a reel the
    // user has already scrolled past.
    _pendingSpares.removeWhere((u, _) => !wanted.containsKey(u));
    _wantedSpares = wanted.keys.toSet();

    wanted.forEach(_requestSpare);
  }

  /// Which urls out of a prefetch window get a live player, in priority
  /// order.
  ///
  /// Pure, and separated out because it is the whole of the "how many
  /// reels are one gesture away" decision — everything after it is
  /// plumbing through [VideoCacheService], which a test of this question
  /// would have to stand up a temp directory and a loopback proxy for.
  ///
  /// An empty [live] means the caller has not thought about it, and gets
  /// the historical behaviour: the nearest url in the window, and nothing
  /// else. Duplicates collapse — a battle whose opponent is also the next
  /// reel's video is one player, asked for twice — and the FIRST lane
  /// named wins it, so a shared url is attributed to the gesture the
  /// caller ranked higher.
  ///
  /// Iteration order is the caller's order, which [_openSpare] treats as
  /// priority when the pool cannot hold them all.
  static Map<String, SpareLane> spareTargets(
    List<String> window,
    List<(SpareLane, String)> live,
  ) {
    final chosen = <String, SpareLane>{};
    for (final (lane, url) in live) {
      if (url.isNotEmpty) chosen.putIfAbsent(url, () => lane);
    }
    if (chosen.isNotEmpty) return chosen;
    final fallback = window.where((u) => u.isNotEmpty);
    return fallback.isEmpty
        ? <String, SpareLane>{}
        : {fallback.first: SpareLane.nextReel};
  }

  /// Open a live spare for [url], now if its opening slice is already
  /// cached and after a short wait if it is not.
  void _requestSpare(String url, SpareLane lane) {
    if (_prefetchedUrls.contains(url)) return;
    if (_pool.any((e) => e.url == url)) return;

    // Already warm: open it now, against the proxy.
    if (VideoCacheService.instance.isReady(url)) {
      _pendingSpares.remove(url);
      _openSpare(url, warm: true, lane: lane);
      return;
    }

    // Cold — and this is the case that used to quietly defeat the whole
    // cache. warm() only ENQUEUES a download; it returns long before any
    // byte arrives. Opening the spare immediately therefore asked
    // playbackUrlFor() a question whose answer could not yet be anything
    // but "origin", so the reel most likely to be watched next — the one
    // a single swipe away — was the one reel guaranteed to open against
    // the network. Worse, its opening slice then finished downloading
    // into a proxy registration that nothing would ever read, because the
    // controller was already bound to the origin URL. Device logs showed
    // the shape of it: proxy=4 (40%), network=6 (60%), with only 3
    // prefixes warmed in the whole session.
    //
    // So wait for the slice, briefly, and open against the proxy when it
    // lands. If it does not land inside the grace we open cold anyway —
    // never having a spare would be worse than having a cold one.
    //
    // The wait doubles as the throttle that keeps fast scrolling cheap. A
    // user moving a reel a second has moved on before the grace elapses,
    // so the url is gone from [_pendingSpares] by then and no player is
    // ever built for it. That is what makes it safe to hand the opponent
    // the same treatment as the next reel: a battle flown past opens
    // nothing, exactly as a reel flown past opens nothing.
    // already waiting on this one
    if (_pendingSpares.containsKey(url)) return;
    _pendingSpares[url] = lane;
    unawaited(
      VideoCacheService.instance.awaitReady(url, spareWarmGrace).then((warm) {
        // Re-check everything: a grace is long enough for the user to
        // swipe, for the window to move on, or for the tile itself to
        // have opened this URL directly. remove() returning false means
        // prefetch already dropped it as out of reach.
        if (_pendingSpares.remove(url) == null) return;
        if (_prefetchedUrls.contains(url)) return;
        if (_pool.any((e) => e.url == url)) return;
        _openSpare(url, warm: warm, lane: lane);
      }),
    );
  }

  /// How long [prefetch] holds the live spare back while that reel's
  /// opening slice is still downloading.
  ///
  /// Covers a first-byte time plus [VideoCacheService.prefixBytes] on a
  /// normal connection, and stays well inside the time a user spends on
  /// a reel before swiping. It is a judgement call, not a measurement —
  /// the spare warm/cold counters in the diagnostics summary are there
  /// so the next profile run can say whether it is set right.
  static const Duration spareWarmGrace = Duration(milliseconds: 1500);

  /// URLs [prefetch] is currently holding a deferred spare for, so a wait
  /// that resolves after the user has moved on is dropped instead of
  /// opening a player for a reel that has left the window.
  final Map<String, SpareLane> _pendingSpares = {};

  /// URLs the latest [prefetch] declared to be one gesture away.
  ///
  /// Read by [_openSpare] so that opening the second spare cannot pay for
  /// itself by evicting the first. Without it a three-slot pool holding
  /// the active reel plus the next reel would hand the last slot to the
  /// opponent by throwing away the next reel — trading the swipe, which
  /// is the common gesture, for the flip, which is not.
  Set<String> _wantedSpares = {};

  /// Create the single live spare controller for [next] and pool it.
  ///
  /// [warm] says whether [next]'s opening slice was already cached, and is
  /// recorded here rather than at the call sites because only this method
  /// knows whether a spare was actually opened.
  void _openSpare(String next, {required bool warm, required SpareLane lane}) {
    // Never let the spare crowd out the active reel's slot.
    //
    // This used to look for a PREFETCH entry to evict and give up when it
    // found none — which is the state the pool reaches within a few
    // swipes, because every spare the user swipes onto is promoted out of
    // prefetch by getController. Three promoted entries and a pool of
    // four meant `evictable` was empty on every subsequent prefetch, so
    // the app quietly stopped opening spares for the rest of the session
    // and every reel paid a cold open. The counters did not show it:
    // spare warm/cold were recorded by the caller BEFORE this method ran,
    // so a session that opened no spares at all still reported them.
    //
    // Stale watched reels are exactly what should make way for the reel
    // one swipe ahead, so evict by age and let the active reel be the
    // only thing that is off limits.
    // Protect every url this window called one gesture away, not just this
    // one. With two spares wanted, evicting by age alone would let the
    // second cannibalise the first — a three-slot pool holding the active
    // reel and the next reel would give the opponent the last slot by
    // throwing the next reel away. Declining is the right answer there:
    // the pool is full of things the user is more likely to reach.
    if (_pool.length >= _config.maxPoolSize - 1) {
      if (!_evictOldest(protect: {next, ..._wantedSpares})) return;
    }

    if (warm) {
      ReelDiagnostics.instance.recordSpareWarm(lane);
    } else {
      ReelDiagnostics.instance.recordSpareCold(lane);
    }

    final controller = _controllerFor(next);
    // ignore: discarded_futures
    controller
        .initialize()
        .then((_) {
          // The spare is silent. AudioFocus on Android is exclusive — an
          // unmuted spare fights the active reel and chops its audio. The
          // promote path in getController restores volume. No pause needed:
          // nothing ever calls play() on a spare, and video_player leaves a
          // controller that was not playing paused once it initialises.
          controller.setVolume(0);
        })
        .catchError((_) {
          // Surfaced when the caller actually tries to use this URL.
        });
    _pool.add(_PoolEntry(controller: controller, url: next, isPrefetch: true));
    _prefetchedUrls.add(next);
  }

  /// Pause all controllers except the one playing the given URL. Also
  /// mutes the paused side as a belt-and-suspenders guard so a
  /// controller that somehow autoplays during init doesn't bleed audio
  /// onto the active reel.
  void pauseAllExcept(String activeUrl) {
    // The authoritative "this reel is on screen" signal. Eviction reads
    // it to keep the watched player alive, and [_volumeFor] reads it so a
    // controller that finishes initialising later comes up at the right
    // volume instead of racing this sweep.
    _activeUrl = activeUrl;
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

  /// Whether THIS EXACT controller is still in the pool.
  ///
  /// [hasController] answers the same question by URL, which is not
  /// enough for a widget that is holding a controller reference: the
  /// pool can evict (and dispose) the controller for a URL and then
  /// build a fresh one for that same URL, at which point the URL check
  /// says "alive" while the captured reference is dead. Identity is the
  /// only question a caller with a reference actually has.
  ///
  /// Check this immediately before handing a captured controller to
  /// VideoPlayer. Building a platform view for a released native player
  /// throws `Bad state: No active player with ID N` out of
  /// AndroidVideoPlayer.buildViewWithOptions, and because that happens
  /// inside build() it takes the whole reel tile down with it.
  bool isLive(VideoPlayerController controller) =>
      _pool.any((e) => identical(e.controller, controller));

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
        _retire(entry.controller);
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
    // Shutdown, so there is no next frame to wait for and no widget left
    // to detach a texture — pause each player and release it here.
    for (final entry in _pool) {
      // ignore: discarded_futures
      entry.controller.pause();
      ReelDiagnostics.instance.recordPlayerRetired();
      await entry.controller.dispose();
    }
    _pool.clear();
    _prefetchedUrls.clear();
    _activeUrl = null;
    _pendingSpares.clear();
    _wantedSpares = {};
  }

  /// Evict the least recently used controller that isn't the reel on
  /// screen. Returns false when nothing was eligible.
  ///
  /// The old rule sorted every prefetch entry ahead of every non-prefetch
  /// one, so the spare for the NEXT reel — the single likeliest thing the
  /// pool will be asked for — was always the first victim, while a reel
  /// watched five swipes ago survived. Each swipe therefore threw away
  /// the player it was about to need and built a fresh one, which is a
  /// hardware decoder created and destroyed per swipe for no gain.
  ///
  /// Recency alone already encodes what the prefetch flag was reaching
  /// for. A spare is opened at the moment it is wanted, so it sorts
  /// newest; the previous reel sorts one swipe old, which is what keeps
  /// back-swipe instant; genuinely stale reels sort oldest and go first.
  ///
  /// [protect] is spared alongside the active reel. Callers pass the url
  /// they are making room FOR, plus anything else that must outlive this
  /// eviction — see [_openSpare], where the set is what stops one spare
  /// being bought with another.
  bool _evictOldest({Set<String> protect = const {}}) {
    _pool.sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    final victim = _pool
        .where((e) => e.url != _activeUrl && !protect.contains(e.url))
        .firstOrNull;
    if (victim == null) return false;
    _pool.remove(victim);
    _prefetchedUrls.remove(victim.url);
    _retire(victim.controller);
    return true;
  }

  /// Shut a controller down in the order the platform expects, then
  /// release it one frame later.
  ///
  /// Disposing straight out of the pool tears the native player down
  /// while its surface is still attached to a mounted `VideoPlayer`,
  /// which is what fills the device log with
  ///
  ///     E/GraphicsTracker: cannot deallocate due to being stopped
  ///     W/Codec2-GraphicBufferAllocator: deallocate() ... was not successful
  ///
  /// on every eviction: Codec2 hands its graphic buffers back to a
  /// BufferQueue that the release already abandoned.
  ///
  /// Removing the entry from [_pool] is what makes [isLive] false, and the
  /// reel tile checks [isLive] before handing the controller to
  /// `VideoPlayer` — so by the end of the next frame the widget tree has
  /// already dropped the texture. Waiting for that frame lets the surface
  /// detach before the decoder goes away. Pausing first stops the decoder
  /// feeding buffers into a surface that is on its way out.
  void _retire(VideoPlayerController controller) {
    // ignore: discarded_futures
    controller.pause();
    // ignore: discarded_futures
    controller.setVolume(0);
    ReelDiagnostics.instance.recordPlayerRetired();
    deferRelease(() {
      // ignore: discarded_futures
      controller.dispose();
    });
  }

  /// Runs [release] once the current frame has been presented.
  ///
  /// Seam, not indirection for its own sake: a `testWidgets` body runs in
  /// a fake-async zone where `VideoPlayerController.dispose()` never
  /// completes against a fake platform, so the frame-accurate behaviour
  /// cannot be exercised there — and the thing worth testing is the
  /// ORDER (out of the pool first, released after), not who owns the
  /// clock. Tests swap this for a queue they drain by hand.
  @visibleForTesting
  static void Function(VoidCallback release) deferRelease = _afterNextFrame;

  static void _afterNextFrame(VoidCallback release) {
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) => release());
    // Dropping a pool entry does not itself dirty the tree, so without
    // this the callback above could wait for a frame that nothing else
    // asks for — and the controller would leak instead of merely
    // lingering.
    binding.scheduleFrame();
  }

  /// Open the read-ahead spare directly.
  ///
  /// [prefetch] reaches this through [VideoCacheService], whose warm path
  /// needs a temp directory, a mock HTTP client and the loopback proxy —
  /// none of which say anything about the question these tests ask, which
  /// is purely "does the pool make room for the spare". This seam keeps
  /// that question separable from how the bytes got there.
  /// [wanted] stands in for the set [prefetch] would have declared one
  /// gesture away, which is what [_openSpare] protects from eviction.
  /// Defaults to just [url], matching a window with a single spare.
  @visibleForTesting
  void debugOpenSpare(
    String url, {
    required bool warm,
    Set<String>? wanted,
    SpareLane lane = SpareLane.nextReel,
  }) {
    _wantedSpares = wanted ?? {url};
    _openSpare(url, warm: warm, lane: lane);
  }

  @visibleForTesting
  int get debugPoolSize => _pool.length;

  @visibleForTesting
  List<String> get debugPoolUrls => _pool.map((e) => e.url).toList();
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
