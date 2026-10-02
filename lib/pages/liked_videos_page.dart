import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/profile_cache.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

/// Liked videos surface — fully wired.
///
/// Cursor-paginated against `GET /api/v1/users/{id}/likes`. Loads the
/// first page on init, infinite-scrolls into subsequent pages when
/// the user is ~3 rows from the bottom. Empty state remains in place
/// for the genuine "never liked anything" case.
class LikedVideosPage extends StatefulWidget {
  /// When true, render as a tab body inside the profile page (no
  /// AppBar, no Scaffold — the parent provides chrome). When false,
  /// render with our own Scaffold + AppBar for the deep-link path.
  final bool embedded;
  const LikedVideosPage({super.key, this.embedded = false});

  @override
  State<LikedVideosPage> createState() => _LikedVideosPageState();
}

class _LikedVideosPageState extends State<LikedVideosPage>
    with PageTracker<LikedVideosPage> {
  @override
  String get pageName => 'liked_videos_page';

  final List<ChallengeModel> _items = [];
  bool _loadingFirstPage = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _nextCursor = '';
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybePrefetch);
    // Your likes as last seen, at once; the fresh first page replaces them.
    final kept = ProfileCache.instance.liked(_userId ?? '');
    if (kept != null) {
      _items.addAll(kept);
      _loadingFirstPage = false;
    }
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String? get _userId =>
      Provider.of<DataProvider>(context, listen: false).user?.id;

  Future<void> _loadFirstPage() async {
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      setState(() => _loadingFirstPage = false);
      return;
    }
    final res = await ApiService.getLikedChallenges(userId: uid, limit: 24);
    ProfileCache.instance.keepLiked(uid, _videos(res));
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll(ProfileCache.instance.liked(uid) ?? _videos(res));
      _hasMore = res['hasMore'] == true;
      _nextCursor = (res['nextCursor'] as String?) ?? '';
      _loadingFirstPage = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final uid = _userId;
    if (uid == null) return;
    setState(() => _loadingMore = true);
    final res = await ApiService.getLikedChallenges(
      userId: uid,
      limit: 24,
      beforeCursor: _nextCursor,
    );
    if (!mounted) return;
    setState(() {
      _items.addAll(_videos(res));
      _hasMore = res['hasMore'] == true;
      _nextCursor = (res['nextCursor'] as String?) ?? '';
      _loadingMore = false;
    });
  }

  void _maybePrefetch() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >
        _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  /// The page's videos, whole — the server sends the same record every
  /// feed does, so they play like any other reel.
  static List<ChallengeModel> _videos(Map<String, dynamic> res) => [
        for (final m in (res['items'] as List?) ?? const [])
          if (m is Map<String, dynamic>) ChallengeModel.fromJson(m),
      ];

  /// Plays your liked videos from the one tapped, in the order you liked
  /// them. It used to open a bare player on that one video alone.
  void _openItem(int index) {
    openVideoPlaylist(context, List.of(_items), index);
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody(context);
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Liked')),
      body: body,
    );
  }

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loadingFirstPage) return const VideoGridPlaceholder();
    if (_items.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.space24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.favorite_outline,
                        size: 72, color: cs.onSurfaceVariant),
                    const SizedBox(height: AppTheme.space16),
                    Text(
                      'No liked videos yet',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: AppTheme.space8),
                    Text(
                      'Tap the heart on any reel and it will show up here.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return PreloadVideoStarts(
      videos: _items,
      child: GridView.builder(
        controller: _scroll,
        padding: videoGridPadding,
        gridDelegate: videoGridDelegate,
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= _items.length) {
            // Tail spinner slot — only painted when there's more to load.
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return VideoGridTile(
            key: ValueKey('liked_tile_${_items[i].id}'),
            video: _items[i],
            mark: Icons.favorite_rounded,
            markColor: const Color(0xFFFF3B5C),
            onTap: () => _openItem(i),
          );
        },
      ),
    );
  }
}
