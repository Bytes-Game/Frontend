import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:myapp/services/create_flow.dart';
import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// What the + button opens: the phone's photos and videos, the way
/// Instagram's and TikTok's do.
///
///   * The camera comes first in the grid. It takes a photo or records a
///     video (see RecordVideoPage).
///   * Then everything on the phone, newest first, photos and videos
///     together. A video shows how long it is.
///   * Tapping one shows it big at the top; Next goes on with it.
///
/// Nobody is asked "photo or video?". The thing picked is one or the other
/// already, and the app takes it from there: a video to the trim screen, a
/// photo straight to the details (see CreateFlow.continueWith).
///
/// Without access to the gallery the page says so, offers to ask again,
/// and offers the phone's own picker, which needs no access at all. The
/// camera works either way.
class CreatePage extends StatefulWidget {
  /// Where it was opened from, for the event log.
  final String from;

  const CreatePage({super.key, this.from = ''});

  /// Photos and videos read from the phone at a time.
  static const int pageSize = 60;

  @override
  State<CreatePage> createState() => _CreatePageState();
}

class _CreatePageState extends State<CreatePage>
    with PageTracker<CreatePage>, WidgetsBindingObserver {
  @override
  String get pageName => 'create_page';

  DeviceGallery get _gallery => DeviceGallery.instance;

  /// Null while the phone is being asked.
  GalleryAccess? _access;
  final List<GalleryItem> _items = [];
  int _nextPage = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _failed = false;
  GalleryItem? _selected;

  /// Getting the picked one ready (a photo is shrunk first).
  bool _preparing = false;

  /// Sent to the phone's settings to allow access: ask again on coming back.
  bool _inSettings = false;

  /// Small pictures, asked for once each.
  final Map<String, Future<Uint8List?>> _pictures = {};

  static const int _gridPicture = 240;
  static const int _previewPicture = 900;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _inSettings) {
      _inSettings = false;
      unawaited(_start());
    }
  }

  Future<void> _start() async {
    final access = await _gallery.requestAccess();
    if (!mounted) return;
    setState(() {
      _access = access;
      _items.clear();
      _nextPage = 0;
      _hasMore = access != GalleryAccess.denied;
      _failed = false;
      _selected = null;
    });
    if (access != GalleryAccess.denied) await _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    try {
      final got = await _gallery.recent(
        page: _nextPage,
        size: CreatePage.pageSize,
      );
      if (!mounted) return;
      setState(() {
        _nextPage++;
        _hasMore = got.length >= CreatePage.pageSize;
        _items.addAll(got);
        // Like Instagram: the newest is ready to go the moment it opens.
        _selected ??= _items.isEmpty ? null : _items.first;
      });
    } catch (_) {
      // DeviceGallery has said what went wrong. The page says so too,
      // rather than looking like a phone with nothing on it.
      if (mounted) setState(() => _failed = true);
    } finally {
      _loading = false;
    }
  }

  Future<Uint8List?> _picture(GalleryItem item, int size) => _pictures
      .putIfAbsent('${item.id}@$size', () => _gallery.thumbnail(item, size));

  /// After a post the page closes, back to wherever + was pressed.
  void _closeIfPosted(bool posted) {
    if (posted && mounted) Navigator.of(context).pop();
  }

  Future<void> _next() async {
    final item = _selected;
    if (item == null || _preparing) return;
    setState(() => _preparing = true);
    final file = await _gallery.fileFor(item);
    if (!mounted) return;
    setState(() => _preparing = false);
    if (file == null) {
      _toast("Couldn't open that one. Try another.");
      return;
    }
    final posted = await CreateFlow.continueWith(
      context,
      file.path,
      photo: !item.isVideo,
    );
    _closeIfPosted(posted);
  }

  Future<void> _camera() async {
    final posted = await CreateFlow.camera(context, from: widget.from);
    _closeIfPosted(posted);
  }

  Future<void> _phonePicker() async {
    final picked = await _gallery.pickWithPhone();
    if (!mounted || picked == null) return;
    final posted = await CreateFlow.continueWith(
      context,
      picked.file.path,
      photo: !picked.isVideo,
    );
    _closeIfPosted(posted);
  }

  Future<void> _askAgain() async {
    final access = await _gallery.requestAccess();
    if (!mounted) return;
    if (access == GalleryAccess.denied) {
      // Refused for good: only the phone's settings can change it now.
      _inSettings = true;
      await _gallery.openSettings();
      return;
    }
    await _start();
  }

  Future<void> _chooseMore() async {
    await _gallery.chooseMore();
    if (mounted) await _start();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final access = _access;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          key: const ValueKey('create_close'),
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'New challenge',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (access != null && access != GalleryAccess.denied)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _preparing
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : TextButton(
                      key: const ValueKey('create_next'),
                      onPressed: _selected == null ? null : _next,
                      style: TextButton.styleFrom(
                        foregroundColor: kAccent,
                        disabledForegroundColor: Colors.white30,
                      ),
                      child: const Text(
                        'Next',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
            ),
        ],
      ),
      body: access == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white54),
            )
          : LayoutBuilder(
              builder: (context, box) {
                final previewHeight = math.min(
                  box.maxWidth,
                  box.maxHeight * 0.42,
                );
                return Column(
                  children: [
                    SizedBox(
                      height: previewHeight,
                      width: double.infinity,
                      child: access == GalleryAccess.denied
                          ? _noAccess()
                          : _preview(),
                    ),
                    _bar(access),
                    Expanded(child: _grid(access)),
                  ],
                );
              },
            ),
    );
  }

  /// The picked one, big.
  Widget _preview() {
    final item = _selected;
    if (item == null) {
      return Center(
        child: Text(
          _failed
              ? "Couldn't read your photos and videos."
              : (_items.isEmpty && !_hasMore
                    ? 'Nothing on this phone yet. Use the camera.'
                    : ''),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        ),
      );
    }
    return Stack(
      key: ValueKey('create_preview_${item.id}'),
      fit: StackFit.expand,
      children: [
        _Picture(future: _picture(item, _previewPicture), fit: BoxFit.contain),
        if (item.isVideo) ...[
          Center(
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.4),
                border: Border.all(color: Colors.white70),
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
          Positioned(
            right: 10,
            bottom: 10,
            child: _Length(item.duration, large: true),
          ),
        ],
      ],
    );
  }

  Widget _noAccess() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        key: const ValueKey('create_no_access'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.photo_library_outlined,
            color: Colors.white70,
            size: 44,
          ),
          const SizedBox(height: 12),
          const Text(
            'Allow access to your photos and videos',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'To pick one to post here. You can also use the camera.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('create_allow'),
            onPressed: _askAgain,
            style: FilledButton.styleFrom(
              backgroundColor: kAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Allow access'),
          ),
          TextButton(
            key: const ValueKey('create_phone_picker'),
            onPressed: _phonePicker,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('Choose from your phone'),
          ),
        ],
      ),
    );
  }

  /// "Recents", and on a limited share, a way to share more.
  Widget _bar(GalleryAccess access) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          const Text(
            'Recents',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (access == GalleryAccess.limited)
            TextButton(
              key: const ValueKey('create_choose_more'),
              onPressed: _chooseMore,
              style: TextButton.styleFrom(foregroundColor: kAccent),
              child: const Text('Choose more'),
            ),
        ],
      ),
    );
  }

  Widget _grid(GalleryAccess access) {
    final items = access == GalleryAccess.denied
        ? const <GalleryItem>[]
        : _items;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 800) unawaited(_loadMore());
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 1,
          crossAxisSpacing: 1,
        ),
        // The camera, then the phone's photos and videos.
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) return _CameraTile(onTap: _camera);
          final item = items[i - 1];
          final chosen = item == _selected;
          return GestureDetector(
            key: ValueKey('create_item_${item.id}'),
            onTap: () => setState(() => _selected = item),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Picture(future: _picture(item, _gridPicture)),
                if (item.isVideo)
                  Positioned(
                    right: 5,
                    bottom: 4,
                    child: _Length(item.duration),
                  ),
                if (chosen)
                  const IgnorePointer(
                    child: ColoredBox(color: Color(0x66FFFFFF)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CameraTile extends StatelessWidget {
  final VoidCallback onTap;
  const _CameraTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('create_camera'),
      onTap: onTap,
      child: const ColoredBox(
        color: Color(0xFF1C1C1E),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera_rounded, color: Colors.white, size: 30),
            SizedBox(height: 4),
            Text(
              'Camera',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A picture from the phone, once it arrives.
class _Picture extends StatelessWidget {
  final Future<Uint8List?> future;
  final BoxFit fit;
  const _Picture({required this.future, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          return const ColoredBox(color: Color(0xFF151517));
        }
        return Image.memory(
          bytes,
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF151517)),
        );
      },
    );
  }
}

/// "0:42" on a video.
class _Length extends StatelessWidget {
  final Duration length;
  final bool large;
  const _Length(this.length, {this.large = false});

  @override
  Widget build(BuildContext context) {
    final s = length.inSeconds;
    final text = '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
    return Text(
      text,
      style: TextStyle(
        color: Colors.white,
        fontSize: large ? 13 : 11,
        fontWeight: FontWeight.w600,
        shadows: const [Shadow(blurRadius: 4)],
      ),
    );
  }
}
