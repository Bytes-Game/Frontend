// Every quality rung has to be listed in every table that mentions rungs.
//
// ════════════════════════════════════════════════════════════════════════════
// THE BUG THIS EXISTS FOR
// ════════════════════════════════════════════════════════════════════════════
//
// A rendition is a real file. The server spends encode time on it, pays to
// store it, and hands the app its address. Whether the app can ever play it
// depends on the rung's name appearing in four separate places in one file:
//
//   bitrateNeededFor   what it costs      — missing: the picker skips it
//   _labelRank         how good it is     — missing: it sorts as the worst
//   decodeRank         how hard to decode — missing: hidden from every phone
//   _preferenceOrder   three fallback lists, one per kind of connection
//                                         — missing from one: never chosen
//                                           on that kind of connection
//
// None of those failures says anything. The file exists, the app plays
// something else, and the only evidence is a storage bill.
//
// This is the check that adding a rung means adding it everywhere. It reads
// the source, because three of those four are private to the class — and it
// strips the comments first, because this repo has twice shipped a test that
// matched the words in the comment explaining a trap rather than the code
// that avoids it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/decoder_budget.dart';
import 'package:myapp/services/network_quality_service.dart';

/// Pretend this phone has a hardware H.265 decoder, or does not.
///
/// The name matters: `c2.android.*` is Android's own SOFTWARE decoder, and
/// the picker must treat that as "no". Software H.265 would decode a
/// full-screen reel at a few frames a second while emptying the battery,
/// which is worse than the H.264 file it replaced.
void setHevc(bool hardware) {
  DecoderBudget.instance.hevcByCodec =
      hardware ? const {'c2.qti.hevc.decoder': 8} : const {};
}

void setSoftwareOnlyHevc() {
  DecoderBudget.instance.hevcByCodec = const {'c2.android.hevc.decoder': 32};
}

/// The file with every line comment and doc comment taken out.
///
/// Without this, a test looking for `'360p'` finds it in the paragraph
/// explaining why 360p was added and passes against code that never lists it.
String codeOnly(String src) {
  final out = <String>[];
  for (final line in src.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('//')) continue;
    out.add(line);
  }
  return out.join('\n');
}

/// The body of the first `{...}` block that follows [marker], balanced.
String blockAfter(String src, String marker) {
  final at = src.indexOf(marker);
  expect(at, greaterThanOrEqualTo(0),
      reason: 'network_quality_service.dart no longer contains "$marker", so '
          'this check is reading nothing. Fix the test rather than deleting '
          'it.');
  final open = src.indexOf('{', at);
  expect(open, greaterThanOrEqualTo(0), reason: 'no block after "$marker"');
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}') {
      depth--;
      if (depth == 0) return src.substring(open + 1, i);
    }
  }
  fail('the block after "$marker" is never closed');
}

