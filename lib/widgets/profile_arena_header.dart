import 'package:flutter/material.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/league_badge.dart';

/// The top of a profile, laid out the way a contact card is: the picture on
/// the left, and beside it the name, the handle and league, and the bio —
/// or, on your own profile with none yet, an "Add bio" button right under
/// your name.
///
/// Behind it, a soft wash of the league's colour fading into the page, the
/// way Apple's product pages put colour behind a headline.
///
/// Everything in it is moved by the scroll itself. As the page goes up:
///   - the picture shrinks and slides up into the top bar,
///   - the words beside it fade out and the @handle fades into the bar,
///   - a hairline appears under the bar once it has closed.
/// Scroll back down and it all runs the other way.
class ArenaHeroHeader extends SliverPersistentHeaderDelegate {
  final UserModel user;
  final BattleRecord record;

  /// Room above the bar for the status bar, when nothing else leaves it.
  final double topInset;
  final Widget? leading;
  final List<Widget> actions;

  /// Your own profile with no bio yet: shows "Add bio" under the name.
  final VoidCallback? onAddBio;

  ArenaHeroHeader({
    required this.user,
    required this.record,
    this.topInset = 0,
    this.leading,
    this.actions = const [],
    this.onAddBio,
  });

  static const double barHeight = kToolbarHeight;

  /// The picture's size when the header is open.
  static const double avatarSize = 76;

  /// How tall the header is when fully open, not counting [topInset]: the
  /// bar, and one row with the picture and the words beside it.
  static const double openHeight = barHeight + avatarSize + 32;

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
    // match on a phone held upright, but not in a split screen or a tablet
    // side panel.
    return LayoutBuilder(
      builder: (context, box) => _build(context, shrinkOffset, box.maxWidth),
    );
  }

  Widget _build(BuildContext context, double shrinkOffset, double width) {
    final t = closedFraction(shrinkOffset);
    final move = Curves.easeInOut.transform(t);
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = cs.onSurface;
    final muted = fg.withValues(alpha: 0.6);
    final page = Theme.of(context).scaffoldBackgroundColor;
    final wash = leagueWash(record.league);
    final top = dark
        ? Color.lerp(wash, Colors.black, 0.62)!
        : Color.lerp(wash, Colors.white, 0.78)!;

    const bigR = avatarSize / 2;
    const smallR = 16.0;
    final r = bigR + (smallR - bigR) * move;
    final startCx = 16.0 + bigR;
    final endCx = (leading != null ? 56.0 : 16.0) + smallR;
    final cx = startCx + (endCx - startCx) * move;
    final startCy = topInset + barHeight + 8 + bigR;
    final endCy = topInset + barHeight / 2;
    final cy = startCy + (endCy - startCy) * move;
    final wordsOpacity = (1 - t * 2.4).clamp(0.0, 1.0);
    final barTitleOpacity = ((t - 0.6) / 0.4).clamp(0.0, 1.0);
    final name = user.fullName.isNotEmpty ? user.fullName : user.username;
    final private = user.visibility == 'friends';
    final league = record.decided == 0
        ? 'Unranked'
        : '${record.league} · ${record.rating}';

    return ClipRect(
      child: Stack(
        children: [
          // The wash: the league's colour at the top, fading into the page.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [top, page],
                ),
              ),
            ),
          ),
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
          // The picture, with a thin ring in the league's colour.
          Positioned(
            left: cx - r,
            top: cy - r,
            child: ArenaAvatar(name: user.username, size: r * 2, ring: wash),
          ),
          // Beside the picture: name, handle and league, bio or "Add bio".
          Positioned(
            left: startCx + bigR + 14,
            right: 16,
            top: topInset + barHeight + 6,
            height: avatarSize + 20,
            child: Opacity(
              opacity: wordsOpacity,
              child: IgnorePointer(
                ignoring: wordsOpacity < 0.5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                        ),
                        if (private) ...[
                          const SizedBox(width: 5),
                          Icon(Icons.lock_rounded, size: 15, color: muted),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.fullName.isNotEmpty
                                ? '@${user.username} · $league'
                                : league,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: muted, fontSize: 13.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (user.bio.isNotEmpty)
                      Text(
                        user.bio,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.85),
                          fontSize: 13.5,
                          height: 1.3,
                        ),
                      )
                    else if (onAddBio != null)
                      Pressable(
                        onTap: onAddBio,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: fg.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_rounded, size: 16, color: kAccent),
                              SizedBox(width: 4),
                              Text(
                                'Add bio',
                                style: TextStyle(
                                  color: kAccent,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // The @handle in the bar, once the header has closed.
          Positioned(
            left: endCx + smallR + 10,
            right: 16 + 46.0 * actions.length,
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
      old.leading != leading ||
      old.onAddBio != onAddBio;
}
