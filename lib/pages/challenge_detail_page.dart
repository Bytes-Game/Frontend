import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myapp/widgets/create_burst.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/pages/record_video_page.dart';
import 'package:myapp/pages/submit_response_upload_page.dart';
import 'package:myapp/pages/video_trim_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/battle_scoreboard.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/upload_job_manager.dart';
import 'package:myapp/models/battle_model.dart' show ActionResult, BattleStandings;
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/widgets/feed_action_bar.dart'
    show ChallengeCommentSheet, ChallengeShareSheet, CommentSheetCaption;
import 'package:myapp/widgets/league_badge.dart' show leagueWash;
import 'package:myapp/widgets/people_list_sheet.dart';
import 'package:myapp/widgets/match_warning.dart';
import 'package:myapp/widgets/report_video.dart';
import 'package:myapp/widgets/video_grid_tile.dart' show openVideoPlaylist;

/// Full-screen challenge detail: video, description, responses, and action buttons.
class ChallengeDetailPage extends StatefulWidget {
  final String challengeId;

  /// Opened from a short's "Accept challenge" button with Record or Upload
  /// already chosen: start that as soon as the challenge has loaded, rather
  /// than making the person find the accept button again here.
  final CreateChoice? acceptWith;

  /// Opened from a reel. A tap on either video then goes back to that
  /// reel — to the answer's side when the answer was tapped — rather than
  /// opening a second, bare player with none of the reel's buttons.
  final bool fromReel;

  const ChallengeDetailPage({
    super.key,
    required this.challengeId,
    this.acceptWith,
    this.fromReel = false,
  });

  /// What a reel is told when this page closes because a video was tapped.
  static const String backToAnswer = 'answer';
  static const String backToChallenger = 'challenger';
  
  @override
  State<ChallengeDetailPage> createState() => _ChallengeDetailPageState();
}

