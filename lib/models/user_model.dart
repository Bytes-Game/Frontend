/// Represents a user profile.
/// Maps to the JSON returned by the Go backend's `User` struct.
class UserModel {
  final String id;
  final String username;
  final String fullName;
  final int wins;
  final int losses;
  final String league;
  final int followersCount;
  final int followingCount;
  final List<String> followingList;
  /// Profile bio. Empty string when the user hasn't set one — own
  /// profile renders an "Add a bio" CTA on empty; other profiles show
  /// nothing. Maps to backend `bio` (omitempty).
  final String bio;
  /// Account visibility — "public" (default) or "friends". Drives the
  /// "private account" lock icon next to the username and (server-side)
  /// gates non-follower access to the user's content.
  final String visibility;
  /// True iff the user has finished TOTP 2FA enrollment. Used by the
  /// settings sheet to flip the "Two-step verification" row to "On".
  final bool twoFactorEnabled;
  /// User-level settings — theme preference, language, etc. Free-form
  /// map keyed by feature; consumers should treat unknown keys as
  /// defaults rather than throwing. omitempty on the wire so the
  /// no-settings case is just a missing field, not a `null` literal.
  final Map<String, dynamic> settings;

  UserModel({
    required this.id,
    required this.username,
    this.fullName = '',
    required this.wins,
    required this.losses,
    this.league = 'Unranked',
    required this.followersCount,
    required this.followingCount,
    this.followingList = const [],
    this.bio = '',
    this.visibility = 'public',
    this.twoFactorEnabled = false,
    this.settings = const {},
  });

  /// Build a copy with selected fields swapped. Used by callers that
  /// receive the updated user from a PATCH /users/{id} round-trip and
  /// want to merge it into in-memory state without reconstructing
  /// every field manually.
  UserModel copyWith({
    String? id,
    String? username,
    String? fullName,
    int? wins,
    int? losses,
    String? league,
    int? followersCount,
    int? followingCount,
    List<String>? followingList,
    String? bio,
    String? visibility,
    bool? twoFactorEnabled,
    Map<String, dynamic>? settings,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      fullName: fullName ?? this.fullName,
      wins: wins ?? this.wins,
      losses: losses ?? this.losses,
      league: league ?? this.league,
      followersCount: followersCount ?? this.followersCount,
      followingCount: followingCount ?? this.followingCount,
      followingList: followingList ?? this.followingList,
      bio: bio ?? this.bio,
      visibility: visibility ?? this.visibility,
      twoFactorEnabled: twoFactorEnabled ?? this.twoFactorEnabled,
      settings: settings ?? this.settings,
    );
  }

  /// Parse from backend JSON.
  /// Backend sends `followers` (int) and `followingList` (array of IDs).
  factory UserModel.fromJson(Map<String, dynamic> json){
    final list =
        (json['followingList'] as List<dynamic>?)?.cast<String>() ?? [];
    return UserModel(
      id: json['id'] ?? '',
      username: json['username'] ?? '',
      fullName: json['fullName'] ?? '',
      wins: json['wins'] ?? 0,
      losses: json['losses'] ?? 0 ,
      league: json['league'] ?? 'Unranked',
      followersCount: json['followers'] ?? 0,
      followingCount: list.length,
      followingList: list,
      bio: (json['bio'] as String?) ?? '',
      visibility: (json['visibility'] as String?) ?? 'public',
      twoFactorEnabled: json['twoFactorEnabled'] == true,
      settings: (json['settings'] as Map<String, dynamic>?) ?? const {},
      );
  }
}