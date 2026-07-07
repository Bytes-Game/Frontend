import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:myapp/services/api_service.dart';
import 'package:uuid/uuid.dart';

/// EventTracker captures every meaningful user interaction and sends it
/// to the recommendation engine backend.
///
/// ## Why this exists
///
/// The recommendation algorithm is only as good as its data. TikTok's real
/// advantage isn't their ML model — it's that they capture EVERY micro-signal:
/// watch duration, skip speed, rewatch, pause, even scroll velocity.
///
/// We capture the practical subset that works without client-side ML:
/// - view (with watch duration and completion rate)
/// - like / unlike
/// - comment
/// - share
/// - save / unsave
/// - skip (swiped away quickly)
/// - not_interested (explicit rejection)
/// - rewatch (watched same content again)
///
/// ## How it works
///
/// 1. Every interaction calls [track()] which queues the event
/// 2. Events are batched and sent every 5 seconds (or when batch hits 10)
/// 3. Session ID groups events — auto-rotates after 30min inactivity
/// 4. Session position tracks the Nth item seen (fatigue signal)
///
/// ## Usage
///
/// ```dart
/// // Track a view with watch time
/// EventTracker.instance.trackView(
///   contentId: '123',
///   contentType: 'challenge',
///   watchDurationMs: 45000,
///   totalDurationMs: 60000,
/// );
///
/// // Track a like
/// EventTracker.instance.trackLike(contentId: '123', contentType: 'post');
///
/// // Track a skip (user swiped past quickly)
/// EventTracker.instance.trackSkip(contentId: '123', contentType: 'challenge');
/// ```
class EventTracker {
  EventTracker._();
  static final EventTracker instance = EventTracker._();

  String? _userId;
  String _sessionId = '';
  int _sessionPosition = 0;
  DateTime _lastActivity = DateTime.now();
  final List<Map<String, dynamic>> _eventQueue = [];
  Timer? _flushTimer;

  static const _batchSize = 10;
  static const _flushInterval = Duration(seconds: 5);
  static const _sessionTimeout = Duration(minutes: 30);

  /// Initialize with the current user ID. Call on login.
  void init(String userId) {
    _userId = userId;
    _rotateSessionIfNeeded();
    _startFlushTimer();
  }

  /// Reset on logout.
  void dispose() {
    _flushTimer?.cancel();
    _flush();
    _userId = null;
    _sessionPosition = 0;
  }

  // ─── Public tracking methods ───────────────────────────────────

  /// Track content view with watch duration.
  /// This is the #1 signal — completion rate tells us more than any like.
  void trackView({
    required String contentId,
    required String contentType,
    required int watchDurationMs,
    required int totalDurationMs,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'view',
      watchDurationMs: watchDurationMs,
      totalDurationMs: totalDurationMs,
    );
  }

  /// Track a like action.
  void trackLike({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'like');
  }

  /// Track unlike (removed like).
  void trackUnlike({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'unlike');
  }

  /// Track comment posted.
  void trackComment({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'comment');
  }

  /// Track share action — highest intent signal.
  void trackShare({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'share');
  }

  /// Track save/bookmark.
  void trackSave({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'save');
  }

  /// Track unsave/unbookmark.
  void trackUnsave({required String contentId, required String contentType}) {
    _track(contentId: contentId, contentType: contentType, eventType: 'unsave');
  }

  /// Track skip — user swiped past without engaging.
  /// Implicit negative signal without requiring user effort.
  void trackSkip({
    required String contentId,
    required String contentType,
    int watchDurationMs = 0,
    int totalDurationMs = 0,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'skip',
      watchDurationMs: watchDurationMs,
      totalDurationMs: totalDurationMs,
    );
  }

  /// Track "not interested" — explicit rejection.
  void trackNotInterested({
    required String contentId,
    required String contentType,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'not_interested',
    );
  }

