import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/widgets/suggest_field.dart';
import 'package:myapp/widgets/tags_input.dart';

/// Final step of the create-challenge flow.
///
/// Form layout (top-to-bottom):
///   1. **Prefix** field — autocomplete against the curated template
///      list (`/suggest/challenge-prefix`). User can type freely; the
///      dropdown is a shortcut, never a constraint.
///   2. **Subject** field — autocomplete against the Meilisearch
///      subject index (`/suggest/challenge-subject`) which blends
///      typo-tolerant prefix match, global popularity, and per-user
///      category affinity from the recommender.
///   3. **Visibility** — public/friends segment.
///   4. **Category** — dropdown.
///   5. **Tags** — multi-select chip field with custom-add. Replaces
///      the previous closed "emotion" picker; same autocomplete
///      backend feeds it so users can pull from the global vocabulary
///      OR type whatever they want.
///
/// What's gone:
///   * **Energy picker** — the server now derives energy from
///     category + subject + caption (see backend energy_classifier.go).
///   * **Emotion picker** — replaced by free-form Tags.
///
/// Lifecycle is unchanged: tap Post → dispatch to UploadJobManager →
/// pop immediately. The upload runs in the background and the global
/// UploadStatusOverlay shows progress.
class ChallengeMetadataPage extends StatefulWidget {
  final String processedSourcePath;
  const ChallengeMetadataPage({
    super.key,
    required this.processedSourcePath,
  });

  @override
  State<ChallengeMetadataPage> createState() => _ChallengeMetadataPageState();
}

