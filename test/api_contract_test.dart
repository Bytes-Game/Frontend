// Pins the request paths for endpoints whose URL was wrong in a way no
// type checker or UI test could catch: the call succeeded locally, the
// server 404'd, and the error was swallowed by a best-effort catch.
//
// Both cases below shipped broken. Asserting the exact path keeps a
// future edit from silently dropping the /api/v1 prefix again.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/services/api_service.dart';

void main() {
  late List<String> requested;

  setUp(() {
    requested = [];
    ApiService.useClient(MockClient((req) async {
      requested.add(req.url.toString());
      return http.Response(
        json.encode({'disliked': true, 'dislikes': 1, 'likes': 4}),
        200,
      );
    }));
  });

  tearDown(() => ApiService.useClient(http.Client()));

  test('recordSuggestionAccepted posts under the /api/v1 prefix', () async {
    await ApiService.recordSuggestionAccepted(
      userId: 'u1',
      lane: 'suggested_accounts',
      targetUserId: 'u2',
    );

    expect(requested, hasLength(1));
    expect(
      requested.single,
      '${AppConstants.apiBaseUrl}/api/v1/suggestions/accepted',
    );
  });

  test('dislikeChallenge hits /api/v1/challenges/dislike and parses counts',
      () async {
    final result = await ApiService.dislikeChallenge(
      challengeId: '42',
      userId: 'u1',
    );

    expect(
      requested.single,
      '${AppConstants.apiBaseUrl}/api/v1/challenges/dislike',
    );
    // The response carries the reconciled state the action bar renders.
    expect(result, isNotNull);
    expect(result!['disliked'], isTrue);
    expect(result['likes'], 4);
  });

  test('dislikeChallenge returns null on a non-2xx response', () async {
    ApiService.useClient(MockClient((_) async => http.Response('nope', 404)));

    final result = await ApiService.dislikeChallenge(
      challengeId: '42',
      userId: 'u1',
    );

    expect(result, isNull);
  });
}