  /// Track rewatch — stronger signal than a like.
  void trackRewatch({
    required String contentId,
    required String contentType,
    int watchDurationMs = 0,
    int totalDurationMs = 0,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'rewatch',
      watchDurationMs: watchDurationMs,
      totalDurationMs: totalDurationMs,
    );
  }

  /// Track scroll speed — how fast user scrolled past content.
  /// Fast scroll = not interested. Slow scroll = scanning/considering.
  /// scrollVelocity: pixels per second. >2000 = fast, <500 = slow.
  void trackScrollSpeed({
    required String contentId,
    required String contentType,
    required double scrollVelocity,
  }) {
    // Only track meaningful speeds (ignore tiny movements)
    if (scrollVelocity < 100) return;

    final speed = scrollVelocity > 2000
        ? 'fast'
        : scrollVelocity > 800
            ? 'medium'
            : 'slow';

    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'scroll_$speed',
    );
  }

  /// Track pause on content — user stopped scrolling and is looking at this.
  /// A pause of 500ms+ on a thumbnail is a strong interest signal.
  void trackPause({
    required String contentId,
    required String contentType,
    required int pauseDurationMs,
  }) {
    // Only track meaningful pauses (>500ms)
    if (pauseDurationMs < 500) return;

    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'pause',
      watchDurationMs: pauseDurationMs,
    );
  }

  /// Track content impression with dwell time (how long content was visible).
  /// This is a CRITICAL signal — we log every piece of content shown, not just watched.
  /// Short dwell (<500ms) = implicit rejection. Long dwell = curiosity.
  /// This is how TikTok learns what NOT to show you within a single session.
  void trackImpression({
    required String contentId,
    required String contentType,
    int dwellMs = 0,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'impression',
      watchDurationMs: dwellMs,
      metadata: {'dwellMs': dwellMs},
    );
  }

  /// Track scroll-back — user scrolled BACK to previous content.
  /// This is one of the strongest positive signals — the user actively sought out this content.
  /// Instagram weights scroll-backs heavily.
  void trackScrollBack({
    required String contentId,
    required String contentType,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'scroll_back',
    );
  }

  /// Track video completion — user watched to 95%+ of video.
  /// Stronger signal than just watch time because it implies intentional completion.
  void trackComplete({
    required String contentId,
    required String contentType,
    required int totalDurationMs,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'complete',
      watchDurationMs: totalDurationMs,
      totalDurationMs: totalDurationMs,
    );
  }

  /// Track video loop — video auto-replayed and user let it.
  /// Every additional loop is a retention multiplier.
  void trackLoop({
    required String contentId,
    required String contentType,
    required int loopNumber,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'loop',
      metadata: {'loopNumber': loopNumber},
    );
  }

  /// Track audio unmute — if videos autoplay muted, unmuting = strong interest.
  /// User explicitly wanted to hear this. Very valuable signal.
  void trackUnmute({
    required String contentId,
    required String contentType,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'unmute',
    );
  }

  /// Track video seek — user scrubbed the video timeline.
  /// Seeking forward = impatient but engaged. Seeking backward = rewatching a moment (strong positive).
  void trackSeek({
    required String contentId,
    required String contentType,
    required int fromMs,
    required int toMs,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: toMs < fromMs ? 'seek_back' : 'seek_forward',
      metadata: {'fromMs': fromMs, 'toMs': toMs, 'deltaMs': toMs - fromMs},
    );
  }

  /// Track profile visit from content — user tapped creator name/avatar.
  /// Strong interest signal in the creator.
  void trackProfileVisit({
    required String creatorId,
    required String fromContentId,
    required String fromContentType,
  }) {
    _track(
      contentId: fromContentId,
      contentType: fromContentType,
      eventType: 'profile_visit',
      metadata: {'creatorId': creatorId},
    );
  }

  /// Track hashtag tap — user tapped a hashtag. Category interest signal.
  void trackHashtagTap({
    required String hashtag,
    required String fromContentId,
    required String fromContentType,
  }) {
    _track(
      contentId: fromContentId,
      contentType: fromContentType,
      eventType: 'hashtag_tap',
      metadata: {'hashtag': hashtag},
    );
  }

  /// Track @mention tap — user tapped a mentioned username.
  void trackMentionTap({
    required String mentionedUserId,
    required String fromContentId,
    required String fromContentType,
  }) {
    _track(
      contentId: fromContentId,
      contentType: fromContentType,
      eventType: 'mention_tap',
      metadata: {'mentionedUserId': mentionedUserId},
    );
  }

  /// Track follow action originating from a piece of content.
  /// Differs from regular follow because it tells us WHAT content converted a viewer to a follower.
  void trackFollowFromContent({
    required String creatorId,
    required String fromContentId,
    required String fromContentType,
  }) {
    _track(
      contentId: fromContentId,
      contentType: fromContentType,
      eventType: 'follow_from_content',
      metadata: {'creatorId': creatorId},
    );
  }

  /// Track report — user reported content. Extremely strong negative signal.
  void trackReport({
    required String contentId,
    required String contentType,
    required String reason,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'report',
      metadata: {'reason': reason},
    );
  }

  /// Track block — user blocked the creator. Strongest negative signal.
  void trackBlock({
    required String blockedUserId,
    required String fromContentId,
    required String fromContentType,
  }) {
    _track(
      contentId: fromContentId,
      contentType: fromContentType,
      eventType: 'block',
      metadata: {'blockedUserId': blockedUserId},
    );
  }

  /// Track comment panel opened — user is reading/writing comments.
  /// Shows deep engagement with the content even if they don't post.
  void trackCommentPanelOpen({
    required String contentId,
    required String contentType,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'comment_panel_open',
    );
  }

  /// Track long press on content (context menu opened). Moderate engagement signal.
  void trackLongPress({
    required String contentId,
    required String contentType,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: 'long_press',
    );
  }

  /// Track app going to background with context. Marks session boundary.
  void trackAppBackground({String? lastContentId, String? lastContentType}) {
    _track(
      contentId: lastContentId ?? '',
      contentType: lastContentType ?? '',
      eventType: 'app_background',
    );
    // Flush immediately — user is leaving, we want to persist their state
    _flush();
  }

  /// Track app returning to foreground. Signals re-entry.
  void trackAppForeground() {
    _rotateSessionIfNeeded();
    _track(
      contentId: '',
      contentType: '',
      eventType: 'app_foreground',
    );
  }

  /// Track pause toggle — user tapped to pause/play video.
  /// Pauses are often to read/observe — a retention signal.
  void trackPauseToggle({
    required String contentId,
    required String contentType,
    required bool isPaused,
    int positionMs = 0,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: isPaused ? 'video_pause' : 'video_play',
      metadata: {'positionMs': positionMs},
    );
  }

  /// Track battle side switch — user toggled between competing videos in a challenge.
  /// Shows active engagement with the battle format.
  void trackBattleSwitch({
    required String challengeId,
    required int side,
  }) {
    _track(
      contentId: challengeId,
      contentType: 'challenge',
      eventType: 'battle_switch',
      metadata: {'side': side},
    );
  }

  // ─── Page lifecycle (every screen) ─────────────────────────────
  //
  // page_view fires when a screen becomes visible. page_exit fires when it
  // leaves and carries the dwell time. These two are the foundation of
  // TikTok/IG-level coverage — together they describe HOW MUCH TIME the user
  // spent on each surface of the app, not just on videos.

  /// Track a page becoming visible.
  /// [pageName] should be a stable, snake_case identifier (e.g. "profile_page").
  /// [referrer] is the page the user came from (for funnel analysis).
  /// [params] are page-specific context (e.g. {"profileUserId": "42"}).
  void trackPageView({
    required String pageName,
    String? referrer,
    Map<String, dynamic>? params,
  }) {
    final meta = <String, dynamic>{
      'pageName': pageName,
      if (referrer != null) 'referrer': referrer,
      if (params != null) ...params,
    };
    _track(
      contentId: pageName,
      contentType: 'page',
      eventType: 'page_view',
      metadata: meta,
    );
  }

  /// Track a page being left, with how long the user spent on it.
  /// Dwell-time per page is a top-tier signal — a user who spends 4 min on
  /// the profile page has a different psychological profile than one who
  /// bounces in 2s.
  void trackPageExit({
    required String pageName,
    required int dwellMs,
    Map<String, dynamic>? params,
  }) {
    if (dwellMs < 100) return; // Ignore micro-views (route flicker)
    final meta = <String, dynamic>{
      'pageName': pageName,
      'dwellMs': dwellMs,
      if (params != null) ...params,
    };
    _track(
      contentId: pageName,
      contentType: 'page',
      eventType: 'page_exit',
      watchDurationMs: dwellMs,
      metadata: meta,
    );
  }

  // ─── Generic UI interaction ────────────────────────────────────

  /// Track a tap on any interactive UI element.
  /// [target] should be a stable identifier like "follow_button", "settings_avatar_change".
  /// [pageName] is the surface the tap happened on (for context).
  void trackTap({
    required String target,
    required String pageName,
    Map<String, dynamic>? params,
  }) {
    final meta = <String, dynamic>{
      'target': target,
      'pageName': pageName,
      if (params != null) ...params,
    };
    _track(
      contentId: target,
      contentType: 'ui',
      eventType: 'tap',
      metadata: meta,
    );
  }

  /// Track a swipe gesture (horizontal/vertical) outside the feed.
  /// Used for swipeable carousels, dismissibles, image galleries.
  void trackSwipe({
    required String target,
    required String pageName,
    required String direction, // "left" | "right" | "up" | "down"
    Map<String, dynamic>? params,
  }) {
    final meta = <String, dynamic>{
      'target': target,
      'pageName': pageName,
      'direction': direction,
      if (params != null) ...params,
    };
    _track(
      contentId: target,
      contentType: 'ui',
      eventType: 'swipe',
      metadata: meta,
    );
  }

  /// Track a list-scroll milestone (25%, 50%, 75%, 100%).
  /// Tells us how deep the user goes into long lists (followers, comments,
  /// challenges, search results). Reveals patience/curiosity.
  void trackListScrollDepth({
    required String listName,
    required String pageName,
    required int percent, // 25 | 50 | 75 | 100
    int totalItems = 0,
  }) {
    _track(
      contentId: listName,
      contentType: 'list',
      eventType: 'list_scroll_depth',
      metadata: {
        'listName': listName,
        'pageName': pageName,
        'percent': percent,
        'totalItems': totalItems,
      },
    );
  }

  // ─── Tab navigation ────────────────────────────────────────────

  /// Track main shell tab switch (Home/Explore/Search/Profile).
  /// Tab preference is a long-term affinity signal — some users live in
  /// the search tab, others stay on the home feed.
  void trackTabSwitch({
    required int fromIndex,
    required int toIndex,
    required String fromLabel,
    required String toLabel,
  }) {
    _track(
      contentId: 'tab_$toIndex',
      contentType: 'navigation',
      eventType: 'tab_switch',
      metadata: {
        'fromIndex': fromIndex,
        'toIndex': toIndex,
        'fromLabel': fromLabel,
        'toLabel': toLabel,
      },
    );
  }

  // ─── Search ────────────────────────────────────────────────────

  /// Track a search query submitted by the user.
  /// [scope] is what they searched ("users" | "challenges" | "all").
  /// [resultCount] tells us if the query returned anything.
  void trackSearchQuery({
    required String query,
    required String scope,
    required int resultCount,
  }) {
    _track(
      contentId: query,
      contentType: 'search',
      eventType: 'search_query',
      metadata: {
        'query': query,
        'scope': scope,
        'resultCount': resultCount,
      },
    );
  }

  /// Track a tap on a search result.
  /// [position] is the index in the result list (0-based) — top results
  /// being tapped means the search ranking worked.
  void trackSearchResultTap({
    required String query,
    required String resultId,
    required String resultType,
    required int position,
  }) {
    _track(
      contentId: resultId,
      contentType: resultType,
      eventType: 'search_result_tap',
      metadata: {
        'query': query,
        'position': position,
      },
    );
  }

  /// Track abandoned search (typed but didn't submit, or no result tapped).
  void trackSearchAbandoned({
    required String query,
    required String reason, // "no_submit" | "no_result_tap"
  }) {
    _track(
      contentId: query,
      contentType: 'search',
      eventType: 'search_abandoned',
      metadata: {'query': query, 'reason': reason},
    );
  }

  // ─── Profile ───────────────────────────────────────────────────

  /// Track viewing a profile (own or someone else's).
  /// Different from profile_visit (which fires from content) — this is
  /// any path into the profile screen.
  void trackProfileView({
    required String profileUserId,
    required bool isSelf,
    String? source, // "search" | "comments" | "leaderboard" | "deeplink"
  }) {
    _track(
      contentId: profileUserId,
      contentType: 'profile',
      eventType: 'profile_view',
      metadata: {
        'profileUserId': profileUserId,
        'isSelf': isSelf,
        if (source != null) 'source': source,
      },
    );
  }

  /// Track follow toggle (in either direction).
  /// [becameFollowing] true = followed, false = unfollowed.
  void trackFollowToggle({
    required String targetUserId,
    required bool becameFollowing,
    required String fromPage,
  }) {
    _track(
      contentId: targetUserId,
      contentType: 'user',
      eventType: becameFollowing ? 'follow' : 'unfollow',
      metadata: {
        'targetUserId': targetUserId,
        'fromPage': fromPage,
      },
    );
  }

  // ─── Chat ──────────────────────────────────────────────────────

  /// Deterministic conversation ID derived from two user IDs.
  /// Sorted so both participants compute the same value.
  static String makeConversationId(String userA, String userB) {
    final a = userA.compareTo(userB) <= 0 ? userA : userB;
    final b = userA.compareTo(userB) <= 0 ? userB : userA;
    return 'conv_${a}_$b';
  }

  /// Track opening a conversation thread.
  void trackChatOpen({
    required String conversationId,
    required String otherUserId,
    String? source,
  }) {
    _track(
      contentId: conversationId,
      contentType: 'chat',
      eventType: 'chat_open',
      metadata: {
        'conversationId': conversationId,
        'otherUserId': otherUserId,
        if (source != null) 'source': source,
      },
    );
  }

  /// Track sending a message. We do NOT record the message text — only
  /// the act of sending and its length bucket.
  void trackMessageSent({
    required String conversationId,
    required int messageLength,
    required bool hasMedia,
  }) {
    _track(
      contentId: conversationId,
      contentType: 'chat',
      eventType: 'message_sent',
      metadata: {
        'conversationId': conversationId,
        'lengthBucket': _bucketLength(messageLength),
        'hasMedia': hasMedia,
      },
    );
  }

  /// Track reading messages in a conversation (inbound message rendered).
  void trackMessagesRead({
    required String conversationId,
    required int messageCount,
  }) {
    _track(
      contentId: conversationId,
      contentType: 'chat',
      eventType: 'messages_read',
      metadata: {
        'conversationId': conversationId,
        'messageCount': messageCount,
      },
    );
  }

  // ─── Notifications ─────────────────────────────────────────────

  void trackNotificationPanelOpen({required int unreadCount}) {
    _track(
      contentId: 'notifications',
      contentType: 'notifications',
      eventType: 'notification_panel_open',
      metadata: {'unreadCount': unreadCount},
    );
  }

  void trackNotificationTap({
    required String notificationId,
    required String notificationType,
    required int position,
  }) {
    _track(
      contentId: notificationId,
      contentType: 'notification',
      eventType: 'notification_tap',
      metadata: {
        'notificationType': notificationType,
        'position': position,
      },
    );
  }

  // ─── Upload / Create funnel ────────────────────────────────────
  //
  // Multi-step flows are funnels — we want to know where users drop off,
  // not just when they finish. Each step fires a separate event so the
  // backend can compute step-by-step conversion rates.

  void trackUploadStart({required String uploadType}) {
    _track(
      contentId: uploadType,
      contentType: 'upload',
      eventType: 'upload_start',
      metadata: {'uploadType': uploadType},
    );
  }

  void trackUploadStep({
    required String uploadType,
    required String step, // "select_video" | "trim" | "caption" | "review"
    int elapsedMs = 0,
  }) {
    _track(
      contentId: uploadType,
      contentType: 'upload',
      eventType: 'upload_step',
      metadata: {
        'uploadType': uploadType,
        'step': step,
        'elapsedMs': elapsedMs,
      },
    );
  }

  void trackUploadAbandon({
    required String uploadType,
    required String atStep,
    required int elapsedMs,
  }) {
    _track(
      contentId: uploadType,
      contentType: 'upload',
      eventType: 'upload_abandon',
      metadata: {
        'uploadType': uploadType,
        'atStep': atStep,
        'elapsedMs': elapsedMs,
      },
    );
  }

  void trackUploadComplete({
    required String uploadType,
    required String contentId,
    required int durationMs,
    required int totalElapsedMs,
  }) {
    _track(
      contentId: contentId,
      contentType: 'upload',
      eventType: 'upload_complete',
      metadata: {
        'uploadType': uploadType,
        'durationMs': durationMs,
        'totalElapsedMs': totalElapsedMs,
      },
    );
  }

  // ─── Settings & preferences ────────────────────────────────────

  /// Track any settings/preference change. Theme switch, language, mute
  /// preference, notification toggles — all flow through here.
  ///
  /// Don't record sensitive values (passwords, tokens). For booleans/enums
  /// pass them through; for free-text use a hashed/truncated representation.
  void trackSettingChange({
    required String settingKey,
    required dynamic oldValue,
    required dynamic newValue,
    String pageName = 'settings',
  }) {
    _track(
      contentId: settingKey,
      contentType: 'setting',
      eventType: 'setting_change',
      metadata: {
        'settingKey': settingKey,
        'oldValue': oldValue?.toString(),
        'newValue': newValue?.toString(),
        'pageName': pageName,
      },
    );
  }

  // ─── Permissions ───────────────────────────────────────────────

  /// Track an OS-level permission outcome (camera, mic, notifications, storage).
  void trackPermission({
    required String permission,
    required bool granted,
    String? source, // page or feature that requested it
  }) {
    _track(
      contentId: permission,
      contentType: 'permission',
      eventType: granted ? 'permission_granted' : 'permission_denied',
      metadata: {
        'permission': permission,
        if (source != null) 'source': source,
      },
    );
  }

  // ─── Errors & performance ──────────────────────────────────────

  /// Track an API/network error encountered during user-facing operations.
  /// Helps detect device/network/quality issues per user.
  void trackError({
    required String surface, // page or feature where it happened
    required String errorType, // "network" | "auth" | "validation" | "crash"
    String? message,
    int? statusCode,
  }) {
    _track(
      contentId: surface,
      contentType: 'error',
      eventType: 'error',
      metadata: {
        'surface': surface,
        'errorType': errorType,
        if (message != null) 'message': message,
        if (statusCode != null) 'statusCode': statusCode,
      },
    );
  }

  /// Track a slow operation (page load, video buffer, search latency).
  /// Used to spot quality-of-experience degradations per user.
  void trackPerf({
    required String operation,
    required int durationMs,
    String? surface,
  }) {
    _track(
      contentId: operation,
      contentType: 'perf',
      eventType: 'perf',
      metadata: {
        'operation': operation,
        'durationMs': durationMs,
        if (surface != null) 'surface': surface,
      },
    );
  }

  // ─── Helpers ───────────────────────────────────────────────────

  String _bucketLength(int n) {
    if (n <= 10) return 'short';
    if (n <= 50) return 'medium';
    if (n <= 200) return 'long';
    return 'very_long';
  }

  /// Get current session ID (for feed requests).
  String get sessionId {
    _rotateSessionIfNeeded();
    return _sessionId;
  }

  // ─── Internal ──────────────────────────────────────────────────

  /// Generic event escape hatch. Use this for new event types that
  /// don't have a dedicated trackXxx() helper yet — e.g. one-off
  /// pipeline events from the create-challenge flow (process_done,
  /// upload_done, pipeline_fail). Anything that becomes recurring
  /// should graduate to its own helper above for clarity.
  void track({
    required String eventType,
    required String contentId,
    required String contentType,
    Map<String, dynamic>? metadata,
    int watchDurationMs = 0,
    int totalDurationMs = 0,
  }) {
    _track(
      contentId: contentId,
      contentType: contentType,
      eventType: eventType,
      watchDurationMs: watchDurationMs,
      totalDurationMs: totalDurationMs,
      metadata: metadata,
    );
  }

  void _track({
    required String contentId,
    required String contentType,
    required String eventType,
    int watchDurationMs = 0,
    int totalDurationMs = 0,
    Map<String, dynamic>? metadata,
  }) {
    if (_userId == null) return;

    _rotateSessionIfNeeded();
    _sessionPosition++;
    _lastActivity = DateTime.now();

    final completionRate = totalDurationMs > 0
        ? (watchDurationMs / totalDurationMs).clamp(0.0, 1.0)
        : 0.0;

    final event = <String, dynamic>{
      'userId': _userId,
      'contentId': contentId,
      'contentType': contentType,
      'eventType': eventType,
      'watchDurationMs': watchDurationMs,
      'totalDurationMs': totalDurationMs,
      'completionRate': completionRate,
      'sessionId': _sessionId,
      'sessionPosition': _sessionPosition,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (metadata != null && metadata.isNotEmpty) {
      event['metadata'] = metadata;
    }
    _eventQueue.add(event);

    // Flush immediately if batch is full
    if (_eventQueue.length >= _batchSize) {
      _flush();
    }
  }

  void _rotateSessionIfNeeded() {
    final now = DateTime.now();
    if (_sessionId.isEmpty ||
        now.difference(_lastActivity) > _sessionTimeout) {
      _sessionId = const Uuid().v4();
      _sessionPosition = 0;
      _lastActivity = now;
    }
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => _flush());
  }

  static const _maxQueueSize = 200;

  Future<void> _flush() async {
    if (_eventQueue.isEmpty) return;

    // Take current batch and clear queue
    final batch = List<Map<String, dynamic>>.from(_eventQueue);
    _eventQueue.clear();

    // trackEventsBatch swallows its own exceptions and reports failure
    // via the returned bool — it never throws. An earlier version of
    // this method only re-queued inside a catch block, which made the
    // re-queue path unreachable and silently dropped every failed
    // batch (offline rides, backend deploys, transient 5xx). Check the
    // bool; keep the try/catch as belt-and-suspenders in case the API
    // layer ever regains the ability to throw.
    var ok = false;
    try {
      ok = await ApiService.trackEventsBatch(batch);
    } catch (e) {
      if (kDebugMode) {
        print('EventTracker flush threw: $e');
      }
      ok = false;
    }
    if (!ok) {
      _requeue(batch);
    }
  }

  /// Put a failed batch back at the head of the queue so it retries on
  /// the next flush, dropping the oldest events past [_maxQueueSize] to
  /// bound memory during long offline stretches.
  void _requeue(List<Map<String, dynamic>> batch) {
    if (kDebugMode) {
      print('EventTracker flush failed — re-queueing ${batch.length} events');
    }
    if (_eventQueue.length + batch.length <= _maxQueueSize) {
      _eventQueue.insertAll(0, batch);
    } else {
      // Drop oldest events, keep newest
      final space = _maxQueueSize - _eventQueue.length;
      if (space > 0) {
        _eventQueue.insertAll(0, batch.sublist(batch.length - space));
      }
    }
  }
}
