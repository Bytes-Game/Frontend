import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart' as pve;

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/pages/music_picker_page.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/leftover_files.dart';
import 'package:myapp/services/music_library.dart';
import 'package:myapp/services/save_to_phone.dart';
import 'package:myapp/services/song_edit.dart';
import 'package:myapp/services/video_edit_engine.dart';
import 'package:myapp/widgets/editor_bottom_bar.dart';
import 'package:myapp/widgets/editor_saving.dart';
import 'package:myapp/widgets/song_sheet.dart';

/// The photo editor: crop and rotate, filters, brightness and colour, text,
/// emoji, drawing and blur — then on to posting.
///
/// Built on pro_image_editor (free, open source). What this page adds is
/// how it fits the app, and what happens to quality:
///
///   * Nothing changed: the photo goes on exactly as it came in. The editor
///     hands back the very same bytes (it keeps the original when nothing
///     was done to it), and this page then uses the original file itself.
///   * Something changed: the editor saves it as a JPEG at full quality
///     (100 out of 100), up to 2000 pixels on the longest side — bigger than
///     the 1600 the app picks photos at, so nothing is lost on the way.
///
/// [onDone] is the next step — the posting page. It answers true when the
/// photo was posted, and this page then closes. Coming back from it without
/// posting lands here again, with the edits still there.
///
/// A song can go under the photo (the Music button), for a length the
/// person picks. The post is then a video: the photo, still, for that long,
/// with the song under it — the way Instagram does a photo with music.
class PhotoEditorPage extends StatefulWidget {
  final String sourcePath;

  /// Whether [sourcePath] is in the phone's gallery already. False for a
  /// photo or video the app's camera just made. A post that is not in the
  /// gallery yet (made here, or changed here) gets a copy kept there; see
  /// SaveToPhone.
  final bool inGallery;

  /// The next step, with the photo — or, with a song, the video made of it,
  /// and the song to credit. With no song [MusicTrack] is null and [path]
  /// is a photo.
  final Future<bool> Function(
    BuildContext context,
    String path,
    MusicTrack? music,
  )
  onDone;

  /// Whether a song can go under the photo. Off for an answer to a photo
  /// battle, which stays a photo against a photo.
  final bool allowMusic;

  const PhotoEditorPage({
    super.key,
    required this.sourcePath,
    required this.onDone,
    this.inGallery = true,
    this.allowMusic = true,
  });

  /// How long a photo with a song can show for.
  static const songLengths = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// The editor's tools, in the order they are shown.
  static const tools = [
    SubEditorMode.cropRotate,
    SubEditorMode.filter,
    SubEditorMode.tune,
    SubEditorMode.text,
    SubEditorMode.emoji,
    SubEditorMode.paint,
    SubEditorMode.blur,
  ];

  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  VideoEditEngine get _engine => VideoEditEngine.instance;

  /// The finished photo — or, with a song, the video made of it — between
  /// the editor saying it is done and the editor closing.
  String? _finished;

  /// The photo itself, for posting without the song if the song was lost.
  String? _finishedPhoto;

  /// The song in what was finished, to credit: null for a plain photo.
  MusicTrack? _finishedMusic;

  /// Saving failed: the editor stays open rather than closing as cancelled.
  bool _saveFailed = false;
  String _saveProblem = _couldNotSave;
  static const _couldNotSave = "Couldn't save your edit. Try again.";
  static const _couldNotGetSong =
      "Couldn't download the song. Check your connection and tap Done again.";

  /// Saving was stopped with Cancel: the editor stays open, nothing said.
  bool _saveStopped = false;

  /// The video made of the photo came out without the song's sound.
  bool _soundLost = false;

  /// Every photo and video this editor wrote, and the one that was posted.
  /// The rest are deleted as it closes (see [LeftoverFiles.forget]).
  final Set<String> _made = {};
  String? _posted;

  final String _taskId = 'photo_${DateTime.now().microsecondsSinceEpoch}';

  // ── The song ──────────────────────────────────────────────────────────

  /// The song under the photo, if one was chosen.
  PickedMusic? _music;

  /// Its part, volume and fades.
  SongEdit _song = SongEdit();

  /// How long the photo shows with the song.
  Duration _length = const Duration(seconds: 10);

  MusicPlayer? _musicPlayer;

  /// Plays the chosen part again each time it ends, as the post will, and
  /// follows the fades.
  Timer? _songTimer;
  final Stopwatch _songClock = Stopwatch();
  double _gainSent = -1;

  final _songWait = SongWait();

  @override
  void dispose() {
    _songTimer?.cancel();
    final player = _musicPlayer;
    if (player != null) unawaited(player.dispose());
    _songWait.dispose();
    unawaited(LeftoverFiles.instance.forget(_made.difference({_posted})));
    super.dispose();
  }

