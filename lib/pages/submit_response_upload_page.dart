import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/upload_job_manager.dart';

/// Hand-off screen that dispatches a response upload to
/// [UploadJobManager] and pops the user straight back to the challenge
/// detail page. The actual transcode + 3× R2 PUT + acceptChallenge call
/// happens in the background — the global [UploadStatusOverlay] shows
/// progress and fires "Posted ✓" when the response lands.
///
/// This is the response-side mirror of [ChallengeMetadataPage]'s
/// background-upload rewrite. Old behavior: user had to stare at a
/// progress bar for 30-90 seconds before they could go back. New
/// behavior: user is back on the challenge in <100ms, the upload
/// finishes silently, and the challenge page auto-refreshes when the
/// new response lands via the [UploadJobManager.onCompleted] stream.
///
/// The page itself only paints for a single frame — long enough to run
/// the post-frame callback that dispatches the job and immediately
/// calls `Navigator.pop(true)`. We keep a small spinner UI as a
/// fallback so a particularly slow first paint doesn't show a blank
/// scaffold.
class SubmitResponseUploadPage extends StatefulWidget {
  /// Local path to the trimmed video produced by VideoTrimPage.
  final String processedSourcePath;

  /// Challenge being responded to.
  final String challengeId;

  const SubmitResponseUploadPage({
    super.key,
    required this.processedSourcePath,
    required this.challengeId,
  });

  @override
  State<SubmitResponseUploadPage> createState() =>
      _SubmitResponseUploadPageState();
}

class _SubmitResponseUploadPageState extends State<SubmitResponseUploadPage>
    with PageTracker<SubmitResponseUploadPage> {
  @override
  String get pageName => 'submit_response_upload_page';

  @override
  Map<String, dynamic> get pageParams => {'challengeId': widget.challengeId};

  // True from the moment we kick off the dispatch until we pop. Used
  // only to ensure we don't dispatch twice if the post-frame callback
  // somehow fires more than once (e.g. a quick rebuild).
  bool _dispatched = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _dispatchAndPop());
  }

  void _dispatchAndPop() {
    if (_dispatched || !mounted) return;
    _dispatched = true;

    final dp = Provider.of<DataProvider>(context, listen: false);
    final responderId = dp.user?.id ?? '';
    if (responderId.isEmpty) {
      _toast('You need to be signed in to submit a response.');
      Navigator.of(context).pop<bool>(false);
      return;
    }

    EventTracker.instance.trackTap(
      target: 'response_dispatch',
      pageName: pageName,
      params: {'challengeId': widget.challengeId},
    );

    // Fire-and-forget — the job survives this page's disposal. The
    // overlay handles all UI; the caller (challenge_detail_page) listens
    // to UploadJobManager.onCompleted to refresh once the new response
    // is actually live.
    UploadJobManager.instance.submitResponse(
      responderId: responderId,
      challengeId: widget.challengeId,
      sourcePath: widget.processedSourcePath,
    );

    // Bump feed refresh so when the user lands back on the feed, it
    // re-fetches as soon as the acceptChallenge API call resolves.
    Provider.of<DataProvider>(context, listen: false).bumpFeedRefresh();

    _toast('Submitting in the background — keep watching.');
    Navigator.of(context).pop<bool>(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // This UI almost never gets seen — the page pops on the very next
    // frame. It exists only so the user doesn't briefly glimpse a blank
    // black scaffold if the post-frame callback is delayed.
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: cs.primary),
            const SizedBox(height: 16),
            const Text(
              'Sending…',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
