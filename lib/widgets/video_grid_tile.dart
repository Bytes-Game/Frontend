import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/video_cache_service.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/shimmer_loading.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// One video in a grid, drawn the way the Search page draws it: the
/// picture, who made it, VS on a battle, the title and the views.
///
/// Every grid of videos on a profile — Shorts, Open, Live, Won, Lost, Liked,
/// Saved — uses this, so a video looks the same wherever you meet it. They
/// used to be three different tiles and, on the battle tabs, not videos at
/// all but lines of text.
class VideoGridTile extends StatelessWidget {
  final ChallengeModel video;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// A coloured line above the title: "Won 5–3", "Ahead 3–2", "Open".
  final TileBadge? badge;

  /// A mark in the top corner in place of VS, for a tab whose whole point
  /// it is: a heart on Liked, a bookmark on Saved.
  final IconData? mark;
  final Color? markColor;

  /// A few words at the right end of the views row: "2d left" on a live
  /// battle. Kept out of [badge] so the score is never cut short.
  final String? trailing;

  const VideoGridTile({
    super.key,
    required this.video,
    required this.onTap,
    this.onLongPress,
    this.badge,
    this.mark,
    this.markColor,
    this.trailing,
  });

  bool get _isBattle =>
      video.responseCount > 0 || video.topResponseId.isNotEmpty;

  /// A removed challenge is still on its owner's own profile — nobody
  /// else's — and says so.
  TileBadge? get _badge =>
      badge ??
      (video.status == 'removed'
          ? const TileBadge('Removed', Icons.block_rounded, Color(0xFFFF453A))
          : null);

  @override
  Widget build(BuildContext context) {
    final thumb = video.thumbnailUrl ?? '';
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      pressedScale: 0.97,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumb.isNotEmpty)
              Image(
                image: ExploreGridCache.posterImage(thumb),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _Backdrop(),
              )
            else
              const _Backdrop(),
            // Scrim top and bottom, so the words read on any picture.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.35),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.78),
                  ],
                  stops: const [0.0, 0.22, 0.45, 1.0],
                ),
              ),
            ),
            // Who made it.
            Positioned(
              top: 6,
              left: 6,
              right: 34,
              child: Row(
                children: [
                  ArenaAvatar(name: video.creatorUsername, size: 18),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      video.creatorUsername,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 4)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (mark != null)
              Positioned(
                top: 5,
                right: 5,
                child: Icon(
                  mark,
                  size: 16,
                  color: markColor ?? Colors.white,
                  shadows: const [Shadow(blurRadius: 4)],
                ),
              )
            else if (_isBattle)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: const Text(
                    'VS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            // What it is, and how many watched.
            Positioned(
              left: 8,
              right: 8,
              bottom: 7,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_badge case final shown?) ...[
                    _BadgeLine(badge: shown),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    video.title.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      // A photo says so, where a video has its play mark.
                      Icon(
                        video.isPhoto
                            ? Icons.image_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: video.isPhoto ? 12 : 14,
                      ),
                      const SizedBox(width: 1),
                      Text(
                        compactCount(video.views),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 4),
                        // Takes what room is left and shortens itself to
                        // fit: on a narrow phone "2h ago" beside the views
                        // ran off the edge of the tile.
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              const Icon(
                                Icons.schedule_rounded,
                                color: Colors.white70,
                                size: 11,
                              ),
                              const SizedBox(width: 2),
                              Flexible(
                                child: Text(
                                  trailing!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A short coloured status on a tile.
class TileBadge {
  final String label;
  final IconData icon;
  final Color color;

  const TileBadge(this.label, this.icon, this.color);
}

class _BadgeLine extends StatelessWidget {
  final TileBadge badge;

  const _BadgeLine({required this.badge});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
      decoration: BoxDecoration(
        color: badge.color,
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badge.icon, size: 11, color: Colors.white),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              badge.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.primary.withValues(alpha: 0.3),
            cs.secondary.withValues(alpha: 0.2),
          ],
        ),
      ),
    );
  }
}

/// 1234 → "1.2K", the way the rest of the app writes counts.
String compactCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

/// The Search page's grid: three columns of tall tiles.
const SliverGridDelegate videoGridDelegate =
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      childAspectRatio: 0.66,
    );

/// What a video grid looks like before its videos arrive: the same tiles,
/// shimmering, so it reads as loading and not as empty.
///
/// A plain box, not a scroll view inside a sliver. The Liked tab put a
/// shrink-wrapped grid inside a SliverFillRemaining, which asks the grid
/// for a height it cannot give — so every time Liked loaded, the layout
/// failed and the tab showed an error box instead of a placeholder.
class VideoGridPlaceholder extends StatelessWidget {
  const VideoGridPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: GridView.builder(
        key: const ValueKey('video_grid_loading'),
        physics: const NeverScrollableScrollPhysics(),
        padding: videoGridPadding,
        gridDelegate: videoGridDelegate,
        itemCount: 9,
        itemBuilder: (_, _) => const SkeletonBone(
          height: double.infinity,
          borderRadius: AppTheme.radiusMd,
        ),
      ),
    );
  }
}

/// Fetches the opening second or two of the first videos in a grid as soon
/// as the grid is on screen, so the one you tap starts at once.
///
/// This is what TikTok does on a profile. Your videos, like everyone's,
/// play from the internet; they feel instant because the start of each was
/// already fetched before you tapped. Here the grid used to fetch nothing
/// until the tap, so every video on a profile started from a cold network.
///
/// Only the tab on screen asks — a tab's grid is only built while it is
/// shown — and each new ask replaces the last, so moving to another tab
/// moves the fetching with you.
class PreloadVideoStarts extends StatefulWidget {
  final List<ChallengeModel> videos;
  final Widget child;

  /// The first two rows.
  static const int count = 6;

  const PreloadVideoStarts({
    super.key,
    required this.videos,
    required this.child,
  });

  @override
  State<PreloadVideoStarts> createState() => _PreloadVideoStartsState();
}

class _PreloadVideoStartsState extends State<PreloadVideoStarts> {
  String _asked = '';

  @override
  void initState() {
    super.initState();
    _preload();
  }

  @override
  void didUpdateWidget(PreloadVideoStarts old) {
    super.didUpdateWidget(old);
    _preload();
  }

  void _preload() {
    final urls = [
      for (final v in widget.videos.take(PreloadVideoStarts.count))
        SmartReelsFeed.playbackUrlFor(v),
    ].where((u) => u.isNotEmpty).toList();
    // The same list again is not asked for again: asking restarts
    // downloads, and a grid rebuilds far more often than its videos change.
    final key = urls.join('|');
    if (urls.isEmpty || key == _asked) return;
    _asked = key;
    VideoCacheService.instance.warm(urls);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Room at the bottom for the tab bar.
const EdgeInsets videoGridPadding = EdgeInsets.fromLTRB(12, 4, 12, 96);

/// Open [videos] full screen at [index], and scroll through exactly those,
/// in that order — nothing from the recommendations mixed in.
///
/// This is what a tap on any profile grid does. It used to open the tapped
/// video with the explore feed underneath, so the next swipe showed
/// somebody else's video instead of the next one on the profile.
void openVideoPlaylist(
  BuildContext context,
  List<ChallengeModel> videos,
  int index,
) {
  if (videos.isEmpty) return;
  final viewerId =
      Provider.of<DataProvider>(context, listen: false).user?.id ?? '';
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        body: SmartReelsFeed(
          userId: viewerId,
          kind: FeedKind.explore,
          playlist: videos,
          startIndex: index.clamp(0, videos.length - 1),
          showBack: true,
        ),
      ),
    ),
  );
}
