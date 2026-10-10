import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart' as pve;
import 'package:video_player/video_player.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/pages/music_picker_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/leftover_files.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/save_to_phone.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/services/video_edit_plan.dart';

/// The video editor: the trim bar, crop and rotate, filters, brightness and
/// colour, blur, text, emoji, drawing, the sound on or off, and a free song
/// under it (the Music button) — then on to posting.
///
/// Built on pro_image_editor's video mode, with pro_video_editor doing the
/// saving. How each edit is saved, and what it costs in quality, is decided
/// in video_edit_plan.dart: nothing at all when only the length changed,
/// and no visible loss otherwise.
///
/// The phones' video chips do not all behave. Some MediaTek ones have
/// dropped the sound when a video was remade on the phone, which is why the
/// app never remade one before. So after a remake the page checks the new
/// video still has sound, if the original had or a song was added; if it
/// lost it, the person is told and offered the video without the edit.
///
/// If the editor cannot open the video on this phone at all, the old trim
/// screen takes over, so a video can always be posted.
class VideoEditorPage extends StatefulWidget {
  final String sourcePath;

  /// Whether [sourcePath] is in the phone's gallery already. False for a
  /// photo or video the app's camera just made. A post that is not in the
  /// gallery yet (made here, or changed here) gets a copy kept there; see
  /// SaveToPhone.
  final bool inGallery;

  /// The next step — the posting page, or sending an answer — with the
  /// video and the free song in it, if it has one (the post credits it).
  /// True when the video was posted; this page then closes. Coming back
  /// without posting lands here again, with the edits still there.
  final Future<bool> Function(
    BuildContext context,
    String path,
    MusicTrack? music,
  )
  onDone;

  /// The longest a post may be. The trim bar will not keep more.
  final Duration maxLength;