class _ChallengeMetadataPageState extends State<ChallengeMetadataPage>
    with PageTracker<ChallengeMetadataPage> {
  @override
  String get pageName => 'challenge_metadata_page';

  // ── Form state ─────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _prefixCtl = TextEditingController(text: 'Who is better at');
  final _subjectCtl = TextEditingController();

  String _visibility = 'arena';
  String _category = 'other';
  final List<String> _tags = [];
  bool _busy = false;

  // EARLY UPLOAD: the video is final the moment this page opens (trim
  // just finished), so processing + upload start NOW and run while the
  // user types. By Post time the bytes are usually already in R2 and
  // posting is one API call — instant. If the user backs out, the
  // prepared job is abandoned.
  UploadJob? _preparedJob;
  bool _submitted = false;

  // ── Suggestion caches ──────────────────────────────────────────────
  // The SuggestField widget pulls these directly from props on every
  // build — when the async fetch lands and we setState, the overlay
  // repaints automatically. This is the fix for "erase + retype
  // doesn't show suggestions": the old Material Autocomplete cached
  // its option list against the text value and never noticed when our
  // backend response arrived a few hundred ms later.
  List<String> _prefixSuggestions = const [];
  List<Map<String, dynamic>> _subjectSuggestions = const [];
  List<String> _tagSuggestions = const [];

  // Last-query guards. The autocomplete widget can fire onQuery
  // multiple times in quick succession (focus warmup + typing); if
  // a slow response for "dan" lands after the user has already typed
  // "danc", we drop it on the floor so the dropdown doesn't flicker.
  String _prefixLastQuery = '';
  String _subjectLastQuery = '';
  String _tagLastQuery = '';

  // Mirrors ContentCategories in devb/models.go.
  static const _categories = [
    'comedy', 'motivation', 'sports', 'dance', 'music', 'gaming',
    'art', 'education', 'story', 'fashion', 'food', 'horror',
    'emotional', 'lifestyle', 'tech', 'prank', 'news', 'other',
  ];

  // Local fallback when the suggest endpoint is unreachable. Short
  // intentionally — we don't want this to crowd out real network
  // results on a good connection, just bridge a temporary outage.
  static const _localPrefixFallback = [
    'Who is better at',
    'Who is the best at',
    'Who has the cleanest',
    'Who can take on',
    'Who can pull off',
    'Who would win at',
  ];

  @override
  void initState() {
    super.initState();
    // Warm both fields' suggestions on entry so the dropdowns
    // populate the moment the user focuses either one.
    _refreshPrefixSuggestions('');
    _refreshSubjectSuggestions('');
    // EARLY UPLOAD: the video is final the moment this page opens, so
    // processing + upload start NOW and run while the user types the
    // metadata — by Post time the bytes are usually already in R2.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final dp = Provider.of<DataProvider>(context, listen: false);
      final creatorId = dp.user?.id ?? '';
      if (creatorId.isEmpty) return;
      _preparedJob = UploadJobManager.instance.prepareChallenge(
        creatorId: creatorId,
        sourcePath: widget.processedSourcePath,
      );
      EventTracker.instance.trackUploadStep(
        uploadType: 'challenge',
        step: 'early_upload_started',
      );
    });
  }

  @override
  void dispose() {
    // Back-swipe / pop without posting → quietly drop the prepared
    // early upload. _submitted guards the intended pop after Post.
    if (!_submitted && _preparedJob != null) {
      UploadJobManager.instance.abandonPrepared(_preparedJob!);
    }
    _prefixCtl.dispose();
    _subjectCtl.dispose();
    super.dispose();
  }

  // ── Async suggestion fetches ───────────────────────────────────────

  Future<void> _refreshPrefixSuggestions(String q) async {
    _prefixLastQuery = q;
    final results = await ApiService.suggestChallengePrefix(query: q);
    if (!mounted) return;
    if (_prefixLastQuery != q) return; // stale response
    setState(() {
      _prefixSuggestions = results.isEmpty
          ? List<String>.from(_localPrefixFallback)
          : results;
    });
  }

  Future<void> _refreshSubjectSuggestions(String q) async {
    _subjectLastQuery = q;
    final userId =
        Provider.of<DataProvider>(context, listen: false).user?.id ?? '';
    final results = await ApiService.suggestChallengeSubject(
      query: q,
      userId: userId,
    );
    if (!mounted) return;
    if (_subjectLastQuery != q) return;
    setState(() => _subjectSuggestions = results);
  }

  Future<void> _refreshTagSuggestions(String q) async {
    _tagLastQuery = q;
    final userId =
        Provider.of<DataProvider>(context, listen: false).user?.id ?? '';
    // Tags share the subject corpus — anything that could be a
    // subject is also a sensible tag. Reusing the same endpoint
    // means we don't have to maintain a second curated list.
    final results = await ApiService.suggestChallengeSubject(
      query: q,
      userId: userId,
      limit: 16,
    );
    if (!mounted) return;
    if (_tagLastQuery != q) return;
    setState(() {
      _tagSuggestions = results
          .map((m) => (m['subject'] as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    });
  }

  // ── Submit ─────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;

    final dp = Provider.of<DataProvider>(context, listen: false);
    final creatorId = dp.user?.id ?? '';
    if (creatorId.isEmpty) {
      _toast('You need to be signed in to post a challenge.');
      return;
    }

    setState(() => _busy = true);

    EventTracker.instance.trackTap(
      target: 'challenge_post_submit',
      pageName: pageName,
      params: {
        'visibility': _visibility,
        'category': _category,
        'tagCount': _tags.length,
      },
    );

    final meta = ChallengeSubmissionMeta(
      prefix: _prefixCtl.text.trim(),
      subject: _subjectCtl.text.trim(),
      visibility: _visibility,
      category: _category,
      // Tags ride in on the emotionTags slot for now — the
      // backend's emotion column was never used as a hard constraint
      // and the column is JSONB so it accepts whatever strings we
      // throw at it. A follow-up will rename the column / API field
      // to "tags" cleanly; for this release we're keeping the
      // payload shape stable so older builds keep working.
      emotionTags: _tags,
    );

    // Prepared path: the upload has (usually) been running since this
    // page opened — finalize attaches the metadata. Fallback path (no
    // prepared job, e.g. creatorId raced empty at page open): classic
    // full pipeline. Both are fire-and-forget from this page's POV.
    _submitted = true;
    final prepared = _preparedJob;
    if (prepared != null) {
      // ignore: discarded_futures
      UploadJobManager.instance.finalizeChallenge(prepared, meta);
    } else {
      UploadJobManager.instance.submitChallenge(
        creatorId: creatorId,
        sourcePath: widget.processedSourcePath,
        meta: meta,
      );
    }

    Provider.of<DataProvider>(context, listen: false).bumpFeedRefresh();
    _toast('Posting in the background — you can keep browsing.');
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: const Text('Challenge details'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section('Challenge'),
              SuggestField<String>(
                controller: _prefixCtl,
                label: 'Prefix',
                hint: 'Who is better at',
                validator: _requiredText,
                suggestions: _prefixSuggestions,
                displayString: (s) => s,
                buildRow: (s) => Text(s),
                onQuery: _refreshPrefixSuggestions,
              ),
              const SizedBox(height: 12),
              SuggestField<Map<String, dynamic>>(
                controller: _subjectCtl,
                label: 'Subject',
                hint: 'pranks',
                validator: _requiredText,
                suggestions: _subjectSuggestions,
                displayString: (m) => (m['subject'] as String?) ?? '',
                buildRow: _subjectOptionTile,
                onQuery: _refreshSubjectSuggestions,
              ),
              const SizedBox(height: 6),
              _autoDetectHint(cs),

              const SizedBox(height: 24),
              _section('Visibility'),
              _segmented(
                cs: cs,
                value: _visibility,
                options: const [
                  ('arena', 'Arena (everyone)'),
                  ('friends', 'Friends only'),
                ],
                onChanged: (v) => setState(() => _visibility = v),
              ),

              const SizedBox(height: 24),
              _section('Category'),
              _categoryDropdown(cs),

              const SizedBox(height: 24),
              _section('Tags (up to 8)'),
              TagsInput(
                selectedTags: _tags,
                onChanged: (next) => setState(() {
                  _tags
                    ..clear()
                    ..addAll(next);
                }),
                onQuery: _refreshTagSuggestions,
                suggestions: _tagSuggestions,
              ),

              const SizedBox(height: 32),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _busy
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Text(
                        'Post Challenge',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── Subject suggestion row ─────────────────────────────────────────

  Widget _subjectOptionTile(Map<String, dynamic> m) {
    final cs = Theme.of(context).colorScheme;
    final s = (m['subject'] as String?) ?? '';
    final count = m['usageCount'] is int ? m['usageCount'] as int : 0;
    return Row(
      children: [
        Expanded(
          child: Text(
            s,
            style: const TextStyle(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count > 0)
          Text(
            '${_compact(count)} uses',
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
  }

  String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  Widget _autoDetectHint(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 2),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome,
            size: 14,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Energy is auto-detected from your subject + category.',
              style: TextStyle(
                fontSize: 12,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Small chrome helpers ───────────────────────────────────────────

  Widget _section(String label) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: cs.onSurface.withValues(alpha: 0.78),
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  Widget _segmented({
    required ColorScheme cs,
    required String value,
    required List<(String, String)> options,
    required ValueChanged<String> onChanged,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((opt) {
        final selected = opt.$1 == value;
        return ChoiceChip(
          label: Text(opt.$2),
          selected: selected,
          onSelected: (_) => onChanged(opt.$1),
          selectedColor: cs.primary,
          backgroundColor: cs.surfaceContainerHighest,
          labelStyle: TextStyle(
            color: selected ? cs.onPrimary : cs.onSurface,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected
                  ? Colors.transparent
                  : cs.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _categoryDropdown(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _category,
          isExpanded: true,
          dropdownColor: cs.surfaceContainerHigh,
          style: TextStyle(color: cs.onSurface),
          iconEnabledColor: cs.onSurface.withValues(alpha: 0.7),
          items: _categories
              .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c[0].toUpperCase() + c.substring(1)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) setState(() => _category = v);
          },
        ),
      ),
    );
  }

  String? _requiredText(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    return null;
  }
}
