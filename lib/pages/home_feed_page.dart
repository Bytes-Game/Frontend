import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_player_service.dart';
import 'package:myapp/widgets/feed_action_bar.dart';
import 'package:visibility_detector/visibility_detector.dart';

class HomeFeedPage extends StatefulWidget {
  final int startIndex;
  const HomeFeedPage({super.key, this.startIndex = 0});

  @override
  State<HomeFeedPage> createState() => _HomeFeedPageState();
}

class _HomeFeedPageState extends State<HomeFeedPage>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _feedItems = [];
  bool _loading = true;
  int _currentIndex = 0;
  int _battleSide = 0; // 0=creator, 1=opponent
  bool _isPaused = false;
  late PageController _pageController;
  Timer? _debounce;
  double _swipeStartX = 0;
  double _swipeStartY = 0;

  // Active controller for whichever URL is currently on screen. Null
  // before _loadFeed resolves and between _openVideo calls (briefly).
  // We don't OWN this controller — VideoPlayerService.getController()
  // pools it, and release() pauses it for re-use on back-swipe.
  VideoPlayerController? _currentController;
  String? _currentUrl;

  // ─── Impression / engagement tracking state ──────────────────────
  DateTime? _currentItemShownAt;   // when current item became visible
  int _currentItemLoopCount = 0;   // how many times current item looped
  bool _currentItemCompleted = false;
  bool _currentItemMuted = true;   // assume muted-ish autoplay; flips on unmute
  int _lastReportedIndex = -1;     // for scroll-back detection
  Duration _lastKnownPosition = Duration.zero;
  // Tracks the controller we've attached a listener to so we can
  // detach cleanly on switch. video_player has no streams — state
  // changes come through a single ValueListenable callback.
  VoidCallback? _listenerRef;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentIndex = widget.startIndex;
    _pageController = PageController(initialPage: widget.startIndex);
    _loadFeed();
  }

  @override
  void dispose() {
    // Flush impression for the final item the user was on
    _flushImpressionForCurrent();
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _detachCurrentListener();
    if (_currentUrl != null) {
      VideoPlayerService.instance.release(_currentUrl!);
    }
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // App-root observer (in main.dart) is the single source of truth for the
    // app_background/app_foreground events themselves. This per-page handler
    // only does local cleanup — flushing the current item's impression so the
    // dwell time isn't lost, and resetting the dwell timer on resume.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushImpressionForCurrent();
    } else if (state == AppLifecycleState.resumed) {
      _currentItemShownAt = DateTime.now();
    }
  }

  ChallengeModel? _currentChallenge() {
    if (_feedItems.isEmpty || _currentIndex >= _feedItems.length) return null;
    return _feedItems[_currentIndex]['challenge'] as ChallengeModel?;
  }

  /// Detach the listener from the previously-active controller (if
  /// any). Call this BEFORE switching to a new URL and on dispose.
  ///
  /// Wrapped in try/catch because the pool may have LRU-evicted (and
  /// disposed) the controller while we weren't looking — calling
  /// removeListener on a disposed VideoPlayerController throws.
  void _detachCurrentListener() {
    final ref = _listenerRef;
    final ctrl = _currentController;
    if (ref != null && ctrl != null) {
      try {
        ctrl.removeListener(ref);
      } catch (_) {
        // Controller already disposed by the pool. Nothing to detach.
      }
    }
    _listenerRef = null;
  }

  /// Attach the unified state listener to [controller]. Replaces
  /// media_kit's separate position/completed/volume streams — all three
  /// signals now come through the single ValueListenable callback, and
  /// we detect transitions by comparing against [_lastKnownPosition] /
  /// [_currentItemMuted] cached state.
  void _attachListener(VideoPlayerController controller) {
    _detachCurrentListener();
    void onUpdate() {
      if (!mounted) return;
      final v = controller.value;
      if (!v.isInitialized) return;
      final c = _currentChallenge();
      final pos = v.position;
      final dur = v.duration;

      // Complete detection (95%+)
      if (!_currentItemCompleted &&
          dur.inMilliseconds > 0 &&
          pos.inMilliseconds >= (dur.inMilliseconds * 0.95).toInt() &&
          c != null) {
        _currentItemCompleted = true;
        EventTracker.instance.trackComplete(
          contentId: c.id,
          contentType: 'challenge',
          totalDurationMs: dur.inMilliseconds,
        );
      }

      // Loop detection. With setLooping(true), video_player wraps
      // position from ~duration back to 0 without an explicit event.
      // We catch that wrap by spotting a large backward jump near
      // the end of the clip and treating it as a loop boundary.
      final deltaMs =
          pos.inMilliseconds - _lastKnownPosition.inMilliseconds;
      if (c != null &&
          dur.inMilliseconds > 0 &&
          _lastKnownPosition.inMilliseconds > (dur.inMilliseconds * 0.8) &&
          pos.inMilliseconds < (dur.inMilliseconds * 0.2)) {
        _currentItemLoopCount++;
        EventTracker.instance.trackLoop(
          contentId: c.id,
          contentType: 'challenge',
          loopNumber: _currentItemLoopCount,
        );
        _currentItemCompleted = false;
      } else if (c != null &&
          dur.inMilliseconds > 0 &&
          (deltaMs > 1200 || deltaMs < -500)) {
        // Seek detection — position jumped more than 1.2s forward
        // or any backward jump > 500ms (and not a loop wrap above).
        EventTracker.instance.trackSeek(
          contentId: c.id,
          contentType: 'challenge',
          fromMs: _lastKnownPosition.inMilliseconds,
          toMs: pos.inMilliseconds,
        );
      }
      _lastKnownPosition = pos;

      // Volume / unmute detection. video_player exposes the current
      // volume on the controller's value, so we sample it here.
      final nowMuted = v.volume <= 0.01;
      if (_currentItemMuted && !nowMuted && c != null) {
        EventTracker.instance.trackUnmute(
          contentId: c.id,
          contentType: 'challenge',
        );
      }
      _currentItemMuted = nowMuted;
    }

    _listenerRef = onUpdate;
    controller.addListener(onUpdate);
  }

  void _flushImpressionForCurrent() {
    final c = _currentChallenge();
    final shownAt = _currentItemShownAt;
    if (c == null || shownAt == null) return;
    final dwellMs = DateTime.now().difference(shownAt).inMilliseconds;
    if (dwellMs <= 0) return;
    EventTracker.instance.trackImpression(
      contentId: c.id,
      contentType: 'challenge',
      dwellMs: dwellMs,
    );
    _currentItemShownAt = null;
  }

  Future<void> _loadFeed() async {
    try {
      final items = await ApiService.getChallengesFeed();
      debugPrint('HomeFeed: loaded ${items.length} items');
      if (!mounted) return;
      final filtered = items.where((item) {
        final c = item['challenge'] as ChallengeModel;
        return c.videoUrl.isNotEmpty;
      }).toList();
      debugPrint('HomeFeed: ${filtered.length} with video');
      final battles = filtered.where((item) {
        final r = (item['responses'] as List?) ?? [];
        return r.isNotEmpty;
      }).length;
      debugPrint('HomeFeed: $battles battles with responses');
      _feedItems = filtered;
      _loading = false;
      setState(() {});
      if (filtered.isNotEmpty) {
        final start = widget.startIndex.clamp(0, filtered.length - 1);
        _currentIndex = start;
        _openVideo(start);
      }
    } catch (e) {
      debugPrint('HomeFeed error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openVideo(int index) {
    if (index < 0 || index >= _feedItems.length) return;
    final c = _feedItems[index]['challenge'] as ChallengeModel;
    final url = c.videoUrl;
    if (url.isEmpty) return;
    debugPrint('HomeFeed: PLAY $url');
    _switchToUrl(url);
    _isPaused = false;
    _battleSide = 0;
    // Reset per-item tracking state
    _currentItemCompleted = false;
    _currentItemLoopCount = 0;
    _lastKnownPosition = Duration.zero;
    _currentItemShownAt ??= DateTime.now();
  }

  /// Switch the active controller to one playing [url]. Pulls from the
  /// pool — prefetched controllers come back already-initialized for
  /// instant scroll. Releases the previous URL back to the pool so it
  /// stays warm for back-swipe.
  void _switchToUrl(String url) {
    if (url == _currentUrl && _currentController != null) {
      // Same URL — just play it.
      // ignore: discarded_futures
      _currentController!.play();
      return;
    }
    // Release the old controller (pause + leave in pool) and detach
    // the listener so the next update doesn't fire against it.
    _detachCurrentListener();
    if (_currentUrl != null) {
      VideoPlayerService.instance.release(_currentUrl!);
    }
    final ctrl = VideoPlayerService.instance.getController(url);
    // ignore: discarded_futures
    ctrl.setLooping(true);
    // ignore: discarded_futures
    ctrl.setVolume(1.0);
    // ignore: discarded_futures
    ctrl.play();
    VideoPlayerService.instance.pauseAllExcept(url);
    _attachListener(ctrl);
    setState(() {
      _currentController = ctrl;
      _currentUrl = url;
    });
  }

  void _onPageChanged(int index) {
    // Flush impression for item we just left
    _flushImpressionForCurrent();

    // Scroll-back detection: index decreased means user swiped backward.
    if (_lastReportedIndex >= 0 &&
        index < _lastReportedIndex &&
        index < _feedItems.length) {
      final c = _feedItems[index]['challenge'] as ChallengeModel?;
      if (c != null) {
        EventTracker.instance.trackScrollBack(
          contentId: c.id,
          contentType: 'challenge',
        );
      }
    }
    _lastReportedIndex = index;

    // Debounce — only play after user stops scrolling for 300ms
    _debounce?.cancel();
    _currentIndex = index;
    // Begin dwell timer for the new item immediately (visibility detector
    // confirms it, but this is a safe lower bound).
    _currentItemShownAt = DateTime.now();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        _openVideo(index);
        setState(() {}); // update overlay text
      }
    });
  }

  void _togglePause() {
    final c = _currentChallenge();
    final ctrl = _currentController;
    if (ctrl == null) return;
    if (_isPaused) {
      // ignore: discarded_futures
      ctrl.play();
    } else {
      // ignore: discarded_futures
      ctrl.pause();
    }
    setState(() => _isPaused = !_isPaused);
    if (c != null) {
      EventTracker.instance.trackPauseToggle(
        contentId: c.id,
        contentType: 'challenge',
        isPaused: _isPaused,
        positionMs: _lastKnownPosition.inMilliseconds,
      );
    }
  }

  void _switchBattleSide(int side) {
    if (side == _battleSide) return;
    final item = _feedItems[_currentIndex];
    final c = item['challenge'] as ChallengeModel;
    final responses = (item['responses'] as List?)
            ?.cast<ChallengeResponseModel>() ??
        [];
    setState(() => _battleSide = side);
    EventTracker.instance.trackBattleSwitch(
      challengeId: c.id,
      side: side,
    );
    if (side == 0) {
      _switchToUrl(c.videoUrl);
    } else if (responses.isNotEmpty) {
      _switchToUrl(responses.first.videoUrl);
    }
    // Reset completion/loop state for new clip
    _currentItemCompleted = false;
    _currentItemLoopCount = 0;
    _lastKnownPosition = Duration.zero;
  }

  @override
  Widget build(BuildContext context) {
    // Current item info (safe defaults when loading)
    ChallengeModel? challenge;
    List<ChallengeResponseModel> responses = [];
    if (_feedItems.isNotEmpty && _currentIndex < _feedItems.length) {
      final item = _feedItems[_currentIndex];
      challenge = item['challenge'] as ChallengeModel;
      responses = (item['responses'] as List?)
              ?.cast<ChallengeResponseModel>() ??
          [];
    }
    final hasBattle = responses.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video — only mounted once we have an initialized controller.
          // Black backdrop fills the screen until then so the user
          // doesn't see a flash of scaffold colour. BoxFit.cover via
          // FittedBox so the video fills the screen edge-to-edge
          // (reels never letterbox — they crop).
          const ColoredBox(color: Colors.black),
          if (_currentController != null &&
              _currentController!.value.isInitialized)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _currentController!.value.size.width,
                  height: _currentController!.value.size.height,
                  child: VideoPlayer(_currentController!),
                ),
              ),
            ),

          // Loading spinner on top of video
          if (_loading)
            const Center(child: CircularProgressIndicator(color: Colors.white)),

          // Empty message
          if (!_loading && _feedItems.isEmpty)
            const Center(
              child: Text('No challenges yet',
                  style: TextStyle(color: Colors.white)),
            ),

          // Vertical PageView for swipe detection (transparent pages)
          if (!_loading && _feedItems.isNotEmpty)
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: _feedItems.length,
                onPageChanged: _onPageChanged,
                itemBuilder: (_, index) {
                  final c =
                      _feedItems[index]['challenge'] as ChallengeModel?;
                  final id = c?.id ?? 'idx_$index';
                  return VisibilityDetector(
                    key: Key('feed_item_$id'),
                    onVisibilityChanged: (info) {
                      // Fully visible (>80%) -> start/refresh dwell timer
                      if (info.visibleFraction > 0.8 &&
                          index == _currentIndex) {
                        _currentItemShownAt ??= DateTime.now();
                      }
                      // Left viewport (<10%) -> flush impression for THIS item
                      if (info.visibleFraction < 0.1 &&
                          c != null &&
                          _currentItemShownAt != null) {
                        final dwellMs = DateTime.now()
                            .difference(_currentItemShownAt!)
                            .inMilliseconds;
                        if (dwellMs > 0) {
                          EventTracker.instance.trackImpression(
                            contentId: c.id,
                            contentType: 'challenge',
                            dwellMs: dwellMs,
                          );
                        }
                        // Only null the timer if we're leaving the current item
                        if (index == _currentIndex) {
                          _currentItemShownAt = null;
                        }
                      }
                    },
                    child: const SizedBox.expand(),
                  );
                },
              ),
            ),

          // Horizontal swipe + tap detection layer.
          // Listener observes raw pointer events without consuming them,
          // so vertical PageView scrolling still works underneath.
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                _swipeStartX = e.position.dx;
                _swipeStartY = e.position.dy;
                debugPrint('SWIPE: pointer down at (${e.position.dx}, ${e.position.dy})');
              },
              onPointerUp: (e) {
                final dx = e.position.dx - _swipeStartX;
                final dy = e.position.dy - _swipeStartY;
                final absDx = dx.abs();
                final absDy = dy.abs();
                debugPrint('SWIPE: pointer up dx=$dx dy=$dy');
                if (absDx < 10 && absDy < 10) {
                  _togglePause();
                } else if (absDx > 50 && absDx > absDy) {
                  final curResponses = (_feedItems.isNotEmpty &&
                          _currentIndex < _feedItems.length)
                      ? ((_feedItems[_currentIndex]['responses'] as List?) ??
                              [])
                          .cast<ChallengeResponseModel>()
                      : <ChallengeResponseModel>[];
                  debugPrint('SWIPE: horizontal! responses=${curResponses.length}');
                  if (curResponses.isNotEmpty) {
                    _switchBattleSide(dx < 0 ? 1 : 0);
                  }
                }
              },
              child: const SizedBox.expand(),
            ),
          ),

          // Pause icon
          if (_isPaused)
            const Center(
              child: IgnorePointer(
                child: Icon(Icons.pause_circle_filled,
                    color: Colors.white70, size: 64),
              ),
            ),

          // Battle switcher + dots
          if (hasBattle && challenge != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12,
              left: 0,
              right: 0,
              child: _buildBattleSwitcher(challenge, responses.first),
            ),

          // Right-side action bar (like, dislike, comment, share, vote)
          if (challenge != null)
            Positioned(
              right: 12,
              bottom: 180,
              child: FeedActionBar(
                challenge: challenge,
                responses: responses,
                battleSide: _battleSide,
              ),
            ),

          // Bottom gradient
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 160,
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
            ),
          ),

          // Bottom: username + title
          if (challenge != null)
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: IgnorePointer(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      challenge.creatorUsername,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      challenge.title,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_currentIndex + 1} / ${_feedItems.length}',
                      style:
                          const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),

          // Progress bar. video_player's controller is a Listenable
          // (not a Stream), so we wrap with ValueListenableBuilder to
          // get equivalent reactive rebuilds without manually
          // forwarding ticks.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: _currentController == null
                  ? const SizedBox.shrink()
                  : ValueListenableBuilder<VideoPlayerValue>(
                      valueListenable: _currentController!,
                      builder: (context, v, _) {
                        final pos = v.position;
                        final dur = v.duration;
                        final progress = dur.inMilliseconds > 0
                            ? (pos.inMilliseconds / dur.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0;
                        return LinearProgressIndicator(
                          value: progress,
                          minHeight: 2,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation(Colors.white),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBattleSwitcher(
      ChallengeModel challenge, ChallengeResponseModel opponent) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () => _switchBattleSide(0),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _battleSide == 0 ? Colors.orange : Colors.white24,
                  borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(20)),
                ),
                child: Text(
                  challenge.creatorUsername,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Colors.red,
              child: const Text('VS',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
            ),
            GestureDetector(
              onTap: () => _switchBattleSide(1),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: _battleSide == 1 ? Colors.blue : Colors.white24,
                  borderRadius: const BorderRadius.horizontal(
                      right: Radius.circular(20)),
                ),
                child: Text(
                  opponent.responderUsername,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _dot(0),
            const SizedBox(width: 6),
            _dot(1),
          ],
        ),
      ],
    );
  }

  Widget _dot(int index) {
    final active = _battleSide == index;
    return Container(
      width: active ? 20 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active ? Colors.white : Colors.white38,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
