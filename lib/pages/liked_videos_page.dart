import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/pages/video_player_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/shimmer_loading.dart';

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

  final List<Map<String, dynamic>> _items = [];
  bool _loadingFirstPage = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String _nextCursor = '';
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybePrefetch);
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
    if (!mounted) return;
    setState(() {
      _items
        ..clear()
        ..addAll((res['items'] as List?)?.cast<Map<String, dynamic>>() ??
            const []);
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
      _items.addAll((res['items'] as List?)?.cast<Map<String, dynamic>>() ??
          const []);
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

  void _openItem(Map<String, dynamic> item) {
    final videoUrl = (item['videoUrl'] as String?) ?? '';
    final title = '${item['prefix'] ?? ''} ${item['subject'] ?? ''}'.trim();
    if (videoUrl.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(videoUrl: videoUrl, title: title),
      ),
    );
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
    if (_loadingFirstPage) {
      return const CustomScrollView(slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ShimmerLoading(child: GridSkeleton()),
        ),
      ]);
    }
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

    return GridView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 80),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 9 / 16,
      ),
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
        final item = _items[i];
        return _LikedTile(item: item, onTap: () => _openItem(item));
      },
    );
  }
}

class _LikedTile extends StatelessWidget {
  final Map<String, dynamic> item;
  final VoidCallback onTap;
  const _LikedTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final thumb = (item['thumbnailUrl'] as String?) ?? '';
    final views = item['views'] is int ? item['views'] as int : 0;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (thumb.isNotEmpty)
            Image.network(
              thumb,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: cs.surfaceContainerHighest,
                child: Icon(Icons.videocam_outlined,
                    color: cs.onSurfaceVariant, size: 28),
              ),
            )
          else
            Container(
              color: cs.surfaceContainerHighest,
              child: Icon(Icons.videocam_outlined,
                  color: cs.onSurfaceVariant, size: 28),
            ),
          const Positioned(
            top: 4,
            right: 4,
            child: Icon(Icons.favorite, color: Colors.red, size: 18),
          ),
          if (views > 0)
            Positioned(
              bottom: 4,
              left: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.play_arrow,
                        color: Colors.white, size: 12),
                    const SizedBox(width: 2),
                    Text(
                      _compact(views),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _compact(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}K';
    return '${(n / 1000000).toStringAsFixed(n < 10000000 ? 1 : 0)}M';
  }
}