void main() {
  final source = codeOnly(
      File('lib/services/network_quality_service.dart').readAsStringSync());

  // The list every other check is measured against. It is the picker's own
  // cost table, so a rung it does not know about cannot be tested for — which
  // is why bitrateNeededFor is the one table that is public.
  final labels = NetworkQualityService.bitrateNeededFor.keys.toList();

  test('there is something to check', () {
    // The shape of failure this whole file is guarding against: a check that
    // reads nothing and reports a clean pass.
    expect(labels.length, greaterThanOrEqualTo(4),
        reason: 'only ${labels.length} rungs were found, so the checks below '
            'are barely checking anything');
    expect(labels, contains('360p'));
    expect(labels, contains('720p'));
    expect(source.length, greaterThan(5000),
        reason: 'the source came back nearly empty after stripping comments');
  });

  test('every rung has a quality rank', () {
    final rank = blockAfter(source, 'static const Map<String, int> _labelRank');
    for (final label in labels) {
      expect(rank, contains("'$label'"),
          reason: 'the picker knows what $label costs but not how good it '
              'looks, so it sorts below every other rung and is only ever '
              'reached as a last resort');
    }
  });

  test('every rung has a decode cost', () {
    final rank = blockAfter(source, 'const decodeRank =');
    for (final label in labels) {
      expect(rank, contains("'$label'"),
          reason: 'decodeRank has no entry for $label, so the ?? 99 fallback '
              'puts it above what any phone can decode and it is dropped for '
              'every viewer');
    }
  });

  test('every rung appears in all three fallback orders', () {
    // One order per kind of connection. A rung left out of one of them is a
    // file that exists and can never be chosen by anybody on that kind of
    // connection — which is exactly the mistake 360p invited, since the
    // obvious thing is to add it to the slow list and stop.
    final body = blockAfter(source, 'List<String> _preferenceOrder(');
    final orders = RegExp(r"trim\(const \[([^\]]*)\]\)")
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    expect(orders.length, 3,
        reason: 'expected three fallback orders and found ${orders.length}; '
            'this check is not reading what it thinks it is');
    for (var i = 0; i < orders.length; i++) {
      for (final label in labels) {
        expect(orders[i], contains("'$label'"),
            reason: 'fallback order ${i + 1} does not list $label, so nobody '
                'on that kind of connection will ever be served it');
      }
    }
  });

  test('the floor is the cheapest rung, not the second cheapest', () {
    // affordableLabel starts from a label and only ever raises it. So that
    // starting label is a FLOOR: no measurement, however slow, can produce
    // anything below it. Set to the wrong rung, the cheapest file the server
    // makes becomes one the app can never choose.
    final body = blockAfter(source, 'String? get affordableLabel');
    final floor = RegExp(r"String best = '([^']+)';").firstMatch(body);
    expect(floor, isNotNull,
        reason: 'affordableLabel no longer starts from a named rung, so this '
            'check cannot see what the floor is');

    final entries = NetworkQualityService.bitrateNeededFor.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    expect(floor!.group(1), entries.first.key,
        reason: 'the floor is ${floor.group(1)} but the cheapest rung the '
            'server makes is ${entries.first.key}. Everything below the floor '
            'is encoded, stored, and unreachable.');
  });

  test('every rung can be played when it is the only one a video has', () {
    // The end-to-end version of all of the above, through the real picker
    // rather than through the source. A freshly uploaded video has exactly
    // one entry in its rendition map for the minutes before the server has
    // converted it, and that one has to play whatever it is called.
    //
    // On a phone that can decode H.265, that includes the H.265 rungs.
    setHevc(true);
    addTearDown(() => setHevc(false));
    final net = NetworkQualityService.instance;
    for (final speed in [0.3, 2.6, 10.0]) {
      net.debugClearThroughput();
      const bytes = 768 * 1024;
      final ms = (bytes * 8 * 1000 / (speed * 1e6)).round();
      for (var i = 0; i < 4; i++) {
        net.recordThroughput(bytes, Duration(milliseconds: ms));
      }
      for (final label in labels) {
        expect(net.pickVariantUrl({label: 'only'}), 'only',
            reason: 'a video whose only rendition is $label played nothing '
                'on a ${speed}Mbps link');
      }
    }
    net.debugClearThroughput();
  });

  _hevcTests();

  test('a slow link is actually given the cheapest rung', () {
    // The presence half. Every check above asks whether a label is listed
    // somewhere; this one asks whether the whole chain produces it.
    final net = NetworkQualityService.instance;
    net.debugClearThroughput();
    net.debugSetQuality(NetworkQuality.medium);
    const bytes = 768 * 1024;
    // 2.6 Mbps: real mobile data, and the number the rung was added for.
    final ms = (bytes * 8 * 1000 / 2.6e6).round();
    for (var i = 0; i < 4; i++) {
      net.recordThroughput(bytes, Duration(milliseconds: ms));
    }
    final entries = NetworkQualityService.bitrateNeededFor.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final cheapest = entries.first.key;

    expect(net.affordableLabel, cheapest,
        reason: 'at 2.6 Mbps — ordinary mobile data — the link cannot carry '
            'anything above $cheapest once read-ahead is paid for');

    final variants = {for (final l in labels) l: 'url-$l'};
    expect(net.pickVariantUrl(variants), 'url-$cheapest',
        reason: 'the picker knew it could only afford $cheapest and served '
            'something else anyway');
    net.debugClearThroughput();
  });
}

// ════════════════════════════════════════════════════════════════════════════
// THE NEWER CODEC, AND THE PHONES THAT CANNOT READ IT
// ════════════════════════════════════════════════════════════════════════════
//
// H.265 files are a third smaller for the same picture. Older phones cannot
// decode them at all — not slowly, not softly: a black screen.
//
// Every other decision in the picker trades quality against stalling, and
// being wrong costs a soft picture or a pause. This one costs the video. So
// it gets its own group, and the tests are written the pessimistic way round:
// the question is never "does a capable phone get the good file", it is
// "can an incapable phone EVER be handed one".

