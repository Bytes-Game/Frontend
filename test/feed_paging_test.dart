// Tests for the "is there another page?" decision.
//
// Background: a device run showed the reels feed stop at fifteen items
// and never request another page, across twenty-plus playbacks. That
// particular feed really had run out — but the run could not say so,
// because the client read `data['hasMore'] == true`, which is false for
// a response that omitted the key exactly as it is for one that said
// `false`. A feed truncated by a missing field and a feed that genuinely
// ended were the same observation.

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/feed_paging.dart';

void main() {
  bool decide({
    Object? declared,
    int rawCount = 20,
    int newItems = 20,
    int limit = 20,
  }) =>
      FeedPaging.hasMoreAfter(
        declared: declared,
        rawCount: rawCount,
        newItems: newItems,
        limit: limit,
      );

  group('the server declared an answer', () {
    test('true is honoured even on a short page', () {
      // Only the server knows; a short page can still have more behind
      // it if it filtered items out after paging.
      expect(decide(declared: true, rawCount: 3, newItems: 3), isTrue);
    });

    test('false is honoured even on a full page', () {
      expect(decide(declared: false, rawCount: 20, newItems: 20), isFalse);
    });
  });

  group('the server declared nothing', () {
    test('a full page is assumed to have more behind it', () {
      // The regression this exists for: absent must not read as "no more".
      expect(decide(declared: null, rawCount: 20, newItems: 20), isTrue);
    });

    test('a short page is the end of the feed', () {
      expect(decide(declared: null, rawCount: 15, newItems: 15), isFalse);
    });

    test('a page of nothing but duplicates stops, not loops', () {
      // A server replaying a page it already sent yields no new items
      // after dedup. Asking again would re-request it forever.
      expect(decide(declared: null, rawCount: 20, newItems: 0), isFalse);
    });

    test('a non-bool value is treated as no answer at all', () {
      // Some backends send "true"/1. Neither is a bool, and guessing at
      // them is how a truthiness bug gets in — fall back to the page-size
      // rule instead, which is right either way for a full page.
      expect(decide(declared: 'true', rawCount: 20, newItems: 20), isTrue);
      expect(decide(declared: 1, rawCount: 4, newItems: 4), isFalse);
    });
  });

  test('an over-full page still counts as full', () {
    // A server that ignores `limit` and returns more than asked has
    // certainly not run out.
    expect(decide(declared: null, rawCount: 50, newItems: 50, limit: 20),
        isTrue);
  });
}
