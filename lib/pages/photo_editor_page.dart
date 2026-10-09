import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'package:myapp/config/editor_setup.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/leftover_files.dart';
import 'package:myapp/services/save_to_phone.dart';

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
class PhotoEditorPage extends StatefulWidget {
  final String sourcePath;

  /// Whether [sourcePath] is in the phone's gallery already. False for a
  /// photo or video the app's camera just made. A post that is not in the
  /// gallery yet (made here, or changed here) gets a copy kept there; see
  /// SaveToPhone.
  final bool inGallery;

  /// The next step, with the photo. (A photo has no song: [MusicTrack] is
  /// always null here; the type is the one the video editor shares.)
  final Future<bool> Function(
    BuildContext context,
    String path,
    MusicTrack? music,
  )
  onDone;

  const PhotoEditorPage({
    super.key,
    required this.sourcePath,
    required this.onDone,
    this.inGallery = true,
  });

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
  /// The finished photo, between the editor saying it is done and the
  /// editor closing.
  String? _finished;

  /// Saving failed: the editor stays open rather than closing as cancelled.
  bool _saveFailed = false;

  /// Every photo this editor wrote, and the one that was posted. The rest
  /// are deleted as it closes (see [LeftoverFiles.forget]).
  final Set<String> _made = {};
  String? _posted;

  @override
  void dispose() {
    unawaited(LeftoverFiles.instance.forget(_made.difference({_posted})));
    super.dispose();
  }

  late final ProImageEditorConfigs _configs = ProImageEditorConfigs(
    theme: editorTheme,
    mainEditor: const MainEditorConfigs(tools: PhotoEditorPage.tools),
    imageGeneration: const ImageGenerationConfigs(
      outputFormat: OutputFormat.jpg,
      jpegQuality: 100,
      maxOutputSize: Size(2000, 2000),
    ),
  );

  Future<void> _complete(Uint8List bytes) async {
    try {
      if (bytes.isEmpty) throw StateError('the editor made an empty photo');
      final kept = await keepEditedPhoto(widget.sourcePath, bytes);
      if (kept != widget.sourcePath) _made.add(kept);
      _finished = kept;
    } catch (e) {
      debugPrint('[editor] saving the photo failed: $e');
      EventTracker.instance.trackError(
        surface: 'photo_editor_page',
        errorType: 'photo_edit_save_failed',
        message: '$e',
      );
      _finished = null;
      _saveFailed = true;
    }
  }

  Future<void> _close(EditorMode mode) async {
    final finished = _finished;
    _finished = null;
    if (_saveFailed) {
      _saveFailed = false;
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text("Couldn't save your edit. Try again."),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    if (finished == null) {
      // Cancelled: back to choosing.
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    final posted = await widget.onDone(context, finished, null);
    if (posted) {
      _posted = finished;
      if (finished != widget.sourcePath || !widget.inGallery) {
        unawaited(SaveToPhone.instance.keep(finished, isVideo: false));
      }
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
