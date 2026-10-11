import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:myapp/widgets/arena_ui.dart';

/// Somebody's profile photo, big, over a blurred page — the way Instagram
/// shows it when you hold or tap a profile picture.
///
/// Two ways in:
///   * [PhotoPeekHold] wraps a picture: hold it and the photo opens, lift
///     your finger and it goes.
///   * [showPhotoPeek] opens it from a tap, and a tap anywhere closes it.
///
/// A person with no photo shows their initial, big: the same as the
/// picture everywhere else.
class _PeekView extends StatelessWidget {
  final String username;
  final Animation<double> appear;

  const _PeekView({required this.username, required this.appear});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final d = (size.shortestSide * 0.72).clamp(160.0, 340.0);
    final curved = CurvedAnimation(parent: appear, curve: Curves.easeOutBack);
    return AnimatedBuilder(
      animation: appear,
      builder: (context, _) {
        final t = appear.value.clamp(0.0, 1.0);
        return Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18 * t, sigmaY: 18 * t),
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Center(
              child: Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * curved.value,
                  child: Column(
                    key: const ValueKey('photo_peek'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 40,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        child: ArenaAvatar(name: username, size: d),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        username,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.none,
                          shadows: [Shadow(blurRadius: 8)],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Open [username]'s photo big from a tap. Closes on a tap anywhere, or
/// back.
Future<void> showPhotoPeek(BuildContext context, String username) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close photo',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, _) => GestureDetector(
      key: const ValueKey('photo_peek_close'),
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(ctx).pop(),
      child: _PeekView(username: username, appear: anim),
    ),
  );
}

/// A picture that opens big while it is held, and closes when let go.
///
/// [onTap] is what a plain tap does (your own photo: change it). The hold
/// never fires a tap, and a tap never opens the photo.
class PhotoPeekHold extends StatefulWidget {
  final String username;
  final Widget child;
  final VoidCallback? onTap;

  const PhotoPeekHold({
    super.key,
    required this.username,
    required this.child,
    this.onTap,
  });

  @override
  State<PhotoPeekHold> createState() => _PhotoPeekHoldState();
}

class _PhotoPeekHoldState extends State<PhotoPeekHold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  OverlayEntry? _entry;

  void _open() {
    if (_entry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: _PeekView(username: widget.username, appear: _appear),
      ),
    );
    overlay.insert(_entry!);
    _appear.forward(from: 0);
  }

  Future<void> _close() async {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    await _appear.reverse();
    entry.remove();
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    _appear.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('photo_hold_${widget.username}'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPressStart: (_) => _open(),
      onLongPressEnd: (_) => _close(),
      onLongPressCancel: _close,
      child: widget.child,
    );
  }
}
