import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// Fullscreen reels viewer launched when the user taps a video on the
/// search page. Opens directly on the tapped challenge and lets the user
/// keep swiping vertically through more discovery content (Explore feed)
/// without ever leaving — matches the Instagram pattern where tapping a
/// search-grid thumbnail enters a vertical-scroll viewer.
///
/// All the rich reel UX (battle indicator, opponent swipe, double-tap
/// like, autoplay-on-visible) is provided by SmartReelsFeed itself; this
/// page only adds the back-button overlay needed because we're a pushed
/// route rather than a tab body.
class SearchReelsViewerPage extends StatelessWidget {
  final ChallengeModel seedChallenge;

  const SearchReelsViewerPage({super.key, required this.seedChallenge});

  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final userId = dp.user?.id ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      // No appBar — reels are edge-to-edge. The feed draws the back arrow
      // itself, top left beside the sound button, so the two never
      // overlap.
      body: SmartReelsFeed(
        userId: userId,
        kind: FeedKind.explore,
        seedChallenge: seedChallenge,
        showBack: true,
      ),
    );
  }
}
