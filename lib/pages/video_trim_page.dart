import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/video_processor_service.dart';

// We use video_player (ExoPlayer/AVPlayer/HTML5) — the official
// Flutter plugin. It doesn't ship a Windows/Linux desktop backend, so
// the trim screen on those platforms will fail to open the local file
// — but the trim *action* itself (video_compress) is already mobile-
// only and the page short-circuits with a "Desktop builds are dev-
// only" toast in _onUseClip(), so the missing preview is consistent
// with the desktop-unsupported message the user already sees.

/// Lightweight trim screen. Plays the source on loop, gives the user
/// a two-handle range slider, and produces a trimmed temp-file before
/// forwarding to [ChallengeMetadataPage] — or popping with the path,
/// when [popOnComplete] is set.
///
/// Trim is mandatory for sources longer than [VideoProcessorService.maxReelDuration].
/// Shorter sources still see the screen — it's the natural place to
/// preview-and-confirm before transcode kicks off.
///
/// Two callers wire this up:
///   * Create-challenge flow: pushes the trim page and lets it
///     pushReplacement → [ChallengeMetadataPage]. We do not need the
///     trimmed path back at the call site because the metadata page
///     takes the whole pipeline from there.
///   * Submit-response flow (from challenge detail): passes
///     [popOnComplete] = true so the trim page returns the trimmed
///     path; the caller then pushes its own response-upload page,
///     which carries the challengeId the metadata page wouldn't know
///     about.
class VideoTrimPage extends StatefulWidget {
  final String sourcePath;

  /// When true, after a successful trim the page pops with the
  /// trimmed file path (String) instead of pushing
  /// [ChallengeMetadataPage]. Default false keeps the legacy
  /// create-challenge behaviour.
  final bool popOnComplete;

  const VideoTrimPage({
    super.key,
    required this.sourcePath,
    this.popOnComplete = false,
  });

  @override
  State<VideoTrimPage> createState() => _VideoTrimPageState();
}

