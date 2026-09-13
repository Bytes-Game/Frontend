// Telling the server how long the video is.
//
// Two separate holes, both found by reading the upload path end to end:
//
// 1. Nothing sent a length. The server has always refused a battle answer
//    shorter than two seconds, so every real answer arrived claiming ZERO
//    and was turned away as "too short". The reason came back in the
//    response body and the app threw it away, so the person saw "Could not
//    submit your response. Tap retry" and nothing else. Forever.
//
// 2. Challenges were never length-checked at all — not loosely, not at all
//    — which is how a ten-minute video got into a short-video feed and
//    stalled on every play.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/api_service.dart';

void main() {
  group('the length is actually sent', () {
    final api = File('lib/services/api_service.dart').readAsStringSync();

    test('when creating a challenge', () {
      final body = api.substring(api.indexOf('createChallenge('));
      expect(body.substring(0, body.indexOf('// ─── Challenge-creation')),
          contains("'durationMs': duration.inMilliseconds"),
          reason: 'the server cannot enforce a limit it is never told about');
    });

    test('when answering one', () {
      final at = api.indexOf('acceptChallenge(');
      final body = api.substring(at, at + 2000);
      expect(body, contains("'durationMs': duration.inMilliseconds"),
          reason: 'sending nothing means the server reads zero and refuses '
              'the answer as too short — which is what it was doing');
    });
  });

  group('the length that gets sent is the one being uploaded', () {
    final proc =
        File('lib/services/video_processor_service.dart').readAsStringSync();
    final mgr =
        File('lib/services/upload_job_manager.dart').readAsStringSync();

    test('the transcode reports what it produced, not what it was given', () {
      // The transcode cuts anything over the reel cap, so a ten-minute
      // source becomes a one-minute upload. Sending the source length would
      // refuse a video that is actually inside the limit.
      expect(proc, contains('uploadedDuration: Duration(milliseconds: clampedMs ?? sourceMs)'),
          reason: 'the length reported must be the clamped one');
    });

    test('the pipeline picks it up off the artifacts', () {
      expect(mgr, contains('if (d != null && d > uploadedDuration) uploadedDuration = d;'),
          reason: 'the transcode already knows the length; measuring it '
              'again somewhere else is a second answer that can disagree');
    });

    test('every upload path passes it on', () {
      expect('duration: uploadedDuration'.allMatches(mgr).length, 3,
          reason: 'there are three ways to post a video — create, prepared '
              'create, and answer a battle — and a path that skips this is '
              'a path with no length limit');
    });

    test('a prepared upload carries it to the post', () {
      // Prepare transcodes and uploads; finalize posts, sometimes much
      // later. Only the first sees the video.
      expect(mgr, contains('job._preparedDuration = uploadedDuration;'));
      expect(mgr, contains('final uploadedDuration = job._preparedDuration;'));
    });
  });

  group('a refusal says why', () {
    test('a 4xx carries the server\'s own words', () {
      final e = ApiRefused('video too long — maximum 180 seconds');
      expect(e.reason, 'video too long — maximum 180 seconds');
      expect(e.toString(), contains('180'),
          reason: 'this string is shown to a person');
    });

    test('the pipeline shows it instead of "try again"', () {
      final mgr =
          File('lib/services/upload_job_manager.dart').readAsStringSync();
      expect("on ApiRefused catch (e)".allMatches(mgr).length, 3,
          reason: 'a refusal caught on only some paths leaves the others '
              'telling people to retry something that can never work');
      expect("_fail(job, 'refused', e.reason)".allMatches(mgr).length, 3,
          reason: 'caught on all three paths but passed on from only some '
              'is the same dead end with extra steps');
    });

    test('only a 4xx is a refusal', () {
      // Scoped to the one function, because this file tests other status
      // codes elsewhere and a whole-file search happily matches those
      // instead — which is a test that passes with the guard deleted.
      final api = File('lib/services/api_service.dart').readAsStringSync();
      final at = api.indexOf('static Object _refusalOr(');
      expect(at, greaterThan(-1), reason: '_refusalOr is gone');
      final body = api.substring(at, api.indexOf('\n  }', at));

      expect(body, contains('res.statusCode >= 400 && res.statusCode < 500'),
          reason: 'a 500 is the server falling over, not a verdict about '
              'the video — that one really is worth retrying');
      expect(body, contains('ApiRefused('),
          reason: 'a 4xx has to come back as a refusal, not a null');
    });
  });
}
