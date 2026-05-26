import 'package:file_picker/file_picker.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/pages/submit_response_upload_page.dart';
import 'package:myapp/pages/video_player_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/widgets/league_badge.dart';

/// Full-screen challenge detail: video, description, responses, and action buttons.
class ChallengeDetailPage extends StatefulWidget {
  final String challengeId;
  const ChallengeDetailPage({super.key, required this.challengeId});
  
  @override
  State<ChallengeDetailPage> createState() => _ChallengeDetailPageState();
}

class _ChallengeDetailPageState extends State<ChallengeDetailPage>
    with PageTracker<ChallengeDetailPage> {
  ChallengeModel? _challenge;
  List<ChallengeResponseModel> _responses = [];
  List<VoteSummary> _votes = [];
  bool _loading = true;
  bool _accepting = false;

  // Subscription to background-upload completions. Fires when ANY
  // upload finishes; we filter by kind == response && challengeId
  // matches so a sibling challenge's response doesn't trigger a refetch
  // here. Without this listener the user would have to manually
  // pull-to-refresh after their backgrounded upload lands.
  StreamSubscription<UploadJob>? _uploadSub;

  @override
  String get pageName => 'challenge_detail_page';

  @override
  Map<String, dynamic> get pageParams => {'challengeId': widget.challengeId};

  @override
  void initState() {
    super.initState();
    _load();
    _uploadSub = UploadJobManager.instance.onCompleted.listen((job) {
      if (!mounted) return;
      if (job.kind != UploadJobKind.response) return;
      if (job.challengeId != widget.challengeId) return;
      // A response upload for THIS challenge just landed in the backend.
      // Refetch so the new response card appears without the user
      // having to pull-to-refresh.
      _load();
    });
  }

  @override
  void dispose() {
    _uploadSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await ApiService.getChallengeDetail(widget.challengeId);
    if (data != null && mounted) {
      setState(() {
        _challenge = data['challenge'] as ChallengeModel;
        _responses =
            (data['responses'] as List).cast<ChallengeResponseModel>();
        _votes = (data['votes'] as List?)?.cast<VoteSummary>() ?? [];
        _loading = false;
      });
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _like() async {
    if (_challenge == null) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    EventTracker.instance.trackTap(
      target: 'challenge_like',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );
    await ApiService.likeChallenge(
      challengeId: _challenge!.id,
      userId: dp.user!.id,
    );
    _load(); // refresh
  }

  Future<void> _vote(String responseId) async {
    if (_challenge == null) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    EventTracker.instance.trackTap(
      target: 'challenge_vote',
      pageName: 'challenge_detail_page',
      params: {
        'challengeId': _challenge!.id,
        'responseId': responseId,
      },
    );
    await ApiService.voteChallenge(
      challengeId: _challenge!.id,
      responseId: responseId,
      voterId: dp.user!.id,
    );
    _load(); // refresh to show updated votes
  }

  /// Owner-only destructive action. Confirms via dialog, calls the
  /// backend (which CASCADEs through responses/votes/likes/comments/
  /// saves/HLS jobs in one transaction), bumps the feed-refresh
  /// counter so the home reels list rebuilds without the deleted
  /// post, then pops the page.
  ///
  /// R2 object cleanup is intentionally NOT done here — the backend
  /// only removes the DB row; orphan video/thumbnail objects get
  /// reaped by a scheduled GC job. Doing R2 sigv4 calls inline would
  /// add seconds of latency to a UI delete and would block if R2 is
  /// down even though the user-visible state (DB row) is already gone.
  Future<void> _delete() async {
    if (_challenge == null) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final uid = dp.user?.id;
    if (uid == null) return;

    EventTracker.instance.trackTap(
      target: 'challenge_delete_open_confirm',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete challenge?'),
        content: const Text(
          'This permanently removes the challenge, every response, '
          'and all votes/likes/comments on it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    EventTracker.instance.track(
      eventType: 'challenge_delete_confirmed',
      contentId: _challenge!.id,
      contentType: 'challenge',
    );

    final ok = await ApiService.deleteChallenge(
      challengeId: _challenge!.id,
      userId: uid,
    );
    if (!mounted) return;
    if (!ok) {
      _toast('Could not delete. Try again.');
      return;
    }
    // Tell every feed surface (home reels, profile grid, etc.) to
    // refetch — the deleted item should disappear without a manual
    // pull-to-refresh.
    dp.bumpFeedRefresh();
    Navigator.of(context).pop<bool>(true);
  }

  /// Opens the response-source chooser. Two big buttons: record a
  /// clip with the in-app camera, or pick one from the device. Both
  /// paths converge on the trim page and then the upload page — the
  /// same Record → Trim → R2 pipeline that create-challenge uses.
  ///
  /// The legacy "paste a video URL" form has been retired: hosting
  /// the video ourselves on R2 is what enables multi-bitrate
  /// adaptive playback, per-user storage prefix scans, and stable
  /// public URLs we control. Letting users paste arbitrary URLs
  /// defeats all three.
  void _showAcceptSheet() {
    if (_challenge == null) return;
    EventTracker.instance.trackTap(
      target: 'challenge_accept_open_sheet',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Accept Challenge',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  'Record or upload your response — we\'ll create three '
                  'quality versions so it plays smoothly on any network.',
                  style: TextStyle(
                    color: cs.onSurface.withValues(alpha: 0.6),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 20),
                _bigChoice(
                  cs: cs,
                  icon: Icons.videocam_rounded,
                  title: 'Record now',
                  subtitle: 'Use the in-app camera with flip and flash',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _onRecord();
                  },
                ),
                const SizedBox(height: 12),
                _bigChoice(
                  cs: cs,
                  icon: Icons.video_library_rounded,
                  title: 'Pick from device',
                  subtitle: 'Upload a clip from your gallery or files',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _onPickFile();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onRecord() async {
    if (_challenge == null || _accepting) return;
    EventTracker.instance.trackTap(
      target: 'accept_challenge_record',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );

    // Camera + mic required to even build the preview. If denied we
    // surface a toast — pushing a half-working camera screen would
    // leave the user confused.
    final cam = await Permission.camera.request();
    final mic = await Permission.microphone.request();
    if (!cam.isGranted || !mic.isGranted) {
      _toast('Camera and microphone permission required.');
      return;
    }
    if (!mounted) return;

    final recorded = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const RecordVideoPage()),
    );
    if (!mounted || recorded == null || recorded.isEmpty) return;
    await _continueWithSource(recorded);
  }

  Future<void> _onPickFile() async {
    if (_challenge == null || _accepting) return;
    EventTracker.instance.trackTap(
      target: 'accept_challenge_pick',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );

    setState(() => _accepting = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.video,
        allowMultiple: false,
        // We need a real path on disk so VideoProcessor can hand it
        // to ffmpeg — streaming the bytes through Dart would be
        // wasteful for a 50MB clip.
        withData: false,
      );
      if (picked == null || picked.files.isEmpty) return;
      final path = picked.files.first.path;
      if (path == null || path.isEmpty) {
        _toast('Could not read the selected file. Try another.');
        return;
      }
      if (!mounted) return;
      await _continueWithSource(path);
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  /// Push the trim screen (which pops with the trimmed path), then
  /// dispatch the response upload to [UploadJobManager] via the
  /// [SubmitResponseUploadPage] hand-off screen. The hand-off pops
  /// immediately with `true`; the actual upload runs in the background
  /// and we rely on [_uploadSub] (subscribed in initState) to refresh
  /// the detail page once the new response is live in the backend.
  Future<void> _continueWithSource(String sourcePath) async {
    if (_challenge == null) return;
    EventTracker.instance.track(
      eventType: 'accept_challenge_source_selected',
      contentId: _challenge!.id,
      contentType: 'challenge_response',
    );

    final trimmed = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => VideoTrimPage(
          sourcePath: sourcePath,
          popOnComplete: true,
        ),
      ),
    );
    if (!mounted || trimmed == null || trimmed.isEmpty) return;

    // The hand-off page dispatches the job and pops instantly with
    // `true`. We don't await the upload here — onCompleted listener
    // refreshes the detail page once the response is actually live.
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SubmitResponseUploadPage(
          processedSourcePath: trimmed,
          challengeId: _challenge!.id,
        ),
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Widget _bigChoice({
    required ColorScheme cs,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 26, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: cs.onSurface.withValues(alpha: 0.4)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final dp = Provider.of<DataProvider>(context, listen: false);
    final isOwner =
        _challenge != null && dp.user?.id == _challenge!.creatorId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Challenge'),
        actions: [
          if (isOwner)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.red),
                      SizedBox(width: 10),
                      Text('Delete', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body:_loading
        ? const Center(child: CircularProgressIndicator())
        : _challenge == null
            ? const Center(child: Text('Challenge not found'))
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // -- Challenge title --
                    Text(
                      _challenge!.title,
                      style: tt.displayLarge?.copyWith(
                        color: cs.primary,
                        fontSize: 26,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // —— Creator info ——
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: cs.primaryContainer,
                          child: Text(
                            _challenge!.creatorUsername.isNotEmpty
                                ? _challenge!.creatorUsername[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: cs.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                              fontSize: 18),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_challenge!.creatorUsername,
                                style: tt.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            Text(
                              _challenge!.visibility == 'arena'
                                  ? 'Arena challenge'
                                  : 'Friends only',
                              style: tt.bodySmall?.copyWith(
                                  color: cs.onSurface.withOpacity(0.5)),
                            ),
                          ],
                        ),
                        const Spacer(),
                        LeagueBadge(league: _challenge!.creatorLeague),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // —— Video thumbnail / placeholder — tap to play ——
                    GestureDetector(
                      onTap: _challenge!.videoUrl.isNotEmpty
                          ? () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => VideoPlayerPage(
                                    videoUrl: _challenge!.videoUrl,
                                    title: _challenge!.title,
                                  ),
                                ),
                              )
                          : null,
                      child: Container(
                        width: double.infinity,
                        height: 220,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(16),
                          image: (_challenge!.thumbnailUrl != null &&
                                  _challenge!.thumbnailUrl!.isNotEmpty)
                              ? DecorationImage(
                                  image: NetworkImage(
                                      _challenge!.thumbnailUrl!),
                                  fit: BoxFit.cover,
                              )
                            : null,
                        ),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.4),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _challenge!.videoUrl.isNotEmpty
                                  ? Icons.play_arrow
                                  : Icons.videocam_off,
                              size: 40,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // —— Stats + Actions ——
                    Row(
                      children: [
                        _StatButton(
                          icon: Icons.favorite,
                          value: _challenge!.likes,
                          color: Colors.red,
                          onTap: _like,
                        ),
                        const SizedBox(width: 20),
                        _StatButton(
                          icon: Icons.visibility,
                          value: _challenge!.views,
                          color: cs.onSurface.withOpacity(0.6),
                        ),
                        const SizedBox(width: 20),
                        _StatButton(
                          icon: Icons.reply,
                          value: _responses.length,
                          color: cs.primary,
                        ),
                        const Spacer(),
                        _statusChip(_challenge!.status, cs),
                      ],
                    ),
                    const SizedBox(height: 20),
                    
                    // —— Accept button ——
                    if (_challenge!.status == 'open')...[
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: FilledButton.icon(
                          onPressed: _accepting ? null : _showAcceptSheet,
                          icon: _accepting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.sports_kabaddi),
                          label: const Text('Accept Challenge',
                              style:TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // —— Responses ——
                    // —— Vote Summary ——
                    if (_votes.isNotEmpty) ...[
                      Row(
                        children: [
                          Icon(Icons.how_to_vote, color: cs.primary, size: 22),
                          const SizedBox(width: 6),
                          Text('Votes', style: tt.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ..._votes.map((v) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(v.username,
                                  style: tt.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: cs.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text('${v.votes} votes',
                                  style: TextStyle(
                                      color: cs.primary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12)),
                            ),
                          ],
                        ),
                      )),
                      const SizedBox(height: 16),
                    ],

                    if (_responses.isNotEmpty)...[
                      Row(
                        children:[
                          Icon(Icons.emoji_events, color: cs.primary, size: 22),
                          const SizedBox(width: 6),
                          Text('Responses (${_responses.length})',
                              style: tt.titleMedium),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ..._responses.map((r) => _ResponseCard(
                        response: r,
                        onVote: _challenge!.status == 'active'
                            ? () => _vote(r.id)
                            : null,
                      )),
                    ] else ...[
                      Center(
                        child:Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Column(
                            children: [
                              Icon(Icons.hourglass_empty,
                                  size: 40,
                                  color: cs.onSurface.withOpacity(0.2)),
                              const SizedBox(height: 8),
                              Text('No responses yet — be the first!',
                                  style: TextStyle(
                                      color:
                                          cs.onSurface.withOpacity(0.4))),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
    );
  }

  Widget _statusChip(String status, ColorScheme cs) {
    Color bg;
    Color fg;
    switch (status) {
      case 'active':
        bg = Colors.orange.withOpacity(0.15);
        fg = Colors.orange;
        break;
      case 'completed':
        bg =Colors.green.withOpacity(0.15);
        fg = Colors.green;
        break;
      default:
        bg = cs.primary.withOpacity(0.15);
        fg = cs.primary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child:Text(
        status.toUpperCase(),
        style: TextStyle(fontSize:11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Stat button (like, views, responses)
// ----------------------------------------------------------------------------

class _StatButton extends StatelessWidget {
  final IconData icon;
  final int value;
  final Color color;
  final VoidCallback? onTap;

  const _StatButton({
    required this.icon,
    required this.value,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(width: 4),
            Text('$value',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Response card
// ---------------------------------------------------------------------------

class _ResponseCard extends StatelessWidget {
  final ChallengeResponseModel response;
  final VoidCallback? onVote;
  const _ResponseCard({required this.response, this.onVote});

  @override
  Widget build(BuildContext context) {
    final cs =Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            // Thumbnail / placeholder — tap to play
            GestureDetector(
              onTap: response.videoUrl.isNotEmpty
                  ? () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => VideoPlayerPage(
                            videoUrl: response.videoUrl,
                            title: '${response.responderUsername}\'s response',
                          ),
                        ),
                      )
                  : null,
              child: Container(
                width: 80,
                height: 60,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  image: (response.thumbnailUrl != null &&
                          response.thumbnailUrl!.isNotEmpty)
                      ? DecorationImage(
                          image: NetworkImage(response.thumbnailUrl!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: Icon(Icons.play_circle,
                    color: cs.primary.withOpacity(0.4), size: 28),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(response.responderUsername,
                          style: tt.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      LeagueBadge(
                          league: response.responderLeague, small: true),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.favorite,
                          size: 14, color: cs.onSurface.withOpacity(0.4)),
                      const SizedBox(width: 3),
                      Text('${response.likes}',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withOpacity(0.5))),
                      const SizedBox(width: 12),
                      Icon(Icons.visibility,
                          size:14, color: cs.onSurface.withOpacity(0.4)),
                      const SizedBox(width: 3),
                      Text('${response.views}',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurface.withOpacity(0.5))),
                    ],
                  ),
                ],
              ),
            ),
            if (onVote != null)
              IconButton(
                onPressed: onVote,
                icon: Icon(Icons.how_to_vote, color: cs.primary),
                tooltip: 'Vote for this response',
              ),
          ],
        ),
      ),
    );
  }
}