import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import 'package:myapp/config/app_theme.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/widgets/friend_picker_sheet.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/match_warning.dart';
import 'package:myapp/widgets/suggest_field.dart';
import 'package:myapp/widgets/tags_input.dart';

/// Longest a challenge's prefix and subject may be, in characters. The
/// server holds new challenges to the same limits.
const maxPrefix = 50;
const maxSubject = 30;

/// Final step of the create-challenge flow.
///
/// At the top, a preview card: the clip playing beside the challenge's
/// headline as people will see it, built live as the fields change, and
/// tiltable in 3D. The Post button is pinned to the bottom of the screen.
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
///   4. **Category** — dropdown. Optional, and starts EMPTY. Leaving it
///      alone is a real answer: the server works the category out from
///      the video itself, and that reading outranks a creator's pick
///      anyway. What is not allowed is a pre-filled answer nobody gave —
///      see ContentCategories in config/constants.dart.
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

  /// For "Only friends": the particular friends chosen. Empty is all of
  /// them.
  List<UserModel> _friends = const [];

  /// How many days the battle runs once somebody answers. The server keeps
  /// it between 7 and 30.
  String _battleDays = '7';

  /// What the creator says the video is about. Null means they did not say.
  ///
  /// It used to start on 'other', and that made the whole field useless.
  /// The server reads 'other' as "nobody said" — so every creator who did
  /// not open the dropdown posted a video the server filed as unlabelled,
  /// while the form looked perfectly filled in. 43 of 44 videos on the
  /// platform had no creator category because of this one line.
  ///
  /// Null is now sent as an empty string, which is the truth and is exactly
  /// what the server expects for "nobody said". It then decides the category
  /// from the video itself — what is spoken in it and written on screen —
  /// and that reading outranks a creator's pick in the ranker regardless.
  /// So skipping this costs nothing; filling it in with a default nobody
  /// chose cost everything. See ContentCategories in config/constants.dart.
  String? _category;
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
        'category': _category ?? '',
        'tagCount': _tags.length,
      },
    );

    final meta = ChallengeSubmissionMeta(
      prefix: _prefixCtl.text.trim(),
      subject: _subjectCtl.text.trim(),
      visibility: _visibility,
      // Non-null by here: the form will not validate without a pick. The
      // fallback is what the server already means by "nobody said", so if
      // that guard is ever loosened this degrades instead of crashing.
      category: _category ?? '',
      // Tags now go in the field that means tags. They used to ride in on
      // emotionTags because the backend had nowhere else to put them, and
      // that quietly cost twice over: the ranker matches emotions against a
      // user's mood from a fixed list of sixteen words, so free-text tags
      // landing there matched nothing and diluted the ones that would have,
      // while the tags themselves were never read as tags at all.
      //
      // emotionTags is left empty on purpose. The server infers emotion from
      // the caption when none is sent, which is a better guess than a
      // creator's subject tags ever were.
      tags: _tags,
      emotionTags: const [],
      battleDays: int.parse(_battleDays),
      visibleTo: _visibility == 'friends'
          ? [for (final u in _friends) u.id]
          : const [],
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
        centerTitle: false,
        title: const Text('New challenge'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            // What people will see, built live as you type. Drag it to
            // tilt it.
            _posterCard(),
            const SizedBox(height: 22),

            _section('Challenge'),
            SuggestField<String>(
              controller: _prefixCtl,
              label: 'Prefix',
              hint: 'Who is better at',
              validator: (v) => _limitedText(v, maxPrefix),
              maxLength: maxPrefix,
              suggestions: _prefixSuggestions,
              displayString: (s) => s,
              buildRow: (s) => Text(s),
              onQuery: _refreshPrefixSuggestions,
            ),
            // The common openings, one tap each.
            if (_prefixSuggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              SizedBox(
                height: 34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _prefixSuggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final p = _prefixSuggestions[i];
                    final chosen = _prefixCtl.text.trim() == p;
                    return Pressable(
                      onTap: () => setState(
                        () => _prefixCtl.text = p.characters
                            .take(maxPrefix)
                            .toString(),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: chosen ? kAccent : quietFill(context),
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusFull),
                        ),
                        child: Text(
                          p,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: chosen ? Colors.white : cs.onSurface,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
            SuggestField<Map<String, dynamic>>(
              controller: _subjectCtl,
              label: 'Subject',
              hint: 'pranks',
              validator: (v) => _limitedText(v, maxSubject),
              maxLength: maxSubject,
              suggestions: _subjectSuggestions,
              displayString: (m) => (m['subject'] as String?) ?? '',
              buildRow: _subjectOptionTile,
              onQuery: _refreshSubjectSuggestions,
            ),

            _section('Who can see it'),
            _choiceRow(
              value: _visibility,
              options: const [
                ('arena', Icons.public_rounded, 'Public'),
                ('friends', Icons.group_rounded, 'Only friends'),
              ],
              onChanged: (v) => setState(() => _visibility = v),
            ),
            if (_visibility == 'friends') ...[
              const SizedBox(height: 10),
              _friendsScope(cs),
            ],

            _section('Battle length'),
            _daysRow(),
            const SizedBox(height: 8),
            Text(
              'Voting starts when someone accepts.',
              style: TextStyle(fontSize: 12.5, color: quietText(context)),
            ),

            _section('Category (optional)'),
            _categoryDropdown(cs),

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
          ],
        ),
      ),
      // Always in reach, however far down the form is scrolled — and so is
      // the warning that the video has to match what was written.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MatchWarning(text: matchWarningChallenge),
              const SizedBox(height: 8),
              SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'Post Challenge',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The challenge as people will meet it: the clip playing beside the
  /// headline, and who can see it and for how long. It changes as the
  /// fields below change, and it tilts in 3D when dragged.
  Widget _posterCard() {
    final deep = Color.lerp(kAccent, Colors.black, 0.55)!;
    final deeper = Color.lerp(kAccent, Colors.black, 0.86)!;
    return TiltCard(
      radius: 24,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [deep, deeper],
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 92,
                height: 164,
                child: _ClipPreview(path: widget.processedSourcePath),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([_prefixCtl, _subjectCtl]),
                builder: (context, _) {
                  final prefix = _prefixCtl.text.trim();
                  final subject = _subjectCtl.text.trim();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      const Text(
                        'YOUR CHALLENGE',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        prefix.isEmpty ? 'Who is better at' : prefix,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: Text(
                          subject.isEmpty ? 'your subject?' : '$subject?',
                          key: ValueKey(subject.isEmpty),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: subject.isEmpty
                                ? Colors.white38
                                : Colors.white,
                            fontSize: 24,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _posterChip(
                            _visibility == 'friends'
                                ? Icons.group_rounded
                                : Icons.public_rounded,
                            _visibility != 'friends'
                                ? 'Public'
                                : _friends.isEmpty
                                ? 'Only friends'
                                : '${_friends.length} '
                                      '${_friends.length == 1 ? 'friend' : 'friends'}',
                          ),
                          _posterChip(
                            Icons.timer_outlined,
                            '$_battleDays-day battle',
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _posterChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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

  // ── Small chrome helpers ───────────────────────────────────────────

  /// A small grey heading over each group, the way iPhone Settings does it.
  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: quietText(context),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// Two or three choices side by side, the chosen one filled in.
  /// Under "Only friends": all of them, or some chosen by name.
  Widget _friendsScope(ColorScheme cs) {
    Future<void> choose() async {
      final uid =
          Provider.of<DataProvider>(context, listen: false).user?.id ?? '';
      if (uid.isEmpty) return;
      final picked = await pickFriends(context, userId: uid, chosen: _friends);
      if (picked == null || !mounted) return;
      setState(() => _friends = picked);
    }

    final some = _friends.isNotEmpty;
    Widget option(String key, String label, IconData icon, bool on,
        VoidCallback tap) {
      return Expanded(
        child: Pressable(
          onTap: tap,
          child: AnimatedContainer(
            key: ValueKey(key),
            duration: const Duration(milliseconds: 160),
            height: 40,
            decoration: BoxDecoration(
              color: on ? kAccent.withValues(alpha: 0.14) : null,
              border: Border.all(
                color: on ? kAccent : quietText(context).withValues(alpha: 0.3),
              ),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: on ? kAccent : cs.onSurface),
                const SizedBox(width: 6),
                // Large text on a narrow phone: cut short, never overflow.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: on ? kAccent : cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            option('friends_all', 'All friends', Icons.groups_rounded, !some,
                () => setState(() => _friends = const [])),
            const SizedBox(width: 8),
            option('friends_choose', 'Choose friends',
                Icons.person_search_rounded, some, choose),
          ],
        ),
        if (some) ...[
          const SizedBox(height: 10),
          Pressable(
            onTap: choose,
            child: Row(
              children: [
                SizedBox(
                  width: 24.0 + 16 * (_friends.take(4).length - 1),
                  height: 26,
                  child: Stack(
                    children: [
                      for (var i = 0; i < _friends.take(4).length; i++)
                        Positioned(
                          left: 16.0 * i,
                          child: ArenaAvatar(
                            name: _friends[i].username,
                            size: 26,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _friends.length == 1
                        ? 'Only @${_friends.first.username}'
                        : '@${_friends.first.username} and '
                              '${_friends.length - 1} more',
                    key: const ValueKey('friends_summary'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  'Edit',
                  style: TextStyle(color: kAccent, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          some
              ? 'Only these friends see it, and each gets a notification.'
              : 'Everyone who follows you sees it and gets a notification.',
          style: TextStyle(fontSize: 12.5, color: quietText(context)),
        ),
      ],
    );
  }

  Widget _choiceRow({
    required String value,
    required List<(String, IconData, String)> options,
    required ValueChanged<String> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Pressable(
              onTap: () => onChanged(options[i].$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                height: 46,
                decoration: BoxDecoration(
                  color: options[i].$1 == value ? kAccent : quietFill(context),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      options[i].$2,
                      size: 18,
                      color: options[i].$1 == value
                          ? Colors.white
                          : cs.onSurface,
                    ),
                    const SizedBox(width: 6),
                    // With large text on a narrow phone the label can be
                    // wider than its half of the row: cut it short rather
                    // than run past the edge.
                    Flexible(
                      child: Text(
                        options[i].$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: options[i].$1 == value
                              ? Colors.white
                              : cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// How long the battle runs, as three tiles with the number large. The
  /// chosen one lifts off the page.
  Widget _daysRow() {
    final cs = Theme.of(context).colorScheme;
    const options = ['7', '14', '30'];
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: Pressable(
              onTap: () => setState(() => _battleDays = options[i]),
              // Only the lift springs past its mark and back. The colour
              // and shadow must not: a shadow pushed past "none" has a
              // blur below zero, which Flutter refuses to draw.
              child: AnimatedSlide(
                offset: Offset(0, _battleDays == options[i] ? -0.05 : 0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  height: 78,
                  decoration: BoxDecoration(
                    color: _battleDays == options[i]
                        ? kAccent
                        : quietFill(context),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    boxShadow: _battleDays == options[i]
                        ? [
                            BoxShadow(
                              color: kAccent.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 8),
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        options[i],
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          height: 1,
                          color: _battleDays == options[i]
                              ? Colors.white
                              : cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'days',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _battleDays == options[i]
                              ? Colors.white70
                              : quietText(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// The Category picker.
  ///
  /// Optional, and starts on nothing. Both of those matter, and for the same
  /// reason: the server treats 'other' as no answer at all, so a picker that
  /// starts on "Other" — or that offers it — produces videos nobody has
  /// described while looking like it did its job. That is how 43 of 44
  /// videos ended up with no creator category.
  ///
  /// Nothing is required here because nothing needs to be. The server reads
  /// the video — what is said in it and written on screen — and that reading
  /// beats a creator's pick in the ranker anyway. A pick is useful extra
  /// evidence, not a gap that has to be filled.
  Widget _categoryDropdown(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: quietFill(context),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _category,
          isExpanded: true,
          dropdownColor: cs.surfaceContainerHigh,
          style: TextStyle(color: cs.onSurface),
          iconEnabledColor: cs.onSurface.withValues(alpha: 0.7),
          // Shown while nothing is picked: examples, in a light shade, so
          // it reads as a hint and not as a choice already made.
          hint: Text(
            'e.g. Dance, Comedy, Sports',
            style: TextStyle(
              color: cs.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ),
          items: ContentCategories.choosable
              .map((c) => DropdownMenuItem(
                    value: c,
                    child: Text(c[0].toUpperCase() + c.substring(1)),
                  ))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() => _category = v);
          },
        ),
      ),
    );
  }

  /// Filled in, and no longer than [max] characters — the same limit the
  /// server holds new challenges to.
  String? _limitedText(String? v, int max) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Required';
    if (t.runes.length > max) return 'Keep it to $max characters';
    return null;
  }
}

/// The clip itself, small, playing on a silent loop — so the preview card
/// shows the video that is being posted, not a placeholder.
///
/// If the phone cannot open it here (it is still being written, or this
/// is a build without a video player), the card shows a quiet film icon
/// instead; nothing about posting depends on this preview.
class _ClipPreview extends StatefulWidget {
  final String path;
  const _ClipPreview({required this.path});

  @override
  State<_ClipPreview> createState() => _ClipPreviewState();
}

class _ClipPreviewState extends State<_ClipPreview> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final c = VideoPlayerController.file(File(widget.path));
    try {
      await c.initialize();
      await c.setVolume(0);
      await c.setLooping(true);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _c = c);
      await c.play();
    } catch (e) {
      // Say so: a preview that silently never appears looks like a slow one.
      debugPrint('challenge details: clip preview could not open: $e');
      // And let go of the half-opened player, or it holds a decoder for
      // as long as the page is open.
      c.dispose().catchError(
        (Object e) =>
            debugPrint('challenge details: clip preview close failed: $e'),
      );
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    // ignore: discarded_futures
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return ColoredBox(
        color: Colors.black26,
        child: Center(
          child: _failed
              ? const Icon(Icons.movie_outlined, color: Colors.white54, size: 30)
              : const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white54,
                  ),
                ),
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}
