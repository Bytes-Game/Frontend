import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';
// Reached only through the `is AndroidVideoPlayer` test in
// [VideoPlayerService._platformSetPlayerAudio]. Importing the Android
// implementation directly is unusual and deliberate: turning a player's audio
// decoding off is a local addition to our vendored copy of the plugin, so it
// is not on VideoPlayerPlatform and cannot be reached generically. See
// third_party/video_player_android/LOCAL_CHANGES.md.
import 'package:video_player_android/video_player_android.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

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

  /// How many players the screen actually needs alive at the same time.
  ///
  /// Four, and each one is on screen or one gesture away from it:
  ///
  ///   1. the reel being watched,
  ///   2. the reel one swipe up,
  ///   3. the reel one swipe down,
  ///   4. the opponent's video, when the reel is a battle.
  ///
  /// The reels PageView builds its neighbours, so 2 and 3 are real
  /// players, not plans to make one. A battle turns both cube faces at
  /// once during the flip, so 4 is real too for as long as the gesture
  /// lasts. This is a floor on the pool, not a wish: see
  /// [maxConcurrentDecoders] for what happens when the pool sits below it.
  static const int onScreenWorkingSet = 4;

  /// The ceiling every tier is clamped to, and the reason the tiers below
  /// no longer reach the numbers they used to.
  ///
  /// The tiers were sized for the Java heap: ~20-30 MB of MediaCodec and
  /// AudioTrack wrappers per live ExoPlayer against a 256 MB (or ~512 MB
  /// with largeHeap) budget, which makes five players look affordable on a
  /// big phone. Memory turned out not to be what runs out. A profile run
  /// on a Xiaomi 2412DPC0AI — 8 GB RAM, so the top tier, pool of 5 — spent
  /// its session being overruled by the platform:
  ///
  ///     D/MediaCodec: MediaCodec::reclaim(0x...) c2.mtk.avc.decoder
  ///     E/MediaCodec: Released by resource manager
  ///
  /// That is Android's resource manager taking decoders back because the
  /// process was holding more concurrent 720p AVC instances than the
  /// vendor Codec2 stack will run. RAM does not predict that number — it
  /// is a property of the SoC's decoder — so the cap exists and RAM is no
  /// longer the ceiling. Nothing above the reachable set was buying warmth
  /// the user could feel, only reclaims.
  ///
  /// It must never drop below [onScreenWorkingSet], and it sat at 3 for
  /// one release, which is worth writing down because the reasoning was
  /// wrong in an instructive way. The thought was that a smaller pool
  /// means fewer live decoders. It does not. [getController] builds a
  /// player whenever a tile asks for one and evicts to make room — the cap
  /// never refuses anybody, it only decides how long a player survives. So
  /// a pool below the working set holds exactly as many decoders at once
  /// and additionally throws one away on every swipe, then rebuilds it
  /// seconds later when the screen asks again. The device run showed it:
  /// 40 player opens and 37 retirements for 14 distinct videos, reclaims
  /// undiminished, and multi-second black frames while an evicted
  /// neighbour re-initialised.
  ///
  /// Fewer live decoders has to come from asking for fewer players, not
  /// from a cap underneath the demand.
  ///
  /// iOS has no equivalent reclaim path, but AVPlayer has its own limit on
  /// simultaneous render pipelines and the gesture argument holds there
  /// too, so the cap is not platform-conditional.
  static const int maxConcurrentDecoders = onScreenWorkingSet;

  /// Pick a config that matches the device's physical RAM, then clamp it
  /// to what the device's DECODER can actually run concurrently.
  ///
  /// RAM still sets the floor — a 2 GB phone should not hold three players
  /// even though its decoder would allow it — but it no longer sets the
  /// ceiling, because [maxConcurrentDecoders] is the constraint that
  /// actually binds. See that constant for the device evidence.
  factory VideoPoolConfig.forRam(double ramGb) {
    return _byRam(ramGb)._clampedToDecoderBudget();
  }

  /// Re-derive this config with [maxConcurrentDecoders] enforced.
  ///
  /// Prefetch counts come down with the pool: one slot is always reserved
  /// for the reel on screen, so a burst window that names more spares than
  /// the pool can hold just makes [_openSpare] decline them one at a time,
  /// which costs a decision per swipe and buys nothing.
  VideoPoolConfig _clampedToDecoderBudget() {
    if (maxPoolSize <= maxConcurrentDecoders) return this;
    final spares = maxConcurrentDecoders - 1;
    return VideoPoolConfig(
      maxPoolSize: maxConcurrentDecoders,
      prefetchAhead: prefetchAhead.clamp(0, spares),
      prefetchAheadBurst: prefetchAheadBurst.clamp(0, spares),
      prefetchBack: prefetchBack.clamp(0, spares),
    );
  }

  static VideoPoolConfig _byRam(double ramGb) {
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

  /// Conservative default used until [DeviceCapabilities.probe] finishes.
  ///
  /// This used to be the 4/2/4/1 shape the top tiers had, on the theory
  /// that startup should behave identically to the pre-config code. That
  /// made the default the most aggressive thing in the file for the window
  /// before the probe lands — which is app start, when the first reel is
  /// opening and the decoder is least likely to have room. It now sits at
  /// the decoder budget like everything else.
  static const VideoPoolConfig fallback = VideoPoolConfig(
    maxPoolSize: maxConcurrentDecoders,
    prefetchAhead: 1,
    prefetchAheadBurst: 2,
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
      // A spare also had its audio decoder taken away; asking for it back
      // here means the sound is ready by the time the reel is played rather
      // than a track re-selection behind the first frame.
      _setEntryAudio(existing, enabled: true);
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
          // Silent is not enough: a neighbour tile that never plays still
          // decodes its whole audio track. Drop it until the reel is the one
          // on screen, at which point pauseAllExcept hands it back. Looked up
          // by URL because the entry may have been evicted while we waited.
          if (url != _activeUrl) {
            final entry = _pool.where((e) => e.url == url).firstOrNull;
            if (entry != null) _setEntryAudio(entry, enabled: false);
          }
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

    // One spare at a time.
    //
    // A window naming two spares used to build both in the same turn,
    // because this method is synchronous on the warm path and `prefetch`
    // calls it once per wanted url. On device that put three players into
    // MediaCodec's INITIALIZING state at the same moment — the reel on
    // screen plus both spares:
    //
    //     I/MediaCodec: [mId: 54] [video-debug-dec] setState: INITIALIZING
    //     I/MediaCodec: [mId: 55] [video-debug-dec] setState: INITIALIZING
    //     I/MediaCodec: [mId: 56] [video-debug-dec] setState: INITIALIZING
    //
    // Three concurrent codec allocations is where the vendor stack starts
    // handing back reclaims, and a reclaimed decoder is worse than a late
    // one: the player survives but its codec does not, so the spare the
    // user swipes onto opens cold anyway AND the pool paid for it.
    //
    // Waiting for the previous spare to finish initialising costs the
    // second spare a few hundred milliseconds it was not going to be
    // needed in — the gesture that reaches it has not happened yet, or it
    // would be the active reel by now — and keeps the peak at two.
    final opening = _spareOpening;
    if (opening != null) {
      if (_pendingSpares.containsKey(url)) return;
      _pendingSpares[url] = lane;
      unawaited(
        opening.then((_) {
          // Same re-checks the grace path makes, for the same reason: the
          // wait is long enough for the user to have moved on.
          if (_pendingSpares.remove(url) == null) return;
          if (_prefetchedUrls.contains(url)) return;
          if (_pool.any((e) => e.url == url)) return;
          _requestSpare(url, lane);
        }),
      );
      return;
    }

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

  /// The initialisation of the spare currently being built, or null when
  /// none is in flight.
  ///
  /// Read by [_requestSpare] as the one-at-a-time gate — see the comment
  /// there for why concurrent spare construction is what triggers decoder
  /// reclaims. Cleared when the initialise settles, whether it succeeded
  /// or threw, and bounded by [spareOpenTimeout] so a player that never
  /// reports ready cannot wedge the gate shut for the session.
  Future<void>? _spareOpening;

  /// Identifies which spare owns [_spareOpening], so a settled gate only
  /// clears itself and never a newer one.
  Object? _spareOpenToken;

  /// How long the one-at-a-time gate waits on a spare that is not
  /// reporting ready before letting the next one through.
  ///
  /// Generous on purpose: this is a deadlock guard, not a latency budget.
  /// A spare that takes longer than this has almost certainly failed in a
  /// way `initialize()` will not surface, and the alternative to letting
  /// the next one through is opening no further spares at all.
  static const Duration spareOpenTimeout = Duration(seconds: 8);

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
    final opening = controller
        .initialize()
        .then((_) {
          // The spare is silent. AudioFocus on Android is exclusive — an
          // unmuted spare fights the active reel and chops its audio. The
          // promote path in getController restores volume. No pause needed:
          // nothing ever calls play() on a spare, and video_player leaves a
          // controller that was not playing paused once it initialises.
          //
          // Via [_volumeFor] rather than a flat 0, because a spare can be
          // promoted to the reel on screen while it is still initialising —
          // the user swiping onto it before its first frame lands. Muting
          // unconditionally here silenced exactly that case, and the sweep
          // that would have fixed it had already run.
          controller.setVolume(_volumeFor(next));
          // Same question, same answer: still a spare means still no reason
          // to decode a sound track nobody can hear. See [setPlayerAudio].
          if (next != _activeUrl) {
            final entry = _pool.where((e) => e.url == next).firstOrNull;
            if (entry != null) _setEntryAudio(entry, enabled: false);
          }
        })
        .catchError((_) {
          // Surfaced when the caller actually tries to use this URL.
        });
    // Hold the gate until this one is ready, so the next spare's codec
    // allocation does not overlap this one's. Failures release the gate
    // too — a spare that could not open is not holding a decoder.
    //
    // The token guards against a later spare having already claimed the
    // gate by the time this one settles, which [debugOpenSpare] can do
    // because it bypasses [_requestSpare] and therefore the gate itself.
    final token = Object();
    _spareOpenToken = token;
    _spareOpening = opening
        .timeout(spareOpenTimeout, onTimeout: () {})
        .whenComplete(() {
          if (identical(_spareOpenToken, token)) {
            _spareOpenToken = null;
            _spareOpening = null;
          }
        });
    _pool.add(_PoolEntry(controller: controller, url: next, isPrefetch: true));
    _prefetchedUrls.add(next);
  }

  /// Pause all controllers except the one playing the given URL. Also
  /// mutes the paused side as a belt-and-suspenders guard so a
  /// controller that somehow autoplays during init doesn't bleed audio
  /// onto the active reel.
  /// Returns once the outgoing players have actually stopped, so the
  /// caller can start the incoming one without overlapping them.
  ///
  /// The pauses used to be fire-and-forget, which reads as harmless —
  /// they are all headed for the same platform channel — but the reel
  /// arriving calls play() in the same turn, and play() is what makes
  /// ExoPlayer request AudioFocus. Focus is exclusive, so the request is
  /// granted by taking focus off the outgoing player, which is still
  /// decoding because its pause has not landed yet. Device logs show the
  /// window plainly, in this order:
  ///
  ///     I/ExoPlayerImpl: Init 768c029
  ///     D/AudioManager: dispatching onAudioFocusChange(-1) ...
  ///     D/AudioTrack: pause(38264): prior state:STATE_ACTIVE
  ///
  /// The outgoing track was ACTIVE when focus moved — that overlap is the
  /// audible chop on every swipe. Awaiting the pauses closes it.
  ///
  /// The wait is bounded, and that bound is the whole safety of this
  /// method. A pause is a round trip to a native player, and a native
  /// player whose decoder the resource manager already took, or whose
  /// playback thread is gone, never answers:
  ///
  ///     E/MediaCodec: Released by resource manager
  ///     java.lang.IllegalStateException: ... a Handler on a dead thread
  ///
  /// Its future then stays pending forever rather than failing, which
  /// `catchError` below does nothing about. Unbounded, that turns one dead
  /// outgoing player into a permanently frozen incoming reel, because the
  /// caller's play() sits behind this await — a worse bug than the chop
  /// the await was added to fix. After [pauseSettleTimeout] we start the
  /// new reel regardless and accept the overlap.
  Future<void> pauseAllExcept(String activeUrl) async {
    // The authoritative "this reel is on screen" signal. Eviction reads
    // it to keep the watched player alive, and [_volumeFor] reads it so a
    // controller that finishes initialising later comes up at the right
    // volume instead of racing this sweep.
    _activeUrl = activeUrl;
    final stopping = <Future<void>>[];
    for (final entry in _pool) {
      if (entry.url != activeUrl) {
        stopping.add(entry.controller.pause());
        stopping.add(entry.controller.setVolume(0));
        // And stop decoding the sound as well as silencing it. This is the
        // one place that knows which reel is on screen, so it is the right
        // place to own the answer for every player at once — see
        // [setPlayerAudio]. Not awaited: nothing the caller does next
        // depends on it, and it must not delay the incoming reel.
        _setEntryAudio(entry, enabled: false);
      } else {
        // Not awaited: the incoming reel's volume is not what the caller
        // is waiting on, and holding play() back for it would add a
        // channel round-trip to every swipe.
        // ignore: discarded_futures
        entry.controller.setVolume(activeVolume);
        // Give this one its audio decoder back. It may have arrived here as
        // a silent spare, and a reel on screen that cannot make a sound is
        // worse than the decoder it costs.
        _setEntryAudio(entry, enabled: true);
      }
    }
    if (stopping.isEmpty) return;
    // A controller disposed mid-sweep completes with an error rather than
    // a value. That is not a reason to leave the incoming reel unstarted,
    // so failures are absorbed — the point of the await is only that the
    // outgoing decoders have had their chance to stop. Neither is a player
    // that never answers at all: see [pauseSettleTimeout].
    await Future.wait(stopping)
        .catchError((_) => const <void>[])
        .timeout(pauseSettleTimeout, onTimeout: () => const <void>[]);
  }

  /// Make [url] the reel on screen and start it playing.
  ///
  /// THE ONLY SUPPORTED WAY TO START A VIDEO. Widgets are not meant to call
  /// `play()` on a controller themselves, and the reason is the class of bug
  /// this method exists to make impossible.
  ///
  /// There used to be two places that started playback — the feed, on a
  /// vertical swipe, and the battle tile, on a flip to the opponent — and
  /// only one of them told this service what it had done. So while the user
  /// watched an opponent's video, [_activeUrl] still named the challenger,
  /// and everything downstream that asks "what is on screen" got the wrong
  /// answer: eviction happily disposed the visible player, and the
  /// initialisation callback muted and paused it. Both showed up as a reel
  /// frozen on its last frame.
  ///
  /// Declaring the reel and starting it are the same act, so they are one
  /// call. A caller that cannot reach playback without going through the
  /// declaration cannot forget to make it.
  ///
  /// Returns without starting anything if [url] has no live player, or if
  /// something else claimed the screen while the outgoing players were
  /// stopping — the user swiping on during the handover.
  Future<void> showAndPlay(String url) async {
    await pauseAllExcept(url);
    // Re-checked AFTER the await rather than before: a second swipe during
    // the handover runs its own showAndPlay, which sets _activeUrl to the
    // new reel. Whichever call loses this race must not start a video the
    // user has already scrolled past.
    if (_activeUrl != url) return;
    final entry = _pool.where((e) => e.url == url).firstOrNull;
    if (entry == null) return;
    entry.lastUsed = DateTime.now();
    // ignore: discarded_futures
    entry.controller.setVolume(activeVolume);
    // Deliberately not awaited, and deliberately allowed before the player
    // has initialised: video_player replays a play() issued during startup
    // once the player is ready, and the feed relies on that to show the
    // first frame of a cold reel the moment it exists.
    // ignore: discarded_futures
    entry.controller.play();
  }

  /// Stop the reel on screen without giving up its place.
  ///
  /// For a deliberate pause — the tap-to-pause gesture. [resumeActive] is
  /// the other half. Nothing about which reel is on screen changes, so the
  /// player keeps its audio decoder and its protection from eviction.
  Future<void> pauseActive() async {
    final entry = _activeEntry;
    if (entry == null) return;
    await entry.controller.pause();
  }

  /// Start the reel on screen again after [pauseActive].
  Future<void> resumeActive() async {
    final entry = _activeEntry;
    if (entry == null) return;
    // ignore: discarded_futures
    entry.controller.setVolume(activeVolume);
    await entry.controller.play();
  }

  _PoolEntry? get _activeEntry {
    final url = _activeUrl;
    if (url == null) return null;
    return _pool.where((e) => e.url == url).firstOrNull;
  }

  /// How long [pauseAllExcept] will wait for the outgoing players.
  ///
  /// Long enough that a healthy pause — a method-channel hop and an
  /// ExoPlayer state change, single-digit milliseconds on device — always
  /// lands inside it, so the ordering this buys is the normal case. Short
  /// enough that a player which will never answer costs the user a
  /// just-noticeable delay rather than a dead reel.
  static const Duration pauseSettleTimeout = Duration(milliseconds: 300);

  /// Pause all controllers (e.g., when app goes to background).
  void pauseAll() {
    for (final entry in _pool) {
      entry.controller.pause();
    }
  }

  /// Release a specific controller back to pool (pause it).
  Future<void> release(String url) async {
    final entry = _pool.where((e) => e.url == url).firstOrNull;
    if (entry == null) return;
    await entry.controller.pause();
  }

  /// Set the session-wide feed mute and apply it to the reel on screen.
  ///
  /// Both halves, because they were split and the split was a bug source.
  /// The mute button used to flip the flag here and then set the volume on
  /// whatever the tile thought the active controller was — a second opinion
  /// about what is on screen, which on a battle flip disagreed with this
  /// service's. Every other path that restores audible volume already reads
  /// [activeVolume], so this is the one that was out of step.
  Future<void> setFeedMuted(bool muted) async {
    feedMuted.value = muted;
    final entry = _activeEntry;
    if (entry == null) return;
    await entry.controller.setVolume(activeVolume);
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
    // Release the one-at-a-time gate. A shutdown that left it held would
    // make the first spare of the NEXT session wait out [spareOpenTimeout]
    // behind a player that no longer exists.
    _spareOpenToken = null;
    _spareOpening = null;
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

  /// Turns audio decoding off, and back on, for a single native player.
  ///
  /// A muted player is not a quiet player. [VideoPlayerController.setVolume]
  /// silences the OUTPUT; the decoder behind it keeps running, holding a
  /// hardware AAC instance and an AudioTrack for a reel nobody can hear. On
  /// device that showed up as `Qinput: 126, Render: 0, Drop: 122` — a hundred
  /// chunks of sound decoded and none of it played — on every warm spare and
  /// every off-screen PageView neighbour at once.
  ///
  /// That is the budget this app actually runs out of. Concurrent hardware
  /// decoders are a small fixed number set by the SoC, and each warm player
  /// was spending two slots to use one. Past the limit Android takes decoders
  /// back mid-playback (`E/MediaCodec: Released by resource manager`), which
  /// the user sees as a reel frozen on its last frame.
  ///
  /// Seam, in the same spirit as [deferRelease]: the real implementation
  /// needs the Android platform class, and the pool tests run against a fake
  /// platform that is deliberately none of the real ones. Swapping this lets
  /// them assert WHEN the pool asks for audio to be dropped and restored,
  /// which is the part that can be wrong, without pretending to be ExoPlayer.
  @visibleForTesting
  static Future<void> Function(VideoPlayerController controller,
      {required bool enabled}) setPlayerAudio = _platformSetPlayerAudio;

  /// The production [setPlayerAudio]: hand the request to the Android plugin.
  ///
  /// Android-only, and silently a no-op everywhere else. The method is a
  /// local addition to our vendored copy of `video_player_android` — see
  /// third_party/video_player_android/LOCAL_CHANGES.md — so it does not exist
  /// on `VideoPlayerPlatform` and the cast is how it is reached. iOS and web
  /// keep the old behaviour: muted, still decoding.
  static Future<void> _platformSetPlayerAudio(
    VideoPlayerController controller, {
    required bool enabled,
  }) async {
    final platform = VideoPlayerPlatform.instance;
    if (platform is! AndroidVideoPlayer) return;
    // The player is addressed by its data source rather than by its id: the
    // id is only reachable through VideoPlayerController.playerId, which
    // upstream marks @visibleForTesting and documents as "shouldn't be used
    // by anyone depending on the plugin". dataSource is public API and is the
    // same string the plugin stored the player under.
    try {
      final applied = await platform.setAudioEnabledForSource(
        controller.dataSource,
        enabled: enabled,
      );
      // A player the plugin has no record of. The normal reasons are benign
      // — it was disposed while this call was in flight, or it has not
      // finished being created — but a lasting mismatch between the string we
      // hold and the one it stored would make every call here a silent no-op,
      // and nothing else in the app would notice. Loud in debug, ignored in
      // release, where a missed decoder is not worth a crash.
      assert(
        applied || !controller.value.isInitialized,
        'No Android player is registered for ${controller.dataSource}, so '
        'audio decoding was left on. If this fires for an initialised '
        'controller, dataSource and the plugin\'s stored uri have diverged.',
      );
    } catch (_) {
      // A player disposed mid-call, or a platform that does not implement it.
      // Audio decoding is a resource optimisation: failing to apply it costs
      // a decoder slot, never correctness, and must not break playback.
    }
  }

  /// Apply [enabled] to [entry] if it is not already in that state.
  void _setEntryAudio(_PoolEntry entry, {required bool enabled}) {
    if (entry.audioEnabled == enabled) return;
    entry.audioEnabled = enabled;
    // ignore: discarded_futures
    setPlayerAudio(entry.controller, enabled: enabled);
  }

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

  /// Whether a spare is mid-construction, i.e. whether [_requestSpare]
  /// would currently defer the next one.
  ///
  /// The gate's failure mode is silent and total — a gate that is never
  /// released opens no further spares for the rest of the session, and
  /// the spare counters would report that as a feed which simply stopped
  /// wanting spares — so the release path is worth asserting on directly.
  @visibleForTesting
  bool get debugSpareGateHeld => _spareOpening != null;

  @visibleForTesting
  int get debugPoolSize => _pool.length;

  @visibleForTesting
  List<String> get debugPoolUrls => _pool.map((e) => e.url).toList();

  /// The reel this service believes is on screen.
  ///
  /// Worth asserting on directly: when this disagreed with what was actually
  /// playing, the visible player lost its protection from eviction and got
  /// muted by its own initialisation callback, and nothing in the pool's
  /// other observable state said so.
  @visibleForTesting
  String? get debugActiveUrl => _activeUrl;
}

class _PoolEntry {
  final VideoPlayerController controller;
  final String url;

  /// Mutable so we can "promote" an entry from prefetch → active when
  /// getController returns an existing prefetched controller.
  bool isPrefetch;
  DateTime lastUsed;

  /// Whether this player is currently decoding its audio track.
  ///
  /// Tracked so the pool only crosses the platform channel when the answer
  /// actually changes. Players are born decoding audio — the flag starts
  /// true to match, not because we asked for it.
  bool audioEnabled = true;

  _PoolEntry({
    required this.controller,
    required this.url,
    this.isPrefetch = false,
  }) : lastUsed = DateTime.now();
}
