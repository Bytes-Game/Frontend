import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/widgets/battle_record_panel.dart' show LeagueEmblem;
import 'package:myapp/widgets/league_badge.dart';

/// The top of a profile: an arena in the person's league colours.
///
/// Everything in it is moved by the scroll itself. As the page goes up:
///   - the avatar shrinks and slides from the middle into the top bar,
///   - the name and league fade out and the @handle fades into the bar,
///   - the lights in the background drift up more slowly than the page,
///     so the page seems to move over them,
///   - the rings round the avatar turn.
/// Scroll back down and it all runs the other way.
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
    this.openHeight = 300,
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
    final t = closedFraction(shrinkOffset);
    final move = Curves.easeInOut.transform(t);
    final width = MediaQuery.sizeOf(context).width;
    final colors = LeagueBadge.gradientFor(record.league);
    final dark = [
      Color.lerp(colors.first, Colors.black, 0.45)!,
      Color.lerp(colors.last, Colors.black, 0.75)!,
    ];

    const bigR = 50.0;
    const smallR = 17.0;
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
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark,
                ),
              ),
            ),
          ),
          // Lights, drifting slower than the page.
          Positioned(
            top: -60 - shrinkOffset * 0.35,
            left: -50,
            child: _Glow(
              size: 240,
              color: colors.first.withValues(alpha: 0.35),
            ),
          ),
          Positioned(
            top: 80 - shrinkOffset * 0.6,
            right: -70,
            child: _Glow(size: 260, color: colors.last.withValues(alpha: 0.30)),
          ),
          // Rings that turn with the scroll.
          Positioned(
            left: cx - r * 1.9,
            top: cy - r * 1.9,
            child: Opacity(
              opacity: (1 - t * 1.6).clamp(0.0, 1.0),
              child: Transform.rotate(
                angle: shrinkOffset * 0.012,
                child: _Rings(size: r * 3.8, color: colors.first),
              ),
            ),
          ),
          Positioned(
            left: cx - r,
            top: cy - r,
            child: Container(
              width: r * 2,
              height: r * 2,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2 + 1 * (1 - t)),
                gradient: LinearGradient(colors: colors),
                boxShadow: [
                  BoxShadow(
                    color: colors.first.withValues(alpha: 0.6 * (1 - t)),
                    blurRadius: 30,
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                user.username.isEmpty ? '?' : user.username[0].toUpperCase(),
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: r * 0.9,
                ),
              ),
            ),
          ),
          // Name and league, under the avatar while the arena is open.
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (user.fullName.isNotEmpty)
                      Text(
                        '@${user.username}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LeagueEmblem(league: record.league, size: 22),
                        const SizedBox(width: 6),
                        Text(
                          record.decided == 0
                              ? 'Unranked'
                              : '${record.league} · ${record.rating}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // The @handle in the bar, once the arena has closed.
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
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
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
                data: const IconThemeData(color: Colors.white),
                child: Center(child: leading!),
              ),
            ),
          Positioned(
            right: 4,
            top: topInset,
            height: barHeight,
            child: IconTheme(
              data: const IconThemeData(color: Colors.white),
              child: Row(children: actions),
            ),
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

class _Glow extends StatelessWidget {
  final double size;
  final Color color;

  const _Glow({required this.size, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

class _Rings extends StatelessWidget {
  final double size;
  final Color color;

  const _Rings({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    Widget ring(double f, double a) => Container(
      width: size * f,
      height: size * f,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: a), width: 1.4),
      ),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ring(1.0, 0.25),
          ring(0.78, 0.4),
          // A notch on the outer ring, so the turning can be seen.
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
