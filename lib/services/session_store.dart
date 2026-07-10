import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
