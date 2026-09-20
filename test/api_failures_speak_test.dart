// Every backend failure gets said out loud, once.
//
// ══════════════════════════════════════════════════════════════════════════
// WHY
// ══════════════════════════════════════════════════════════════════════════
//
// Ninety-six catch blocks in this app do nothing at all, sixty-eight of them
// in api_service.dart. They almost all read:
//
//     } catch (_) {
//       return null;      // or [], or false
//     }
//
// That rule is a good one — a network hiccup must never throw into a widget
// tree. What it also does is make "the server said no" and "there is nothing
// here" produce exactly the same thing: an empty list and a quiet screen.
//
// This repo's own notes say it: "catch (_) { return; } hid a whole page
// failing for two rounds of diagnosis."
//
// It matters more than usual now. Twelve queries in the backend were broken
// for months and have just been fixed, along with the silence that hid them.
// If the app goes on swallowing the answer, half of that is wasted.
//
// The fix is one wrapper rather than sixty-eight edits, because every request
// already passes through _AuthHttp. These checks are what stop a future
// method going around it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();

  group('every request passes the place that speaks', () {
    test('all four verbs go through _say', () {
      // A fifth verb added later that skips _say is a whole class of failure
      // going quiet again, and nothing else would notice.
      for (final verb in ['get', 'post', 'patch', 'delete']) {
        final sig = 'Future<http.Response> $verb(Uri url';
        expect(api, contains(sig), reason: '$verb is gone from _AuthHttp');
        final at = api.indexOf(sig);
        final upTo = api.indexOf('Future<http.Response> _say', at);
        final region = api.substring(at, upTo > at ? upTo : api.length);
        expect(region.contains("_say('${verb.toUpperCase()}'"), isTrue,
            reason: '$verb does not go through _say, so anything that fails '
                'on that verb fails in silence');
      }
    });

    test('a failed request is reported and still rethrown', () {
      // The callers all catch. Swallowing it HERE would change behaviour —
      // a caller expecting an exception would get a broken response object
      // instead, which is a worse failure than the one being fixed.
      final body = bodyOf(api, 'Future<http.Response> _say(');
      expect(body, contains('rethrow'),
          reason: 'the wrapper swallows the exception instead of passing it '
              'on, which changes what every caller sees');
      expect(body, contains('_note('),
          reason: 'nothing is said when a request fails');
    });

    test('a non-2xx answer is reported too', () {
      // Many callers read `if (res.statusCode != 200) return null;` — so a
      // 403 or a 500 is exactly as quiet as a thrown exception.
      final body = bodyOf(api, 'Future<http.Response> _say(');
      expect(body, contains('res.statusCode < 200 || res.statusCode >= 300'),
          reason: 'only thrown exceptions are reported, so a server that '
              'answers 500 is still silent');
    });
  });

  group('it cannot drown the log', () {
    test('a repeating failure is counted, not repeated', () {
      // Diagnosing this app has always meant reading a whole logcat capture.
      // A dead endpoint called on every scroll would bury everything else,
      // which is its own bug.
      final body = bodyOf(api, 'void _note(');
      expect(body, contains('_saidBefore'),
          reason: 'nothing counts repeats, so one broken endpoint fills the '
              'log and hides whatever else is in it');
      expect(body, contains('n == 1'),
          reason: 'the first occurrence should always be printed');
    });
  });

  group('a log line is not a place for somebody\'s id', () {
    test('only the path is logged, never the query string', () {
      final body = bodyOf(api, 'Future<http.Response> _say(');
      expect(body, contains('url.path'),
          reason: 'the URL is logged whole. Query strings on this API carry '
              'user ids, and a log is shared far more casually than a '
              'database is.');
      expect(body.contains('url.toString()'), isFalse,
          reason: 'logging the whole URL puts the query string in the log');
    });
  });
}
