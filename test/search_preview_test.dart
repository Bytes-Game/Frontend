// The search grid was streaming the raw upload.
//
// ChallengeModel.videoUrl is the file the phone sent, before the server
// re-encoded it. The feed has never played that — it picks a rendition sized
// for the connection. The search grid played the original.
//
// Measured across ten videos in this app:
//
//   video 43     1.0 MB raw     1.0 MB chosen     same
//   video 48     3.6 MB raw     2.0 MB chosen     1.8x
//   video 49    13.9 MB raw     2.4 MB chosen     5.8x
//   video 38    57.8 MB raw     4.5 MB chosen    12.9x
//
// On the link this app actually sees, 2 to 4 Mbps, 57 MB is not a video that
// plays. That is "every video on the search page sticks", and the feed being
// fine at the same moment is the clue: the two pages never shared this code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/pages/search_page.dart').readAsStringSync();

  group('a preview plays what the feed would play', () {
    test('the rendition is picked for the connection', () {
      final body = bodyOf(src, 'String _originUrl()');
      expect(body, contains('pickVariantUrl(c.videoVariants)'),
          reason: 'without this the grid streams the raw upload — up to '
              'thirteen times the bytes, on the slowest thing in the app');
    });

    test('the raw upload is only the fallback', () {
      final body = bodyOf(src, 'String _originUrl()');
      expect(body, contains(': c.videoUrl'),
          reason: 'a video with no renditions yet still has to play');
      final pickAt = body.indexOf('pickVariantUrl');
      final rawAt = body.indexOf('c.videoUrl');
      expect(pickAt, lessThan(rawAt),
          reason: 'the raw file must be the fallback, not the first choice');
    });

    test('the player is handed the bytes already on the phone', () {
      // ═══════════════════════════════════════════════════════════════════
      // THIS TEST USED TO ASSERT THE OPPOSITE. HERE IS WHY IT CHANGED.
      // ═══════════════════════════════════════════════════════════════════
      //
      // The proxy was taken off this path once, because the build that put
      // it here was the build where previews stopped playing altogether.
      // The note left at the time was honest that this could not be proved
      // and that the proxy was only the newest thing on the path.
      //
      // It has since been proved, and it was not the proxy. The grid was
      // holding fifteen of the phone's video decoders — it paused tiles
      // instead of releasing them — so there were none left to open
      // anything with. In the device log after that fix: 93 decoders asked
      // for, 93 granted, no playback failures at all.
      //
      // Meanwhile this page was downloading the opening of every visible
      // preview and then streaming the origin anyway, so the same bytes
      // were fetched twice and the tile sat waiting for the second copy.
      // That is the "sticks for a few seconds then plays" everybody saw.
      final body = bodyOf(src, 'String _previewUrl()');
      expect(body, contains('playbackUrlFor('),
          reason: 'warming the opening and then streaming the origin means '
              'paying for the head start and never using it');
      expect(body, contains('_originUrl()'),
          reason: 'the cache is asked about the ORIGIN, which is the name '
              'the warmed bytes are filed under');
    });

    test('a preview that cannot open says so', () {
      // It used to `catch (_) { return; }`. A page where every preview
      // failed looked exactly like a page where every preview was slow:
      // no error, no log line, nothing to tell them apart. A whole round
      // of diagnosis went into guessing at it.
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('search preview failed to open'),
          reason: 'the failure is swallowed again, so the next time this '
              'breaks there will be no evidence of it');
      expect(body, isNot(contains('} catch (_) {')),
          reason: 'the reason is discarded');
    });

    test('and it is actually used', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      final entry = bodyOf(src, 'Future<void> _ensurePlayerAndPlay()');
      expect(entry, contains('_openAndPlay(_previewUrl())'),
          reason: 'the choice is made and then ignored, which is the bug '
              'with extra code');
      expect(body, isNot(contains('widget.challenge.videoUrl')),
          reason: 'the raw upload is read directly again');
    });
  });

  group('one choice, not two', () {
    test('the played url is built from the warmed one', () {
      // Two copies of "which rendition" could disagree, and then the tile
      // warms one file and plays another — which costs the bandwidth and
      // fixes nothing.
      final body = bodyOf(src, 'String _previewUrl()');
      expect(body, contains('_originUrl()'),
          reason: 'the play path picks the rendition again on its own');
      expect(body, isNot(contains('pickVariantUrl')),
          reason: 'the choice is repeated here instead of reused');
    });

    test('warming still uses the cache, even though playback does not', () {
      // Warming is not wasted by playing the origin: tapping a result opens
      // the real reels feed, and THAT goes through the proxy.
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, contains('VideoCacheService.instance.warm('));
    });

    test('warming is keyed by the origin, not the proxy address', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, isNot(contains('playbackUrlFor')),
          reason: 'the cache files bytes under the ORIGIN url; warming the '
              'proxy address stores them under a name nothing looks up');
      final report = bodyOf(src, 'Widget build(BuildContext context)');
      expect(src, contains('url: _originUrl()'),
          reason: 'the tile reports the proxied url, so the coordinator '
              'warms the wrong name');
      expect(report, isNotEmpty);
    });
  });

  group('warming does not fight itself', _churn);

  group('the previews about to play are fetched first', () {
    test('visible tiles are warmed', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, contains('VideoCacheService.instance.warm('),
          reason: 'nothing is fetched ahead, so every preview starts from '
              'byte zero against the network');
    });

    test('most visible first', () {
      final body = bodyOf(src, 'void _warmVisible()');
      expect(body, contains('b.value.compareTo(a.value)'),
          reason: 'unordered warming puts the tile about to take its turn '
              'behind two the user is scrolling past');
    });

    test('and the window is shallow', () {
      final m = RegExp(r'_warmAhead\s*=\s*(\d+)').firstMatch(src);
      expect(m, isNotNull, reason: 'the window is gone');
      final n = int.parse(m!.group(1)!);
      expect(n, greaterThan(0), reason: 'zero warms nothing, which is the bug');
      expect(n, lessThanOrEqualTo(4),
          reason: 'bytes spent ahead are bytes the preview playing right '
              'now does not get — the feed learned this the hard way');
    });

    test('a tile that scrolls away stops being warmed', () {
      final body = bodyOf(src, 'void report(String tileId, double fraction');
      expect(body, contains('_urls.remove(tileId)'),
          reason: 'urls pile up for tiles nobody can see, and the warm '
              'window fills with them');
    });

    test('warming runs when visibility changes, not only on activation', () {
      final body = bodyOf(src, 'void report(String tileId, double fraction');
      expect(body, contains('_warmVisible()'),
          reason: 'warming only when a tile activates is warming a video at '
              'the moment it needs to play, which is too late');
    });
  });
}

