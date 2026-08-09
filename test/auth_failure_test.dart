// Tests for telling apart "your password is wrong" from "the server never
// answered".
//
// The bug these exist for: ApiService.login returned null for every failure —
// a 401, a 500, a DNS error, and a timeout were all the same value. The login
// screen could therefore only ever say "Invalid username or password."
//
// That is not a cosmetic problem. This backend runs on Render's free tier,
// sleeps after inactivity, and takes the better part of a minute to wake, so a
// login landing on a cold start times out as a matter of routine. The app
// responded by telling the user their password was wrong. It happened on a
// real device, to the person who owns the account, with the correct password.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';

void main() {
  tearDown(() => ApiService.useClient(http.Client()));

  test('valid credentials return the session payload', () async {
    ApiService.useClient(MockClient((_) async =>
        http.Response('{"token":"abc","user":{"id":1}}', 200)));

    final r = await ApiService.login('player1', 'pass1');

    expect(r.ok, isTrue);
    expect(r.failure, isNull);
    expect(r.data!['token'], 'abc');
    expect(ApiService.authToken, 'abc');
  });

  test('a 401 is reported as rejected — the password really is wrong',
      () async {
    ApiService.useClient(
        MockClient((_) async => http.Response('bad credentials', 401)));

    final r = await ApiService.login('player1', 'wrong');

    expect(r.ok, isFalse);
    expect(r.failure, AuthFailure.rejected);
  });

  test('a timeout is NOT reported as bad credentials', () async {
    // The cold-start case, and the whole reason this file exists.
    ApiService.useClient(MockClient((_) async {
      throw TimeoutException('connection timed out');
    }));

    final r = await ApiService.login('player1', 'pass1');

    expect(r.failure, AuthFailure.unreachable,
        reason: 'a server that never answered has said nothing about the '
            'password; calling this "rejected" sends the user off resetting '
            'a password that was correct');
  });

  test('a dropped connection is unreachable, not rejected', () async {
    ApiService.useClient(MockClient((_) async {
      throw const SocketExceptionLike();
    }));

    final r = await ApiService.login('player1', 'pass1');
    expect(r.failure, AuthFailure.unreachable);
  });

  test('a 502 from a waking server is a server error, not bad credentials',
      () async {
    // Render answers a cold start with its own holding page before the app
    // is up. That is emphatically not a statement about the password.
    ApiService.useClient(MockClient(
        (_) async => http.Response('<html>Bad Gateway</html>', 502)));

    final r = await ApiService.login('player1', 'pass1');

    expect(r.failure, AuthFailure.serverError);
    expect(r.failure, isNot(AuthFailure.rejected));
  });

  test('a 500 is a server error', () async {
    ApiService.useClient(
        MockClient((_) async => http.Response('boom', 500)));

    expect((await ApiService.login('a', 'b')).failure,
        AuthFailure.serverError);
  });

  test('malformed success body does not masquerade as valid credentials',
      () async {
    // A 200 carrying junk cannot be decoded; treating that as a successful
    // login would authenticate someone with no token at all.
    ApiService.useClient(
        MockClient((_) async => http.Response('not json at all', 200)));

    final r = await ApiService.login('a', 'b');

    expect(r.ok, isFalse);
    expect(r.failure, AuthFailure.unreachable);
  });

  group('signup', () {
    test('201 is success', () async {
      ApiService.useClient(MockClient(
          (_) async => http.Response('{"token":"t","user":{"id":2}}', 201)));

      expect((await ApiService.signup('new', 'pw')).ok, isTrue);
    });

    test('409 taken is rejected, not a network problem', () async {
      ApiService.useClient(
          MockClient((_) async => http.Response('taken', 409)));

      expect((await ApiService.signup('taken', 'pw')).failure,
          AuthFailure.rejected);
    });

    test('an unreachable server during signup is not "username taken"',
        () async {
      ApiService.useClient(MockClient((_) async {
        throw TimeoutException('timed out');
      }));

      expect((await ApiService.signup('new', 'pw')).failure,
          AuthFailure.unreachable,
          reason: 'telling someone their chosen name is taken when the '
              'server never answered is the same lie in a different shape');
    });
  });
}

/// Stand-in for a socket-level failure. The concrete type does not matter —
/// what matters is that anything thrown by the transport lands as
/// `unreachable` rather than being read as a verdict on the credentials.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
