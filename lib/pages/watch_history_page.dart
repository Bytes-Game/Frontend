import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/pages/video_player_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';

/// Watch history surface — fully wired.
///
/// Cursor-paginated against `GET /api/v1/users/{id}/history`. Each
/// row shows the challenge thumbnail + title + relative timestamp of
/// when the user watched it. The trailing action clears ALL history;
/// per-row delete is left for a follow-up because the row-level
/// DELETE endpoint isn't built yet (the wholesale DELETE shares the
/// same handler so it's a one-line addition when we need it).
class WatchHistoryPage extends StatefulWidget {
  const WatchHistoryPage({super.key});

  @override
  State<WatchHistoryPage> createState() => _WatchHistoryPageState();
}

class _WatchHistoryPageState extends State<WatchHistoryPage>
    with PageTracker<WatchHistoryPage> {
  @override
  String get pageName => 'watch_history_page';

  final List<Map<String, dynamic>> _items = [];
  bool _loadingFirstPage = true;
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

  Future<void> _loadFirstPage() async {
    final uid = _userId;
    if (uid == null || uid.isEmpty) {
      setState(() => _loadingFirstPage = false);
      return;
    }
    final res = await ApiService.getWatchHistory(userId: uid, limit: 30);
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
    final res = await ApiService.getWatchHistory(
      userId: uid,
      limit: 30,
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

  Future<void> _clearAll() async {
    final uid = _userId;
    if (uid == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'This permanently removes every watch event you\'ve generated. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
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
        _items.clear();
        _hasMore = false;
        _nextCursor = '';
      }
    });
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not clear. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openItem(Map<String, dynamic> challenge) {
    final videoUrl = (challenge['videoUrl'] as String?) ?? '';
    final title =
        '${challenge['prefix'] ?? ''} ${challenge['subject'] ?? ''}'.trim();
    if (videoUrl.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(videoUrl: videoUrl, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch History'),
        actions: [
          if (_clearing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_items.isNotEmpty)
            IconButton(
              tooltip: 'Clear history',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loadingFirstPage
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _empty(cs)
              : ListView.builder(
                  controller: _scroll,
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= _items.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    return _HistoryRow(
                      entry: _items[i],
                      onTap: () => _openItem(
                          (_items[i]['challenge'] as Map<String, dynamic>?) ??
                              const {}),
                    );
                  },
                ),
    );
  }

  Widget _empty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded,
                size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: AppTheme.space16),
            Text(
              'No watch history yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: AppTheme.space8),
            Text(
              'Reels you watch will show up here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  final VoidCallback onTap;
  const _HistoryRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final challenge = (entry['challenge'] as Map<String, dynamic>?) ?? const {};
    final thumb = (challenge['thumbnailUrl'] as String?) ?? '';
    final title =
        '${challenge['prefix'] ?? ''} ${challenge['subject'] ?? ''}'.trim();
    final creator = (challenge['creatorUsername'] as String?) ?? '';
    final watchedAt = (entry['watchedAt'] as String?) ?? '';
    final completed = entry['completed'] == true;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 72,
          height: 96,
          child: thumb.isNotEmpty
              ? Image.network(
                  thumb,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: cs.surfaceContainerHighest,
                    child: const Icon(Icons.videocam_outlined),
                  ),
                )
              : Container(
                  color: cs.surfaceContainerHighest,
                  child: const Icon(Icons.videocam_outlined),
                ),
        ),
      ),
      title: Text(
        title.isEmpty ? '(untitled)' : title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (creator.isNotEmpty) Text('@$creator'),
            Row(
              children: [
                Icon(
                  completed
                      ? Icons.check_circle_outline
                      : Icons.watch_later_outlined,
                  size: 14,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '${completed ? "Finished" : "Watched"} · ${_relative(watchedAt)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Cheap relative-time string for a backend ISO timestamp. Good
  /// enough for a history list ("2h ago", "3d ago"). Avoids pulling
  /// in intl just for this one surface.
  static String _relative(String iso) {
    if (iso.isEmpty) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }
}
