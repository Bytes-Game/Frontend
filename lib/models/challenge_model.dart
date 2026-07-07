/// Represents a challenge created by a user.
/// Maps to the Go backend's `Challenge` struct.
class ChallengeModel {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String creatorLeague;
  final String videoUrl;
  /// Multi-bitrate variants keyed by quality label ("480p","720p","1080p").
  /// Empty map means "no variants encoded yet" — fall back to [videoUrl],
  /// which is the canonical/default-quality URL kept for backward compat
  /// with every reader that predates the multi-bitrate feature.
  final Map<String, String> videoVariants;
  /// HLS master manifest URL (.m3u8). Set by the server-side transcode
  /// worker once it has produced the segmented bitrate ladder for this
  /// challenge. When non-empty, the player should prefer this over
  /// [videoUrl] / [videoVariants] — HLS gives sub-500ms time-to-first
  /// frame, mid-stream adaptive bitrate, and trivially-cacheable 2s
  /// segments. Falls back to [videoUrl] when empty (legacy uploads, or
  /// brand-new uploads in the window before the worker has finished).
  ///
  /// The manifest is canonical: it embeds the URLs of all per-quality
  /// sub-manifests + their segments, so the client never needs to know
  /// the segment URL pattern. media_kit handles parsing automatically.
  final String hlsManifestUrl;
  final String? thumbnailUrl;
  final String prefix;
  final String subject;
  final String visibility; // "arena" or "friends"
  final List<String> visibleTo;
  final String status; // "open", "active", "completed"
  final int likes;
  final int views;
  /// Live count of comments on this challenge. Populated by the backend's
  /// populateChallengeCommentCounts at the feed-handler boundary so the
  /// reels right-rail can render the same digit the comment sheet shows.
  /// Defaults to 0 for legacy payloads / endpoints that haven't started
  /// shipping it; readers should treat 0 as "unknown / hide the count".
  final int commentCount;
  final String createdAt;
  final String expiresAt;
  final int responseCount;
  // Content understanding fields
  final String category;          // "comedy","motivation","sports","dance",etc.
  final List<String> emotionTags; // ["happy","intense","inspiring"]
  final String energyLevel;       // "low","medium","high"

  // Top response (a.k.a. "opponent") fields. Populated by the backend's
  // populateTopResponses on every endpoint that may surface this challenge
  // inside the reels viewer (smart feed, explore feed, /search). Empty
  // strings mean "no response yet" — i.e. this challenge is a plain short
  // and the client should NOT render the battle indicator pill.
  /// Stable response ID for the top opponent. Required by the home reels
  /// vote button to call [ApiService.voteChallenge] without first having
  /// to hit the challenge-detail endpoint to look up which response was
  /// chosen as the opponent. Empty when no responses yet.
  final String topResponseId;
  final String topResponseVideoUrl;
  final String topResponseThumbnailUrl;
  final String topResponseUsername;
  final String topResponseLeague;
  /// Multi-bitrate variants for the opponent video (see [videoVariants]).
  /// Empty when the response was uploaded before the multi-bitrate feature
  /// shipped — readers should fall back to [topResponseVideoUrl].
  final Map<String, String> topResponseVideoVariants;
  /// HLS master manifest for the opponent video (see [hlsManifestUrl]).
  /// Empty until the transcode worker finishes the response leg —
  /// readers fall back to [topResponseVideoVariants]/[topResponseVideoUrl].
  final String topResponseHlsManifestUrl;

  ChallengeModel({
  required this.id,
  required this.creatorId,
  required this.creatorUsername,
  required this.creatorLeague,
  required this.videoUrl,
  this.videoVariants = const {},
  this.hlsManifestUrl = '',
  this.thumbnailUrl,
  required this.prefix,
  required this.subject,
  required this.visibility,
  this.visibleTo = const [],
  required this.status,
  required this.likes,
  required this.views,
  this.commentCount = 0,
  required this.createdAt,
  this.expiresAt = '',
  required this.responseCount,
  this.category = 'other',
  this.emotionTags = const [],
  this.energyLevel = 'medium',
  this.topResponseId = '',
  this.topResponseVideoUrl = '',
  this.topResponseThumbnailUrl = '',
  this.topResponseUsername = '',
  this.topResponseLeague = '',
  this.topResponseVideoVariants = const {},
  this.topResponseHlsManifestUrl = '',
  });

  /// Full challenge title from the two-part description.
  String get title => '$prefix $subject';
  
