import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/video_grid_tile.dart';

/// Watch history: the videos you watched, newest first, as a grid of videos
/// like Search and the profile.
///
/// It used to be a list of titles, and a tap opened a bare player on that
/// one video. Now a tap plays your history, from the one tapped, one after
/// another — the next swipe is the next video you watched, never a
/// recommendation.
///
/// The server sends each as the same full record every feed sends (counts,
/// encoded versions, a battle's answer), so it plays like any other video.
class WatchHistoryPage extends StatefulWidget {
  const WatchHistoryPage({super.key});

  @override
  State<WatchHistoryPage> createState() => _WatchHistoryPageState();
}

class _WatchHistoryPageState extends State<WatchHistoryPage>
    with PageTracker<WatchHistoryPage> {
  @override
  String get pageName => 'watch_history_page';

  final List<ChallengeModel> _videos = [];

  /// When each was watched, by video id.
  final Map<String, DateTime> _watchedAt = {};
  bool _loadingFirstPage = true;
  bool _failed = false;
  bool _loadingMore = false;
  bool _clearing = false;
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

  /// The videos in a page from the server, and when each was watched.
  List<ChallengeModel> _take(Map<String, dynamic> res) {
    final out = <ChallengeModel>[];
    for (final it in (res['items'] as List?) ?? const []) {
      if (it is! Map<String, dynamic>) continue;
      final c = it['challenge'];
      if (c is! Map<String, dynamic>) continue;
      final video = ChallengeModel.fromJson(c);
      if (video.id.isEmpty || _watchedAt.containsKey(video.id)) continue;
      final at = DateTime.tryParse('${it['watchedAt'] ?? ''}');
      if (at != null) _watchedAt[video.id] = at.toLocal();
      out.add(video);
    }
    return out;
  }

  Future<void> _loadFirstPage() async {
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      setState(() => _loadingFirstPage = false);
      return;
    }
    setState(() => _failed = false);
    final res = await ApiService.getWatchHistory(userId: uid, limit: 30);
    if (!mounted) return;
    setState(() {
      _watchedAt.clear();
      _videos
        ..clear()
        ..addAll(_take(res));
      _hasMore = res['hasMore'] == true;
      _nextCursor = (res['nextCursor'] as String?) ?? '';
      _failed = res['_ok'] == false && _videos.isEmpty;
      _loadingFirstPage = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final uid = _userId;
    if (uid == null) return;
    setState(() => _loadingMore = true);
    final res = await ApiService.getWatchHistory(
      userId: uid,
      limit: 30,
      beforeCursor: _nextCursor,
    );
    if (!mounted) return;
    setState(() {
      _videos.addAll(_take(res));
      _hasMore = res['hasMore'] == true;
      _nextCursor = (res['nextCursor'] as String?) ?? '';
      _loadingMore = false;
    });
  }

  void _maybePrefetch() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  Future<void> _clearAll() async {
    final uid = _userId;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          "Every video you've watched comes off this list. "
          "This can't be undone.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('history_clear_confirm'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    final ok = await ApiService.clearWatchHistory(uid);
    if (!mounted) return;
    setState(() {
      _clearing = false;
      if (ok) {
        _videos.clear();
        _watchedAt.clear();
        _hasMore = false;
        _nextCursor = '';
      }
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't clear it. Try again."),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// "now", "5m", "3h", "2d", "4w".
  static String ago(DateTime at, {DateTime? now}) {
    final d = (now ?? DateTime.now()).difference(at);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${d.inDays ~/ 7}w ago';
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loadingFirstPage) {
      body = const VideoGridPlaceholder();
    } else if (_videos.isEmpty) {
      body = RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: ListView(
          children: [
            const SizedBox(height: 80),
            ArenaEmptyState(
              icon: _failed ? Icons.cloud_off_rounded : Icons.history_rounded,
              title: _failed ? "Couldn't load your history" : 'Nothing here yet',
              subtitle: _failed
                  ? 'Pull down to try again.'
                  : 'Videos you watch will show up here.',
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: PreloadVideoStarts(
          videos: _videos,
          child: GridView.builder(
            controller: _scroll,
            padding: videoGridPadding,
            gridDelegate: videoGridDelegate,
            itemCount: _videos.length,
            itemBuilder: (_, i) {
              final v = _videos[i];
              final at = _watchedAt[v.id];
              return VideoGridTile(
                key: ValueKey('history_tile_${v.id}'),
                video: v,
                trailing: at == null ? null : ago(at),
                onTap: () => openVideoPlaylist(context, List.of(_videos), i),
              );
            },
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch history'),
        actions: [
          if (_clearing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_videos.isNotEmpty)
            TextButton(
              key: const ValueKey('history_clear'),
              onPressed: _clearAll,
              child: const Text('Clear all'),
            ),
        ],
      ),
      body: body,
    );
  }
}
