import 'package:myapp/models/music_track.dart';

/// Represents a challenge created by a user.
/// Maps to the Go backend's `Challenge` struct.
class ChallengeModel {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String creatorLeague;
  /// The post's media: the video, or for a photo challenge ([isPhoto]) the
  /// photo. Its answers are always the same kind.
  final String videoUrl;

  /// "photo" for a photo challenge ("who looks better", "which meme is
  /// better"); "video" otherwise, which is also what an older server that
  /// does not say means.
  final String mediaType;

  bool get isPhoto => mediaType == 'photo';

  /// The free song under the video, with the credit its licence asks for;
  /// [topResponseMusic] is the top answer's. Null for none.
  final MusicCredit? music;
  final MusicCredit? topResponseMusic;
  /// Multi-bitrate variants keyed by quality label ("360p","480p","720p",
  /// "720p_hq","1080p").
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

  /// Whether anybody may answer it with their own video. Off makes it a
  /// normal post: no "Accept challenge", and its words are a caption, not
  /// a question. Every post is open unless its owner said otherwise (the
  /// server sends "closedToBattles" only for those).
  ///
  /// Not final: the owner can change it from the battle page, which
  /// updates the post it is showing in place.
  bool openToBattles;
  final int likes;
  final int views;
  /// Live count of comments on this challenge. Populated by the backend's
  /// populateChallengeCommentCounts at the feed-handler boundary so the
  /// reels right-rail can render the same digit the comment sheet shows.
  /// Defaults to 0 for legacy payloads / endpoints that haven't started
  /// shipping it; readers should treat 0 as "unknown / hide the count".
  final int commentCount;

  /// Votes cast, people who shared, people who saved. The server fills these
  /// with the comment count on every video it sends, so every screen shows
  /// the same numbers.
  final int voteCount;
  final int shareCount;
  final int saveCount;
  final String createdAt;
  final String expiresAt;
  final int responseCount;
  // Content understanding fields
  final String category;          // "comedy","motivation","sports","dance",etc.
  final List<String> emotionTags; // ["happy","intense","inspiring"]
  final List<String> tags;        // creator's own words, already normalized server-side
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

  /// The answer's own likes. See _ReelItem.opponentLikes.
  final int topResponseLikes;

  /// Which side of the battle is ahead, as the server counted it when it
  /// sent this: "creator", "answer" (the answer above), or "" when nobody
  /// is ahead yet or it was not counted. The reel opens on that side.
  final String leader;

  /// What the person looking has done to this video, as the server knows
  /// it: liked it, saved it, voted in it (and for whom), liked the answer.
  /// Without these every heart started empty, so a video you had liked came
  /// back unliked — and tapping it took your like away.
  final bool isLiked;
  final bool isSaved;
  final bool hasVoted;
  final String votedFor;
  final bool topResponseLiked;
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
  this.mediaType = 'video',
  this.music,
  this.topResponseMusic,
  this.videoVariants = const {},
  this.hlsManifestUrl = '',
  this.thumbnailUrl,
  required this.prefix,
  required this.subject,
  required this.visibility,
  this.visibleTo = const [],
  required this.status,
  this.openToBattles = true,
  required this.likes,
  required this.views,
  this.commentCount = 0,
  this.voteCount = 0,
  this.shareCount = 0,
  this.saveCount = 0,
  required this.createdAt,
  this.expiresAt = '',
  required this.responseCount,
  /// Empty means the server did not say. NOT 'other' — the backend reads
  /// 'other' as "nobody said" too, so defaulting to it here turns a silence
  /// into what looks like an answer. See ContentCategories in
  /// config/constants.dart.
  this.category = '',
  this.emotionTags = const [],
  this.tags = const [],
  this.energyLevel = 'medium',
  this.topResponseId = '',
  this.topResponseVideoUrl = '',
  this.topResponseThumbnailUrl = '',
  this.topResponseUsername = '',
  this.topResponseLeague = '',
  this.topResponseLikes = 0,
  this.leader = '',
  this.isLiked = false,
  this.isSaved = false,
  this.hasVoted = false,
  this.votedFor = '',
  this.topResponseLiked = false,
  this.topResponseVideoVariants = const {},
  this.topResponseHlsManifestUrl = '',
  });

  /// Full challenge title from the two-part description.
  String get title => '$prefix $subject'.trim();

  /// The title as people read it. A challenge is a question ("Who is
  /// better at pranks?"); a normal post has no opener, and its caption is
  /// not one.
  String get question {
    final t = title;
    if (t.isEmpty || prefix.trim().isEmpty || t.endsWith('?')) return t;
    return '$t?';
  }

  factory ChallengeModel.fromJson(Map<String, dynamic> json) {
    return ChallengeModel(
      id: json['id'] ??'',
      creatorId: json['creatorId'] ?? '',
      creatorUsername: json['creatorUsername'] ?? '',
      creatorLeague: json['creatorLeague'] ?? 'Unranked',
      videoUrl: json['videoUrl'] ?? '',
      mediaType: json['mediaType'] == 'photo' ? 'photo' : 'video',
      music: MusicCredit.fromJson(json['music']),
      topResponseMusic: MusicCredit.fromJson(json['topResponseMusic']),
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
      openToBattles: json['closedToBattles'] != true,
      likes: json['likes'] ?? 0,
      views: json['views'] ?? 0,
      commentCount: json['commentCount'] ?? 0,
      voteCount: (json['voteCount'] as num?)?.toInt() ?? 0,
      shareCount: (json['shareCount'] as num?)?.toInt() ?? 0,
      saveCount: (json['saveCount'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] ?? '',
      expiresAt: json['expiresAt'] ?? '',
      responseCount: json['responseCount'] ?? 0,
      category: json['category'] ?? '',
      emotionTags: (json['emotionTags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      tags: (json['tags'] as List<dynamic>?)
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
      topResponseLikes: json['topResponseLikes'] as int? ?? 0,
      leader: json['leader'] as String? ?? '',
      isLiked: json['isLiked'] == true,
      isSaved: json['isSaved'] == true,
      hasVoted: json['hasVoted'] == true,
      votedFor: json['votedFor']?.toString() ?? '',
      topResponseLiked: json['topResponseLiked'] == true,
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