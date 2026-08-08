// Regression tests for the "logged in with a dead token" state.
//
// Symptom on a real device (2026-08-08): the app restored a session whose
// token had expired on 2026-07-25, then ran as authenticated — so every
// authed request 401'd ("EventTracker flush failed — re-queueing 2 events"
// on a loop) and the websocket upgrade was refused once per reconnect.
//
// Root cause: refreshToken() returned null for BOTH "server rejected the
// token" and "couldn't reach the server", and restoreSession treated the
// null branch as success, setting _isAuthenticated = true regardless.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/session_store.dart';

/// Builds an unsigned JWT with the given `exp`. Only the payload matters —
/// jwtExpiry never verifies the signature (that's the server's job).
String jwtWithExp(DateTime exp) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  final header = seg({'alg': 'HS256', 'typ': 'JWT'});
  final payload = seg({
    'username': 'player2',
    'sub': '2',
    'exp': exp.millisecondsSinceEpoch ~/ 1000,
  });
  return '$header.$payload.signature';
}

void main() {
  group('jwtExpiry', () {
    test('reads exp from the real token that caused the outage', () {
      // Verbatim from the device log. Issued 2026-07-18, expired 2026-07-25.
      const token =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6InBsYXllcjIiLCJzdWIiOiIyIiwiZXhwIjoxNzg0OTc1MjYzLCJpYXQiOjE3ODQzNzA0NjN9.TUcspEQMl4wU5lead_haUuSpvboq2HQWkWrqOuZvUsY';
      final exp = jwtExpiry(token);
      expect(exp, isNotNull);
      expect(exp!.toUtc().toIso8601String(), startsWith('2026-07-25'));
    });

    test('returns null for tokens it cannot parse', () {
      expect(jwtExpiry(''), isNull);
      expect(jwtExpiry('not-a-jwt'), isNull);
      expect(jwtExpiry('only.two'), isNull);
      expect(jwtExpiry('a.!!!not-base64!!!.c'), isNull);
    });
  });

  group('StoredSession.isExpired', () {
    StoredSession withToken(String token) => StoredSession(
          token: token,
          userJson: const {},
          issuedAt: DateTime.now(),
        );

    test('true for a token past its exp', () {
      final s = withToken(
          jwtWithExp(DateTime.now().toUtc().subtract(const Duration(days: 1))));
      expect(s.isExpired, isTrue);
    });

    test('false for a token still in date', () {
      final s = withToken(
          jwtWithExp(DateTime.now().toUtc().add(const Duration(days: 3))));
      expect(s.isExpired, isFalse);
    });

    test('false when expiry is unreadable — never lock out on a parse quirk',
        () {
      expect(withToken('opaque-token').isExpired, isFalse);
    });
  });

  group('ApiService.refreshSession', () {
    tearDown(() {
      ApiService.useClient(http.Client());
      ApiService.clearAuth();
    });

    test('401 is rejected, not unreachable', () async {
      ApiService.useClient(MockClient((_) async => http.Response('no', 401)));
      expect(await ApiService.refreshSession(), TokenRefresh.rejected);
    });

    test('403 is rejected', () async {
      ApiService.useClient(MockClient((_) async => http.Response('no', 403)));
      expect(await ApiService.refreshSession(), TokenRefresh.rejected);
    });

    test('200 with a token refreshes and installs it', () async {
      ApiService.useClient(MockClient(
          (_) async => http.Response(json.encode({'token': 'fresh'}), 200)));
      expect(await ApiService.refreshSession(), TokenRefresh.refreshed);
      expect(ApiService.authToken, 'fresh');
    });

    test('200 without a usable token is rejected', () async {
      ApiService.useClient(
          MockClient((_) async => http.Response(json.encode({}), 200)));
      expect(await ApiService.refreshSession(), TokenRefresh.rejected);
    });

    test('5xx is unreachable — a sick server is not a dead token', () async {
      ApiService.useClient(MockClient((_) async => http.Response('err', 503)));
      expect(await ApiService.refreshSession(), TokenRefresh.unreachable);
    });

    test('a thrown transport error is unreachable', () async {
      ApiService.useClient(
          MockClient((_) async => throw const SocketishFailure()));
      expect(await ApiService.refreshSession(), TokenRefresh.unreachable);
    });
  });

  _wsIdentityTests();
}

/// Stand-in for a transport-level failure (no dart:io in widget tests).
class SocketishFailure implements Exception {
  const SocketishFailure();
}

// ── Websocket identity guard ────────────────────────────────────────────
//
// Observed on device: a socket opened for player2 kept retrying after the
// user signed in as player1, picking up the NEW token each time, so the
// backend refused every handshake — /ws/player2?token=<player1's token>.
void _wsIdentityTests() {
  group('jwtUsername', () {
    test('reads the username claim', () {
      const player1 =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1c2VybmFtZSI6InBsYXllcjEiLCJzdWIiOiIxIiwiZXhwIjoxNzg2Nzg2NzEyLCJpYXQiOjE3ODYxODE5MTJ9.tbiivyq1tvIkoIQ3kxCP-ZSLMySLzww_izZsvKlj4Ys';
      expect(jwtUsername(player1), 'player1');
    });

    test('null when unreadable', () {
      expect(jwtUsername('opaque'), isNull);
      expect(jwtUsername(''), isNull);
    });
  });
}
