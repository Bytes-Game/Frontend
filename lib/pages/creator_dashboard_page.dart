import 'package:flutter/material.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// CreatorDashboardPage — surfaces the same signals the ranker computes
/// for scoring, repackaged for the creator. Anonymized benchmarks against
/// other creators in the same category; plain-English recommendations.
///
/// Two depths:
///   - Overview: best/worst content, completion rank, category benchmarks,
///     1-3 high-level recommendations.
///   - Per-content: tap a content card to see watch histogram, drop-off
///     seconds, hook strength, content-specific recommendations.
///
/// Data is fetched fresh on every open (no client-side cache) — a small
/// dashboard isn't worth caching invalidation bugs.
class CreatorDashboardPage extends StatefulWidget {
  final String creatorId;
  final String creatorUsername;

  const CreatorDashboardPage({
    super.key,
    required this.creatorId,
    required this.creatorUsername,
  });

  @override
  State<CreatorDashboardPage> createState() => _CreatorDashboardPageState();
}

class _CreatorDashboardPageState extends State<CreatorDashboardPage>
    with PageTracker<CreatorDashboardPage> {
  Map<String, dynamic>? _overview;
  bool _loading = true;
  String? _error;
  int _windowDays = 30;

  @override
  String get pageName => 'creator_dashboard';

  @override
  Map<String, dynamic> get pageParams => {
        'creatorId': widget.creatorId,
        'windowDays': _windowDays,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final data = await ApiService.getCreatorInsightsOverview(
      widget.creatorId,
      windowDays: _windowDays,
    );
    if (!mounted) return;
    if (data == null) {
      setState(() {
        _loading = false;
        _error = 'Could not load insights. Try again in a moment.';
      });
      return;
    }
    setState(() {
      _overview = data;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Insights — @${widget.creatorUsername}'),
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.calendar_month),
            onSelected: (days) {
              setState(() => _windowDays = days);
              _load();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Last 7 days')),
              PopupMenuItem(value: 30, child: Text('Last 30 days')),
              PopupMenuItem(value: 90, child: Text('Last 90 days')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _overview == null
                  ? _ErrorState(message: 'No data', onRetry: _load)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _OverviewBody(overview: _overview!, creatorId: widget.creatorId),
                    ),
    );
  }
}

// ─── Body ────────────────────────────────────────────────────────────────

class _OverviewBody extends StatelessWidget {
  final Map<String, dynamic> overview;
  final String creatorId;
  const _OverviewBody({required this.overview, required this.creatorId});

  @override
  Widget build(BuildContext context) {
    final totalPosts = (overview['totalPosts'] ?? 0) as int;
    if (totalPosts == 0) {
      return ListView(
        children: const [
          SizedBox(height: 200),
          Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'You haven\'t posted in this window.\nWhen you do, your stats land here.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ),
          ),
        ],
      );
    }

    final avgCompletion = (overview['avgCompletion'] ?? 0.0) as num;
    final completionRank = (overview['completionRank'] ?? '') as String;
    final totalViews = overview['totalViews'] ?? 0;
    final totalLikes = overview['totalLikes'] ?? 0;
    final recommendations = (overview['recommendations'] as List?)?.cast<String>() ?? [];
    final best = (overview['bestContent'] as List?) ?? [];
    final worst = (overview['worstContent'] as List?) ?? [];
    final categoryStats =
        (overview['categoryStats'] as Map?)?.cast<String, dynamic>() ?? {};

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _HeadlineCard(
          totalPosts: totalPosts,
          totalViews: totalViews as int,
          totalLikes: totalLikes as int,
          avgCompletion: avgCompletion.toDouble(),
          completionRank: completionRank,
        ),
        const SizedBox(height: 24),
        if (recommendations.isNotEmpty) ...[
          const Text('Recommendations',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...recommendations.map((r) => _RecommendationTile(text: r)),
          const SizedBox(height: 24),
        ],
        if (categoryStats.isNotEmpty) ...[
          const Text('By category',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...categoryStats.entries.map((e) => _CategoryRow(
                category: e.key,
                stat: (e.value as Map).cast<String, dynamic>(),
              )),
          const SizedBox(height: 24),
        ],
        if (best.isNotEmpty) ...[
          const Text('Your best',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...best.map((c) => _ContentCard(
                content: (c as Map).cast<String, dynamic>(),
                creatorId: creatorId,
                accentColor: Colors.green,
              )),
          const SizedBox(height: 24),
        ],
        if (worst.isNotEmpty) ...[
          const Text('Underperforming',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...worst.map((c) => _ContentCard(
                content: (c as Map).cast<String, dynamic>(),
                creatorId: creatorId,
                accentColor: Colors.orange,
              )),
        ],
      ],
    );
  }
}

class _HeadlineCard extends StatelessWidget {
  final int totalPosts, totalViews, totalLikes;
  final double avgCompletion;
  final String completionRank;
  const _HeadlineCard({
    required this.totalPosts,
    required this.totalViews,
    required this.totalLikes,
    required this.avgCompletion,
    required this.completionRank,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Stat(label: 'Posts', value: '$totalPosts'),
                _Stat(label: 'Views', value: _shortNum(totalViews)),
                _Stat(label: 'Likes', value: _shortNum(totalLikes)),
                _Stat(label: 'Avg completion', value: '${(avgCompletion * 100).toStringAsFixed(0)}%'),
              ],
            ),
            if (completionRank.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(completionRank,
                  style: const TextStyle(fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label, value;
  const _Stat({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7))),
      ],
    );
  }
}

class _RecommendationTile extends StatelessWidget {
  final String text;
  const _RecommendationTile({required this.text});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.primary.withValues(alpha: 0.12),
      child: ListTile(
        leading: Icon(Icons.lightbulb_outline, color: cs.primary),
        title: Text(text),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  final String category;
  final Map<String, dynamic> stat;
  const _CategoryRow({required this.category, required this.stat});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final yours = ((stat['yourCompletion'] ?? 0.0) as num).toDouble();
    final p50 = ((stat['categoryP50'] ?? 0.0) as num).toDouble();
    final p90 = ((stat['categoryP90'] ?? 0.0) as num).toDouble();
    final pct = (stat['yourPercentile'] ?? 0) as int;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(category,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text('You: ${(yours * 100).toStringAsFixed(0)}%   '
                'Median: ${(p50 * 100).toStringAsFixed(0)}%   '
                'Top 10%: ${(p90 * 100).toStringAsFixed(0)}%'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: pct / 100.0,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(_pctColor(pct)),
            ),
            const SizedBox(height: 4),
            Text('You\'re in the ${pct}th percentile in this category',
                style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.7), fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Color _pctColor(int pct) {
    if (pct >= 75) return Colors.green;
    if (pct >= 50) return Colors.lightGreen;
    if (pct >= 25) return Colors.orange;
    return Colors.red;
  }
}

class _ContentCard extends StatelessWidget {
  final Map<String, dynamic> content;
  final String creatorId;
  final Color accentColor;
  const _ContentCard({
    required this.content,
    required this.creatorId,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final title = (content['title'] ?? 'Untitled') as String;
    final completion = ((content['completion'] ?? 0.0) as num).toDouble();
    final views = content['views'] ?? 0;
    final likes = content['likes'] ?? 0;
    final category = (content['category'] ?? 'other') as String;
    final contentId = (content['contentId'] ?? '') as String;
    final contentType = (content['contentType'] ?? '') as String;

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: accentColor.withValues(alpha: 0.15),
          foregroundColor: accentColor,
          child: Text('${(completion * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('$category • $views views • $likes likes'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          EventTracker.instance.trackTap(
            pageName: 'creator_dashboard',
            target: 'content_card',
            params: {'contentId': contentId, 'contentType': contentType},
          );
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _PerContentInsightsPage(
                creatorId: creatorId,
                contentType: contentType,
                contentId: contentId,
                title: title,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Per-content deep-dive ───────────────────────────────────────────────

class _PerContentInsightsPage extends StatefulWidget {
  final String creatorId, contentType, contentId, title;
  const _PerContentInsightsPage({
    required this.creatorId,
    required this.contentType,
    required this.contentId,
    required this.title,
  });

  @override
  State<_PerContentInsightsPage> createState() =>
      _PerContentInsightsPageState();
}

class _PerContentInsightsPageState extends State<_PerContentInsightsPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final d = await ApiService.getCreatorInsightsPerContent(
      creatorId: widget.creatorId,
      contentType: widget.contentType,
      contentId: widget.contentId,
    );
    if (!mounted) return;
    if (d == null) {
      setState(() {
        _loading = false;
        _error = 'Could not load.';
      });
      return;
    }
    setState(() {
      _data = d;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _PerContentBody(data: _data!),
    );
  }
}

class _PerContentBody extends StatelessWidget {
  final Map<String, dynamic> data;
  const _PerContentBody({required this.data});

  @override
  Widget build(BuildContext context) {
    final completion = ((data['completion'] ?? 0.0) as num).toDouble();
    final skipRate = ((data['skipRate'] ?? 0.0) as num).toDouble();
    final hookStrength = (data['hookStrength'] ?? 'unknown') as String;
    final earlySkipPct = ((data['earlySkipPct'] ?? 0.0) as num).toDouble();
    final views = data['views'] ?? 0;
    final likes = data['likes'] ?? 0;
    final histogram =
        (data['watchHistogram'] as Map?)?.cast<String, dynamic>() ?? {};
    final dropOff = (data['dropOffSeconds'] as Map?)?.cast<String, dynamic>() ?? {};
    final recs = (data['recommendations'] as List?)?.cast<String>() ?? [];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Stat(label: 'Views', value: _shortNum(views as int)),
                _Stat(label: 'Likes', value: _shortNum(likes as int)),
                _Stat(label: 'Completion', value: '${(completion * 100).toStringAsFixed(0)}%'),
                _Stat(label: 'Skip rate', value: '${(skipRate * 100).toStringAsFixed(0)}%'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: _hookColor(hookStrength).withValues(alpha: 0.08),
          child: ListTile(
            leading: Icon(Icons.flash_on, color: _hookColor(hookStrength)),
            title: Text('Hook: $hookStrength',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(
                '${(earlySkipPct * 100).toStringAsFixed(0)}% of skips happen in the first 25%'),
          ),
        ),
        const SizedBox(height: 24),
        if (histogram.isNotEmpty) ...[
          const Text('Watch distribution',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...['0-25%', '25-50%', '50-75%', '75-100%', '100%+'].map((bucket) {
            final n = (histogram[bucket] ?? 0) as int;
            return _HistogramBar(label: bucket, count: n, max: _maxIntInMap(histogram));
          }),
          const SizedBox(height: 24),
        ],
        if (dropOff.isNotEmpty) ...[
          const Text('Drop-off seconds (when viewers skip)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _DropOffChart(dropOff: dropOff),
          const SizedBox(height: 24),
        ],
        if (recs.isNotEmpty) ...[
          const Text('What to try',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...recs.map((r) => _RecommendationTile(text: r)),
        ],
      ],
    );
  }

  Color _hookColor(String s) {
    switch (s) {
      case 'strong':
        return Colors.green;
      case 'ok':
        return Colors.orange;
      case 'weak':
        return Colors.red;
    }
    return Colors.grey;
  }

  int _maxIntInMap(Map<String, dynamic> m) {
    var max = 1;
    for (final v in m.values) {
      if (v is int && v > max) max = v;
      if (v is num && v.toInt() > max) max = v.toInt();
    }
    return max;
  }
}

class _HistogramBar extends StatelessWidget {
  final String label;
  final int count, max;
  const _HistogramBar({required this.label, required this.count, required this.max});

  @override
  Widget build(BuildContext context) {
    final ratio = max > 0 ? count / max : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 70, child: Text(label)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 18,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(Colors.indigo.shade400),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(width: 50, child: Text('$count', textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _DropOffChart extends StatelessWidget {
  final Map<String, dynamic> dropOff;
  const _DropOffChart({required this.dropOff});
  @override
  Widget build(BuildContext context) {
    // Bucket the seconds by 5-second chunks for readability.
    final buckets = <int, int>{};
    int maxCount = 1;
    dropOff.forEach((k, v) {
      final sec = int.tryParse(k) ?? 0;
      final cnt = (v is int) ? v : (v as num).toInt();
      final b = (sec ~/ 5) * 5;
      buckets[b] = (buckets[b] ?? 0) + cnt;
      if ((buckets[b] ?? 0) > maxCount) maxCount = buckets[b]!;
    });
    final keys = buckets.keys.toList()..sort();
    return Column(
      children: keys.map((k) {
        return _HistogramBar(
          label: '$k-${k + 5}s',
          count: buckets[k] ?? 0,
          max: maxCount,
        );
      }).toList(),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

String _shortNum(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}
