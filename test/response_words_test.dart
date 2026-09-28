// A battle answer gets to say what it is, too.
//
// The app has always sent a challenge's category and tags. It sent nothing at
// all about the answer half of a battle, because the database had nowhere to
// put it — so half of what a viewer watches was described by nobody. The
// backend has those columns now, and these are the app-side wires into them.
//
// Every check here is against the SOURCE rather than a live call, for the same
// reason the rest of this suite is: the failure being guarded against is a
// path that quietly stops being sent, and a test that calls the far end by
// hand would pass with the wire cut.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';


void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();

  group('posting an answer says what it is', () {
    const sig = 'static Future<ChallengeResponseModel?> acceptChallenge(';

    test('the three fields reach the request', () {
      final body = bodyOf(api, sig);
      for (final field in ['category', 'tags', 'emotionTags']) {
        expect(body, contains("'$field'"),
            reason: 'the app collects $field and never sends it, so the '
                'column it was added for stays empty forever');
      }
    });

    test('an empty one is left out rather than sent blank', () {
      final body = bodyOf(api, sig);
      // The server falls back to the challenge being answered when the
      // category is absent. Sending an empty string instead of omitting it
      // would still be "absent" to the server today, but it is one rename
      // away from being a stored empty category — which reads as a claim
      // that the video is nothing.
      expect(body, contains("if (category.isNotEmpty) 'category': category"));
      expect(body, contains("if (tags.isNotEmpty) 'tags': tags"));
      expect(body,
          contains("if (emotionTags.isNotEmpty) 'emotionTags': emotionTags"));
    });

    test('all three are optional, so an older call site still compiles', () {
      final decl = api.substring(api.indexOf(sig));
      final params = decl.substring(0, decl.indexOf('}) async'));
      for (final d in [
        "String category = ''",
        'List<String> tags = const []',
        'List<String> emotionTags = const []',
      ]) {
        expect(params, contains(d),
            reason: 'a required parameter here breaks every caller, and the '
                'server has a working answer for each of these when absent');
      }
    });
  });
}
