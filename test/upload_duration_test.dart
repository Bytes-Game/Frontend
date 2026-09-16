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

import 'support/dart_source.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/services/clip_length.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/video_processor_service.dart';

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

  group('one length limit, not three', _oneLimit);

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

// ══════════════════════════════════════════════════════════════════════════
// ONE LENGTH LIMIT, NOT THREE
// ══════════════════════════════════════════════════════════════════════════
//
// Added as its own group because the limit lived in three places at once:
// the trim screen (60s, commented "mirrors processor cap"), the transcode
// (60s), and the server (3 minutes, and only for battle answers). A mirror
// is a second number, and a second number is one that can stop matching.

void _oneLimit() {
  test('the app takes the same three minutes the server does', () {
    expect(AppConstants.maxVideoDuration, const Duration(minutes: 3),
        reason: 'the server refuses anything over three minutes and '
            'measures the file to be sure — a different number here only '
            'means uploads that are paid for and then thrown away');
  });

  test('the transcode reads it rather than keeping its own', () {
    expect(VideoProcessorService.maxReelDuration,
        AppConstants.maxVideoDuration);

    final src =
        File('lib/services/video_processor_service.dart').readAsStringSync();
    expect(src, contains('maxReelDuration = AppConstants.maxVideoDuration'),
        reason: 'written out again rather than read, so the two can drift');
  });

  test('the trim screen reads it rather than keeping its own', () {
    final src = File('lib/pages/video_trim_page.dart').readAsStringSync();
    expect(src,
        contains('_hardCapMs = VideoProcessorService.maxReelDuration.inMilliseconds'),
        reason: 'this is where the copy was, with a comment admitting it');
    expect(src, isNot(contains('60 * 1000')),
        reason: 'the old copy is back');
  });

  test('the picker offers lengths, the cap refuses them', () {
    // Two different jobs. The picker is what this person asked for; the
    // cap is what the server will take. Confusing them either offers a
    // length the upload will be refused for, or silently shortens a clip
    // somebody explicitly chose.
    final src = File('lib/pages/video_trim_page.dart').readAsStringSync();

    // The slider clamps to the CHOICE.
    final slider = bodyOf(src, 'void _onSliderChanged(RangeValues v)');
    expect(slider, contains('_limitMs'),
        reason: 'the handles let you select past the length you picked');
    expect(slider, isNot(contains('_hardCapMs')),
        reason: 'clamping to the cap ignores the picker entirely — pick '
            '30s and the slider still gives you three minutes');

    // The window opens at the CHOICE.
    expect(src, contains('dur.inMilliseconds.clamp(0, _limitMs)'),
        reason: 'the screen opens showing the cap rather than the length '
            'that is actually selected, so it posts three minutes unless '
            'you notice');

    // The final guard is against the CAP.
    final use = bodyOf(src, 'Future<void> _onUseClip()');
    expect(use, contains('spanMs > _hardCapMs'),
        reason: 'the last check before upload has to be the server\'s '
            'limit; checking the picker would let a bug past it');
  });

  test('the picker can never offer more than the server takes', () {
    for (final d in ClipLength.optionsWithin(AppConstants.maxVideoDuration)) {
      expect(d <= AppConstants.maxVideoDuration, isTrue,
          reason: '$d would be offered and then refused after the upload '
              'has already been paid for');
    }
  });

  test('recording stops at the same place', () {
    // Not a separate number either — the record screen already reads the
    // processor's, and it has to keep doing that or someone records four
    // minutes and is refused after the upload.
    final src = File('lib/pages/record_video_page.dart').readAsStringSync();
    expect(src, contains('VideoProcessorService.maxReelDuration'));
  });
}
