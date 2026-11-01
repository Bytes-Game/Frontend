import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The blue glow behind every page in dark mode: the app's blue, soft,
/// from the top, fading to black. The same glow as behind the QR code on
/// the share page.
///
/// ## How every page gets it
///
/// Each page the app opens goes through [BackdropPageTransitionsBuilder],
/// which puts the glow under it. In dark mode the theme's page colour
/// (scaffoldBackgroundColor) is see-through, so a page shows the glow
/// unless it paints its own background. The video screens do: they set
/// black themselves, so a video is never lit blue from behind.
///
/// Widgets that need a solid colour the shape of "the page" (a ring cut
/// around a badge, a header that content scrolls under) use
/// AppTheme.pageColor, never the see-through one.
class PageBackdrop extends StatelessWidget {
  const PageBackdrop({super.key, required this.child});

  final Widget child;

  /// The glow itself.
  static const glow = RadialGradient(
    center: Alignment(0, -0.85),
    radius: 1.15,
    colors: [Color(0xFF0B3D73), Color(0xFF051425), Colors.black],
    stops: [0, 0.45, 1],
  );

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) return child;
    return DecoratedBox(
      key: const ValueKey('page_backdrop'),
      decoration: const BoxDecoration(color: Colors.black, gradient: glow),
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
