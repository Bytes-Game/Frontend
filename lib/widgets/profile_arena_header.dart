import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/widgets/battle_record_panel.dart' show LeagueEmblem;
import 'package:myapp/widgets/arena_ui.dart';

/// The top of a profile: who they are, in a plain header that turns into
/// the top bar as the page scrolls.
///
/// Everything in it is moved by the scroll itself. As the page goes up:
///   - the avatar shrinks and slides from the middle into the top bar,
///   - the name and league fade out and the @handle fades into the bar,
///   - a hairline appears under the bar once it has closed.
/// Scroll back down and it all runs the other way.
///
/// Quiet on purpose, like the top of a contact on an iPhone: black in dark
/// mode, light grey in light mode, no colour but the league's own emblem.
class ArenaHeroHeader extends SliverPersistentHeaderDelegate {
  final UserModel user;
  final BattleRecord record;

  /// Room above the bar for the status bar, when nothing else leaves it.
  final double topInset;

  /// How tall the arena is when fully open, not counting [topInset].
  final double openHeight;
  final Widget? leading;
  final List<Widget> actions;

  ArenaHeroHeader({
    required this.user,
    required this.record,
    this.topInset = 0,
    this.openHeight = 270,
    this.leading,
    this.actions = const [],
  });

  static const double barHeight = kToolbarHeight;

  @override
  double get minExtent => barHeight + topInset;

  @override
  double get maxExtent => openHeight + topInset;

  /// How far the header has closed, 0 (open) to 1 (just the bar).
  double closedFraction(double shrinkOffset) =>
      (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    // The width this header is actually given, not the screen's: the two
    // match on a phone held upright, but not in a split screen, a tablet
    // side panel or a test — and the avatar is centred on this number.
    return LayoutBuilder(
      builder: (context, box) =>
          _build(context, shrinkOffset, box.maxWidth),
    );
  }

  Widget _build(BuildContext context, double shrinkOffset, double width) {
    final t = closedFraction(shrinkOffset);
    final move = Curves.easeInOut.transform(t);
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = cs.onSurface;
    final muted = fg.withValues(alpha: 0.55);
    final bg = dark ? Colors.black : const Color(0xFFF2F2F7);

    const bigR = 46.0;
    const smallR = 16.0;
    final r = bigR + (smallR - bigR) * move;
    final endCx = (leading != null ? 56.0 : 16.0) + smallR;
    final cx = width / 2 + (endCx - width / 2) * move;
    final startCy = topInset + openHeight * 0.36;
    final endCy = topInset + barHeight / 2;
    final cy = startCy + (endCy - startCy) * move;
    final nameOpacity = (1 - t * 2.2).clamp(0.0, 1.0);
    final barTitleOpacity = ((t - 0.6) / 0.4).clamp(0.0, 1.0);
    final name = user.fullName.isNotEmpty ? user.fullName : '@${user.username}';

    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: bg)),
          // Hairline under the bar once the header has closed into it.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 0.5,
            child: Opacity(
              opacity: barTitleOpacity,
              child: ColoredBox(color: fg.withValues(alpha: 0.15)),
            ),
          ),
          Positioned(
            left: cx - r,
            top: cy - r,
            child: ArenaAvatar(name: user.username, size: r * 2),
          ),
          // Name and league, under the avatar while the header is open.
          Positioned(
            left: 16,
            right: 16,
            top: cy + r + 12,
            child: IgnorePointer(
              child: Opacity(
                opacity: nameOpacity,
                child: Column(
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: fg,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    if (user.fullName.isNotEmpty)
                      Text(
                        '@${user.username}',
                        style: TextStyle(color: muted, fontSize: 14),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LeagueEmblem(league: record.league, size: 18),
                        const SizedBox(width: 6),
                        Text(
                          record.decided == 0
                              ? 'Unranked'
                              : '${record.league} · ${record.rating}',
                          style: TextStyle(
                            color: muted,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The @handle in the bar, once the header has closed.
          Positioned(
            left: endCx + smallR + 10,
            right: 16 + 48.0 * actions.length,
            top: topInset,
            height: barHeight,
            child: IgnorePointer(
              child: Opacity(
                opacity: barTitleOpacity,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '@${user.username}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (leading != null)
            Positioned(
              left: 4,
              top: topInset,
              height: barHeight,
              child: IconTheme(
                data: IconThemeData(color: fg),
                child: Center(child: leading!),
              ),
            ),
          Positioned(
            right: 12,
            top: topInset,
            height: barHeight,
            child: Row(children: actions),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ArenaHeroHeader old) =>
      old.user != user ||
      old.record != record ||
      old.topInset != topInset ||
      old.actions != actions ||
      old.leading != leading;
}
