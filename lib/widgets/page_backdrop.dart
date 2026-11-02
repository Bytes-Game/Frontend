import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The blue glow behind every page: the app's colour, soft, from the
/// top. Deep and fading to black in dark mode (the same glow as behind the
/// QR code on the share page); pale and fading to white in light mode.
///
/// ## How every page gets it
///
/// Each page the app opens goes through [BackdropPageTransitionsBuilder],
/// which puts the glow under it. The theme's page colour
/// (scaffoldBackgroundColor) is see-through in both modes, so a page shows
/// the glow unless it paints its own background. The video screens do:
/// they set black themselves, so a video is never lit from behind.
///
/// Widgets that need a solid colour the shape of "the page" (a ring cut
/// around a badge, a header that content scrolls under) use
/// AppTheme.pageColor, never the see-through one.
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, required this.child});

  final Widget child;

  /// The glow in dark mode: deep blue to black.
  static const glow = RadialGradient(
    center: Alignment(0, -0.85),
    radius: 1.15,
    colors: [Color(0xFF1C3784), Color(0xFF0A1430), Colors.black],
    stops: [0, 0.45, 1],
  );

  /// The glow in light mode: the same, pale, to white.
  static const lightGlow = RadialGradient(
    center: Alignment(0, -0.85),
    radius: 1.15,
    colors: [Color(0xFFDCE6FF), Color(0xFFEEF3FF), Colors.white],
    stops: [0, 0.45, 1],
  );

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      key: const ValueKey('page_backdrop'),
      decoration: dark
          ? const BoxDecoration(color: Colors.black, gradient: glow)
          : const BoxDecoration(color: Colors.white, gradient: lightGlow),
      child: child,
    );
  }
}

/// The app's page transition (the iPhone's slide, on every platform), with
/// [PageBackdrop] under each page. The glow slides with its page, so two
/// pages never show through each other mid-slide.
class BackdropPageTransitionsBuilder extends PageTransitionsBuilder {
  const BackdropPageTransitionsBuilder();

  static const _slide = CupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _slide.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _slide.reverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _slide.delegatedTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _slide.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      PageBackdrop(child: child),
    );
  }
}
