import 'dart:async';

import 'package:flutter/material.dart';

import 'package:myapp/pages/music_picker_page.dart';
import 'package:myapp/services/video_edit_engine.dart';

/// The person stopped waiting for the song to download.
class SongWaitStopped implements Exception {
  const SongWaitStopped();
}

/// The song could not be downloaded, even trying twice.
class SongUnavailable implements Exception {
  final Object cause;
  const SongUnavailable(this.cause);
}

/// Waits for a picked song's file when Done comes before it has
/// downloaded (see PickedMusic), letting the saving box say so and offer
/// to stop waiting. One per editor.
class SongWait {
  /// True while it waits: the saving box says "Getting the song ready…".
  final fetching = ValueNotifier<bool>(false);

  Completer<void>? _stop;

  /// The song's file. Throws [SongWaitStopped] when the person stops
  /// waiting, and [SongUnavailable] when it cannot be had.
  Future<String> file(PickedMusic music) async {
    final here = music.path;
    if (here != null) return here;
    debugPrint('[editor] Done before the song finished downloading: waiting');
    final clock = Stopwatch()..start();
    final stop = _stop = Completer<void>();
    fetching.value = true;
    try {
      final got = await Future.any<String?>([
        music.file(),
        stop.future.then((_) => null),
      ]);
      if (got == null) throw const SongWaitStopped();
      debugPrint(
        '[editor] the song was ready after ${clock.elapsedMilliseconds}ms',
      );
      return got;
    } on SongWaitStopped {
      rethrow;
    } catch (e) {
      throw SongUnavailable(e);
    } finally {
      _stop = null;
      if (!_disposed) fetching.value = false;
    }
  }

  /// Stop waiting: [file] throws [SongWaitStopped].
  void stop() {
    final stop = _stop;
    if (stop != null && !stop.isCompleted) stop.complete();
  }

  bool _disposed = false;

  void dispose() {
    stop();
    _disposed = true;
    fetching.dispose();
  }
}

/// The "please wait" box while an editor saves. A cut or the original is
/// quick and shows only a spinner; a remake can take a while on a long
/// video, so it shows how far it has got, and a Cancel. Before that, if
/// the song is still downloading, it says so, with a Cancel too.
class EditorSavingBox extends StatefulWidget {
  final VideoEditEngine engine;
  final String taskId;
  final SongWait songWait;

  /// What is being made, once there is no number yet: "Saving…" unless
  /// this says otherwise.
  final String saving;

  const EditorSavingBox({
    super.key,
    required this.engine,
    required this.taskId,
    required this.songWait,
    this.saving = 'Saving…',
  });

  @override
  State<EditorSavingBox> createState() => _EditorSavingBoxState();
}

class _EditorSavingBoxState extends State<EditorSavingBox> {
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
    valueListenable: widget.songWait.fetching,
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
                          ? widget.saving
                          : 'Saving your video… ${(done * 100).round()}%',
                      key: const ValueKey('video_saving_words'),
                      style: const TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 6),
                    if (fetchingSong)
                      TextButton(
                        key: const ValueKey('video_saving_stop_song'),
                        onPressed: widget.songWait.stop,
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
