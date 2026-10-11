import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// Sharing a profile or a video: a QR code to scan and the link to send.
///
/// The code is drawn the way the best of them are — round dots, rounded
/// corner markers in the app's blue, and the person's photo in the middle —
/// on a white card that floats over a dark page with a soft blue glow. Under
/// it, the link itself, and two things to do with it: copy it, or save the
/// card to your photos to post anywhere.
///
/// Scanning the code or opening the link shows the person or the video on
/// a web page anybody can open (public_pages.go on the server).
class ShareCardPage extends StatefulWidget {
  /// What the code holds, and what Copy copies.
  final String link;

  /// Big, under the code: "@maya", or the video's title.
  final String title;

  /// Small, under that: their name, or "by @maya".
  final String subtitle;

  /// Whose photo sits in the middle of the code.
  final String photoOf;

  /// "profile" or "video", for the page's wording and what is tracked.
  final String what;

  const ShareCardPage({
    super.key,
    required this.link,
    required this.title,
    required this.subtitle,
    required this.photoOf,
    required this.what,
  });

  /// How a saved card reaches the gallery. A seam for tests.
  @visibleForTesting
  static Future<bool> Function(String path) keepInGallery = (path) =>
      DeviceGallery.instance.keepInGallery(path, isVideo: false);

  @override
  State<ShareCardPage> createState() => _ShareCardPageState();
}

class _ShareCardPageState extends State<ShareCardPage>
    with SingleTickerProviderStateMixin {
  final _card = GlobalKey();
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  )..forward();
  bool _saving = false;

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _say(String text) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(text),
      duration: const Duration(seconds: 2),
    ));
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.link));
    EventTracker.instance.trackTap(
      target: 'share_${widget.what}_copy_link',
      pageName: 'share_card',
    );
    if (mounted) _say('Link copied');
  }

  /// The card as a picture in the gallery: drawn at three times the
  /// screen's size so it stays sharp when posted.
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    var saved = false;
    File? file;
    try {
      final boundary =
          _card.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: 3);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (png != null) {
          final dir = await getTemporaryDirectory();
          file = File('${dir.path}/share_qr_'
              '${DateTime.now().millisecondsSinceEpoch}.png');
          await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
          saved = await ShareCardPage.keepInGallery(file.path);
        }
      }
    } catch (e) {
      debugPrint('[share] could not save the QR card: $e');
    } finally {
      // The gallery has its own copy now; this one was only the way there.
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (e) {
        debugPrint('[share] could not tidy the QR picture away: $e');
      }
    }
    EventTracker.instance.trackTap(
      target: 'share_${widget.what}_save_qr',
      pageName: 'share_card',
      params: {'saved': saved},
    );
    if (!mounted) return;
    setState(() => _saving = false);
    _say(saved
        ? 'Saved to your photos'
        : "Couldn't save it. Allow access to your photos and try again.");
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final qr = (size.width - 120).clamp(180.0, 260.0);
    final rise = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey('share_close'),
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(widget.what == 'video' ? 'Share video' : 'Share profile'),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          // The glow: the app's blue, soft, from the top.
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.85),
                  radius: 1.15,
                  colors: [Color(0xFF0B3D73), Color(0xFF051425), Colors.black],
                  stops: [0, 0.45, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: AnimatedBuilder(
                  animation: rise,
                  builder: (context, child) => Opacity(
                    opacity: rise.value,
                    child: Transform.translate(
                      offset: Offset(0, 24 * (1 - rise.value)),
                      child: Transform.scale(
                        scale: 0.94 + 0.06 * rise.value,
                        child: child,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RepaintBoundary(
                        key: _card,
                        child: _Card(
                          link: widget.link,
                          title: widget.title,
                          subtitle: widget.subtitle,
                          photoOf: widget.photoOf,
                          qrSize: qr,
                        ),
                      ),
                      const SizedBox(height: 22),
                      _LinkPill(link: widget.link, onCopy: _copy),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: _BigButton(
                              key: const ValueKey('share_copy'),
                              icon: Icons.link_rounded,
                              label: 'Copy link',
                              filled: true,
                              onTap: _copy,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _BigButton(
                              key: const ValueKey('share_save_qr'),
                              icon: _saving
                                  ? Icons.hourglass_top_rounded
                                  : Icons.download_rounded,
                              label: _saving ? 'Saving…' : 'Save QR code',
                              onTap: _saving ? null : _save,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        widget.what == 'video'
                            ? 'Anyone can scan it to watch the video.'
                            : 'Anyone can scan it to see the profile.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 13,
                        ),
                      ),
                    ],
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

/// The white card: the code with the photo in its middle, and who it is.
class _Card extends StatelessWidget {
  final String link, title, subtitle, photoOf;
  final double qrSize;

  const _Card({
    required this.link,
    required this.title,
    required this.subtitle,
    required this.photoOf,
    required this.qrSize,
  });

  static const _blue = Color(0xFF0A84FF);

  @override
  Widget build(BuildContext context) {
    final face = (qrSize * 0.24).roundToDouble();
    return Container(
      key: const ValueKey('share_card'),
      padding: const EdgeInsets.fromLTRB(26, 26, 26, 22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(
            color: _blue.withValues(alpha: 0.35),
            blurRadius: 60,
            spreadRadius: -8,
            offset: const Offset(0, 24),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: qrSize,
            height: qrSize,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ShareQr(link: link, size: qrSize),
                Container(
                  width: face + 10,
                  height: face + 10,
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: ArenaAvatar(name: photoOf, size: face),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            key: const ValueKey('share_title'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF111114),
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.2,
            ),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF6E6E73), fontSize: 14),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _blue,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: const Text(
                  'd',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'devf',
                style: TextStyle(
                  color: Color(0xFF111114),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The code itself: round dots, round corner markers in the app's blue.
///
/// Highest error correction, so a quarter of it can be covered and it still
/// scans — which is what lets the photo sit in the middle.
class ShareQr extends StatelessWidget {
  /// What it holds.
  final String link;
  final double size;

  const ShareQr({super.key, required this.link, required this.size});

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      key: const ValueKey('share_qr'),
      data: link,
      size: size,
      padding: EdgeInsets.zero,
      errorCorrectionLevel: QrErrorCorrectLevel.H,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.circle,
        color: Color(0xFF0A84FF),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.circle,
        color: Color(0xFF111114),
      ),
    );
  }
}

/// The link, in full, on a glass strip; a tap copies it.
class _LinkPill extends StatelessWidget {
  final String link;
  final VoidCallback onCopy;

  const _LinkPill({required this.link, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final shown = link.replaceFirst(RegExp(r'^https?://'), '');
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: const ValueKey('share_link'),
        borderRadius: BorderRadius.circular(16),
        onTap: onCopy,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Row(
            children: [
              const Icon(Icons.public_rounded, size: 18, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  shown,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.copy_rounded, size: 18, color: kAccent),
            ],
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  const _BigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = filled
        ? const Color(0xFF0A84FF)
        : Colors.white.withValues(alpha: 0.10);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
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
