import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/services/clip_length.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/video_processor_service.dart';
import 'package:myapp/widgets/arena_ui.dart';

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

  /// The furthest the app will ever let a clip run. Read from the
  /// processor, not copied. The comment here used to read "mirrors
  /// processor cap" — and a mirror is a second number that can stop
  /// matching the first without anything saying so.
  static final _hardCapMs = VideoProcessorService.maxReelDuration.inMilliseconds;
  static const _minClipMs = 1500;       // anything < 1.5s is a misclick

  /// The lengths offered on the picker, and the one chosen by default.
  /// Both come from [ClipLength], which is where they can be tested.
  static final List<Duration> _lengthOptions =
      ClipLength.optionsWithin(VideoProcessorService.maxReelDuration);

  /// The longest this clip may run, as chosen on the picker. The slider
  /// cannot select more than this; it can select less.
  late int _limitMs =
      ClipLength.defaultWithin(VideoProcessorService.maxReelDuration)
          .inMilliseconds;

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
      // A clip shorter than the chosen length is taken whole — the point
      // of the picker is a ceiling, not a target.
      final endMs = dur.inMilliseconds.clamp(0, _limitMs);
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
    if (spanMs > _hardCapMs) {
      // Should be impossible because the slider clamps, but defense
      // in depth is cheap and prevents shipping out-of-spec clips.
      // Checked against the HARD cap rather than the picker: the picker
      // is what this person asked for, the cap is what the server will
      // take, and only the second one makes an upload fail.
      _toast('Clip is too long — max ${_hardCapMs ~/ 1000}s.');
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
    // Dark whatever the phone's theme: a video is best judged on black, and
    // this screen is about the video.
    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: const ColorScheme.dark(
          primary: AppTheme.primary,
          surface: Colors.black,
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: _initError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _initError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                )
              : (_controller == null || _range == null)
                  ? const Center(child: CircularProgressIndicator())
                  : _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final controller = _controller!;
    final r = _range!;
    final spanMs = (r.end - r.start).round();
    final totalMs = _total.inMilliseconds.clamp(1, 1 << 30);
    final showLengths = ClipLength.worthShowing(
        totalMs: totalMs, cap: VideoProcessorService.maxReelDuration);

    return Column(
      children: [
        // ── Top bar: back, what this is, how long the clip is ──
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                color: Colors.white,
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Expanded(
                child: Text(
                  'Trim your clip',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // The length, large enough to read at a glance while the
              // handles move.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: Container(
                  key: ValueKey(spanMs ~/ 100),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${(spanMs / 1000).toStringAsFixed(1)}s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── The clip, as a card you can tilt ──
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 12),
            child: Center(
              child: TiltCard(
                onTap: () {
                  setState(() {
                    if (controller.value.isPlaying) {
                      controller.pause();
                    } else {
                      controller.play();
                    }
                  });
                },
                child: AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(controller),
                      // Paused: a play mark in the middle.
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (_, v, _) => AnimatedOpacity(
                          opacity: v.isPlaying ? 0 : 1,
                          duration: const Duration(milliseconds: 150),
                          child: Center(
                            child: Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black.withValues(alpha: 0.45),
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Where the playhead is inside the chosen piece.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 3,
                        child: ValueListenableBuilder<VideoPlayerValue>(
                          valueListenable: controller,
                          builder: (_, v, _) {
                            final f = spanMs <= 0
                                ? 0.0
                                : ((v.position.inMilliseconds - r.start) /
                                        spanMs)
                                    .clamp(0.0, 1.0);
                            return FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: f,
                              child: const ColoredBox(color: Colors.white),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // ── The strip: pick the piece to post ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 40,
              rangeTrackShape: const RoundedRectRangeSliderTrackShape(),
              rangeThumbShape: const _HandleThumb(),
              activeTrackColor: AppTheme.primary.withValues(alpha: 0.35),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.10),
              overlayShape: SliderComponentShape.noOverlay,
              thumbColor: Colors.white,
            ),
            child: RangeSlider(
              values: r,
              min: 0,
              max: totalMs.toDouble(),
              onChanged: _trimming ? null : _onSliderChanged,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 2, 24, 0),
          child: Row(
            children: [
              Text(_fmt(r.start.toInt()), style: _timeStyle),
              const Spacer(),
              Text(
                'of ${_fmt(totalMs)}',
                style: _timeStyle.copyWith(color: Colors.white38),
              ),
              const Spacer(),
              Text(_fmt(r.end.toInt()), style: _timeStyle),
            ],
          ),
        ),

        // ── How long, as pills ──
        // Hidden outright when the whole video fits inside the shortest
        // option: every pill would mean the same thing, and a row that all
        // does nothing reads as broken.
        if (showLengths)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final option in _lengthOptions)
                    if (ClipLength.isUseful(option,
                        totalMs: totalMs,
                        cap: VideoProcessorService.maxReelDuration))
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _LengthPill(
                          label: ClipLength.label(option),
                          selected: _limitMs == option.inMilliseconds,
                          onTap: _trimming ? null : () => _setLimit(option),
                        ),
                      ),
                ],
              ),
            ),
          ),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Text(
            totalMs > _limitMs
                ? 'Drag the handles to choose which '
                    '${ClipLength.label(Duration(milliseconds: _limitMs))} '
                    'to post.'
                : 'Your whole video fits. Drag the handles to trim it.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
        ),

        // ── Next ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: _trimming ? null : _onUseClip,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _trimming
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Next',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(width: 6),
                        Icon(Icons.arrow_forward_rounded, size: 20),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }

  static const _timeStyle = TextStyle(
    color: Colors.white70,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Choose how long the clip may run.
  ///
  /// Opens the window to that length from wherever the start handle
  /// currently sits, so picking a longer option keeps the moment the
  /// person has already found instead of jumping back to the beginning.
  /// If that would run off the end of the source, the window slides back
  /// to fit rather than being truncated — a clip that fits should always
  /// get its full length.
  void _setLimit(Duration choice) {
    final totalMs = _total.inMilliseconds;
    if (totalMs <= 0) return;
    final w = ClipLength.window(
      totalMs: totalMs,
      limitMs: choice.inMilliseconds,
      startMs: (_range?.start ?? 0).round(),
    );
    setState(() {
      _limitMs = choice.inMilliseconds;
      _range = RangeValues(w.startMs.toDouble(), w.endMs.toDouble());
    });
    final c = _controller;
    if (c != null) {
      // Put the playhead back at the top of the new window so the preview
      // shows what was just chosen.
      // ignore: discarded_futures
      c.seekTo(Duration(milliseconds: w.startMs));
    }
  }

  /// Slider listener that enforces the max-clip-length invariant by
  /// pushing whichever handle the user is moving back into the
  /// allowed window. Without this RangeSlider would happily let the
  /// user select the full source even if it's 5 minutes long.
  void _onSliderChanged(RangeValues v) {
    final span = v.end - v.start;
    if (span <= _limitMs) {
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
          v.end - _limitMs,
          v.end,
        );
      });
    } else {
      setState(() {
        _range = RangeValues(
          v.start,
          v.start + _limitMs,
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

/// A trim handle: a tall white bar with a grip, like the edge of a film
/// strip being pulled.
class _HandleThumb extends RangeSliderThumbShape {
  const _HandleThumb();

  static const _size = Size(14, 44);

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => _size;

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    bool isDiscrete = false,
    bool isEnabled = false,
    bool? isOnTop,
    required SliderThemeData sliderTheme,
    TextDirection? textDirection,
    Thumb? thumb,
    bool? isPressed,
  }) {
    final canvas = context.canvas;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: _size.width, height: _size.height),
      const Radius.circular(5),
    );
    canvas.drawShadow(Path()..addRRect(rect), Colors.black, 4, false);
    canvas.drawRRect(rect, Paint()..color = Colors.white);
    final grip = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      center.translate(0, -8),
      center.translate(0, 8),
      grip,
    );
  }
}

/// One clip-length choice, as a pill.
class _LengthPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _LengthPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
          ),
        ),
      ),
    );
  }
}