  late final ProImageEditorConfigs _configs = ProImageEditorConfigs(
    theme: editorTheme,
    mainEditor: MainEditorConfigs(
      tools: PhotoEditorPage.tools,
      widgets: widget.allowMusic
          ? MainEditorWidgets(bottomBar: _bottomBar)
          : const MainEditorWidgets(),
    ),
    imageGeneration: const ImageGenerationConfigs(
      outputFormat: OutputFormat.jpg,
      jpegQuality: 100,
      maxOutputSize: Size(2000, 2000),
    ),
    dialogConfigs: DialogConfigs(
      widgets: DialogWidgets(
        loadingDialog: (message, configs) => EditorSavingBox(
          engine: _engine,
          taskId: _taskId,
          songWait: _songWait,
          saving: _music == null ? 'Saving…' : 'Making your video…',
        ),
      ),
    ),
  );

  ReactiveWidget<Widget> _bottomBar(
    ProImageEditorState editor,
    Stream<void> rebuild,
    Key key,
  ) => editorBottomBar(
    editor: editor,
    rebuild: rebuild,
    key: key,
    tools: PhotoEditorPage.tools,
    song: _music?.track,
    onAddMusic: _chooseMusic,
    onMusic: _musicOptions,
  );

  /// The song's part, from its start, again every [_length] — as the post
  /// will play it, over and over.
  Future<void> _playSong() async {
    final music = _music;
    final player = _musicPlayer;
    if (music == null || player == null) return;
    _songClock
      ..reset()
      ..start();
    _gainSent = _song.volumeAt(Duration.zero, _length);
    _songTimer ??= Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _songTick(),
    );
    try {
      await player.play(
        music.playable,
        from: _song.startWithin(music.track.duration, _length),
        loop: true,
      );
      await player.setVolume(_gainSent);
    } catch (e) {
      // The photo still edits and saves; only the preview is quiet.
      debugPrint('[editor] the song could not play under the photo: $e');
    }
  }

  void _songTick() {
    final into = _songClock.elapsed;
    if (into >= _length) {
      unawaited(_playSong());
      return;
    }
    final gain = _song.volumeAt(into, _length);
    if ((gain - _gainSent).abs() < 0.02) return;
    _gainSent = gain;
    unawaited(_musicPlayer?.setVolume(gain));
  }

  void _stopSong() {
    _songTimer?.cancel();
    _songTimer = null;
    _songClock.stop();
    unawaited(_musicPlayer?.pause());
  }

  Future<void> _chooseMusic() async {
    _stopSong();
    final picked = await Navigator.of(context).push<PickedMusic>(
      MaterialPageRoute(builder: (_) => const MusicPickerPage()),
    );
    if (!mounted) return;
    if (picked != null) {
      _musicPlayer ??= MusicPlayer.create();
      setState(() {
        _music = picked;
        // A new song starts from its start; the volume and fades stay.
        _song.start = Duration.zero;
      });
      EventTracker.instance.track(
        eventType: 'editor_music_added',
        contentId: picked.track.id,
        contentType: 'music',
        metadata: {'on': 'photo'},
      );
    }
    if (_music != null) unawaited(_playSong());
  }

  Future<void> _removeMusic() async {
    _stopSong();
    await _musicPlayer?.stop();
    if (!mounted) return;
    setState(() {
      _music = null;
      _song = SongEdit();
    });
  }

  /// The song's settings, with how long the photo shows (see showSongSheet).
  Future<void> _musicOptions() async {
    final music = _music;
    if (music == null) return;
    await showSongSheet(
      context,
      track: music.track,
      edit: _song,
      length: () => _length,
      lengths: PhotoEditorPage.songLengths,
      onLength: (l) => setState(() => _length = l),
      onVolume: () {
        _gainSent = _song.volumeAt(_songClock.elapsed, _length);
        unawaited(_musicPlayer?.setVolume(_gainSent));
      },
      onPart: () {
        debugPrint(
          '[editor] the photo shows for ${_length.inSeconds}s; the song '
          'starts at ${_song.start.inMilliseconds}ms',
        );
        unawaited(_playSong());
      },
      onChangeSong: () => unawaited(_chooseMusic()),
      onRemoveSong: () => unawaited(_removeMusic()),
    );
    if (mounted) setState(() {});
  }

  Future<void> _complete(Uint8List bytes) async {
    _saveProblem = _couldNotSave;
    _saveStopped = false;
    _soundLost = false;
    _finishedMusic = null;
    try {
      if (bytes.isEmpty) throw StateError('the editor made an empty photo');
      final kept = await keepEditedPhoto(widget.sourcePath, bytes);
      if (kept != widget.sourcePath) _made.add(kept);
      _finishedPhoto = kept;
      final music = _music;
      if (music == null) {
        _finished = kept;
        return;
      }
      _stopSong();
      _finished = await _withSong(kept, music);
      _finishedMusic = music.track;
    } on SongWaitStopped {
      debugPrint('[editor] stopped waiting for the song');
      _finished = null;
      _saveStopped = true;
    } on pve.RenderCanceledException {
      debugPrint('[editor] making the video was stopped with Cancel');
      _finished = null;
      _saveStopped = true;
    } catch (e) {
      final cause = e is SongUnavailable ? e.cause : e;
      debugPrint('[editor] saving the photo failed: $cause');
      EventTracker.instance.trackError(
        surface: 'photo_editor_page',
        errorType: e is SongUnavailable
            ? 'photo_edit_song_download_failed'
            : 'photo_edit_save_failed',
        message: '$cause',
      );
      if (e is SongUnavailable) _saveProblem = _couldNotGetSong;
      _finished = null;
      _saveFailed = true;
    }
  }

  /// [photo] as a video [_length] long with the song under it: the photo
  /// made into a still video first, then the song put under that.
  Future<String> _withSong(String photo, PickedMusic music) async {
    final song = await _songWait.file(music);
    debugPrint(
      '[editor] making the photo a ${_length.inSeconds}s video with its song',
    );
    final still = await _engine.renderStill(
      photo,
      _length,
      id: '${_taskId}_still',
    );
    _made.add(still);
    final out = await _engine.render(
      pve.VideoRenderData(
        id: _taskId,
        videoSegments: [pve.VideoSegment(video: pve.EditorVideo.file(still))],
        audioTracks: [_song.track(song, length: _length)],
        bitrate: 4000000,
      ),
    );
    _made.add(out);
    // Some phones drop the sound when they make a video; see the video
    // editor. A photo with a song that lost it is just the photo.
    final facts = await _engine.facts(out);
    if (!facts.hasSound) {
      _soundLost = true;
      debugPrint('[editor] the photo\'s video lost its song on this phone');
      EventTracker.instance.trackError(
        surface: 'photo_editor_page',
        errorType: 'photo_edit_lost_sound',
        message: 'the video made of the photo has no sound track',
      );
    }
    return out;
  }

  Future<bool?> _askAboutLostSound() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('edit_lost_sound'),
        title: const Text('The song did not save'),
        content: const Text(
          'This phone dropped the song while making your video. You can post '
          'the photo without it, or go back and try again.',
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
            child: const Text('Post the photo'),
          ),
        ],
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
    var finished = _finished;
    var music = _finishedMusic;
    _finished = null;
    if (_saveFailed) {
      _saveFailed = false;
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(_saveProblem),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (_saveStopped) {
      _saveStopped = false;
      if (_music != null) unawaited(_playSong());
      return;
    }
    if (finished == null) {
      // Cancelled: back to choosing.
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    if (_soundLost) {
      _soundLost = false;
      final photoInstead = await _askAboutLostSound();
      if (!mounted) return;
      if (photoInstead != true) {
        if (_music != null) unawaited(_playSong());
        return;
      }
      finished = _finishedPhoto ?? widget.sourcePath;
      music = null;
    }
    _stopSong();
    final posted = await widget.onDone(context, finished, music);
    if (posted) {
      _posted = finished;
      // A video made here is never in the gallery yet.
      if (music != null ||
          finished != widget.sourcePath ||
          !widget.inGallery) {
        unawaited(SaveToPhone.instance.keep(finished, isVideo: music != null));
      }
    } else if (mounted && _music != null) {
      // Back from the details without posting: the song plays on.
      unawaited(_playSong());
    }
    if (posted && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // A Scaffold of its own, for the "couldn't save" message (see the
    // video editor).
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: ProImageEditor.file(
        File(widget.sourcePath),
        configs: _configs,
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: _complete,
          onCloseEditor: _close,
        ),
      ),
    );
  }
}

/// The file to post for a photo the editor finished as [bytes].
///
/// Unchanged — the very same bytes as [sourcePath] — is the original file
/// itself, so it is not written again, not even once. Anything else goes in
/// a new file of its own.
@visibleForTesting
Future<String> keepEditedPhoto(String sourcePath, Uint8List bytes) async {
  try {
    final original = await File(sourcePath).readAsBytes();
    if (listEquals(original, bytes)) return sourcePath;
  } catch (e) {
    debugPrint('[editor] could not read the original photo to compare: $e');
  }
  final dir = await getTemporaryDirectory();
  final out = File(
    '${dir.path}/edited_photo_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await out.writeAsBytes(bytes, flush: true);
  return out.path;
}
