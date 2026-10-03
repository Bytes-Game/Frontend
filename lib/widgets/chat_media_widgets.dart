import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// The pieces of a chat that show photos and voice notes: the photo in its
/// bubble, the full-screen photo, the voice note in its bubble, the bar
/// shown while recording, and the screen to look at a photo (and add a
/// caption) before sending it.

// ── A photo in its bubble ─────────────────────────────────────────────────

/// A photo message: the picture at its own shape, corners matching the
/// bubble, a caption under it if there is one. While it uploads, a ring
/// fills over it; a tap opens it full screen.
class ChatPhoto extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;
  final BorderRadius radius;
  final Color bubbleColor;
  final VoidCallback onOpen;

  const ChatPhoto({
    super.key,
    required this.message,
    required this.isMe,
    required this.radius,
    required this.bubbleColor,
    required this.onOpen,
  });

  /// The picture itself, from the phone while it is being sent, otherwise
  /// from storage.
  static ImageProvider? imageOf(Map<String, dynamic> m) {
    final local = '${m['localPath'] ?? ''}';
    if (local.isNotEmpty) return FileImage(File(local));
    final url = '${m['mediaUrl'] ?? ''}';
    if (url.isNotEmpty) return NetworkImage(url);
    return null;
  }

  /// One per message on screen: the same photo forwarded twice into a
  /// chat is two messages, and two pictures with one tag would break the
  /// open-full-screen animation.
  static String heroTag(Map<String, dynamic> m) =>
      'chat_photo_${identityHashCode(m)}';

  @override
  Widget build(BuildContext context) {
    final w = (message['mediaWidth'] as num?)?.toDouble() ?? 0;
    final h = (message['mediaHeight'] as num?)?.toDouble() ?? 0;
    // Its own shape, within reason: a very tall or very wide photo is
    // cropped a little rather than drawn as a sliver.
    final aspect = (w > 0 && h > 0) ? (w / h).clamp(0.6, 1.8) : 1.0;
    final width = math.min(MediaQuery.of(context).size.width * 0.64, 260.0);
    final caption = '${message['message'] ?? ''}';
    final uploading = message['status'] == 'uploading';
    final progress = (message['progress'] as num?)?.toDouble();
    final image = imageOf(message);
    final cs = Theme.of(context).colorScheme;

    final picture = SizedBox(
      width: width,
      height: width / aspect,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: quietFill(context)),
          if (image != null)
            Hero(
              tag: heroTag(message),
              child: Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (_, child, frame, sync) => AnimatedOpacity(
                  opacity: sync || frame != null ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: child,
                ),
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    Icons.broken_image_rounded,
                    color: cs.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
          if (uploading)
            Container(
              color: Colors.black.withValues(alpha: 0.32),
              alignment: Alignment.center,
              child: SizedBox(
                width: 38,
                height: 38,
                child: CircularProgressIndicator(
                  key: const ValueKey('photo_uploading'),
                  value: progress == null || progress <= 0 ? null : progress,
                  strokeWidth: 3,
                  color: Colors.white,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
        ],
      ),
    );

    return GestureDetector(
      onTap: image == null ? null : onOpen,
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          width: width,
          color: bubbleColor,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              picture,
              if (caption.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 9),
                  child: Text(
                    caption,
                    style: TextStyle(
                      color: isMe ? Colors.white : cs.onSurface,
                      fontSize: 15,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo full screen: black around it, pinch to zoom, tap to hide the
/// bar, swipe down to close.
class ChatPhotoViewer extends StatefulWidget {
  final Map<String, dynamic> message;
  final String from;

  const ChatPhotoViewer({super.key, required this.message, required this.from});

  static Future<void> open(
    BuildContext context,
    Map<String, dynamic> message,
    String from,
  ) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, a, _) => FadeTransition(
          opacity: a,
          child: ChatPhotoViewer(message: message, from: from),
        ),
      ),
    );
  }

  @override
  State<ChatPhotoViewer> createState() => _ChatPhotoViewerState();
}

class _ChatPhotoViewerState extends State<ChatPhotoViewer> {
  bool _chrome = true;
  double _drag = 0;
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  bool get _zoomed => _zoom.value.getMaxScaleOnAxis() > 1.01;

  @override
  Widget build(BuildContext context) {
    final image = ChatPhoto.imageOf(widget.message);
    final caption = '${widget.message['message'] ?? ''}';
    final fade = (1 - _drag.abs() / 400).clamp(0.3, 1.0);
    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: fade),
      // Every layer is placed against the whole screen. A layer left
      // unplaced would make the screen only as tall as itself.
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _chrome = !_chrome),
              onVerticalDragUpdate: _zoomed
                  ? null
                  : (d) => setState(() => _drag += d.delta.dy),
              onVerticalDragEnd: _zoomed
                  ? null
                  : (_) {
                      if (_drag.abs() > 120) {
                        Navigator.of(context).maybePop();
                      } else {
                        setState(() => _drag = 0);
                      }
                    },
              child: Transform.translate(
                offset: Offset(0, _drag),
                child: InteractiveViewer(
                  transformationController: _zoom,
                  minScale: 1,
                  maxScale: 4,
                  child: Center(
                    child: image == null
                        ? const SizedBox.shrink()
                        : Hero(
                            tag: ChatPhoto.heroTag(widget.message),
                            child: Image(
                              image: image,
                              fit: BoxFit.contain,
                              // Scaled down, never squeezed: while it flies
                              // in from the bubble it can be tiny.
                              errorBuilder: (_, _, _) => const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.broken_image_rounded,
                                      color: Colors.white54,
                                      size: 40,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      "This photo couldn't be loaded",
                                      style: TextStyle(color: Colors.white70),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            widget.from,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (caption.trim().isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _chrome ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Text(
                      caption,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── A voice note in its bubble ────────────────────────────────────────────

/// A voice message: a play button, the shape of the recording (filling in
/// as it plays), how long it is, and while playing a speed button. Only one
/// plays at a time.
class ChatVoice extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isMe;

  const ChatVoice({super.key, required this.message, required this.isMe});

  /// What to play: the file on this phone while it is being sent, or the
  /// uploaded one.
  static String sourceOf(Map<String, dynamic> m) {
    final url = '${m['mediaUrl'] ?? ''}';
    if (url.isNotEmpty) return url;
    return '${m['localPath'] ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final src = sourceOf(message);
    final length = Duration(
      milliseconds: (message['mediaDurationMs'] as num?)?.toInt() ?? 0,
    );
    final levels = [
      for (final v in (message['waveform'] as List?) ?? const [])
        (v as num).toInt(),
    ];
    final uploading = message['status'] == 'uploading';
    final played = isMe ? Colors.white : kAccent;
    final unplayed = isMe
        ? Colors.white.withValues(alpha: 0.45)
        : cs.onSurface.withValues(alpha: 0.28);

    return AnimatedBuilder(
      animation: VoicePlayback.instance,
      builder: (context, _) {
        final pb = VoicePlayback.instance;
        final mine = src.isNotEmpty && pb.current == src;
        final playing = mine && pb.playing;
        final at = mine ? pb.position : Duration.zero;
        final fraction = length.inMilliseconds == 0
            ? 0.0
            : (at.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
        return SizedBox(
          width: 224,
          child: Row(
            children: [
              GestureDetector(
                key: const ValueKey('voice_play'),
                onTap: src.isEmpty || uploading
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        // ignore: discarded_futures
                        pb.toggle(src);
                      },
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isMe ? Colors.white : kAccent,
                  ),
                  alignment: Alignment.center,
                  child: uploading
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: isMe ? kAccent : Colors.white,
                          ),
                        )
                      : Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                          color: isMe ? kAccent : Colors.white,
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: CustomPaint(
                    painter: WaveformPainter(
                      levels: levels.isEmpty
                          ? List.filled(ChatMedia.waveformBars, 18)
                          : levels,
                      fraction: fraction,
                      played: played,
                      unplayed: unplayed,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (mine)
                GestureDetector(
                  key: const ValueKey('voice_speed'),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    // ignore: discarded_futures
                    pb.nextSpeed();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (isMe ? Colors.white : kAccent).withValues(
                        alpha: 0.18,
                      ),
                      borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                    ),
                    child: Text(
                      '${pb.speed == pb.speed.roundToDouble() ? pb.speed.toInt() : pb.speed}×',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isMe ? Colors.white : kAccent,
                      ),
                    ),
                  ),
                )
              else
                Text(
                  voiceClock(length),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.9)
                        : cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The shape of a voice note: one rounded bar per level, the played part
/// in full colour.
class WaveformPainter extends CustomPainter {
  final List<int> levels;
  final double fraction;
  final Color played;
  final Color unplayed;

  WaveformPainter({
    required this.levels,
    required this.fraction,
    required this.played,
    required this.unplayed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0) return;
    final n = levels.length;
    final step = size.width / n;
    final bar = math.max(2.0, step * 0.55);
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < n; i++) {
      final v = levels[i].clamp(0, 100) / 100;
      final h = math.max(bar, size.height * (0.15 + 0.85 * v));
      final x = i * step + step / 2;
      paint
        ..color = (i + 0.5) / n <= fraction ? played : unplayed
        ..strokeWidth = bar;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2 + bar / 2),
        Offset(x, (size.height + h) / 2 - bar / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter old) =>
      old.fraction != fraction ||
      old.levels != levels ||
      old.played != played ||
      old.unplayed != unplayed;
}

// ── Recording ─────────────────────────────────────────────────────────────

/// What a finished recording hands back.
class VoiceNote {
  final File file;
  final Duration length;
  final List<int> waveform;
  const VoiceNote(this.file, this.length, this.waveform);
}

/// Shown in place of the message box while recording: a bin to throw it
/// away, a red dot and the time, the voice's loudness moving as you speak,
/// and send. It stops by itself at two minutes and sends what it has.
class VoiceRecordingBar extends StatefulWidget {
  final ValueChanged<VoiceNote> onSend;
  final VoidCallback onCancel;

  const VoiceRecordingBar({
    super.key,
    required this.onSend,
    required this.onCancel,
  });

  @override
  State<VoiceRecordingBar> createState() => _VoiceRecordingBarState();
}

class _VoiceRecordingBarState extends State<VoiceRecordingBar>
    with SingleTickerProviderStateMixin {
  static const _tick = Duration(milliseconds: 100);

  late final VoiceRecorder _rec = ChatMedia.instance.recorder();
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  StreamSubscription<double>? _levelsSub;
  Timer? _timer;
  int _ticks = 0;
  final List<int> _levels = [];
  int _latest = 0;
  bool _started = false;
  bool _done = false;

  Duration get _length => _tick * _ticks;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _start();
  }

  Future<void> _start() async {
    try {
      final dir = await ChatMedia.instance.directory();
      final path =
          '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _rec.start(path);
    } catch (e) {
      debugPrint('[chat] recording would not start: $e');
      if (mounted) widget.onCancel();
      return;
    }
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _started = true;
    _levelsSub = _rec.levels().listen((db) => _latest = levelFromDb(db));
    _timer = Timer.periodic(_tick, (_) {
      if (!mounted) return;
      setState(() {
        _ticks++;
        _levels.add(_latest);
      });
      if (_length >= ChatMedia.maxVoice) {
        // ignore: discarded_futures
        _send();
      }
    });
    setState(() {});
  }

  Future<void> _send() async {
    if (_done || !_started) return;
    _done = true;
    _timer?.cancel();
    final length = _length;
    final path = await _rec.stop();
    if (!mounted) return;
    // Under half a second is a slip of the finger, not a message.
    if (path == null || length < const Duration(milliseconds: 500)) {
      widget.onCancel();
      return;
    }
    HapticFeedback.lightImpact();
    widget.onSend(
      VoiceNote(
        File(path),
        length,
        fitWaveform(_levels, ChatMedia.waveformBars),
      ),
    );
  }

  Future<void> _cancel() async {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    HapticFeedback.selectionClick();
    try {
      await _rec.cancel();
    } catch (e) {
      debugPrint('[chat] could not throw the recording away: $e');
    }
    if (mounted) widget.onCancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _levelsSub?.cancel();
    _pulse.dispose();
    // A recording left behind (the page closed mid-way) is thrown away.
    if (!_done && _started) {
      // ignore: discarded_futures
      _rec.cancel();
    }
    // ignore: discarded_futures
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final recent = _levels.length > 40
        ? _levels.sublist(_levels.length - 40)
        : _levels;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconBubble(
          key: const ValueKey('voice_cancel'),
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete recording',
          size: 44,
          onTap: _cancel,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: cs.onSurface.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppTheme.radiusXxl),
              border: Border.all(color: cs.onSurface.withValues(alpha: 0.08)),
            ),
            child: Row(
              children: [
                FadeTransition(
                  opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  voiceClock(_length),
                  key: const ValueKey('voice_clock'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 24,
                    child: recent.isEmpty
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Recording…',
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface.withValues(alpha: 0.5),
                              ),
                            ),
                          )
                        : CustomPaint(
                            painter: WaveformPainter(
                              levels: [
                                ...List.filled(40 - recent.length, 0),
                                ...recent,
                              ],
                              fraction: 1,
                              played: AppTheme.error.withValues(alpha: 0.8),
                              unplayed: AppTheme.error,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconBubble(
          key: const ValueKey('voice_send'),
          icon: Icons.arrow_upward_rounded,
          tooltip: 'Send voice message',
          filled: true,
          size: 44,
          onTap: _started ? _send : null,
        ),
      ],
    );
  }
}

// ── Before sending a photo ────────────────────────────────────────────────

/// The photo, big, before it goes — with who it is going to and a box to
/// add a caption. Answers the caption ("" for none), or null when the
/// person backs out.
class PhotoPreviewPage extends StatefulWidget {
  final File file;
  final String to;

  const PhotoPreviewPage({super.key, required this.file, required this.to});

  @override
  State<PhotoPreviewPage> createState() => _PhotoPreviewPageState();
}

class _PhotoPreviewPageState extends State<PhotoPreviewPage> {
  final _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  void _send() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop(_caption.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: Colors.black,
        // Every layer is placed against the whole screen. A layer left
        // unplaced would make the screen only as tall as itself.
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.file(widget.file, fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                  child: Row(
                    children: [
                      IconBubble(
                        icon: Icons.close_rounded,
                        tooltip: 'Cancel',
                        onImage: true,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusFull,
                          ),
                        ),
                        child: Text(
                          'To ${widget.to}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  12,
                  20,
                  12,
                  12 + MediaQuery.of(context).viewInsets.bottom,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 46),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(
                              AppTheme.radiusXxl,
                            ),
                          ),
                          child: TextField(
                            key: const ValueKey('photo_caption'),
                            controller: _caption,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: 1000,
                            cursorColor: kAccent,
                            textCapitalization: TextCapitalization.sentences,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Add a caption…',
                              hintStyle: TextStyle(color: Colors.white60),
                              counterText: '',
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              isCollapsed: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconBubble(
                        key: const ValueKey('photo_send'),
                        icon: Icons.arrow_upward_rounded,
                        tooltip: 'Send photo',
                        filled: true,
                        size: 46,
                        onTap: _send,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
