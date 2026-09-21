// The feed log could not say which ranker answered.
//
// A device log showed the same seventeen videos served twice, with the
// server insisting every one of them was new:
//
//   feed forYou page 1: 17 items  new=17 repeat=0 againThisRun=0
//   feed forYou page 1: 17 items  new=17 repeat=0 againThisRun=18
//
// The explanation was in the SAME response the whole time — `coldStart:
// true` — and nothing read it. Hours went into working out from the outside
// what one unread field said outright.
//
// The cold-start ranker is a different machine: it pages by page NUMBER
// rather than by what you have watched, so page 1 is identical every time
// it is asked for, and it caps each page per kind, which is why those pages
// were short. `cold=true` next to a repeat means the new-user path;
// `cold=false` next to a repeat means something else entirely. Without it
// the two look the same.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/widgets/smart_reels_feed.dart').readAsStringSync();

  group('the feed log says which ranker answered', () {
    test('the server\'s coldStart flag is read off the response', () {
      final body = bodyOf(src, 'Future<void> _loadNextPage(');
      expect(body.contains("data['coldStart']"), isTrue,
          reason: 'The server sends coldStart on every feed response and '
              'nothing reads it. That flag is the difference between "the '
              'new-user ranker is repeating itself" and "something else is", '
              'and without it an investigation has to infer from the outside '
              'what the response already stated.');
    });

    test('and it reaches the log line', () {
      final body = bodyOf(src, 'void _logPageComposition(');
      expect(body.contains('cold='), isTrue,
          reason: 'Read but not logged is the same as not read: the device '
              'log is the only place this is ever seen.');
      expect(body.contains(r'${coldStart == true}'), isTrue,
          reason: 'Print the resolved boolean, not the raw value — the field '
              'is absent on some paths, and "cold=null" in a log reads as a '
              'broken logger rather than as "the warm ranker answered".');
    });

    test('the counters it has to sit beside are still there', () {
      // The presence half. Every check above is about ONE field; a log line
      // rewritten to print only that field would pass all of them while
      // losing the two counters that named the problem in the first place.
      final body = bodyOf(src, 'void _logPageComposition(');
      for (final field in ['new=', 'repeat=', 'againThisRun=', 'raw=']) {
        expect(body.contains(field), isTrue,
            reason: '$field went missing from the feed log. repeat and '
                'againThisRun together are what tell "the catalogue ran out" '
                'apart from "the server is not recording what it showed" — '
                'neither settles it alone.');
      }
    });
  });
}