// ══════════════════════════════════════════════════════════════════════════
// WARMING MADE IT WORSE BEFORE IT MADE IT BETTER
// ══════════════════════════════════════════════════════════════════════════
//
// Measured on device across three builds:
//
//   no warming on the grid at all      80% of starts warm    1 of 32 cancelled
//   warming on every visibility report 50% of starts warm   17 of 33 cancelled
//
// report() fires every frame a finger is moving. warm() cancels whatever has
// dropped out of the list it is handed, so calling it on each report cancels
// and restarts the same downloads over and over — they never got far enough
// to be worth anything, and they took the bandwidth from the preview that was
// actually playing.

void _churn() {
  final src = File('lib/pages/search_page.dart').readAsStringSync();

  test('an unchanged list is not handed over again', () {
    final body = bodyOf(src, 'void _warmVisible()');
    expect(body, contains('_sameList(urls, _lastWarmed)'),
        reason: 'every visibility frame re-warms, which cancels the '
            'downloads it started on the frame before');
    expect(body, contains('_lastWarmed = urls'),
        reason: 'the comparison never updates, so it either always fires '
            'or never does');
  });

  test('the rendition is picked once per tile, not once per frame', () {
    final body = bodyOf(src, 'String _originUrl()');
    expect(body, contains('final cached = _origin;'),
        reason: 'the picker runs on every visibility report — four hundred '
            'times in one scroll, for the same answer');
    expect(body, contains('_origin = chosen;'));
  });

  test('the list comparison is by order too', () {
    // Order is the whole point: the tile about to take its turn has to be
    // first in the queue. A comparison that ignored order would skip a
    // re-warm that reprioritised.
    final body = bodyOf(src, 'static bool _sameList(');
    expect(body, contains('a[i] != b[i]'),
        reason: 'comparing as sets would treat a reordered list as '
            'unchanged and leave the wrong preview at the front');
  });
}
