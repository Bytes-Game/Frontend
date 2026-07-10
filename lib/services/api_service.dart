import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:myapp/config/constants.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/models/challenge_model.dart';

/// Thin wrapper over package:http that injects the session bearer token (held
/// in [ApiService.authToken]) into every backend request. Introduced so the
/// ~60 call sites in [ApiService] don't each have to thread the Authorization
/// header through by hand. Direct-to-R2 uploads (media_upload_service)
/// deliberately do NOT go through this — they authenticate to object storage
/// with a presigned URL, not our token.
class _AuthHttp {
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) =>
      http.get(url, headers: _merge(headers));

  Future<http.Response> post(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.post(url, headers: _merge(headers), body: body, encoding: encoding);

  Future<http.Response> patch(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.patch(url, headers: _merge(headers), body: body, encoding: encoding);

  Future<http.Response> delete(Uri url,
          {Map<String, String>? headers, Object? body, Encoding? encoding}) =>
      http.delete(url, headers: _merge(headers), body: body, encoding: encoding);

  Map<String, String> _merge(Map<String, String>? headers) {
    final h = <String, String>{...?headers};
    final token = ApiService.authToken;
    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    return h;
  }
}

final _authHttp = _AuthHttp();

/// Tri-state result for [ApiService.updateUserProfile]. Lets callers
/// distinguish a no-op success (server returned 200 with `updated:
/// false`, no fresh user payload) from a real failure that should
/// surface to the user. Previously the API returned `UserModel?` and
/// collapsed those two cases — a successful no-op showed the user a
/// generic "Could not save" toast.
class UpdateProfileResult {
  final bool success;
  /// Fresh user object from the server when it sent one. Null when
  /// the server returned 200 with no body, or `{"updated": false}`,
  /// or when the request failed.
  final UserModel? user;
  /// Server-supplied error message (or exception text) when [success]
  /// is false. Used by EditProfilePage to show "Bio too long" / etc.
  /// rather than a generic failure toast.
  final String? error;
  const UpdateProfileResult({
    required this.success,
    this.user,
    this.error,
  });
}

/// Centralised HTTP client. Every REST call goes through here so the
/// network layer is in one place (separation of concerns).
///
/// All methods are static - no state is held. Providers call these
/// methods and manage the returned data in their own state.
class ApiService {
  ApiService._();
  static const _base = AppConstants.apiBaseUrl;

  /// Session bearer token captured on [login]. Attached to every backend
  /// request by [_AuthHttp]. Held in memory only — like the rest of the auth
  /// state, it does not survive a cold start, so the user re-logs in on
  /// relaunch (unchanged from before tokens existed). Cleared by [clearAuth].
  static String? authToken;

  /// Drop the session token (call on logout).
  static void clearAuth() {
    authToken = null;
  }

  /// POST /signup → same shape as /login ({user, token, allUsers}).
  /// Returns null on failure; [error] via the second element when the
  /// server gave a usable message (taken username, weak password).
  static Future<Map<String, dynamic>?> signup(
      String username, String password) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/signup'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );
      if (res.statusCode == 201) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        authToken = data['token'] as String?;
        return data;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /signup/available — live availability for the signup form.
  static Future<bool> isUsernameAvailable(String username) async {
    try {
      final res = await _authHttp.get(Uri.parse(
          '$_base/signup/available?username=${Uri.encodeQueryComponent(username)}'));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        return body['available'] == true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/auth/refresh — mint a fresh token for the current
  /// session. Doubles as session VALIDATION on restore: a 401 means the
  /// stored token is dead and the caller should clear the session.
  static Future<String?> refreshToken() async {
    try {
      final res =
          await _authHttp.post(Uri.parse('$_base/api/v1/auth/refresh'));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        final fresh = body['token'] as String?;
        if (fresh != null && fresh.isNotEmpty) {
          authToken = fresh;
          return fresh;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/profile/interests — onboarding interest picker.
  static Future<bool> seedInterests(List<String> categories) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/profile/interests'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'categories': categories}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // —— Auth —————————————————————————————————————————————————————————————

  /// POST /login →{ user:{...}, token: "...", allUsers: [...] }
  static Future<Map<String, dynamic>?> login(
      String username, String password) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        // Capture the session token so every subsequent request is authorized.
        authToken = data['token'] as String?;
        return data;
      }
      return null;
      } catch (_) {
      return null;
    }
  }

  // —— Recommended Feed ————————————————————————————————————————————

  /// GET /api/v1/feed/recommended?userId=X&page=Y&limit=Z
  /// Returns a ranked mix of challenges and posts personalized for the user.
  static Future<Map<String, dynamic>> getRecommendedFeed(
      String userId, {int page = 1, int limit = 20}) async {
    try {
      final res = await _authHttp.get(Uri.parse(
        '$_base/api/v1/feed/recommended?userId=$userId&page=$page&limit=$limit',
      ));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return {'items': [], 'page': page, 'hasMore': false};
    } catch (_) {
      return {'items': [], 'page': page, 'hasMore': false};
    }
  }

  /// GET /api/v1/feed/following?userId=X&page=Y&limit=Z
  /// Returns ranked content only from users the person follows.
  static Future<Map<String, dynamic>> getFollowingFeed(
      String userId, {int page = 1, int limit = 20}) async {
    try {
      final res = await _authHttp.get(Uri.parse(
        '$_base/api/v1/feed/following?userId=$userId&page=$page&limit=$limit',
      ));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return {'items': [], 'page': page, 'hasMore': false};
    } catch (_) {
      return {'items': [], 'page': page, 'hasMore': false};
    }
  }

  // —— Users —————————————————————————————————————————————————————————
    
  /// GET /api/v1/users?page=&limit= → one bounded page of users.
  ///
  /// The backend caps `limit` at 100. This is intentionally NOT the whole
  /// roster — loading every user (the old behaviour, on every login) doesn't
  /// scale. Surfaces that need a specific user resolve it via
  /// [getUserByUsername]; follow lists use [getFollowers] / [getFollowing].
  static Future<List<UserModel>> getAllUsers({int page = 1, int limit = 50}) async {
    try {
      final res = await _authHttp.get(
          Uri.parse('$_base/api/v1/users?page=$page&limit=$limit'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => UserModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /api/v1/users/{username} → a single user, or null if not found.
  /// Used to resolve a username to its id before hitting id-keyed endpoints.
  static Future<UserModel?> getUserByUsername(String username) async {
    try {
      final res = await _authHttp.get(
          Uri.parse('$_base/api/v1/users/${Uri.encodeComponent(username)}'));
      if (res.statusCode == 200) {
        return UserModel.fromJson(json.decode(res.body) as Map<String, dynamic>);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/users/{id}/followers?page=&limit= → accounts that follow {id}.
  static Future<List<UserModel>> getFollowers(String userId,
      {int page = 1, int limit = 30}) async {
    try {
      final res = await _authHttp.get(Uri.parse(
          '$_base/api/v1/users/$userId/followers?page=$page&limit=$limit'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => UserModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /api/v1/users/{id}/following?page=&limit= → accounts {id} follows.
  static Future<List<UserModel>> getFollowing(String userId,
      {int page = 1, int limit = 30}) async {
    try {
      final res = await _authHttp.get(Uri.parse(
          '$_base/api/v1/users/$userId/following?page=$page&limit=$limit'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => UserModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /search?q=... → ranked list of matching users
  static Future<List<UserModel>> searchUsers(String query) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/search?q=${Uri.encodeComponent(query)}'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final list = data['results'] as List? ?? [];
        return list.map((j)=> UserModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // —— Social —————————————————————————————————————————————————————————

  /// POST/api/v1/follow
  static Future<bool> followUser({
    required String followerId,
    required String followerUsername,
    required String followingId,
    required String followingUsername,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/follow'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'followerId': followerId,
          'followerUsername':followerUsername,
          'followingId': followingId,
          'followingUsername': followingUsername,
          'clientTimestamp': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/unfollow
  static Future<bool> unfollowUser({
    required String unfollowerId,
    required String unfollowerUsername,
    required String unfollowedId,
    required String unfollowedUsername,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/unfollow'),
        headers:{'Content-Type':'application/json'},
        body: json.encode({
          'unfollowerId': unfollowerId,
          'unfollowerUsername': unfollowerUsername,
          'unfollowedId': unfollowedId,
          'unfollowedUsername': unfollowedUsername,
          'clientTimestamp':DateTime.now().toUtc().toIso8601String(),
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // —— Legacy posts feed retired ——————————————————————————————————
  //
  // The old `/api/v1/feed`, `/api/v1/posts/{userId}`, `/api/v1/like`, and
  // `/api/v1/comments` endpoints were post-centric. Posts as a distinct
  // entity have been removed from the product. The home reels feed now
  // pulls challenges (battles + unaccepted-as-shorts) via the SmartReels
  // endpoints (getSmartFeed / getFollowingFeedV2 / getExploreFeed below),
  // and per-challenge comments use getChallengeComments / addChallengeComment.



  // (Legacy /api/v1/comments POST and /api/v1/home retired alongside posts.)


  /// GET /api/v1/challenges/arena -> all challenges as a shorts feed.
  /// Only fetches full details (responses) for battles (responseCount > 0)
  /// to avoid flooding the backend with 35+ concurrent requests.
  static Future<List<Map<String, dynamic>>> getChallengesFeed() async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/arena'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        final challenges =
            data.map((j) => ChallengeModel.fromJson(j)).toList();

        // Only fetch details for battles (have responses) — skip shorts
        final results = <Map<String, dynamic>>[];
        final battleFutures = <int, Future<Map<String, dynamic>?>>{};
        for (int i = 0; i < challenges.length; i++) {
          if (challenges[i].responseCount > 0) {
            battleFutures[i] = getChallengeDetail(challenges[i].id);
          }
        }
        final battleResults = <int, Map<String, dynamic>?>{};
        for (final entry in battleFutures.entries) {
          battleResults[entry.key] = await entry.value;
        }

        for (int i = 0; i < challenges.length; i++) {
          if (battleResults.containsKey(i) && battleResults[i] != null) {
            results.add(battleResults[i]!);
          } else {
            results.add({
              'challenge': challenges[i],
              'responses': <ChallengeResponseModel>[],
              'votes': <VoteSummary>[],
            });
          }
        }
        return results;
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// POST /api/v1/challenges/dislike -> dislike a challenge
  static Future<bool> dislikeChallenge({
    required String challengeId,
    required String userId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/dislike'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'userId': userId,
        }),
      );
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  // --- Challenges ------------------------------------------------------

  /// GET /api/v1/challenges/arena -> list of open arena challenges
  static Future<List<ChallengeModel>> getArenaChallenges() async {
    try {
      final res= await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/arena'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => ChallengeModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
      }
  }

  /// Returns challenges authored by [userId].
  ///
  /// No dedicated backend endpoint exists for this yet (the arena/explore
  /// feeds don't filter by creator), so we fetch the arena set and filter
  /// client-side. That's fine at our current content volume — arena
  /// returns at most a few hundred items — but it's the FIRST thing to
  /// migrate to a backend `/users/{id}/challenges` route once content
  /// scales. Listed here as a TODO so it's not invisible later:
  ///
  /// TODO(scale): replace with `GET /api/v1/users/{userId}/challenges`
  /// once the backend ships that route. The server can index by creatorId
  /// and avoid shipping the full arena to every profile open.
  ///
  /// Returns newest-first by createdAt where available, otherwise the
  /// arena's intrinsic order (which the backend already sorts roughly
  /// by recency).
  static Future<List<ChallengeModel>> getUserChallenges(
      String userId) async {
    if (userId.isEmpty) return const [];
    final all = await getArenaChallenges();
    final mine = all.where((c) => c.creatorId == userId).toList();
    return mine;
  }

  /// GET /api/v1/challenges/friends?userld=..._ friends-only challenges
  static Future<List<ChallengeModel>> getFriendsChallenges(
      String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/friends?userId=$userId'),
      );
      if (res.statusCode ==200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => ChallengeModel.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /api/v1/challenges/{id} -> challenge + responses
  static Future<Map<String, dynamic>?> getChallengeDetail(String id) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/$id'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        return {
          'challenge': ChallengeModel.fromJson(data['challenge']),
          'responses': (data['responses'] as List? ?? [])
              .map((j) => ChallengeResponseModel.fromJson(j))
              .toList(),
          'votes': (data['votes'] as List? ?? [])
              .map((j) => VoteSummary.fromJson(j))
              .toList(),
        };
      }
      return null;
    } catch(_) {
      return null;
    }
  }

  /// POST /api/v1/challenges -> create a new challenge
  /// POST /api/v1/media/presign — mint AWS SigV4 PUT URLs for one upload's
  /// variants (e.g. 480p, 720p, 1080p video + thumbnail). The mobile client
  /// then PUTs each file directly to R2; the backend never touches the
  /// bytes, which keeps Render's free-tier RAM/CPU budget out of the
  /// upload path.
  ///
  /// `items` shape: `[{kind:"video", variant:"720p", contentType:"video/mp4"}]`.
  ///
  /// Returns a parsed map matching the server's `presignResponse`:
  /// ```
  /// {
  ///   "uploadId": "32-char hex",
  ///   "expiresIn": 600,
  ///   "items": [
  ///     {"kind":"video","variant":"720p","contentType":"video/mp4",
  ///      "key":"u/<userId>/<uploadId>/720p.mp4",
  ///      "uploadUrl":"https://...?X-Amz-Signature=...",
  ///      "publicUrl":"https://cdn.r2.dev/..."},
  ///     ...
  ///   ]
  /// }
  /// ```
  /// Returns `null` on any non-2xx so callers can show a generic
  /// "couldn't reach storage, try again" toast without parsing errors.
  static Future<Map<String, dynamic>?> presignMediaUpload({
    required String userId,
    required List<Map<String, String>> items,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/media/presign'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'items': items,
        }),
      );
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<ChallengeModel?> createChallenge({
    required String creatorId,
    required String videoUrl,
    String thumbnailUrl = '',
    required String prefix,
    required String subject,
    required String visibility,
    List<String> visibleTo = const [],
    String category = 'other',
    List<String> emotionTags = const [],
    // Multi-bitrate map (480p/720p/1080p → public R2 URL). Optional —
    // legacy callers that only pasted one URL still work because the
    // backend treats an empty/missing map as "no variants encoded yet"
    // and falls back to videoUrl. New flows ALWAYS send a map so the
    // adaptive player has alternatives.
    Map<String, String> videoVariants = const {},
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges'),
        headers: {'Content-Type': 'application/json'},
        // energyLevel intentionally omitted from the payload — the
        // server derives it from category + subject + caption (see
        // energy_classifier.go) so the picker on the metadata form
        // could be retired. Older builds that still ship the field
        // keep working because the backend honors an explicit value
        // when present.
        body: json.encode({
          'creatorId': creatorId,
          'videoUrl': videoUrl,
          'videoVariants': videoVariants,
          'thumbnailUrl': thumbnailUrl,
          'prefix': prefix,
          'subject': subject,
          'visibility': visibility,
          'visibleTo': visibleTo,
          'category': category,
          'emotionTags': emotionTags,
        }),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return ChallengeModel.fromJson(json.decode(res.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // ─── Challenge-creation autocomplete ────────────────────────────────

  /// GET /api/v1/suggest/challenge-prefix?q=&limit=
  ///
  /// Returns up to [limit] prefix templates ("Who is better at",
  /// "Who has the cleanest", …) matching [query]. Empty query returns
  /// the curated default ordering.
  ///
  /// Resilient by design — the metadata form's autocomplete falls back
  /// to its locally-shipped suggestion list when this call fails so a
  /// flaky network doesn't block posting.
  static Future<List<String>> suggestChallengePrefix({
    required String query,
    int limit = 8,
  }) async {
    try {
      final uri = Uri.parse(
        '$_base/api/v1/suggest/challenge-prefix'
        '?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      final res = await _authHttp.get(uri);
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body) as Map<String, dynamic>;
        return (decoded['items'] as List?)?.cast<String>() ?? const [];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// GET /api/v1/suggest/challenge-subject?q=&userId=&limit=
  ///
  /// Returns ranked subject suggestions (`{subject, usageCount}` maps).
  /// Ranking blends Meilisearch typo-tolerance, global popularity, and
  /// (when [userId] is supplied) per-category affinity from the
  /// recommender's user_profiles table.
  static Future<List<Map<String, dynamic>>> suggestChallengeSubject({
    required String query,
    String userId = '',
    int limit = 10,
  }) async {
    try {
      final q = StringBuffer(
        '$_base/api/v1/suggest/challenge-subject'
        '?q=${Uri.encodeQueryComponent(query)}&limit=$limit',
      );
      if (userId.isNotEmpty) {
        q.write('&userId=${Uri.encodeQueryComponent(userId)}');
      }
      final res = await _authHttp.get(Uri.parse(q.toString()));
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body) as Map<String, dynamic>;
        return (decoded['items'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const [];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// POST /api/v1/challenges/accept -> accept a challenge with response video
  ///
  /// [videoVariants] is the optional `{quality: url}` map produced by the
  /// device-side transcoder (480/720/1080). When empty the backend falls
  /// back to [videoUrl] for every viewer regardless of network — fine for
  /// quick replies but means cellular users will pull the canonical bitrate.
  static Future<ChallengeResponseModel?> acceptChallenge({
    required String challengeId,
    required String responderId,
    required String videoUrl,
    Map<String, String> videoVariants = const {},
    String thumbnailUrl = '',
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/accept'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'responderId': responderId,
          'videoUrl': videoUrl,
          if (videoVariants.isNotEmpty) 'videoVariants': videoVariants,
          'thumbnailUrl': thumbnailUrl,
        }),
      );
      if (res.statusCode == 200 || res.statusCode == 201) {
        return ChallengeResponseModel.fromJson(json.decode(res.body));
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/challenges/like -> toggle like on a challenge
  static Future<Map<String, dynamic>?> likeChallenge({
    required String challengeId,
    required String userId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/like'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'userId': userId,
        }),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/challenges/delete -> delete a challenge the caller created.
  ///
  /// Returns true on 200 (server confirmed the row + cascaded children
  /// are gone), false on any other status (403 = not your challenge,
  /// 404 = already deleted / unknown id, 5xx = server problem).
  /// Caller is expected to refresh the UI on `true` and surface the
  /// failure case as a toast on `false`.
  static Future<bool> deleteChallenge({
    required String challengeId,
    required String userId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/delete'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'userId': userId,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/challenges/vote -> vote for a challenge response
  static Future<Map<String, dynamic>?> voteChallenge({
    required String challengeId,
    required String responseId,
    required String voterId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/vote'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'responseId': responseId,
          'voterId': voterId,
        }),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/challenges/{id}/votes -> vote results
  static Future<List<VoteSummary>> getVoteResults(String challengeId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/$challengeId/votes'),
      );
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List;
        return data.map((j) => VoteSummary.fromJson(j)).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // —— Watch Events ————————————————————————————————————————————————

  /// POST /api/v1/watch -> record a watch event
  static Future<bool> recordWatchEvent({
    required String userId,
    required String contentId,
    required String contentType,
    required int watchTime,
    bool completed = false,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/watch'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'contentId': contentId,
          'contentType': contentType,
          'watchTime': watchTime,
          'completed': completed,
        }),
      );
      return res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  // —— Smart Feed (Psychology Engine v2) ——————————————————————————

  /// GET /api/v1/feed/smart — psychology-based personalized feed.
  /// Uses dopamine budget, ego state, resistance detection, slot composition.
  static Future<Map<String, dynamic>> getSmartFeed(
      String userId,
      {int page = 1,
      int limit = 20,
      String sessionId = '',
      bool refresh = false}) async {
    try {
      var url = '$_base/api/v1/feed/smart?userId=$userId&page=$page&limit=$limit';
      if (sessionId.isNotEmpty) url += '&sessionId=$sessionId';
      // Send the device's UTC offset (minutes east of UTC) so the backend's
      // hour-of-day routing buckets by the user's LOCAL hour rather than the
      // server's timezone. Absent → backend treats it as UTC (no behaviour change).
      url += '&tzOffset=${DateTime.now().timeZoneOffset.inMinutes}';
      // Pull-to-refresh signal — the backend drops the seen-content filter
      // and clears session dedup so the new feed isn't biased back toward
      // the items the user just swiped past.
      if (refresh) url += '&refresh=true';
      final res = await _authHttp.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        // Normalize: backend cold path returns items:null, warm path
        // returns items:[]. Treat both as "empty" with the same shape so
        // the client doesn't have to distinguish.
        if (body['items'] == null) body['items'] = [];
        body['_ok'] = true;
        return body;
      }
      return {
        'items': [],
        'page': page,
        'hasMore': false,
        '_ok': false,
        '_error': 'Server returned ${res.statusCode}. Try again in a moment.',
      };
    } catch (e) {
      return {
        'items': [],
        'page': page,
        'hasMore': false,
        '_ok': false,
        '_error': 'Cannot reach server: ${e.runtimeType}. Check your connection.',
      };
    }
  }

  /// GET /api/v1/feed/following/v2 — chronological feed from followed users.
  /// Pure chronological. NO algorithm: just newest content from people the
  /// user follows. Returns the same JSON shape as the smart and explore feeds
  /// so the SmartReelsFeed widget can parse all three with one parser.
  static Future<Map<String, dynamic>> getFollowingFeedV2(
      String userId, {int page = 1, int limit = 20}) async {
    try {
      final res = await _authHttp.get(Uri.parse(
        '$_base/api/v1/feed/following/v2?userId=$userId&page=$page&limit=$limit',
      )).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        if (body['items'] == null) body['items'] = [];
        body['_ok'] = true;
        return body;
      }
      return {
        'items': [], 'page': page, 'hasMore': false,
        '_ok': false, '_error': 'Server returned ${res.statusCode}.',
      };
    } catch (e) {
      return {
        'items': [], 'page': page, 'hasMore': false,
        '_ok': false, '_error': 'Cannot reach server: ${e.runtimeType}',
      };
    }
  }

  /// GET /api/v1/feed/explore but flattened to challenges only.
  /// Used by the search page's empty-state grid (Instagram-style "below the
  /// search bar" discovery). Same algorithm as the Explore tab — we just
  /// drop non-video items (e.g. suggested-account cards) so the surface
  /// stays a pure video grid. No new backend algorithm required.
  static Future<List<ChallengeModel>> getExploreChallenges(
      String userId, {int page = 1, int limit = 30, bool refresh = false}) async {
    final body = await getExploreFeed(userId, page: page, limit: limit, refresh: refresh);
    final items = (body['items'] as List? ?? []);
    final out = <ChallengeModel>[];
    for (final raw in items) {
      if (raw is! Map<String, dynamic>) continue;
      // HomeFeedItem.type == "challenge" carries a populated .challenge.
      // Skip suggestedAccounts cards and any future non-video variants.
      if (raw['type'] != 'challenge') continue;
      final ch = raw['challenge'];
      if (ch is! Map<String, dynamic>) continue;
      // Defensive: don't surface a tile that has no playable video, since
      // the whole point of this surface is preview-on-scroll.
      if ((ch['videoUrl'] ?? '').toString().isEmpty) continue;
      out.add(ChallengeModel.fromJson(ch));
    }
    return out;
  }

  /// GET /api/v1/feed/explore — discovery-first, non-personalized feed.
  /// Different algorithm from "For You": ignores personal embeddings, LTR,
  /// bandit, hour-routing. Surfaces realtime-trending + recent content with
  /// aggressive diversity (MMR lambda=0.40) and always sprinkles wildcards.
  /// Used for the "Explore" tab.
  static Future<Map<String, dynamic>> getExploreFeed(
      String userId, {int page = 1, int limit = 20, bool refresh = false}) async {
    try {
      var url = '$_base/api/v1/feed/explore?userId=$userId&page=$page&limit=$limit';
      // Pull-to-refresh signal — backend clears the seen-content filter,
      // resets session dedup, jitters scores, and demotes the previous
      // refresh's top-3 so the head of the feed reliably changes.
      if (refresh) url += '&refresh=true';
      final res = await _authHttp.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        if (body['items'] == null) body['items'] = [];
        body['_ok'] = true;
        return body;
      }
      return {
        'items': [], 'page': page, 'hasMore': false,
        '_ok': false, '_error': 'Server returned ${res.statusCode}.',
      };
    } catch (e) {
      return {
        'items': [], 'page': page, 'hasMore': false,
        '_ok': false, '_error': 'Cannot reach server: ${e.runtimeType}',
      };
    }
  }

  // —— Event Tracking ————————————————————————————————————————————

  /// POST /api/v1/events/batch — send batched user interaction events.
  static Future<bool> trackEventsBatch(List<Map<String, dynamic>> events) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/events/batch'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'events': events}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/v1/categories — available content categories, emotions, energy levels.
  static Future<Map<String, dynamic>> getCategories() async {
    try {
      final res = await _authHttp.get(Uri.parse('$_base/api/v1/categories'));
      if (res.statusCode == 200) return json.decode(res.body);
      return {'categories': [], 'emotionTags': [], 'energyLevels': []};
    } catch (_) {
      return {'categories': [], 'emotionTags': [], 'energyLevels': []};
    }
  }

  /// GET /api/v1/profile — get computed user personality profile.
  static Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/profile?userId=$userId'),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  // —— Reports ————————————————————————————————————————————————————

  // —— Admin ————————————————————————————————————————————————————

  /// POST /api/v1/admin/reseed -> drop all data and reseed
  static Future<bool> reseedDatabase() async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/admin/reseed'),
        headers: {'Content-Type': 'application/json'},
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // —— Reports ————————————————————————————————————————————————————

  /// POST /api/v1/report -> report content or user
  static Future<bool> reportContent({
    required String reporterId,
    required String targetId,
    required String targetType,
    required String reason,
    String description = '',
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/report'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'reporterId': reporterId,
          'targetId': targetId,
          'targetType': targetType,
          'reason': reason,
          'description': description,
        }),
      );
      return res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  // —— Challenge Comments ——————————————————————————————————————

  /// GET /api/v1/challenges/{id}/comments
  static Future<List<Map<String, dynamic>>> getChallengeComments(
      String challengeId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/challenges/$challengeId/comments'),
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// POST /api/v1/challenges/comments
  static Future<Map<String, dynamic>?> addChallengeComment({
    required String challengeId,
    required String userId,
    required String username,
    required String text,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/challenges/comments'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'challengeId': challengeId,
          'userId': userId,
          'username': username,
          'text': text,
        }),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  // —— Chat ————————————————————————————————————————————————————

  /// GET /api/v1/chat/conversations/{userId}
  static Future<List<Map<String, dynamic>>> getConversations(
      String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/chat/conversations/$userId'),
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /api/v1/chat/messages/{userId}/{otherUserId}
  static Future<List<Map<String, dynamic>>> getChatMessages(
      String userId, String otherUserId,
      {int limit = 50, int offset = 0}) async {
    try {
      final res = await _authHttp.get(
        Uri.parse(
            '$_base/api/v1/chat/messages/$userId/$otherUserId?limit=$limit&offset=$offset'),
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// POST /api/v1/chat/send
  static Future<Map<String, dynamic>?> sendChatMessage({
    required String senderId,
    required String receiverId,
    required String message,
    String? replyToId,
  }) async {
    try {
      final body = <String, dynamic>{
        'senderId': senderId,
        'receiverId': receiverId,
        'message': message,
      };
      if (replyToId != null && replyToId.isNotEmpty) {
        body['replyToId'] = replyToId;
      }
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/chat/send'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/chat/read
  static Future<void> markChatRead(String senderId, String receiverId) async {
    try {
      await _authHttp.post(
        Uri.parse('$_base/api/v1/chat/read'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'senderId': senderId,
          'receiverId': receiverId,
        }),
      );
    } catch (_) {}
  }

  /// POST /api/v1/chat/edit
  static Future<bool> editChatMessage({
    required String messageId,
    required String senderId,
    required String text,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/chat/edit'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'messageId': messageId,
          'senderId': senderId,
          'text': text,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/chat/delete
  static Future<bool> deleteChatMessage({
    required String messageId,
    required String senderId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/chat/delete'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'messageId': messageId,
          'senderId': senderId,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/chat/forward
  static Future<Map<String, dynamic>?> forwardChatMessage({
    required String messageId,
    required String senderId,
    required String receiverId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/chat/forward'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'messageId': messageId,
          'senderId': senderId,
          'receiverId': receiverId,
        }),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/chat/online/{username}
  static Future<Map<String, dynamic>> getUserOnlineStatus(
      String username) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/chat/online/$username'),
      );
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return {'online': false, 'lastSeen': ''};
    } catch (_) {
      return {'online': false, 'lastSeen': ''};
    }
  }

  // —— Search ————————————————————————————————————————————————————

  /// GET /search?q=...&type=all|accounts|battles|shorts[&userId=X]
  ///
  /// Returns the multi-section response shape:
  ///   {
  ///     "accounts":   [...User],          // ranked users
  ///     "battles":    [...Challenge],     // challenges with responseCount > 0
  ///     "shorts":     [...Challenge],     // challenges with responseCount = 0
  ///     "challenges": [...battles+shorts],// legacy merged list
  ///     "users":      [...accounts]       // legacy alias
  ///   }
  ///
  /// Passing [userId] enables server-side personalization (boosts results in
  /// the user's preferred categories, surfaces FoF accounts higher, etc.).
  static Future<Map<String, dynamic>> searchAll(
    String query, {
    String type = 'all',
    String userId = '',
  }) async {
    try {
      final params = <String, String>{
        'q': query,
        'type': type,
      };
      if (userId.isNotEmpty) {
        params['userId'] = userId;
      }
      final uri = Uri.parse('$_base/search').replace(queryParameters: params);
      final res = await _authHttp.get(uri);
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return _emptySearchResponse();
    } catch (_) {
      return _emptySearchResponse();
    }
  }

  /// POST /api/v1/media/multipart — presigned S3 multipart operations
  /// (init/part/complete/abort). Body shape per media_multipart.go.
  static Future<Map<String, dynamic>?> mediaMultipart(
      Map<String, dynamic> body) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/media/multipart'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      );
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/search/recent — the caller's own recent queries (the
  /// same list the For You ranker's search-affinity signal reads).
  static Future<List<String>> getRecentSearches() async {
    try {
      final res = await _authHttp.get(Uri.parse('$_base/api/v1/search/recent'));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        return (body['recent'] as List? ?? []).map((e) => e.toString()).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// GET /api/v1/search/trending — the platform's current top queries.
  static Future<List<String>> getTrendingSearches() async {
    try {
      final res = await _authHttp.get(Uri.parse('$_base/api/v1/search/trending'));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        return (body['trending'] as List? ?? []).map((e) => e.toString()).toList();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Empty search shape — every section returns an empty list so callers
  /// don't need null-checks on individual keys.
  static Map<String, dynamic> _emptySearchResponse() => {
        'accounts': <dynamic>[],
        'battles': <dynamic>[],
        'shorts': <dynamic>[],
        'challenges': <dynamic>[],
        'users': <dynamic>[],
      };

  // —— Suggestion-acceptance feedback loop ─────────────────────────────

  /// Record that the user followed someone from a suggested-accounts card.
  /// The backend uses [lane] ("fof" | "category" | "popular" | "league")
  /// to learn which suggestion source each user actually responds to, and
  /// boosts that lane on future cards. Fire-and-forget — the response
  /// doesn't matter to the UI.
  static Future<void> recordSuggestionAccepted({
    required String userId,
    required String lane,
    String targetUserId = '',
    String cardId = '',
  }) async {
    if (userId.isEmpty || lane.isEmpty) return;
    try {
      await _authHttp.post(
        Uri.parse('$_base/suggestions/accepted'),
        headers: const {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'lane': lane,
          if (targetUserId.isNotEmpty) 'targetUserId': targetUserId,
          if (cardId.isNotEmpty) 'cardId': cardId,
        }),
      );
    } catch (_) {
      // Best-effort. A failed acceptance signal degrades only future
      // ranking; current UI state already reflects the follow.
    }
  }

  // —— Save ————————————————————————————————————————————————————

  /// POST /api/v1/save
  static Future<Map<String, dynamic>?> toggleSaveChallenge({
    required String userId,
    required String challengeId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/save'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'challengeId': challengeId,
        }),
      );
      if (res.statusCode == 200) return json.decode(res.body);
      return null;
    } catch (_) {
      return null;
    }
  }

  // —— Push notifications ————————————————————————————————————————————

  /// POST /api/v1/notifications/register
  /// Register this device's FCM/APNs token so the backend can push to this user.
  static Future<bool> registerPushToken({
    required String userId,
    required String token,
    required String platform, // 'fcm' or 'apns'
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/notifications/register'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'token': token,
          'platform': platform,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/notifications/unregister
  /// Called on logout / push-permission revocation.
  static Future<void> unregisterPushToken(String token) async {
    try {
      await _authHttp.post(
        Uri.parse('$_base/api/v1/notifications/unregister'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'token': token}),
      );
    } catch (_) {/* best-effort */}
  }

  /// GET /api/v1/notifications/prefs?userId=X
  static Future<Map<String, dynamic>?> getNotificationPrefs(String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/notifications/prefs?userId=$userId'),
      );
      if (res.statusCode == 200) return json.decode(res.body) as Map<String, dynamic>;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/notifications/prefs
  static Future<bool> setNotificationPrefs(Map<String, dynamic> prefs) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/notifications/prefs'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(prefs),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/notifications/clicked
  /// Records that the user opened the app from a push notification.
  static Future<void> trackNotificationClicked(String outboxId) async {
    try {
      await _authHttp.post(
        Uri.parse('$_base/api/v1/notifications/clicked'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'id': outboxId}),
      );
    } catch (_) {/* best-effort */}
  }

  // —— Creator insights ————————————————————————————————————————————

  /// GET /api/v1/creator/insights?creatorId=X&windowDays=30
  static Future<Map<String, dynamic>?> getCreatorInsightsOverview(
      String creatorId, {int windowDays = 30}) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/creator/insights?creatorId=$creatorId&windowDays=$windowDays'),
      );
      if (res.statusCode == 200) return json.decode(res.body) as Map<String, dynamic>;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/creator/insights/content?creatorId=X&type=Y&id=Z&windowDays=30
  static Future<Map<String, dynamic>?> getCreatorInsightsPerContent({
    required String creatorId,
    required String contentType,
    required String contentId,
    int windowDays = 30,
  }) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/creator/insights/content?creatorId=$creatorId&type=$contentType&id=$contentId&windowDays=$windowDays'),
      );
      if (res.statusCode == 200) return json.decode(res.body) as Map<String, dynamic>;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /api/v1/saved/{userId}
  static Future<List<Map<String, dynamic>>> getSavedChallenges(
      String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/saved/$userId'),
      );
      if (res.statusCode == 200) {
        return (json.decode(res.body) as List).cast<Map<String, dynamic>>();
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  // ─── Profile editing ────────────────────────────────────────────────

  /// PATCH /api/v1/users/{id}
  ///
  /// Updates any subset of {fullName, bio, visibility, settings}. Pass
  /// null for fields you don't want changed — only non-null fields go
  /// on the wire. Returns the updated [UserModel] on success so the
  /// caller can merge it into [DataProvider] without a follow-up GET.
  /// Result of an [updateUserProfile] call. Carries explicit success +
  /// optional user + optional error so the caller can distinguish a
  /// 200-with-no-changes (success, no fresh user) from a real
  /// failure that should surface to the user. The old shape returned
  /// `UserModel?` and collapsed those two cases to `null`, which made
  /// the EditProfilePage toast a generic "Could not save" even when
  /// the server happily accepted the request.
  static Future<UpdateProfileResult> updateUserProfile({
    required String userId,
    String? fullName,
    String? bio,
    String? visibility,
    Map<String, dynamic>? settings,
  }) async {
    try {
      final body = <String, dynamic>{'userId': userId};
      if (fullName != null) body['fullName'] = fullName;
      if (bio != null) body['bio'] = bio;
      if (visibility != null) body['visibility'] = visibility;
      if (settings != null) body['settings'] = settings;
      final res = await _authHttp
          .patch(
            Uri.parse('$_base/api/v1/users/$userId'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          // Cap network wait so a stalled connection doesn't leave the
          // Save button stuck in its spinner state forever.
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        // 200 = success, whether or not the body carries a fresh user.
        // Backend returns `{"updated": false}` for no-op requests (no
        // dirty fields landed) — that's still a successful save from
        // the user's perspective, just no changes to merge.
        try {
          final decoded = json.decode(res.body) as Map<String, dynamic>;
          final u = decoded['user'] as Map<String, dynamic>?;
          return UpdateProfileResult(
            success: true,
            user: u == null ? null : UserModel.fromJson(u),
          );
        } catch (_) {
          // Empty or malformed body — still a 200, still a success.
          return const UpdateProfileResult(success: true, user: null);
        }
      }
      // Non-200: pull the server's text into the error so the page can
      // show "username taken" / "bio too long" / etc. rather than a
      // generic "Could not save."
      final msg = res.body.isEmpty
          ? 'Server returned HTTP ${res.statusCode}.'
          : res.body.trim();
      return UpdateProfileResult(success: false, error: msg);
    } catch (e) {
      return UpdateProfileResult(success: false, error: e.toString());
    }
  }

  // ─── Activity: liked + watch history ────────────────────────────────

  /// GET /api/v1/users/{id}/likes?limit=&before=
  ///
  /// Cursor-based pagination keyed on the like timestamp. Pass
  /// [beforeCursor] from a previous response's `nextCursor` to fetch
  /// the next page.
  static Future<Map<String, dynamic>> getLikedChallenges({
    required String userId,
    int limit = 24,
    String? beforeCursor,
  }) async {
    try {
      final q = StringBuffer('$_base/api/v1/users/$userId/likes?limit=$limit');
      if (beforeCursor != null && beforeCursor.isNotEmpty) {
        q.write('&before=$beforeCursor');
      }
      final res = await _authHttp.get(Uri.parse(q.toString()));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return const {'items': [], 'hasMore': false, 'nextCursor': ''};
    } catch (_) {
      return const {'items': [], 'hasMore': false, 'nextCursor': ''};
    }
  }

  /// GET /api/v1/users/{id}/history?limit=&before=
  ///
  /// Newest-first watch history. Each item carries the watched
  /// challenge + watch duration + completion flag.
  static Future<Map<String, dynamic>> getWatchHistory({
    required String userId,
    int limit = 30,
    String? beforeCursor,
  }) async {
    try {
      final q = StringBuffer('$_base/api/v1/users/$userId/history?limit=$limit');
      if (beforeCursor != null && beforeCursor.isNotEmpty) {
        q.write('&before=$beforeCursor');
      }
      final res = await _authHttp.get(Uri.parse(q.toString()));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return const {'items': [], 'hasMore': false, 'nextCursor': ''};
    } catch (_) {
      return const {'items': [], 'hasMore': false, 'nextCursor': ''};
    }
  }

  /// DELETE /api/v1/users/{id}/history — clear all history.
  static Future<bool> clearWatchHistory(String userId) async {
    try {
      final res = await _authHttp.delete(
        Uri.parse('$_base/api/v1/users/$userId/history'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': userId}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ─── Blocks ─────────────────────────────────────────────────────────

  /// POST /api/v1/blocks — block another user.
  /// Tears down follow edges in both directions on the server.
  static Future<bool> blockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/blocks'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'blockerId': blockerId,
          'blockedId': blockedId,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/unblock — remove a block.
  static Future<bool> unblockUser({
    required String blockerId,
    required String blockedId,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/unblock'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'blockerId': blockerId,
          'blockedId': blockedId,
        }),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /api/v1/users/{id}/blocks — list users this user has blocked.
  static Future<List<Map<String, dynamic>>> getBlockedUsers(
      String userId) async {
    try {
      final res = await _authHttp.get(
        Uri.parse('$_base/api/v1/users/$userId/blocks'),
      );
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body) as Map<String, dynamic>;
        return (decoded['items'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  // ─── 2FA / TOTP ─────────────────────────────────────────────────────

  /// POST /api/v1/users/{id}/totp/enroll
  ///
  /// Returns the freshly-generated secret + otpauth URI (for QR) +
  /// recovery codes (PLAINTEXT — only time the server ever surfaces
  /// these; the client must show them ONCE and tell the user to save
  /// them). The 2FA row is created with `is_active=false`; call
  /// [verifyTOTP] with a valid 6-digit code to activate.
  static Future<Map<String, dynamic>?> enrollTOTP(String userId) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/users/$userId/totp/enroll'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': userId}),
      );
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// POST /api/v1/users/{id}/totp/verify
  /// Activates the pending enrollment on a valid code.
  /// Returns true on success (HTTP 200), false otherwise.
  static Future<bool> verifyTOTP({
    required String userId,
    required String code,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/users/$userId/totp/verify'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': userId, 'code': code}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// POST /api/v1/users/{id}/totp/disable
  /// Turns 2FA off. Requires a valid TOTP or recovery code.
  static Future<bool> disableTOTP({
    required String userId,
    required String code,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/users/$userId/totp/disable'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': userId, 'code': code}),
      );
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ─── Bug reports ────────────────────────────────────────────────────

  /// Reuses the existing /api/v1/events endpoint to ship a
  /// user-submitted bug report. No new endpoint or storage — bug
  /// reports flow into the same events table the rest of the
  /// telemetry uses, where the analytics job can roll them up by
  /// surface for triage.
  static Future<bool> reportBug({
    required String userId,
    required String description,
    String surface = '',
    Map<String, dynamic>? extra,
  }) async {
    try {
      final res = await _authHttp.post(
        Uri.parse('$_base/api/v1/events'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': userId,
          'contentId': 'bug_report',
          'contentType': 'feedback',
          'eventType': 'bug_report',
          'metadata': {
            'surface': surface,
            'description': description,
            if (extra != null) ...extra,
          },
        }),
      );
      return res.statusCode == 200 || res.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}