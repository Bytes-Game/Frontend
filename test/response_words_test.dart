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

import 'package:myapp/services/api_service.dart';

void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();

  group('which kind of video a tag question is about', () {
    test('the two path segments match the backend routes', () {
      // Wrong here and every call 404s, which this API layer turns into
      // "nothing to show" — the feature would look like it simply never has
      // anything to offer.
      expect(TagSubject.challenge.pathSegment, 'challenges');
      expect(TagSubject.response.pathSegment, 'challenges/responses');
    });

    test('asking is the same call with a different subject', () {
      for (final sig in [
        'static Future<TagSuggestions?> getTagSuggestions(',
        'static Future<TagSuggestions?> decideTagSuggestions(',
      ]) {
        final body = bodyOf(api, sig);
        expect(body, contains(r'${subject.pathSegment}'),
            reason: '$sig builds a fixed challenges path, so an answer can '
                'never be asked about');
      }
    });

    test('the default is a challenge, so old call sites are unchanged', () {
      for (final sig in [
        'static Future<TagSuggestions?> getTagSuggestions(',
        'static Future<TagSuggestions?> decideTagSuggestions(',
      ]) {
        expect(bodyOf(api, sig).isNotEmpty, isTrue);
        final decl = api.substring(api.indexOf(sig));
        expect(decl.substring(0, 200),
            contains('TagSubject subject = TagSubject.challenge'),
            reason: 'without a default every existing caller has to be '
                'changed, and the one that is missed silently asks about '
                'the wrong kind of video');
      }
    });
  });

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

  group('the model is offered back to whoever posted the answer', () {
    final detail =
        File('lib/pages/challenge_detail_page.dart').readAsStringSync();

    test('the response card can ask about an answer', () {
      expect(detail, contains('subject: TagSubject.response'),
          reason: 'the card asks the challenges route about a response id, '
              'which is a different video — or somebody else entirely');
    });

    test('only on your own answer', () {
      // The server checks ownership again, so this is not the security
      // boundary. It is what stops every viewer of every battle asking the
      // server about a video that is not theirs.
      expect(detail, contains('if (isMine && response.id.isNotEmpty)'));
      expect(detail, contains('isMine: dp.user?.id != null'),
          reason: 'a null viewer id must not match a blank responder id');
    });

    test('keyed by the answer, not the challenge', () {
      expect(detail, contains(r"key: ValueKey('response-tags-${response.id}')"),
          reason: 'several answers render in one list; without a key per '
              'answer Flutter reuses one state object across all of them');
    });
  });
}
