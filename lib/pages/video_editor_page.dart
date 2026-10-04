import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart' as pve;
import 'package:video_player/video_player.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/services/video_edit_plan.dart';

/// The video editor: the trim bar, crop and rotate, filters, brightness and
/// colour, blur, text, emoji, drawing, and the sound on or off — then on to
/// posting.
///
/// Built on pro_image_editor's video mode, with pro_video_editor doing the
/// saving. How each edit is saved, and what it costs in quality, is decided
/// in video_edit_plan.dart: nothing at all when only the length changed,
/// and no visible loss otherwise.
///
/// The phones' video chips do not all behave. Some MediaTek ones have
/// dropped the sound when a video was remade on the phone, which is why the
/// app never remade one before. So after a remake the page checks the new
/// video still has sound, if the original had; if it lost it, the person
/// is told and offered the video without the edit, with its sound.
///
/// If the editor cannot open the video on this phone at all, the old trim
/// screen takes over, so a video can always be posted.
class VideoEditorPage extends StatefulWidget {
  final String sourcePath;

  /// The next step — the posting page, or sending an answer. True when the
  /// video was posted; this page then closes. Coming back without posting
  /// lands here again, with the edits still there.
  final Future<bool> Function(BuildContext context, String path) onDone;

  /// The longest a post may be. The trim bar will not keep more.
  final Duration maxLength;

  const VideoEditorPage({
    super.key,
    required this.sourcePath,
    required this.onDone,
    this.maxLength = AppConstants.maxVideoDuration,
  });

  /// The editor's tools, in the order they are shown. The trim bar and the
  /// sound button are always there.
  static const tools = [
    SubEditorMode.cropRotate,
    SubEditorMode.filter,
    SubEditorMode.tune,
    SubEditorMode.text,
    SubEditorMode.emoji,
    SubEditorMode.paint,
    SubEditorMode.blur,
  ];

  /// The shortest clip the trim bar allows, as the old trim screen did.
  static const minLength = Duration(milliseconds: 1500);

  @override
  State<VideoEditorPage> createState() => VideoEditorPageState();
}

class VideoEditorPageState extends State<VideoEditorPage> {
  VideoEditEngine get _engine => VideoEditEngine.instance;

  VideoFacts? _facts;
  VideoPlayerController? _player;
  ProVideoController? _controller;
  TrimDurationSpan? _span;
  bool _seeking = false;

  final String _taskId = 'edit_${DateTime.now().microsecondsSinceEpoch}';

  /// What saving produced, waiting for the editor to close.
  String? _finished;

  /// Saving failed: the editor stays open rather than closing as cancelled.
  bool _saveFailed = false;

  /// Saving was stopped with Cancel: the editor stays open, and nothing
  /// needs saying.
  bool _saveStopped = false;

  /// The remake lost the sound the original had.
  bool _soundLost = false;

  /// The plan the last save followed: the way back to a version with sound.
  VideoSavePlan? _plan;