class _ChallengeDetailPageState extends State<ChallengeDetailPage>
    with PageTracker<ChallengeDetailPage> {
  ChallengeModel? _challenge;
  List<ChallengeResponseModel> _responses = [];
  /// Bumped on every reload so the live score reloads with the page.
  int _scoreVersion = 0;
  bool _loading = true;
  bool _accepting = false;

  /// [ChallengeDetailPage.acceptWith] runs once, not on every reload.
  bool _acceptStarted = false;

  /// The first comments, for the preview under the score.
  List<Map<String, dynamic>> _comments = [];

  /// The live count, for the "Leading" crown on the video cards. The
  /// scoreboard below loads its own; this is only who is ahead.
  BattleStandings? _standings;

  /// The heart, starting from what the server says you did.
  bool _liked = false;
  int _likes = 0;

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
        _scoreVersion++;
        _loading = false;
        _liked = _challenge!.isLiked;
        _likes = _challenge!.likes;
      });
      _startAcceptIfAsked();
      _loadExtras();
    } else if (mounted) {
      setState(() => _loading = false);
    }
  }

  /// Comments and who is leading. Neither holds the page up.
  Future<void> _loadExtras() async {
    final id = widget.challengeId;
    final comments = await ApiService.getChallengeComments(id);
    final standings = await ApiService.getBattleStandings(id);
    if (!mounted) return;
    setState(() {
      _comments = comments;
      if (standings != null) _standings = standings;
    });
  }

  void _openComments() {
    final c = _challenge;
    if (c == null) return;
    showModalBottomSheet(
      // The sheet draws its own handle; the theme's would be a second.
      showDragHandle: false,
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeCommentSheet(
        challengeId: c.id,
        header: CommentSheetCaption(
          username: c.creatorUsername,
          caption: _question(c),
          detail: '${_compact(c.views)} views',
        ),
      ),
    ).then((_) => _loadExtras());
  }

  /// "Accept challenge": Record or Upload rising out of the button, then
  /// the same steps as ever.
  void _acceptFrom(Offset anchor) {
    CreateBurst.show(
      context,
      anchor: anchor,
      fromHold: false,
      title: 'Accept challenge',
      anchorSize: const Size(44, 44),
      anchorRadius: 22,
      onChoose: (how) {
        if (!mounted) return;
        switch (how) {
          case CreateChoice.record:
            _onRecord();
          case CreateChoice.upload:
            _onPickFile();
        }
      },
    );
  }

  static String _question(ChallengeModel c) {
    final t = c.title.trim();
    return t.endsWith('?') ? t : '$t?';
  }

  static String _compact(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  void _startAcceptIfAsked() {
    final how = widget.acceptWith;
    if (how == null || _acceptStarted) return;
    _acceptStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (how) {
        case CreateChoice.record:
          _onRecord();
        case CreateChoice.upload:
          _onPickFile();
      }
    });
  }

  Future<void> _like() async {
    if (_challenge == null) return;
    final dp = Provider.of<DataProvider>(context, listen: false);
    EventTracker.instance.trackTap(
      target: 'challenge_like',
      pageName: 'challenge_detail_page',
      params: {'challengeId': _challenge!.id},
    );
    final was = _liked;
    setState(() {
      _liked = !was;
      _likes = (_likes + (was ? -1 : 1)).clamp(0, 1 << 31);
    });
    final res = await ApiService.likeChallenge(
      challengeId: _challenge!.id,
      userId: dp.user!.id,
    );
    if (!mounted) return;
    if (res == null) {
      setState(() {
        _liked = was;
        _likes = (_likes + (was ? 1 : -1)).clamp(0, 1 << 31);
      });
      _toast("Couldn't update your like. Try again.");
      return;
    }
    setState(() {
      _liked = res['liked'] == true;
      final n = res['likes'];
      if (n is int) _likes = n;
    });
    _refreshStandings();
  }

  /// Likes on every video in the battle. The creator's comes from this
  /// page's own heart, so a tap shows at once; the answers' from the live
  /// score.
  int _totalLikes(ChallengeModel c) {
    final answers = _standings?.sides
            .where((x) => !x.isCreator)
            .fold<int>(0, (a, x) => a + x.likes) ??
        0;
    return _likes + answers;
  }

  /// Share the challenge: the share sheet, and the share counted.
  Future<void> _share() async {
    final c = _challenge;
    if (c == null) return;
    EventTracker.instance.trackShare(contentId: c.id, contentType: 'challenge');
    // ignore: discarded_futures
    ApiService.shareChallenge(challengeId: c.id).then((_) {
      if (mounted) _refreshStandings();
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChallengeShareSheet(challenge: c),
    );
  }

  /// The live score again, quietly, for the totals.
  Future<void> _refreshStandings() async {
    final st = await ApiService.getBattleStandings(widget.challengeId);
    if (mounted && st != null) setState(() => _standings = st);
  }

  /// Sends a vote and says how it went. The score box shows the vote the
  /// moment it is tapped and does not wait for this. It used to reload the
  /// whole page after every vote, which is why voting felt slow.
  Future<ActionResult> _vote(String responseId) async {
    final c = _challenge;
    final user = Provider.of<DataProvider>(context, listen: false).user;
    if (c == null || user == null) {
      return const ActionResult(false, 'Sign in to vote.');
    }
    EventTracker.instance.trackTap(
      target: 'challenge_vote',
      pageName: 'challenge_detail_page',
      params: {'challengeId': c.id, 'responseId': responseId},
    );
    return ApiService.voteChallenge(
      challengeId: c.id,
      responseId: responseId,
      voterId: user.id,
    );
  }

  /// A vote from the "More answers" list, which has no score box of its
  /// own: say how it went, and bring the score box up to date.
  Future<void> _voteFromList(String responseId) async {
    final res = await _vote(responseId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(res.ok ? 'Vote counted.' : res.message),
        duration: const Duration(seconds: 3),
      ),
    );
    setState(() => _scoreVersion++);
  }

  /// The videos on this page the signed-in person may report as not
  /// matching the challenge: every one that isn't theirs, still up. Each is
  /// (answer id, whose it is) — an empty id is the challenge's own video.
  List<(String, String)> _reportable(ChallengeModel c, String? me) {
    if (me == null || me.isEmpty || c.status == 'removed') return const [];
    return [
      if (c.creatorId != me) ('', "${c.creatorUsername}'s"),
      for (final r in _responses)
        if (r.responderId != me) (r.id, "${r.responderUsername}'s"),
    ];
  }

  /// Report one video as not matching the challenge. The video stays up
  /// whatever happens; its owner may lose rating points. Somebody in the
  /// battle is told first that a false report costs them.
  Future<void> _report(String responseId) async {
    final c = _challenge;
    if (c == null) return;
    final me = Provider.of<DataProvider>(context, listen: false).user?.id;
    EventTracker.instance.trackTap(
      target: 'challenge_report_open',
      pageName: 'challenge_detail_page',
      params: {'challengeId': c.id, 'responseId': responseId},
    );
    await reportVideo(
      context,
      challengeId: c.id,
      responseId: responseId,
      inBattle: me != null &&
          (c.creatorId == me || _responses.any((r) => r.responderId == me)),
    );
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

    // The last word before it goes: does this video answer the challenge?
    // One that doesn't costs its owner rating points, so they are asked
    // now rather than told afterwards.
    final question = _challenge == null ? '' : _question(_challenge!);
    if (!await confirmAnswerMatches(context, question) || !mounted) return;

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

  /// Watch one side of this battle, in a reel with all its buttons.
  ///
  /// From a reel: back to it, on the side tapped. From anywhere else (a
  /// notification, a profile, a link): a reel of this challenge. It used to
  /// open a bare player — the video and nothing else, no like, no comment,
  /// no vote — which felt like a different app.
  void _watch({required bool answer}) {
    if (widget.fromReel) {
      Navigator.of(context).pop(
        answer
            ? ChallengeDetailPage.backToAnswer
            : ChallengeDetailPage.backToChallenger,
      );
      return;
    }
    final c = _challenge;
    if (c == null) return;
    openVideoPlaylist(context, [c], 0);
  }

  @override
  Widget build(BuildContext context) {
    // This page is dark whatever the app's theme. Everything on it that
    // takes its colours from the theme — the title, the live score, the
    // players' names — has to take them from a dark one, or in light mode
    // they come out dark on dark and simply vanish.
    return Theme(data: AppTheme.darkTheme, child: _page(context));
  }

  Widget _page(BuildContext context) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final c = _challenge;
    final isOwner = c != null && dp.user?.id == c.creatorId;
    final isBattle = _responses.isNotEmpty;
    final me = dp.user?.id;
    final isPlayer = me != null &&
        (isOwner || _responses.any((r) => r.responderId == me));
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          c == null ? '' : (isBattle ? 'Battle' : 'Challenge'),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (c != null && (isOwner || _reportable(c, me).isNotEmpty))
            PopupMenuButton<String>(
              key: const ValueKey('detail_more'),
              icon: const Icon(Icons.more_horiz_rounded),
              tooltip: 'More',
              color: const Color(0xFF2C2C2E),
              onSelected: (v) {
                if (v == 'delete') _delete();
                if (v.startsWith('report:')) _report(v.substring(7));
              },
              itemBuilder: (_) => [
                // One line per video that isn't yours: the challenge's own,
                // and each answer, by whose it is.
                for (final (rid, whose) in _reportable(c, me))
                  PopupMenuItem<String>(
                    key: ValueKey('report_$rid'),
                    value: 'report:$rid',
                    child: Row(
                      children: [
                        const Icon(Icons.flag_outlined, color: Colors.white),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            "$whose video doesn't match",
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (isOwner)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded,
                            color: Color(0xFFFF453A)),
                        SizedBox(width: 10),
                        Text('Delete',
                            style: TextStyle(color: Color(0xFFFF453A))),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: _loading && c == null
          ? const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            )
          : c == null
              ? const Center(
                  child: Text(
                    'This challenge is not here any more.',
                    style: TextStyle(color: _muted),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    children: [
                      // Who: the two videos, side by side.
                      _Versus(
                        challenge: c,
                        answer: isBattle ? _responses.first : null,
                        standings: _standings,
                        isOwner: isOwner,
                        onAccept: _acceptFrom,
                        onWatch: _watch,
                      ),
                      const SizedBox(height: 18),
                      // What: the question, as big as anything on the page.
                      Text(
                        _question(c),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (c.status == 'removed') ...[
                        const SizedBox(height: 12),
                        const _TakenDown(),
                      ],
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _StatusChip(challenge: c, standings: _standings),
                          _Chip(
                            icon: c.visibility == 'friends'
                                ? Icons.group_rounded
                                : Icons.public_rounded,
                            label: c.visibility == 'friends'
                                ? 'Only friends'
                                : 'Public',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Every number is a total across the players, from
                      // the same live score the rows below show, so the two
                      // always agree. Tap a number for who — for the
                      // people in the video.
                      _StatsBar(
                        liked: _liked,
                        likes: _totalLikes(c),
                        comments: math.max(_comments.length, c.commentCount),
                        shares: _standings?.totalShares ?? c.shareCount,
                        votes: isBattle
                            ? (_standings?.totalVotes ?? c.voteCount)
                            : null,
                        views: _standings?.totalViews ?? c.views,
                        onLike: dp.user == null ? null : _like,
                        onComments: _openComments,
                        onShare: dp.user == null ? null : _share,
                        onWho: isPlayer
                            ? (list) => showPeople(context, c.id, list)
                            : null,
                      ),
                      if (c.status == 'open' && !isOwner) ...[
                        const SizedBox(height: 16),
                        Builder(
                          builder: (btn) => SizedBox(
                            height: 52,
                            child: FilledButton.icon(
                              key: const ValueKey('accept_button'),
                              onPressed: _accepting
                                  ? null
                                  : () {
                                      final box = btn.findRenderObject()!
                                          as RenderBox;
                                      _acceptFrom(box.localToGlobal(
                                          box.size.center(Offset.zero)));
                                    },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              icon: _accepting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.bolt_rounded),
                              label: const Text(
                                'Accept challenge',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const MatchWarning(text: matchWarningAnswer),
                      ],
                      // —— Live score ——
                      // Genuine votes, likes, views and shares per side, how
                      // long is left, and what did not count — the same
                      // count that decides the winner.
                      if (c.status != 'open' || isBattle) ...[
                        const SizedBox(height: 16),
                        BattleScoreboard(
                          challengeId: c.id,
                          viewerId: dp.user?.id,
                          onVote: dp.user == null ? null : _vote,
                          refreshToken: _scoreVersion,
                          // One count on the page: the totals above follow
                          // the rows below, votes included.
                          onStandings: (st) {
                            if (mounted) setState(() => _standings = st);
                          },
                        ),
                      ],
                      const SizedBox(height: 20),
                      _CommentsPreview(
                        comments: _comments,
                        onOpen: _openComments,
                      ),
                      // The top answer is in the cards above. Any others,
                      // listed; and on your own answer, what the app
                      // noticed in it.
                      if (isBattle && _responses.length > 1) ...[
                        const SizedBox(height: 20),
                        const _SectionTitle('More answers'),
                        ..._responses.skip(1).map(
                              (r) => _ResponseCard(
                                response: r,
                                onWatch: () => _watch(answer: true),
                                onVote: c.status == 'active'
                                    ? () => _voteFromList(r.id)
                                    : null,
                              ),
                            ),
                      ],
                    ],
                  ),
                ),
    );
  }
}

const _surface = Color(0xFF1C1C1E);
const _raised = Color(0xFF2C2C2E);
const _muted = Color(0xFF8E8E93);

// ----------------------------------------------------------------------------
// The two videos
// ----------------------------------------------------------------------------

/// The creator's video and the answer, as two tall cards with "VS" between
/// them. On an open challenge the right-hand card is the empty seat: tap it
/// to take it.
class _Versus extends StatelessWidget {
  final ChallengeModel challenge;
  final ChallengeResponseModel? answer;
  final BattleStandings? standings;
  final bool isOwner;
  final ValueChanged<Offset> onAccept;
  final void Function({required bool answer}) onWatch;

  const _Versus({
    required this.challenge,
    required this.answer,
    required this.standings,
    required this.isOwner,
    required this.onAccept,
    required this.onWatch,
  });

  bool _leading(bool creator) {
    final st = standings;
    if (st == null) return false;
    for (final s in st.sides) {
      if (s.isCreator == creator && s.leading) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final a = answer;
    return Stack(
      alignment: Alignment.center,
      children: [
        Row(
          children: [
            Expanded(
              child: _VideoCard(
                key: const ValueKey('card_creator'),
                role: 'Challenger',
                username: challenge.creatorUsername,
                league: challenge.creatorLeague,
                thumbnailUrl: challenge.thumbnailUrl ?? '',
                videoUrl: challenge.videoUrl,
                title: challenge.title,
                onTap: () => onWatch(answer: false),
                leading: _leading(true),
                decided: standings?.resolved == true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: a != null
                  ? _VideoCard(
                      key: const ValueKey('card_answer'),
                      role: 'Answer',
                      username: a.responderUsername,
                      league: a.responderLeague,
                      thumbnailUrl: a.thumbnailUrl ?? '',
                      videoUrl: a.videoUrl,
                      title: "${a.responderUsername}'s answer",
                      onTap: () => onWatch(answer: true),
                      leading: _leading(false),
                      decided: standings?.resolved == true,
                    )
                  : _EmptySeat(
                      opponent: challenge.creatorUsername,
                      canTake: !isOwner && challenge.status == 'open',
                      onTake: onAccept,
                    ),
            ),
          ],
        ),
        IgnorePointer(
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black,
              border: Border.all(color: Colors.white24, width: 1.5),
            ),
            alignment: Alignment.center,
            child: const Text(
              'VS',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One side's video: its picture, who it is, and a play button. Tap to
/// watch.
class _VideoCard extends StatelessWidget {
  final String role;
  final String username;
  final String league;
  final String thumbnailUrl;
  final String videoUrl;
  final String title;
  final bool leading;
  final bool decided;
  final VoidCallback onTap;

  const _VideoCard({
    super.key,
    required this.role,
    required this.username,
    required this.league,
    required this.thumbnailUrl,
    required this.videoUrl,
    required this.title,
    required this.onTap,
    this.leading = false,
    this.decided = false,
  });

  @override
  Widget build(BuildContext context) {
    final ring = league.isEmpty ? Colors.white38 : leagueWash(league);
    return GestureDetector(
      onTap: videoUrl.isEmpty ? null : onTap,
      child: AspectRatio(
        aspectRatio: 0.66,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: leading ? const Color(0xFFFFD60A) : Colors.white12,
              width: leading ? 1.5 : 1,
            ),
            boxShadow: leading
                ? [
                    BoxShadow(
                      color: const Color(0xFFFFD60A).withValues(alpha: 0.25),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (thumbnailUrl.isNotEmpty)
                Image.network(
                  thumbnailUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _cardBackground(ring),
                )
              else
                _cardBackground(ring),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.45, 1],
                    colors: [Colors.transparent, Color(0xCC000000)],
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.35),
                    border: Border.all(color: Colors.white38),
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
              Positioned(
                top: 10,
                left: 10,
                child: _Pill(
                  label: role,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
              ),
              if (leading)
                Positioned(
                  top: 10,
                  right: 10,
                  child: _Pill(
                    label: decided ? 'Winner' : 'Leading',
                    icon: Icons.emoji_events_rounded,
                    color: const Color(0xFFFFD60A),
                    dark: true,
                  ),
                ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Row(
                  children: [
                    Container(
                      width: 26,
                      height: 26,
                      padding: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ring,
                      ),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _raised,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          username.isEmpty ? '?' : username[0].toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        username,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cardBackground(Color ring) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(ring, Colors.black, 0.55)!,
              const Color(0xFF111113),
            ],
          ),
        ),
      );
}

/// The right-hand card on an open challenge: nobody has taken it yet.
class _EmptySeat extends StatelessWidget {
  final String opponent;
  final bool canTake;
  final ValueChanged<Offset> onTake;

  const _EmptySeat({
    required this.opponent,
    required this.canTake,
    required this.onTake,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 0.66,
      child: Builder(
        builder: (card) => GestureDetector(
          key: const ValueKey('empty_seat'),
          onTap: canTake
              ? () {
                  final box = card.findRenderObject()! as RenderBox;
                  onTake(box.localToGlobal(box.size.center(Offset.zero)));
                }
              : null,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: _surface,
              border: Border.all(
                color: canTake
                    ? AppTheme.primary.withValues(alpha: 0.6)
                    : Colors.white12,
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: canTake
                        ? AppTheme.primary.withValues(alpha: 0.18)
                        : _raised,
                  ),
                  child: Icon(
                    canTake ? Icons.add_rounded : Icons.hourglass_top_rounded,
                    color: canTake ? AppTheme.primary : _muted,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  canTake ? 'Your move' : 'Waiting for a challenger',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  canTake
                      ? 'Accept to take on $opponent'
                      : 'Anyone can accept it',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool dark;

  const _Pill({
    required this.label,
    required this.color,
    this.icon,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// Under the title
// ----------------------------------------------------------------------------

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _Chip({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final fg = color ?? const Color(0xFFD1D1D6);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color == null ? _surface : color!.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A challenge that has been removed (by hand or by moderation — never for
/// not matching; that costs rating points instead) is still here for its
/// owner, and gone for everyone else.
class _TakenDown extends StatelessWidget {
  const _TakenDown();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('taken_down'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFF453A).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.block_rounded, size: 18, color: Color(0xFFFF453A)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'This challenge has been removed. Nobody else can see it, '
              'answer it or vote on it.',
              style: TextStyle(color: Colors.white, fontSize: 13.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the challenge is in its life: waiting, live (and how long is
/// left), removed, or decided.
class _StatusChip extends StatelessWidget {
  final ChallengeModel challenge;
  final BattleStandings? standings;

  const _StatusChip({required this.challenge, required this.standings});

  @override
  Widget build(BuildContext context) {
    final st = standings;
    if (challenge.status == 'removed') {
      return const _Chip(
        icon: Icons.block_rounded,
        label: 'Removed',
        color: Color(0xFFFF453A),
      );
    }
    if (challenge.status == 'open') {
      return const _Chip(
        icon: Icons.hourglass_top_rounded,
        label: 'Open',
        color: AppTheme.primary,
      );
    }
    if (challenge.status == 'completed' || (st?.resolved ?? false)) {
      return const _Chip(
        icon: Icons.flag_rounded,
        label: 'Final',
        color: _muted,
      );
    }
    var label = 'Live';
    final end = st?.endsAt;
    if (end != null) {
      final d = end.difference(DateTime.now());
      if (d.isNegative) {
        label = 'Voting closed';
      } else if (d.inDays >= 1) {
        label = 'Live · ${d.inDays}d ${d.inHours % 24}h left';
      } else {
        label = 'Live · ${d.inHours}h left';
      }
    }
    return _Chip(
      icon: Icons.circle,
      label: label,
      color: const Color(0xFF30D158),
    );
  }
}

/// Likes, comments, shares, votes and views on one bar — each a total
/// across the players, the same numbers as the live score's rows and as the
/// reel.
///
/// As on Instagram, the icon does the thing (like, comment, share) and the
/// number opens who did it — for the people in the video ([onWho]); for
/// everyone else the number is only a number.
class _StatsBar extends StatelessWidget {
  final bool liked;
  final int likes;
  final int comments;
  final int shares;

  /// Null on a challenge nobody has answered: there is nothing to vote on.
  final int? votes;
  final int views;
  final VoidCallback? onLike;
  final VoidCallback onComments;
  final VoidCallback? onShare;
  final void Function(PeopleList list)? onWho;

  const _StatsBar({
    required this.liked,
    required this.likes,
    required this.comments,
    required this.shares,
    required this.votes,
    required this.views,
    required this.onLike,
    required this.onComments,
    required this.onShare,
    required this.onWho,
  });

  @override
  Widget build(BuildContext context) {
    Widget cell({
      required String name,
      required IconData icon,
      required int value,
      required String label,
      Color color = Colors.white,
      VoidCallback? onTap,
      PeopleList? who,
      String? tooltip,
    }) {
      final open = who == null || onWho == null ? onTap : () => onWho!(who);
      final iconPart = InkWell(
        key: ValueKey('stat_icon_$name'),
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 22, color: color),
        ),
      );
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              tooltip == null
                  ? iconPart
                  : Tooltip(message: tooltip, child: iconPart),
              InkWell(
                key: ValueKey('stat_count_$name'),
                onTap: open,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    children: [
                      Text(
                        _ChallengeDetailPageState._compact(value),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        label,
                        style: const TextStyle(color: _muted, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final v = votes;
    return Container(
      key: const ValueKey('stats_bar'),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          cell(
            name: 'likes',
            icon: liked
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            value: likes,
            label: 'Likes',
            color: liked ? const Color(0xFFFF375F) : Colors.white,
            onTap: onLike,
            who: PeopleList.likes,
            tooltip: liked ? 'Unlike' : 'Like',
          ),
          cell(
            name: 'comments',
            icon: Icons.chat_bubble_outline_rounded,
            value: comments,
            label: 'Comments',
            onTap: onComments,
            tooltip: 'Comments',
          ),
          cell(
            name: 'shares',
            icon: Icons.reply_rounded,
            value: shares,
            label: 'Shares',
            onTap: onShare,
            who: PeopleList.shares,
            tooltip: 'Share',
          ),
          if (v != null)
            cell(
              name: 'votes',
              icon: Icons.how_to_vote_rounded,
              value: v,
              label: 'Votes',
              who: PeopleList.votes,
            ),
          cell(
            name: 'views',
            icon: Icons.visibility_outlined,
            value: views,
            label: 'Views',
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// The first two comments, and the way into all of them.
class _CommentsPreview extends StatelessWidget {
  final List<Map<String, dynamic>> comments;
  final VoidCallback onOpen;

  const _CommentsPreview({required this.comments, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(
          'Comments',
          trailing: comments.length > 2
              ? TextButton(
                  onPressed: onOpen,
                  child: Text(
                    'View all ${comments.length}',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : null,
        ),
        for (final c in comments.take(2))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: _raised,
                  child: Text(
                    ((c['authorUsername'] as String?) ?? '?')
                        .characters
                        .first
                        .toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${c['authorUsername'] ?? '?'}  ',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text: '${c['text'] ?? ''}',
                          style: const TextStyle(color: Color(0xFFD1D1D6)),
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
        // The way in, even with nothing yet: a field-shaped button.
        InkWell(
          key: const ValueKey('add_comment'),
          onTap: onOpen,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(20),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              comments.isEmpty ? 'Be the first to comment…' : 'Add a comment…',
              style: const TextStyle(color: _muted, fontSize: 14.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// Another answer, beyond the top one shown in the cards: its video, who,
/// its likes and views, and a vote.
class _ResponseCard extends StatelessWidget {
  final ChallengeResponseModel response;
  final VoidCallback? onVote;
  final VoidCallback onWatch;

  const _ResponseCard({
    required this.response,
    required this.onWatch,
    this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final thumb = response.thumbnailUrl ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: response.videoUrl.isNotEmpty ? onWatch : null,
                child: Container(
                  width: 54,
                  height: 72,
                  decoration: BoxDecoration(
                    color: _raised,
                    borderRadius: BorderRadius.circular(10),
                    image: thumb.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(thumb),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white70,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            response.responderUsername,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_ChallengeDetailPageState._compact(response.likes)} '
                      'likes  ·  '
                      '${_ChallengeDetailPageState._compact(response.views)} '
                      'views',
                      style: const TextStyle(color: _muted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              if (onVote != null)
                IconButton(
                  onPressed: onVote,
                  icon: const Icon(
                    Icons.how_to_vote_rounded,
                    color: AppTheme.primary,
                  ),
                  tooltip: 'Vote for this answer',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