  factory ChallengeModel.fromJson(Map<String, dynamic> json) {
    return ChallengeModel(
      id: json['id'] ??'',
      creatorId: json['creatorId'] ?? '',
      creatorUsername: json['creatorUsername'] ?? '',
      creatorLeague: json['creatorLeague'] ?? 'Unranked',
      videoUrl: json['videoUrl'] ?? '',
      videoVariants: (json['videoVariants'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v?.toString() ?? '')) ??
          const {},
      // Backend marks `hlsManifestUrl` as omitempty — absent means
      // "transcode worker hasn't produced the HLS ladder for this
      // challenge yet (or worker isn't deployed in this env)". Defaults
      // to '' which makes the SmartReelsFeed variant picker fall back
      // to the legacy [videoUrl] / [videoVariants] path.
      hlsManifestUrl: json['hlsManifestUrl']?.toString() ?? '',
      thumbnailUrl: json['thumbnailUrl'],
      prefix: json['prefix'] ?? '',
      subject: json['subject'] ?? '',
      visibility: json['visibility'] ?? 'arena',
      visibleTo: (json['visibleTo'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      status: json['status'] ?? 'open',
      likes: json['likes'] ?? 0,
      views: json['views'] ?? 0,
      commentCount: json['commentCount'] ?? 0,
      createdAt: json['createdAt'] ?? '',
      expiresAt: json['expiresAt'] ?? '',
      responseCount: json['responseCount'] ?? 0,
      category: json['category'] ?? 'other',
      emotionTags: (json['emotionTags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      energyLevel: json['energyLevel'] ?? 'medium',
      // Backend marks these omitempty, so absent keys mean "no response yet".
      // Default to '' which makes ChallengeModel and SmartReelsFeed agree
      // that this challenge should render as a plain short (no opponent UI).
      topResponseId: json['topResponseId'] ?? '',
      topResponseVideoUrl: json['topResponseVideoUrl'] ?? '',
      topResponseThumbnailUrl: json['topResponseThumbnailUrl'] ?? '',
      topResponseUsername: json['topResponseUsername'] ?? '',
      topResponseLeague: json['topResponseLeague'] ?? '',
      topResponseVideoVariants:
          (json['topResponseVideoVariants'] as Map<String, dynamic>?)
                  ?.map((k, v) => MapEntry(k, v?.toString() ?? '')) ??
              const {},
      topResponseHlsManifestUrl:
          json['topResponseHlsManifestUrl']?.toString() ?? '',
    );
  }
}

/// Represents a response to a challenge.
/// Maps to the Go backend's `ChallengeResponse`struct.
class ChallengeResponseModel {
  final String id;
  final String challengeId;
  final String responderId;
  final String responderUsername;
  final String responderLeague;
  final String videoUrl;
  /// Multi-bitrate variants (see [ChallengeModel.videoVariants]). Empty
  /// map ⇒ fall back to [videoUrl].
  final Map<String, String> videoVariants;
  final String? thumbnailUrl;
  final int likes;
  final int views;
  final String createdAt;

  ChallengeResponseModel({
    required this.id,
    required this.challengeId,
    required this.responderId,
    required this.responderUsername,
    required this.responderLeague,
    required this.videoUrl,
    this.videoVariants = const {},
    this.thumbnailUrl,
    required this.likes,
    required this.views,
    required this.createdAt,
  });

  factory ChallengeResponseModel.fromJson(Map<String, dynamic> json) {
    return ChallengeResponseModel(
      id: json['id'] ?? '',
      challengeId: json['challengeId'] ?? '',
      responderId: json['responderId'] ?? '',
      responderUsername: json['responderUsername'] ?? '',
      responderLeague: json['responderLeague'] ?? 'Unranked',
      videoUrl: json['videoUrl'] ?? '',
      videoVariants: (json['videoVariants'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v?.toString() ?? '')) ??
          const {},
      thumbnailUrl: json['thumbnailUrl'],
      likes: json['likes'] ?? 0,
      views: json['views'] ?? 0,
      createdAt: json['createdAt'] ?? '',
    );
  }
}

/// Vote summary for a challenge response.
class VoteSummary {
  final String responseId;
  final String username;
  final int votes;

  VoteSummary({
    required this.responseId,
    required this.username,
    required this.votes,
  });

  factory VoteSummary.fromJson(Map<String, dynamic> json) {
    return VoteSummary(
      responseId: json['responseId'] ?? '',
      username: json['username'] ?? '',
      votes: json['votes'] ?? 0,
    );
  }
}

// (HomeFeedItem retired alongside the post entity — the home reels feed
// now ships challenge-only items via SmartReelsFeed.)