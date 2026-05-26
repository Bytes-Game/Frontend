import 'package:flutter/foundation.dart';
import 'package:myapp/services/api_service.dart';

/// PushNotificationService — thin facade that handles token registration
/// and click attribution. The actual platform binding (FCM on Android,
/// APNs on iOS) lives in production-only `firebase_messaging` /
/// `apple_push_notifications` packages that this app doesn't pull in
/// during local development.
///
/// Production wiring (drop-in replacement for the dev stub below):
///
///   final messaging = FirebaseMessaging.instance;
///   await messaging.requestPermission();
///   final fcmToken = await messaging.getToken();
///   await PushNotificationService.instance.bindUser(userId, fcmToken, 'fcm');
///   FirebaseMessaging.onMessageOpenedApp.listen((msg) {
///     final outboxId = msg.data['outboxId'];
///     if (outboxId != null) {
///       PushNotificationService.instance.recordClick(outboxId);
///       // Navigate using msg.data['deeplink'].
///     }
///   });
///
/// In local dev (no Firebase configured) the calls below are safe no-ops
/// for token-related ops and best-effort for click tracking.
class PushNotificationService {
  PushNotificationService._();
  static final instance = PushNotificationService._();

  String? _userId;
  String? _token;
  String? _platform;

  /// Bind a registered FCM/APNs token to the active user. Idempotent —
  /// the same token re-registered just updates last_seen_at server-side.
  Future<bool> bindUser(String userId, String? token, String platform) async {
    if (token == null || token.isEmpty) {
      if (kDebugMode) {
        debugPrint('PushNotificationService: empty token, skipping registration');
      }
      return false;
    }
    _userId = userId;
    _token = token;
    _platform = platform;
    final ok = await ApiService.registerPushToken(
      userId: userId,
      token: token,
      platform: platform,
    );
    if (!ok && kDebugMode) {
      debugPrint('PushNotificationService: register failed for $platform token');
    }
    return ok;
  }

  /// Unbind on logout / push-permission revocation.
  Future<void> unbind() async {
    if (_token != null) {
      await ApiService.unregisterPushToken(_token!);
    }
    _userId = null;
    _token = null;
    _platform = null;
  }

  /// Record that the user opened the app from a push notification. Drives
  /// the notification → app-open conversion funnel. Call this from the
  /// foreground/cold-start handler with the outboxId that was attached
  /// to the push payload's data section.
  Future<void> recordClick(String outboxId) async {
    if (outboxId.isEmpty) return;
    await ApiService.trackNotificationClicked(outboxId);
  }

  /// Fetch current per-trigger preferences for the active user.
  Future<Map<String, dynamic>?> getPrefs() async {
    if (_userId == null) return null;
    return ApiService.getNotificationPrefs(_userId!);
  }

  /// Persist per-trigger preferences.
  Future<bool> setPrefs(Map<String, dynamic> prefs) async {
    if (_userId == null) return false;
    final body = Map<String, dynamic>.from(prefs);
    body['userId'] = _userId;
    return ApiService.setNotificationPrefs(body);
  }

  String? get userId => _userId;
  String? get token => _token;
  String? get platform => _platform;
}