class _VideoTrimPageState extends State<VideoTrimPage>
    with PageTracker<VideoTrimPage> {
  @override
  String get pageName => 'video_trim_page';

  VideoPlayerController? _controller;
  Duration _total = Duration.zero;
  RangeValues? _range; // in milliseconds, both bounds inclusive
  bool _trimming = false;
  String? _initError;

  static const _maxClipMs = 60 * 1000; // mirrors processor cap
  static const _minClipMs = 1500;       // anything < 1.5s is a misclick

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerUpdate);
    // ignore: discarded_futures
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initVideo() async {
    try {
      // Construct from a File handle so we don't have to hand-roll the
      // file:// URI dance — VideoPlayerController.file does the right
      // thing on every supported platform.
      final controller = VideoPlayerController.file(File(widget.sourcePath));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      // Loop the source so the preview keeps playing while the user
      // tweaks the trim handles. The listener below seeks back to
      // start whenever playback overruns the trim end, so this loop
      // only matters for clips that fall entirely inside the selected
      // window.
      await controller.setLooping(true);
      // Volume isn't muted — the trim preview should be audible so the
      // user can pick a moment by ear as well as eye.
      await controller.setVolume(1.0);

      // Guard one more time: setLooping/setVolume each suspend on a
      // platform-channel hop, so the widget may have been disposed
      // between initialize() returning and now. Without this check we
      // either leak `controller` (dispose() ran with _controller still
      // null) or call setState on a disposed State.
      if (!mounted) {
        await controller.dispose();
        return;
      }

      // After initialize() resolves, duration is known. Seed the
      // slider window: full clip if it fits the cap, otherwise the
      // first [_maxClipMs] window. This way users who pick a 12s
      // clip can hit "Use clip" without touching the slider.
      final dur = controller.value.duration;
      _total = dur;
      final endMs = dur.inMilliseconds.clamp(0, _maxClipMs);
      _range = RangeValues(0, endMs.toDouble());

      controller.addListener(_onControllerUpdate);

      setState(() => _controller = controller);
      // Fire-and-forget play; the listener handles state once it starts.
      // ignore: discarded_futures
      controller.play();
    } catch (e) {
      if (!mounted) return;
      setState(() => _initError = 'Could not open video: $e');
    }
  }

  /// Listener replaces media_kit's separate position/duration streams.
  /// Two responsibilities:
  ///   1. Clamp playback to the user's trim window (seek back to start
  ///      whenever the playhead overruns r.end).
  ///   2. Defensive: track late-arriving duration updates (rare with
  ///      local files but cheap to handle).
  void _onControllerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (!v.isInitialized) return;

    // Late duration update — shouldn't fire with local files but be safe.
    if (v.duration.inMilliseconds > 0 && v.duration != _total) {
      setState(() => _total = v.duration);
    }

    final r = _range;
    if (r == null) return;
    final posMs = v.position.inMilliseconds;
    if (posMs > r.end || posMs < r.start - 50) {
      // ignore: discarded_futures
      c.seekTo(Duration(milliseconds: r.start.toInt()));
    }
  }

  Future<void> _onUseClip() async {
    final r = _range;
    if (r == null || _trimming) return;

    final spanMs = (r.end - r.start).round();
    if (spanMs < _minClipMs) {
      _toast('Clip is too short — pick at least 1.5 seconds.');
      return;
    }
    if (spanMs > _maxClipMs) {
      // Should be impossible because the slider clamps, but defense
      // in depth is cheap and prevents shipping out-of-spec clips.
      _toast('Clip is too long — max ${_maxClipMs ~/ 1000}s.');
      return;
    }

    // video_compress (the ffmpeg bridge we use for both the trim here
    // and the 3-variant transcode on the next screen) only ships
    // native backends for Android and iOS. On Windows / macOS / Linux
    // desktop the plugin throws MissingPluginException the instant we
    // call it. Previously that exception escaped the try block silently
    // (there was no catch) — the finally flipped `_trimming` back off
    // and from the user's POV the button did nothing. Surface it
    // explicitly so dev builds on desktop fail loudly instead of
    // mysteriously.
    if (!Platform.isAndroid && !Platform.isIOS) {
      _toast(
        'Trim and upload are only supported on Android and iOS. '
        'Desktop builds are dev-only — run on a mobile device or '
        'emulator to test the upload flow.',
      );
      EventTracker.instance.track(
        eventType: 'trim_unsupported_platform',
        contentId: 'pending',
        contentType: 'challenge',
        metadata: {'platform': Platform.operatingSystem},
      );
      return;
    }

    setState(() => _trimming = true);
    try {
      EventTracker.instance.track(
        eventType: 'trim_apply',
        contentId: 'pending',
        contentType: 'challenge',
        metadata: {
          'startMs': r.start.toInt(),
          'endMs': r.end.toInt(),
          'spanMs': spanMs,
        },
      );

      // Trim via Android's native MediaExtractor + MediaMuxer (stream copy).
      // Copies video/audio bytes directly between containers without any
      // codec involvement — the AAC track is preserved 100% on every SoC.
      //
      // Why not video_compress? Its MediaCodec pipeline silently drops the
      // audio track on MediaTek SoCs (c2.mtk.*) when startTime > 0 (device
      // logs show mMaxAmplitude=0 on the AudioTrack). Stream copy skips
      // MediaCodec entirely and moves bytes container-to-container unchanged.
      final tmp = await getTemporaryDirectory();
      final dest = File(
        '${tmp.path}/devf_trim_${DateTime.now().millisecondsSinceEpoch}.mp4',
      );
      try {
        await const MethodChannel('devf/video_trim').invokeMethod<String>(
          'trimVideo',
          {
            'sourcePath': widget.sourcePath,
            'startMs': r.start.toInt(),
            'endMs': r.end.toInt(),
            'destPath': dest.path,
          },
        );
      } on PlatformException catch (e) {
        EventTracker.instance.trackError(
          surface: pageName,
          errorType: 'trim_native_failed',
          message: e.message ?? 'unknown',
        );
        _toast('Could not trim the clip. Try again.');
        return;
      }

      if (!mounted) return;
      if (widget.popOnComplete) {
        // Submit-response flow: hand the trimmed path back to the
        // caller (challenge_detail_page) and let it decide what to
        // push next. We pop instead of pushReplacement because the
        // caller doesn't have a chooser screen sitting behind us.
        Navigator.of(context).pop(dest.path);
        return;
      }
      // Create-challenge flow: replace this screen so back-navigation
      // goes to the chooser (recording the same clip twice is rarely
      // what users want).
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChallengeMetadataPage(processedSourcePath: dest.path),
        ),
      );
    } catch (e) {
      // Catch-all so any failure inside the trim path becomes a
      // visible toast instead of a silent re-enable. Most common
      // culprits: MissingPluginException on an unsupported platform
      // (already filtered above but defense in depth), codec issues on
      // unusual source files, or temp-dir write failures on
      // storage-constrained devices.
      EventTracker.instance.trackError(
        surface: pageName,
        errorType: 'trim_compress_failed',
      );
      _toast('Could not trim the clip: $e');
    } finally {
      if (mounted) setState(() => _trimming = false);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      // App bar follows the system theme — the previous forced
      // Colors.black header looked out of place when the surrounding
      // app was in light mode. The video viewport below stays black
      // because video letterboxing always looks best on pure black.
      appBar: AppBar(
        elevation: 0,
        title: const Text('Trim clip'),
      ),
      body: SafeArea(
        child: _initError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _initError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              )
            : (_controller == null || _range == null)
                ? const Center(child: CircularProgressIndicator())
                : _buildBody(cs),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    final controller = _controller!;
    final r = _range!;
    final spanMs = (r.end - r.start).round();
    final totalMs = _total.inMilliseconds.clamp(1, 1 << 30);

    return Column(
      children: [
        // Video viewport sits on a black backdrop so letterbox bars
        // disappear into the page. AspectRatio + VideoPlayer gives
        // BoxFit.contain semantics — the video paints at its true
        // ratio and the black backdrop fills any unused space.
        Expanded(
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          // Bottom controls follow the theme so the slider, copy,
          // and Continue button stay readable in light mode.
          color: cs.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    _fmt(r.start.toInt()),
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'Selected: ${(spanMs / 1000).toStringAsFixed(1)}s',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    _fmt(r.end.toInt()),
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  rangeThumbShape: const RoundRangeSliderThumbShape(
                    enabledThumbRadius: 10,
                  ),
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: cs.outlineVariant,
                ),
                child: RangeSlider(
                  values: r,
                  min: 0,
                  max: totalMs.toDouble(),
                  onChanged: _trimming ? null : _onSliderChanged,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Reels are capped at ${_maxClipMs ~/ 1000}s — drag the handles '
                'to pick the best moment.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: cs.onSurface.withValues(alpha: 0.6),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _trimming ? null : _onUseClip,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _trimming
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          // FilledButton uses cs.primary for bg, so
                          // its foreground should be cs.onPrimary —
                          // hardcoded Colors.white was correct by
                          // coincidence on most themes.
                          color: cs.onPrimary,
                        ),
                      )
                    : const Text(
                        'Use clip',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Slider listener that enforces the max-clip-length invariant by
  /// pushing whichever handle the user is moving back into the
  /// allowed window. Without this RangeSlider would happily let the
  /// user select the full source even if it's 5 minutes long.
  void _onSliderChanged(RangeValues v) {
    final span = v.end - v.start;
    if (span <= _maxClipMs) {
      setState(() => _range = v);
      return;
    }
    // Figure out which side moved by comparing to the previous range.
    final prev = _range!;
    final movedStart = v.start != prev.start;
    if (movedStart) {
      // User dragged the start handle right beyond the cap — pin it.
      setState(() {
        _range = RangeValues(
          v.end - _maxClipMs,
          v.end,
        );
      });
    } else {
      setState(() {
        _range = RangeValues(
          v.start,
          v.start + _maxClipMs,
        );
      });
    }
  }

  String _fmt(int ms) {
    final s = (ms / 1000).floor();
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }
}
