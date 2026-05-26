import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/video_player_service.dart';

/// Full-screen video player page using the official `video_player`
/// plugin (ExoPlayer/AVPlayer/HTML5). Supports play/pause, seek,
/// progress bar, duration display, looping, and double-tap to seek
/// forward/backward.
class VideoPlayerPage extends StatefulWidget {
  final String videoUrl;
  final String title;

  const VideoPlayerPage({
    super.key,
    required this.videoUrl,
    this.title = 'Video',
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with PageTracker<VideoPlayerPage>, WidgetsBindingObserver {
  late final VideoPlayerController _controller;
  bool _hasError = false;
  bool _initialized = false;
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  String get pageName => 'video_player_page';

  @override
  Map<String, dynamic> get pageParams => {'title': widget.title};

  // Double-tap seek feedback
  String? _seekFeedback;
  Timer? _seekFeedbackTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = VideoPlayerService.instance.getController(widget.videoUrl);
    // Mute any background players (e.g. the reels feed underneath) so
    // they don't compete for AudioFocus while this page is foreground.
    VideoPlayerService.instance.pauseAllExcept(widget.videoUrl);

    // Single listener for everything we care about — initialization,
    // playback errors, and forwarding state changes to setState.
    _controller.addListener(_onControllerUpdate);

    // The pool may hand us either a fresh controller still initializing
    // or a prefetched one already past initialize(). Cover both:
    // poll once for the prefetched case, await for the fresh case.
    if (_controller.value.isInitialized) {
      _initialized = true;
    } else {
      // Fire-and-forget — listener handles state once init resolves.
      // ignore: discarded_futures
      _controller.initialize().catchError((_) {
        // Surfaced via the listener's hasError check.
      });
    }

    _controller.setLooping(true);
    _controller.setVolume(1.0);
    // Fire-and-forget play; if init is still in flight ExoPlayer queues
    // the play() call and honors it once ready.
    // ignore: discarded_futures
    _controller.play();

    // Auto-hide controls after 3 seconds
    _startHideTimer();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final v = _controller.value;
    // First-frame ready → flip _initialized so the spinner can hide.
    if (v.isInitialized && !_initialized) {
      setState(() => _initialized = true);
    }
    // Playback error surfaces here whether it came from init or from a
    // mid-playback failure (network drop, decoder bail).
    if (v.hasError && !_hasError) {
      EventTracker.instance.trackError(
        surface: 'video_player_page',
        errorType: 'video_playback_error',
        message: v.errorDescription ?? 'unknown',
      );
      setState(() => _hasError = true);
    } else if (mounted) {
      // Cheap setState so the progress bar / play-pause icon repaint
      // as position and isPlaying change. video_player's controller is
      // a ValueNotifier so this listener fires roughly per frame
      // during playback — Flutter coalesces redundant rebuilds.
      setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    // Detach BEFORE releasing — the controller survives this page (it
    // goes back to the pool), and a stray listener call after dispose
    // would call setState on a disposed State. Wrapped in try/catch
    // because the pool may have LRU-evicted the controller while we
    // weren't looking — calling removeListener on a disposed
    // VideoPlayerController throws.
    try {
      _controller.removeListener(_onControllerUpdate);
    } catch (_) {
      // Controller already disposed by the pool. Listener went with it.
    }
    VideoPlayerService.instance.release(widget.videoUrl);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-assert audio ownership. SmartReelsFeed's lifecycle observer
      // fires before ours (FIFO — it was registered first) and calls
      // pauseAllExcept(feedUrl), which mutes our controller. We fire
      // after it and reclaim audio for the video that's actually on
      // screen.
      VideoPlayerService.instance.pauseAllExcept(widget.videoUrl);
      _controller.play();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _controller.pause();
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _startHideTimer();
  }

  void _togglePlayPause() {
    if (_controller.value.isPlaying) {
      _controller.pause();
    } else {
      _controller.play();
    }
    _startHideTimer();
  }

  void _seekRelative(Duration offset) {
    final current = _controller.value.position;
    final dur = _controller.value.duration;
    var target = current + offset;
    if (target < Duration.zero) target = Duration.zero;
    if (target > dur) target = dur;
    _controller.seekTo(target);

    final seconds = offset.inSeconds;
    setState(() {
      _seekFeedback = seconds > 0 ? '+${seconds}s' : '${seconds}s';
    });
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _seekFeedback = null);
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _showControls
          ? AppBar(
              backgroundColor: Colors.black87,
              foregroundColor: Colors.white,
              title: Text(widget.title),
              systemOverlayStyle: SystemUiOverlayStyle.light,
            )
          : null,
      extendBodyBehindAppBar: true,
      body: _hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 48),
                  const SizedBox(height: 12),
                  Text('Could not play video',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 16)),
                  const SizedBox(height: 16),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _hasError = false;
                        _initialized = false;
                      });
                      // ignore: discarded_futures
                      _controller.initialize().then((_) => _controller.play());
                    },
                    icon: const Icon(Icons.refresh, color: Colors.white70),
                    label: const Text('Retry',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            )
          : GestureDetector(
              onTap: _toggleControls,
              onDoubleTapDown: (details) {
                final screenWidth = MediaQuery.of(context).size.width;
                if (details.globalPosition.dx < screenWidth / 2) {
                  _seekRelative(const Duration(seconds: -10));
                } else {
                  _seekRelative(const Duration(seconds: 10));
                }
              },
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Video. Letterboxed via AspectRatio — for a full-screen
                  // player this is the right choice: stretching would
                  // crop content the user explicitly asked to see.
                  if (_initialized)
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),

                  // Loading indicator while we wait for the first frame.
                  if (!_initialized)
                    const CircularProgressIndicator(color: Colors.white),

                  // Seek feedback
                  if (_seekFeedback != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _seekFeedback!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold),
                      ),
                    ),

                  // Controls overlay
                  if (_showControls && _initialized)
                    _buildControls(),
                ],
              ),
            ),
    );
  }

  Widget _buildControls() {
    final position = _controller.value.position;
    final duration = _controller.value.duration;
    final isPlaying = _controller.value.isPlaying;

    return Container(
      color: Colors.transparent,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Center play/pause button
          Expanded(
            child: Center(
              child: IconButton(
                onPressed: _togglePlayPause,
                iconSize: 64,
                icon: Icon(
                  isPlaying ? Icons.pause_circle : Icons.play_circle,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
            ),
          ),

          // Bottom bar: progress + time
          Container(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black87],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Progress bar
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14),
                    activeTrackColor:
                        Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Theme.of(context).colorScheme.primary,
                  ),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? (position.inMilliseconds /
                                duration.inMilliseconds)
                            .clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: (value) {
                      final target = Duration(
                          milliseconds:
                              (value * duration.inMilliseconds).round());
                      _controller.seekTo(target);
                    },
                  ),
                ),

                // Time display
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatDuration(position),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                      Text(_formatDuration(duration),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