  /// For tests: the editor's own controller, which holds the trim bar and
  /// the sound button.
  @visibleForTesting
  ProVideoController? get controller => _controller;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _player?.removeListener(_onTick);
    unawaited(_player?.dispose());
    // The editor below has already let go of it by now.
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final facts = await _engine.facts(widget.sourcePath);
      final player = VideoPlayerController.file(File(widget.sourcePath));
      await player.initialize();
      await player.setLooping(false);
      if (!mounted) {
        await player.dispose();
        return;
      }
      // Longer than a post may be: start with the first part kept, and let
      // the person slide it to the part they want.
      final span = facts.duration > widget.maxLength
          ? TrimDurationSpan(start: Duration.zero, end: widget.maxLength)
          : null;
      _span = span;
      int fileSize = 0;
      try {
        fileSize = await File(widget.sourcePath).length();
      } catch (_) {}
      final controller = ProVideoController(
        videoPlayer: _playerView(player),
        videoDuration: facts.duration,
        initialResolution: facts.resolution,
        fileSize: fileSize,
        initialTrimSpan: span,
      );
      player.addListener(_onTick);
      setState(() {
        _facts = facts;
        _player = player;
        _controller = controller;
      });
      EventTracker.instance.track(
        eventType: 'video_editor_open',
        contentId: 'pending',
        contentType: 'challenge',
        metadata: {
          'durationMs': facts.duration.inMilliseconds,
          'longSide': facts.longSide,
          'bitrate': facts.bitrate,
        },
      );
      unawaited(_loadThumbnails(facts));
    } catch (e) {
      debugPrint(
        '[editor] the video editor could not open this video: $e '
        '— the trim screen takes over',
      );
      EventTracker.instance.trackError(
        surface: 'video_editor_page',
        errorType: 'video_editor_open_failed',
        message: '$e',
      );
      if (mounted) await _fallBackToTrim();
    }
  }

  Future<void> _loadThumbnails(VideoFacts facts) async {
    try {
      final pics = await _engine.thumbnails(
        widget.sourcePath,
        facts.duration,
        count: 7,
        size: 160,
      );
      if (!mounted || _controller == null) return;
      _controller!.thumbnails = [for (final p in pics) MemoryImage(p)];
    } catch (e) {
      // The trim bar works without its pictures.
      debugPrint('[editor] no pictures for the trim bar: $e');
    }
  }

  /// The editor could not open the video: the old trim screen, then on.
  Future<void> _fallBackToTrim() async {
    final nav = Navigator.of(context);
    final trimmed = await nav.push<String>(
      MaterialPageRoute(
        builder: (_) =>
            VideoTrimPage(sourcePath: widget.sourcePath, popOnComplete: true),
      ),
    );
    if (!mounted) return;
    if (trimmed == null || trimmed.isEmpty) {
      nav.pop(false);
      return;
    }
    final posted = await widget.onDone(context, trimmed);
    if (mounted) nav.pop(posted);
  }

  Widget _playerView(VideoPlayerController player) {
    return Center(
      child: AspectRatio(
        aspectRatio: player.value.aspectRatio,
        child: VideoPlayer(player),
      ),
    );
  }

  /// Keeps the play position on the trim bar, and plays only the kept part.
  void _onTick() {
    final player = _player;
    final controller = _controller;
    final facts = _facts;
    if (player == null || controller == null || facts == null) return;
    final at = player.value.position;
    controller.setPlayTime(at);
    final end = _span?.end ?? facts.duration;
    if (at >= end && !_seeking) {
      unawaited(_seekTo(_span?.start ?? Duration.zero));
    }
  }

  Future<void> _seekTo(Duration at) async {
    _seeking = true;
    try {
      await _player?.seekTo(at);
    } finally {
      _seeking = false;
    }
  }

  /// The colour matrices that change something: picking "no filter" can
  /// leave one that changes nothing, and that is not an edit.
  static List<List<double>> _realColour(List<List<double>> matrices) => [
    for (final m in matrices)
      if (!_isIdentity(m)) m,
  ];

  static bool _isIdentity(List<double> m) {
    const identity = [
      1.0, 0.0, 0.0, 0.0, 0.0, //
      0.0, 1.0, 0.0, 0.0, 0.0, //
      0.0, 0.0, 1.0, 0.0, 0.0, //
      0.0, 0.0, 0.0, 1.0, 0.0, //
    ];
    if (m.length != identity.length) return false;
    for (var i = 0; i < m.length; i++) {
      if ((m[i] - identity[i]).abs() > 1e-6) return false;
    }
    return true;
  }

  /// Done was pressed: save the edit the cheapest way that keeps it.
  Future<void> _save(CompleteParameters p) async {
    final facts = _facts;
    if (facts == null) return;
    _saveFailed = false;
    _saveStopped = false;
    _soundLost = false;
    unawaited(_player?.pause());
    final colour = _realColour(p.colorFilters);
    final muted = !(_controller?.isAudioEnabled ?? true);
    final cropLong =
        p.isTransformed && p.cropWidth != null && p.cropHeight != null
        ? math.max(p.cropWidth!, p.cropHeight!)
        : facts.longSide;
    final plan = planVideoSave(
      edits: VideoEdits(
        hasLayers: p.layers.isNotEmpty,
        hasColour: colour.isNotEmpty,
        hasBlur: p.blur > 0,
        isTransformed: p.isTransformed,
        muted: muted,
        start: p.startTime,
        end: p.endTime,
      ),
      duration: facts.duration,
      longSide: cropLong,
      sourceBitrate: facts.bitrate,
      maxLength: widget.maxLength,
    );
    _plan = plan;
    debugPrint('[editor] saving the video: $plan');
    try {
      switch (plan.way) {
        case VideoSaveWay.original:
          _finished = widget.sourcePath;
        case VideoSaveWay.cut:
          _finished = await _cut(plan, facts);
        case VideoSaveWay.remake:
          final out = await _engine.render(
            pve.VideoRenderData(
              id: _taskId,
              videoSegments: [
                pve.VideoSegment(
                  video: pve.EditorVideo.file(widget.sourcePath),
                ),
              ],
              enableAudio: !muted,
              imageLayers: p.layers.isNotEmpty
                  ? [
                      pve.ImageLayer(
                        image: pve.EditorLayerImage.memory(p.image),
                      ),
                    ]
                  : null,
              blur: p.blur > 0 ? p.blur : null,
              colorFilters: [
                for (final m in colour) pve.ColorFilter(matrix: m),
              ],
              startTime: plan.start,
              endTime: plan.end,
              transform: p.isTransformed || plan.scale != 1
                  ? pve.ExportTransform(
                      width: p.isTransformed ? p.cropWidth : null,
                      height: p.isTransformed ? p.cropHeight : null,
                      rotateTurns: p.isTransformed ? p.rotateTurns : 0,
                      x: p.isTransformed ? p.cropX : null,
                      y: p.isTransformed ? p.cropY : null,
                      flipX: p.isTransformed && p.flipX,
                      flipY: p.isTransformed && p.flipY,
                      scaleX: plan.scale != 1 ? plan.scale : null,
                      scaleY: plan.scale != 1 ? plan.scale : null,
                    )
                  : null,
              bitrate: plan.bitrate,
            ),
          );
          _finished = out;
          if (facts.hasSound && !muted) {
            final kept = await _engine.facts(out);
            _soundLost = !kept.hasSound;
            if (_soundLost) {
              debugPrint(
                '[editor] the remade video lost its sound on this '
                'phone',
              );
              EventTracker.instance.trackError(
                surface: 'video_editor_page',
                errorType: 'video_edit_lost_sound',
                message: 'remade video has no sound track',
              );
            }
          }
      }
      EventTracker.instance.track(
        eventType: 'video_editor_saved',
        contentId: 'pending',
        contentType: 'challenge',
        metadata: {'way': plan.way.name, 'bitrate': plan.bitrate ?? 0},
      );
    } on pve.RenderCanceledException {
      debugPrint('[editor] saving was stopped with Cancel');
      _finished = null;
      _saveStopped = true;
    } catch (e) {
      debugPrint('[editor] saving the edit failed: $e');
      EventTracker.instance.trackError(
        surface: 'video_editor_page',
        errorType: 'video_edit_save_failed',
        message: '$e',
      );
      _finished = null;
      _saveFailed = true;
    }
  }

  /// Cut without remaking. On a phone that cannot (an iPhone), remade at
  /// the original's own data rate instead, which shows no difference.
  Future<String> _cut(VideoSavePlan plan, VideoFacts facts) async {
    final start = plan.start ?? Duration.zero;
    final end = plan.end ?? facts.duration;
    try {
      final cut = await _engine.cutLossless(widget.sourcePath, start, end);
      if (cut != null) return cut;
    } catch (e) {
      debugPrint('[editor] the lossless cut failed: $e — remaking instead');
    }
    return _engine.render(
      pve.VideoRenderData(
        id: _taskId,
        videoSegments: [
          pve.VideoSegment(video: pve.EditorVideo.file(widget.sourcePath)),
        ],
        startTime: plan.start,
        endTime: plan.end,
        bitrate: remakeBitrate(
          sourceBitrate: facts.bitrate,
          longSide: math.min(facts.longSide, maxRemakeLongSide),
        ),
      ),
    );
  }

  Future<void> _close(EditorMode mode) async {
    var out = _finished;
    _finished = null;
    if (_saveFailed) {
      _saveFailed = false;
      _toast("Couldn't save your edit. Try again.");
      return;
    }
    if (_saveStopped) {
      _saveStopped = false;
      return;
    }
    if (out == null) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    if (_soundLost) {
      _soundLost = false;
      final withoutEdit = await _askAboutLostSound();
      if (!mounted || withoutEdit != true) return;
      final plan = _plan;
      final facts = _facts;
      out = plan != null && plan.isTrimmed && facts != null
          ? await _cut(
              VideoSavePlan(
                way: VideoSaveWay.cut,
                start: plan.start,
                end: plan.end,
              ),
              facts,
            )
          : widget.sourcePath;
      if (!mounted) return;
    }
    final posted = await widget.onDone(context, out);
    if (posted && mounted) Navigator.of(context).pop(true);
  }

  Future<bool?> _askAboutLostSound() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('edit_lost_sound'),
        title: const Text('Your edit lost its sound'),
        content: const Text(
          'This phone dropped the sound while saving your edit. You can '
          'post the video without the edit, with its sound, or go back and '
          'change it.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('edit_lost_sound_back'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Go back'),
          ),
          TextButton(
            key: const ValueKey('edit_lost_sound_post'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Post without the edit'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final player = _player;
    final facts = _facts;
    if (controller == null || player == null || facts == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white54)),
      );
    }
    // A Scaffold of its own, for the "couldn't save" message: the editor's
    // own screen is built from the standalone design library, so without
    // this the message would show on the page underneath, out of sight.
    return Scaffold(
      backgroundColor: Colors.black,
      // The editor moves its own things out of the keyboard's way.
      resizeToAvoidBottomInset: false,
      body: ProImageEditor.video(
        controller,
        configs: ProImageEditorConfigs(
          theme: editorTheme,
          mainEditor: const MainEditorConfigs(tools: VideoEditorPage.tools),
          // While Done saves: how far a remake has got, and a way to stop it.
          dialogConfigs: DialogConfigs(
            widgets: DialogWidgets(
              loadingDialog: (message, configs) =>
                  _SavingBox(engine: _engine, taskId: _taskId),
            ),
          ),
          paintEditor: const PaintEditorConfigs(
            // Blur and pixelate brushes cannot be saved into a video.
            tools: [
              PaintMode.freeStyle,
              PaintMode.arrow,
              PaintMode.line,
              PaintMode.rect,
              PaintMode.circle,
              PaintMode.eraser,
            ],
          ),
          videoEditor: VideoEditorConfigs(
            initialPlay: true,
            isAudioSupported: facts.hasSound,
            minTrimDuration: facts.duration < VideoEditorPage.minLength
                ? facts.duration
                : VideoEditorPage.minLength,
            maxTrimDuration: facts.duration > widget.maxLength
                ? widget.maxLength
                : null,
            playTimeSmoothingDuration: const Duration(milliseconds: 600),
          ),
        ),
        callbacks: ProImageEditorCallbacks(
          onCompleteWithParameters: _save,
          onCloseEditor: _close,
          videoEditorCallbacks: VideoEditorCallbacks(
            onPlay: player.play,
            onPause: player.pause,
            onMuteToggle: (muted) => player.setVolume(muted ? 0 : 1),
            onTrimSpanUpdate: (span) {
              _span = span;
              if (player.value.isPlaying) controller.pause();
            },
            onTrimSpanEnd: (span) {
              _span = span;
              unawaited(_seekTo(span.start));
            },
          ),
        ),
      ),
    );
  }
}

