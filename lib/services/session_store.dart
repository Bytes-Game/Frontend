import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Reads the `exp` claim out of a JWT without verifying its signature.
///
/// Verification is the server's job — all we need locally is the answer to
/// "is it even worth sending this?". Returns null for anything we can't
/// parse (opaque tokens, malformed input), which callers treat as "can't
/// tell, try it".
DateTime? jwtExpiry(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    // JWT uses base64url WITHOUT padding; Dart's decoder requires it.
    var payload = parts[1];
    payload = payload.padRight(
        payload.length + ((4 - payload.length % 4) % 4), '=');
    final claims =
        json.decode(utf8.decode(base64Url.decode(payload)));
    if (claims is! Map) return null;
    final exp = claims['exp'];
    if (exp is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  } catch (_) {
    return null;
  }
}

/// A restored session: the bearer token, the user snapshot captured at
/// login, and when the token was minted (drives proactive refresh).
class StoredSession {
  final String token;
  final Map<String, dynamic> userJson;
  final DateTime issuedAt;

  StoredSession({
    required this.token,
    required this.userJson,
    required this.issuedAt,
  });

  /// Tokens live 7 days server-side; refresh past 3 so an active user
  /// never gets anywhere near the hard expiry.
  bool get shouldRefresh =>
      DateTime.now().difference(issuedAt) > const Duration(days: 3);

  /// When this token stops being valid, if we can read it.
  DateTime? get expiresAt => jwtExpiry(token);

  /// True only when the token's own `exp` is definitively in the past.
  ///
  /// This is deliberately decided from the token itself rather than from
  /// [issuedAt]: an already-expired token cannot work under ANY condition —
  /// online, offline, or against a sleeping server — so restoring a session
  /// around one just produces an app where every authed request 401s and the
  /// websocket upgrade is refused. Unreadable tokens return false, so we
  /// never lock someone out over a parsing quirk.
  bool get isExpired {
    final exp = expiresAt;
    return exp != null && DateTime.now().toUtc().isAfter(exp);
  }
}

/// Persists the session in the platform keystore (Android
/// EncryptedSharedPreferences / iOS Keychain) so cold starts restore
/// straight into the feed. All methods are best-effort: storage
/// failures degrade to the old behavior (re-login), never to a crash.
class SessionStore {
  SessionStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _key = 'session_v1';

  static Future<void> save(String token, Map<String, dynamic> userJson) async {
    try {
      await _storage.write(
        key: _key,
        value: json.encode({
          'token': token,
          'user': userJson,
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      // Keystore unavailable (rare, e.g. corrupted Android keyset) —
      // session just won't survive restart, same as before this existed.
    }
  }

  static Future<StoredSession?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return null;
      final data = json.decode(raw) as Map<String, dynamic>;
      final token = data['token'] as String?;
      final user = data['user'] as Map<String, dynamic>?;
      if (token == null || token.isEmpty || user == null) return null;
      return StoredSession(
        token: token,
        userJson: user,
        issuedAt:
            DateTime.tryParse(data['issuedAt'] as String? ?? '')?.toLocal() ??
                DateTime.now().subtract(const Duration(days: 4)),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