void _hevcTests() {
  final net = NetworkQualityService.instance;

  void linkAt(double mbps) {
    net.debugClearThroughput();
    const bytes = 768 * 1024;
    final ms = (bytes * 8 * 1000 / (mbps * 1e6)).round();
    for (var i = 0; i < 4; i++) {
      net.recordThroughput(bytes, Duration(milliseconds: ms));
    }
  }

  final hevcLabels = NetworkQualityService.bitrateNeededFor.keys
      .where(NetworkQualityService.isHevc)
      .toList();

  group('a phone with no H.265 decoder is never handed an H.265 file', () {
    setUp(() {
      setHevc(false);
      net.debugClearThroughput();
      net.debugSetQuality(NetworkQuality.high);
    });
    tearDown(() {
      setHevc(false);
      net.debugClearThroughput();
    });

    test('there are H.265 rungs to get wrong', () {
      // The absence checks below would all pass against a picker that knows
      // no H.265 at all. This is the presence half.
      expect(hevcLabels, isNotEmpty,
          reason: 'no H.265 rungs exist, so nothing below is being tested');
      expect(hevcLabels, contains('720p_hevc'));
    });

    test('not as the ceiling, at any speed', () {
      for (final mbps in [0.3, 1.0, 2.0, 2.6, 4.0, 8.0, 20.0, 100.0]) {
        linkAt(mbps);
        final label = net.affordableLabel;
        expect(NetworkQualityService.isHevc(label ?? ''), isFalse,
            reason: 'at $mbps Mbps the best file it thinks it can carry is '
                '$label, which this phone cannot decode at all');
      }
    });

    test('not when the video has both, at any speed', () {
      final both = {
        for (final l in NetworkQualityService.bitrateNeededFor.keys) l: 'url-$l'
      };
      for (final mbps in [0.3, 2.6, 8.0, 50.0]) {
        linkAt(mbps);
        final picked = net.pickVariantUrl(Map.of(both));
        expect(picked, isNotNull);
        for (final h in hevcLabels) {
          expect(picked, isNot('url-$h'),
              reason: 'at $mbps Mbps it picked $h, a black screen on this phone');
        }
      }
    });

    test('and not through the last-resort branch either', () {
      // The branch that runs when nothing in the preference order matched.
      // It used to hand back literally any rendition, which was safe while
      // every file was H.264. With H.265 in the map it is a black screen.
      //
      // Empty is the right answer: every caller falls back to the original
      // upload, which came off a camera and is always H.264.
      linkAt(8.0);
      final onlyHevc = {for (final h in hevcLabels) h: 'url-$h'};
      expect(net.pickVariantUrl(onlyHevc), '',
          reason: 'a video with only H.265 renditions must send this phone '
              'back to the original upload, not to a file it cannot decode');
    });

    test('a software H.265 decoder still counts as no', () {
      // Android ships one on phones whose chip has none. It would decode a
      // full-screen reel at a few frames a second while emptying the
      // battery — worse than the H.264 file it replaced.
      //
      // Measured at 4 Mbps on purpose. This first read 8, where the best
      // affordable rung is 720p_hq whether or not H.265 is allowed — so it
      // passed with the hardware check deleted, which is the one thing it
      // exists to catch. 4 Mbps is a speed where a wrong yes shows up.
      setSoftwareOnlyHevc();
      linkAt(4.0);
      expect(net.affordableLabel, '480p',
          reason: 'software H.265 was treated as real support, so this phone '
              'would be sent a file it can only decode in software');

      // And the same link with a real decoder does take it — otherwise this
      // is asserting that nothing happens, which would pass on a picker that
      // knows no H.265 at all.
      setHevc(true);
      expect(net.affordableLabel, '720p_hevc');
    });
  });

  group('a phone that can decode H.265 is actually given it', () {
    setUp(() {
      setHevc(true);
      net.debugClearThroughput();
      net.debugSetQuality(NetworkQuality.medium);
    });
    tearDown(() {
      setHevc(false);
      net.debugClearThroughput();
    });

    test('the whole point: 720p on a link that could only carry 480p', () {
      // 720p_hevc costs what plain 480p costs. So a connection that could
      // only manage the 480p picture before now gets the full 720p one.
      linkAt(4.0);
      final capable = net.affordableLabel;

      setHevc(false);
      final notCapable = net.affordableLabel;

      expect(capable, '720p_hevc',
          reason: 'a phone that can decode H.265 should be offered the '
              '720p picture at 1.5 Mbps on a 4 Mbps link');
      expect(notCapable, '480p',
          reason: 'and the same link on a phone that cannot is still 480p — '
              'if these two are equal the feature is doing nothing');
    });

    test('it prefers the smaller file when both would play', () {
      linkAt(50.0);
      final variants = {'720p': 'big', '720p_hevc': 'small'};
      expect(net.pickVariantUrl(variants), 'small',
          reason: 'both play and both are the same picture, so the one that '
              'costs less to send is the one to send');
    });

    test('and still falls back when the video has no H.265 copy', () {
      linkAt(8.0);
      expect(net.pickVariantUrl({'720p': 'only'}), 'only',
          reason: 'everything uploaded before H.265 existed still has to play');
    });
  });
}