/// The "please wait" box while the video editor saves. A cut or the
/// original is quick and shows only a spinner; a remake can take a while
/// on a long video, so it shows how far it has got, and a Cancel.
class _SavingBox extends StatefulWidget {
  final VideoEditEngine engine;
  final String taskId;

  const _SavingBox({required this.engine, required this.taskId});

  @override
  State<_SavingBox> createState() => _SavingBoxState();
}

class _SavingBoxState extends State<_SavingBox> {
  StreamSubscription<double>? _sub;
  double? _done;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine
        .progress(widget.taskId)
        .listen(
          (p) {
            if (mounted) setState(() => _done = p.clamp(0.0, 1.0));
          },
          onError: (Object e) {
            // The box still says "Saving…"; only the number is missing.
            debugPrint('[editor] no progress for the save: $e');
          },
        );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await widget.engine.cancel(widget.taskId);
    } catch (e) {
      debugPrint('[editor] could not stop the save: $e');
      if (mounted) setState(() => _stopping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    return Stack(
      children: [
        const ModalBarrier(color: Colors.black54, dismissible: false),
        Center(
          child: Material(
            key: const ValueKey('video_saving'),
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 10),
              child: SizedBox(
                width: 220,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (done == null)
                      const CircularProgressIndicator(color: Colors.white70)
                    else
                      LinearProgressIndicator(
                        value: done,
                        color: Colors.white,
                        backgroundColor: Colors.white24,
                      ),
                    const SizedBox(height: 16),
                    Text(
                      done == null
                          ? 'Saving…'
                          : 'Saving your video… ${(done * 100).round()}%',
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    if (done != null)
                      TextButton(
                        key: const ValueKey('video_saving_cancel'),
                        onPressed: _stopping ? null : _stop,
                        child: const Text('Cancel'),
                      )
                    else
                      const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