  const VideoEditorPage({
    super.key,
    required this.sourcePath,
    required this.onDone,
    this.maxLength = AppConstants.maxVideoDuration,
    this.inGallery = true,
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

  /// Whether the person has the video playing — the editor's play button,
  /// as its play and pause tell this page.
  ///
  /// Not the player's own "playing". That goes false for a moment every
  /// time the video jumps, while the phone gets the new spot ready, and
  /// comes back by itself. The song used to ask the player at the jump back
  /// to the start, hear "not playing", and stop — and the video then carried
  /// on without it. A device log shows exactly that at every loop: the song
  /// paused 7ms after the video jumped back, and the video playing again
  /// 90ms later, alone.
  bool _playing = false;

  /// Where the video was at the last tick, to notice it going back to the
  /// start by itself.
  Duration? _lastAt;

  /// When this page last moved the video itself. A position read just
  /// before that move can arrive just after it, and must not look like the
  /// video going back by itself.
  DateTime _movedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Whether the trim bar has said where it starts. It says so once as it
  /// appears, which is not the person moving it.
  bool _trimShown = false;

  final String _taskId = 'edit_${DateTime.now().microsecondsSinceEpoch}';

  /// What saving produced, waiting for the editor to close.
  String? _finished;

  /// Saving failed: the editor stays open rather than closing as cancelled.
  bool _saveFailed = false;

  /// Saving was stopped with Cancel: the editor stays open, and nothing
  /// needs saying.
  bool _saveStopped = false;

  /// What to tell the person when saving failed.
  String _saveProblem = _couldNotSave;
  static const _couldNotSave = "Couldn't save your edit. Try again.";
  static const _couldNotGetSong =
      "Couldn't download the song. Check your connection and tap Done again.";

  /// Done came before the song finished downloading: the saving box says
  /// so while it waits (see PickedMusic).
  final _fetchingSong = ValueNotifier<bool>(false);

  /// Completes when the person stops waiting for the song.
  Completer<void>? _stopWaiting;

  /// The remake lost the sound the original had.
  bool _soundLost = false;

  /// The plan the last save followed: the way back to a version with sound.
  VideoSavePlan? _plan;

  /// The free song under the video, if one was chosen.
  PickedMusic? _music;

  /// How loud the song is, from 0 to 1. The video's own sound is on or off
  /// (the sound button).
  double _musicVolume = 0.8;

  /// Where in the song the video starts.
  Duration _musicStart = Duration.zero;

  /// Plays the song under the video while editing.
  MusicPlayer? _musicPlayer;

  /// The song in what saving produced: null when it has none (no song, or
  /// a version without the edit after the sound was lost).
  MusicTrack? _finishedMusic;

  /// Every video this editor made (cuts and remakes, each a full copy),
  /// and the one that was posted. The rest are deleted as it closes,
  /// rather than waiting for the app's next start (see
  /// [LeftoverFiles.forget]).
  final Set<String> _made = {};
  String? _posted;

  /// [path], if it is a copy this editor made rather than the original.
  String? _keep(String? path) {
    if (path != null && path != widget.sourcePath) _made.add(path);
    return path;
  }

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
    // Leaving has frozen a phone, with nothing in the log to say where.
    // Each part that lets go of the phone's video or sound hardware now
    // says when it is done, so a step that never finishes is the last
    // line without its "done".
    debugPrint('[editor] closing: letting go of the video and the song');
    final clock = Stopwatch()..start();
    void letGo(String what, Future<void>? going) {
      if (going == null) return;
      going.then(
        (_) => debugPrint(
          '[editor] closing: $what let go after ${clock.elapsedMilliseconds}ms',
        ),
        onError: (Object e) =>
            debugPrint('[editor] closing: $what could not let go: $e'),
      );
    }

    letGo('the song player', _musicPlayer?.dispose());
    _stopWaiting?.complete();
    _fetchingSong.dispose();
    unawaited(LeftoverFiles.instance.forget(_made.difference({_posted})));
    _player?.removeListener(_onTick);
    letGo('the video player', _player?.dispose());
    // The editor below has already let go of it by now.
    _controller?.dispose();
    debugPrint(
      '[editor] closing: the editor let go after '
      '${clock.elapsedMilliseconds}ms',
    );
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final facts = await _engine.facts(widget.sourcePath);
      final player = VideoPlayerController.file(File(widget.sourcePath));
      await player.initialize();
      // The phone loops the whole video by itself. Not looping, a video
      // that reaches its very end stops there — and the end the player
      // reaches is not always the length this page was told, so the loop
      // back below could miss it and leave the video standing still.
      await player.setLooping(true);
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
      // The editor opens showing the video as playing (initialPlay), so
      // start it. Nothing did: the button said playing while the picture
      // stood still, and the first tap "paused" a video that was not
      // moving.
      _playing = true;
      unawaited(player.play());
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
    final posted = await widget.onDone(context, trimmed, null);
    if (posted) _keepOnPhone(trimmed);
    if (mounted) nav.pop(posted);
  }

  /// A copy of what was posted in the phone's gallery, unless it is the
  /// gallery's own video untouched (see SaveToPhone).
  void _keepOnPhone(String posted) {
    if (posted != widget.sourcePath || !widget.inGallery) {
      unawaited(SaveToPhone.instance.keep(posted, isVideo: true));
    }
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
    final last = _lastAt;
    _lastAt = at;
    if (_seeking) return;
    final start = _span?.start ?? Duration.zero;
    final end = _span?.end ?? facts.duration;
    if (at >= end) {
      unawaited(_seekTo(start));
    } else if (_playing &&
        last != null &&
        last - at > const Duration(milliseconds: 500) &&
        DateTime.now().difference(_movedAt) > const Duration(seconds: 1)) {
      // Gone back to the start by itself: the phone looped the whole video
      // (see _open). The song goes back with it, and the video to the start
      // of the kept part.
      debugPrint('[editor] the video looped by itself: the song goes back too');
      unawaited(at < start ? _seekTo(start) : _musicFollow(at));
    }
  }

  Future<void> _seekTo(Duration at) async {
    _seeking = true;
    _movedAt = DateTime.now();
    try {
      await _player?.seekTo(at);
      await _musicFollow(at);
    } finally {
      _seeking = false;
    }
  }

  // ── The song ──────────────────────────────────────────────────────────

  /// Where in the song the video's moment [at] falls.
  Duration _songAt(Duration at) {
    final from = _span?.start ?? Duration.zero;
    final into = at > from ? at - from : Duration.zero;
    return _musicStart + into;
  }

  /// Keeps the song where the video is: playing from the same moment when
  /// the video plays, still when it stops. "Plays" is what the person chose
  /// (see [_playing]).
  Future<void> _musicFollow(Duration at) async {
    final music = _music;
    final player = _musicPlayer;
    if (music == null || player == null) return;
    try {
      if (_playing) {
        await player.play(music.playable, from: _songAt(at), loop: true);
        await player.setVolume(_musicVolume);
      } else {
        await player.pause();
      }
    } catch (e) {
      // The video still edits and saves; only the preview is quiet.
      debugPrint('[editor] the song could not play under the video: $e');
    }
  }

  Future<void> _chooseMusic() async {
    final wasPlaying = _playing;
    _controller?.pause();
    await _musicPlayer?.pause();
    if (!mounted) return;
    final picked = await Navigator.of(context).push<PickedMusic>(
      MaterialPageRoute(builder: (_) => const MusicPickerPage()),
    );
    if (!mounted) return;
    if (picked != null) {
      _musicPlayer ??= MusicPlayer.create();
      setState(() {
        _music = picked;
        _musicStart = Duration.zero;
      });
      EventTracker.instance.track(
        eventType: 'editor_music_added',
        contentId: picked.track.id,
        contentType: 'music',
      );
    }
    if (wasPlaying) _controller?.play();
  }

  Future<void> _removeMusic() async {
    await _musicPlayer?.stop();
    if (mounted) setState(() => _music = null);
  }

  /// The song's volume and starting point, and a way to change or remove
  /// it.
  Future<void> _musicOptions() async {
    final music = _music;
    if (music == null) return;
    final length = music.track.duration;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surfaceDark,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  music.track.credit.line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Song volume',
                  style: TextStyle(color: AppTheme.textMutedDark),
                ),
                Slider(
                  key: const ValueKey('music_volume'),
                  value: _musicVolume,
                  min: 0.05,
                  max: 1,
                  onChanged: (v) {
                    setSheet(() {});
                    setState(() => _musicVolume = v);
                    unawaited(_musicPlayer?.setVolume(v));
                  },
                ),
                if (length > const Duration(seconds: 2)) ...[
                  const Text(
                    'Start the song from',
                    style: TextStyle(color: AppTheme.textMutedDark),
                  ),
                  Slider(
                    key: const ValueKey('music_start'),
                    value: _musicStart.inMilliseconds
                        .clamp(0, length.inMilliseconds)
                        .toDouble(),
                    max: length.inMilliseconds.toDouble(),
                    onChanged: (v) {
                      setSheet(() {});
                      setState(
                        () => _musicStart = Duration(milliseconds: v.round()),
                      );
                    },
                    onChangeEnd: (_) => unawaited(
                      _musicFollow(_player?.value.position ?? Duration.zero),
                    ),
                  ),
                ],
                Row(
                  children: [
                    TextButton(
                      key: const ValueKey('music_change'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        unawaited(_chooseMusic());
                      },
                      child: const Text('Change song'),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const ValueKey('music_remove'),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        unawaited(_removeMusic());
                      },
                      child: const Text(
                        'Remove song',
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The editor's bottom row: its own tools, drawn the way it draws them,
  /// with Music first, so a song is added where everything else is done to
  /// the video.
  ReactiveWidget<Widget> _bottomBar(
    ProImageEditorState editor,
    Stream<void> rebuild,
    Key key,
  ) {
    return ReactiveWidget(
      stream: rebuild,
      builder: (context) {
        final c = editor.configs;
        // Out of the way while a text or emoji on the video is being moved,
        // as the editor's own row is.
        if (editor.hasSelectedLayers &&
            c.layerInteraction.hideToolbarOnInteraction) {
          return const SizedBox.shrink();
        }
        final colour = c.mainEditor.style.bottomBarColor;
        Widget button(
          String key,
          String label,
          IconData icon,
          VoidCallback onPressed, {
          Color? iconColour,
        }) => FlatIconTextButton(
          key: ValueKey(key),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 72),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: colour),
            ),
          ),
          icon: Icon(icon, size: 22, color: iconColour ?? colour),
          onPressed: onPressed,
        );
        final music = _music;
        final buttons = <Widget>[
          if (music == null)
            button(
              'editor_add_music',
              'Music',
              Icons.music_note_rounded,
              _chooseMusic,
            )
          else
            button(
              'editor_music',
              music.track.title,
              Icons.music_note_rounded,
              _musicOptions,
              iconColour: AppTheme.primary,
            ),
          for (final tool in VideoEditorPage.tools)
            switch (tool) {
              SubEditorMode.cropRotate => button(
                'open-crop-rotate-editor-btn',
                c.i18n.cropRotateEditor.bottomNavigationBarText,
                c.cropRotateEditor.icons.bottomNavBar,
                editor.openCropRotateEditor,
              ),
              SubEditorMode.filter => button(
                'open-filter-editor-btn',
                c.i18n.filterEditor.bottomNavigationBarText,
                c.filterEditor.icons.bottomNavBar,
                editor.openFilterEditor,
              ),
              SubEditorMode.tune => button(
                'open-tune-editor-btn',
                c.i18n.tuneEditor.bottomNavigationBarText,
                c.tuneEditor.icons.bottomNavBar,
                () => editor.openTuneEditor(),
              ),
              SubEditorMode.text => button(
                'open-text-editor-btn',
                c.i18n.textEditor.bottomNavigationBarText,
                c.textEditor.icons.bottomNavBar,
                () => editor.openTextEditor(),
              ),
              SubEditorMode.emoji => button(
                'open-emoji-editor-btn',
                c.i18n.emojiEditor.bottomNavigationBarText,
                c.emojiEditor.icons.bottomNavBar,
                editor.openEmojiEditor,
              ),
              SubEditorMode.paint => button(
                'open-paint-editor-btn',
                c.i18n.paintEditor.bottomNavigationBarText,
                c.paintEditor.icons.bottomNavBar,
                editor.openPaintEditor,
              ),
              SubEditorMode.blur => button(
                'open-blur-editor-btn',
                c.i18n.blurEditor.bottomNavigationBarText,
                c.blurEditor.icons.bottomNavBar,
                editor.openBlurEditor,
              ),
              // Not offered here (see VideoEditorPage.tools).
              SubEditorMode.sticker ||
              SubEditorMode.audio ||
              SubEditorMode.videoClips => const SizedBox.shrink(),
            },
        ];
        return mui.Theme(
          data: editorTheme,
          child: mui.BottomAppBar(
            key: key,
            height: kBottomNavigationBarHeight,
            color: c.mainEditor.style.bottomBarBackground,
            padding: EdgeInsets.zero,
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: math.max(0, box.maxWidth - 24),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: buttons,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
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
    _saveProblem = _couldNotSave;
    _soundLost = false;
    unawaited(_player?.pause());
    final colour = _realColour(p.colorFilters);
    final muted = !(_controller?.isAudioEnabled ?? true);
    final music = _music;
    unawaited(_musicPlayer?.pause());
    _finishedMusic = null;
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
        hasMusic: music != null,
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
          _finished = _keep(await _cut(plan, facts));
        case VideoSaveWay.remake:
          final song = music == null ? null : await _songFile(music);
          final out = await _engine.render(
            pve.VideoRenderData(
              id: _taskId,
              videoSegments: [
                pve.VideoSegment(
                  video: pve.EditorVideo.file(widget.sourcePath),
                ),
              ],
              enableAudio: !muted,
              audioTracks: [
                if (song != null)
                  pve.VideoAudioTrack(
                    path: song,
                    volume: _musicVolume,
                    // A song shorter than the video starts again.
                    loop: true,
                    audioStartTime: _musicStart > Duration.zero
                        ? _musicStart
                        : null,
                  ),
              ],
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
          _finished = _keep(out);
          _finishedMusic = music?.track;
          // It should have sound if the original did and it was left on,
          // or if a song was added.
          if ((facts.hasSound && !muted) || music != null) {
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
    } on _StoppedWaiting {
      debugPrint('[editor] stopped waiting for the song');
      _finished = null;
      _saveStopped = true;
    } on _SongUnavailable catch (e) {
      debugPrint('[editor] saving the edit failed: ${e.cause}');
      EventTracker.instance.trackError(
        surface: 'video_editor_page',
        errorType: 'video_edit_song_download_failed',
        message: '${e.cause}',
      );
      _finished = null;
      _saveFailed = true;
      _saveProblem = _couldNotGetSong;
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

  /// The song's file, for the remake. Usually it has downloaded by now; if
  /// Done came first, the saving box says so while this waits, and offers
  /// to stop waiting.
  Future<String> _songFile(PickedMusic music) async {
    final here = music.path;
    if (here != null) return here;
    debugPrint('[editor] Done before the song finished downloading: waiting');
    final clock = Stopwatch()..start();
    final stop = _stopWaiting = Completer<void>();
    _fetchingSong.value = true;
    try {
      final got = await Future.any<String?>([
        music.file(),
        stop.future.then((_) => null),
      ]);
      if (got == null) throw const _StoppedWaiting();
      debugPrint(
        '[editor] the song was ready after ${clock.elapsedMilliseconds}ms',
      );
      return got;
    } on _StoppedWaiting {
      rethrow;
    } catch (e) {
      throw _SongUnavailable(e);
    } finally {
      _stopWaiting = null;
      if (mounted) _fetchingSong.value = false;
    }
  }

  void _stopWaitingForSong() {
    final stop = _stopWaiting;
    if (stop != null && !stop.isCompleted) stop.complete();
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
    // One of the editor's tools (crop, filter, paint...) closing without
    // its change. The editor reports that here too, naming the tool; only
    // that tool closes. Taken for the whole editor closing, it popped the
    // tool's screen with a yes/no that screen cannot take (the crop tool
    // answers with how the picture was turned): Flutter threw, the pop
    // never finished, and every tap after that did nothing.
    if (mode != EditorMode.main) {
      debugPrint('[editor] the ${mode.name} tool closed: back to the editor');
      if (mounted) Navigator.of(context).pop();
      return;
    }
    debugPrint(
      '[editor] the editor closed (${_finished == null ? 'nothing saved' : 'saved'})',
    );
    var out = _finished;
    _finished = null;
    if (_saveFailed) {
      _saveFailed = false;
      _toast(_saveProblem);
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
          ? _keep(
              await _cut(
                VideoSavePlan(
                  way: VideoSaveWay.cut,
                  start: plan.start,
                  end: plan.end,
                ),
                facts,
              ),
            )!
          : widget.sourcePath;
      // Without the edit, so without the song too.
      _finishedMusic = null;
      if (!mounted) return;
    }
    final posted = await widget.onDone(context, out, _finishedMusic);
    if (posted) {
      _posted = out;
      _keepOnPhone(out);
    }
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
      body: _editor(controller, player, facts),
    );
  }

  Widget _editor(
    ProVideoController controller,
    VideoPlayerController player,
    VideoFacts facts,
  ) {
    return ProImageEditor.video(
      controller,
      configs: ProImageEditorConfigs(
        theme: editorTheme,
        mainEditor: MainEditorConfigs(
          tools: VideoEditorPage.tools,
          widgets: MainEditorWidgets(bottomBar: _bottomBar),
        ),
        // While Done saves: how far a remake has got, and a way to stop it.
        dialogConfigs: DialogConfigs(
          widgets: DialogWidgets(
            loadingDialog: (message, configs) => _SavingBox(
              engine: _engine,
              taskId: _taskId,
              fetchingSong: _fetchingSong,
              onStopWaiting: _stopWaitingForSong,
            ),
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
        mainEditorCallbacks: MainEditorCallbacks(
          onPopInvoked: (didPop, _) => debugPrint(
            didPop
                ? '[editor] leaving the editor'
                : '[editor] back pressed with changes: asking before leaving',
          ),
        ),
        videoEditorCallbacks: VideoEditorCallbacks(
          onPlay: () async {
            _playing = true;
            await player.play();
            await _musicFollow(player.value.position);
          },
          onPause: () async {
            _playing = false;
            await player.pause();
            await _musicFollow(player.value.position);
          },
          onMuteToggle: (muted) => player.setVolume(muted ? 0 : 1),
          onTrimSpanUpdate: (span) {
            final before = _span;
            _span = span;
            // Pausing for the trim bar's own first report stopped the video
            // the moment the editor opened.
            if (!_trimShown) {
              _trimShown = true;
              return;
            }
            if (before != null &&
                before.start == span.start &&
                before.end == span.end) {
              return;
            }
            if (_playing) controller.pause();
          },
          onTrimSpanEnd: (span) {
            _span = span;
            unawaited(_seekTo(span.start));
          },
        ),
      ),
    );
  }
}

/// The person stopped waiting for the song to download.
class _StoppedWaiting implements Exception {
  const _StoppedWaiting();
}

/// The song could not be downloaded, even trying twice.
class _SongUnavailable implements Exception {
  final Object cause;
  const _SongUnavailable(this.cause);
}

/// The "please wait" box while the video editor saves. A cut or the
/// original is quick and shows only a spinner; a remake can take a while
/// on a long video, so it shows how far it has got, and a Cancel. Before
/// that, if the song is still downloading, it says so, with a Cancel too.
class _SavingBox extends StatefulWidget {
  final VideoEditEngine engine;
  final String taskId;
  final ValueListenable<bool> fetchingSong;
  final VoidCallback onStopWaiting;

  const _SavingBox({
    required this.engine,
    required this.taskId,
    required this.fetchingSong,
    required this.onStopWaiting,
  });

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
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.fetchingSong,
    builder: (context, fetching, _) => _box(fetching && _done == null),
  );

  Widget _box(bool fetchingSong) {
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
                      fetchingSong
                          ? 'Getting the song ready…'
                          : done == null
                          ? 'Saving…'
                          : 'Saving your video… ${(done * 100).round()}%',
                      key: const ValueKey('video_saving_words'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    if (fetchingSong)
                      TextButton(
                        key: const ValueKey('video_saving_stop_song'),
                        onPressed: widget.onStopWaiting,
                        child: const Text('Cancel'),
                      )
                    else if (done != null)
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
