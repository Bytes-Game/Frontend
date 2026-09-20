import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Reads the `exp` claim out of a JWT without verifying its signature.
///
/// Verification is the server's job — all we need locally is the answer to
/// "is it even worth sending this?". Returns null for anything we can't
/// parse (opaque tokens, malformed input), which callers treat as "can't
/// tell, try it".
Map<String, dynamic>? jwtClaims(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;
    // JWT uses base64url WITHOUT padding; Dart's decoder requires it.
    var payload = parts[1];
    payload = payload.padRight(
        payload.length + ((4 - payload.length % 4) % 4), '=');
    final claims = json.decode(utf8.decode(base64Url.decode(payload)));
    if (claims is! Map) return null;
    return Map<String, dynamic>.from(claims);
  } catch (_) {
    return null;
  }
}

DateTime? jwtExpiry(String token) {
  final exp = jwtClaims(token)?['exp'];
  if (exp is! int) return null;
  return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
}

/// The `username` claim, i.e. who this token actually authenticates as.
/// Used to catch a token being sent on a socket opened for someone else.
String? jwtUsername(String token) {
  final u = jwtClaims(token)?['username'];
  return u is String && u.isNotEmpty ? u : null;
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

  /// The read that [prefetch] started, kept so [load] can pick up the
  /// answer instead of asking the keystore a second time.
  ///
  /// Dropped whenever we write or wipe, so `load()` always means "what is
  /// in storage now" rather than "what was in storage at boot".
  static Future<StoredSession?>? _pending;

  /// Start reading the saved session NOW, without waiting for the answer.
  ///
  /// The first time anything touches the phone's secure storage, Android
  /// has to unlock the key it encrypted the data with. That is a trip to
  /// the phone's security chip and it takes a while — on a real device it
  /// measured 223ms. It only happens once per app launch; every read after
  /// it is quick.
  ///
  /// The app used to pay that 223ms at the worst possible moment: after
  /// the first frame was on screen, with the user watching a spinner, and
  /// with the login-or-feed decision stuck behind it. Nothing else was
  /// happening during it.
  ///
  /// Calling this at the start of `main()` does not make the work faster.
  /// It makes it happen AT THE SAME TIME as the rest of startup — building
  /// the HTTP client, sizing the video pool, reading the remembered link
  /// speed, painting the first frame. By the time anyone asks for the
  /// answer it is usually already sitting here.
  ///
  /// Safe to call more than once; the second call does nothing.
  static void prefetch() {
    _pending ??= _read();
  }

  /// True when [prefetch] has work in flight or an answer waiting.
  /// Only the tests care; nothing in the app branches on it.
  @visibleForTesting
  static bool get hasPrefetched => _pending != null;

  /// Forget anything [prefetch] read. Tests use this to start clean.
  @visibleForTesting
  static void resetForTest() {
    _pending = null;
  }

  static Future<void> save(String token, Map<String, dynamic> userJson) async {
    // What we prefetched at boot is now out of date. Drop it so the next
    // load() reads the session we are about to write, not the old one.
    _pending = null;
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

  /// The saved session, or null if there isn't one we can use.
  ///
  /// If [prefetch] was called at startup this hands back the answer that
  /// read already produced — it does not ask the keystore again. If it
  /// wasn't (tests, or a code path that skipped startup), this reads now,
  /// exactly as it always did.
  static Future<StoredSession?> load() {
    return _pending ??= _read();
  }

  static Future<StoredSession?> _read() async {
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
    } catch (e) {
      // Say so. A session that can't be read looks exactly like no session
      // at all — the user lands on the login screen either way — so without
      // this line a broken keystore is invisible and reads as "they logged
      // out". Same reasoning as the rest of the app's failure logging.
      debugPrint('Could not read the saved session: $e '
          '— showing the login screen.');
      return null;
    }
  }

  static Future<void> clear() async {
    _pending = null;
    try {
      await _storage.delete(key: _key);
    } catch (e) {
      debugPrint('Could not wipe the saved session: $e '
          '— it may come back on the next launch.');
    }
  }
}
