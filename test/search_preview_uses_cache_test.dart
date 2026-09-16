// The search grid used to pay for its head start and then throw it away.
//
// _warmVisible downloads the opening of every visible preview onto the
// phone. The tile then played the ORIGIN url, so the player went to the
// network and fetched those same bytes a second time. That is what "the
// preview sticks for a few seconds and then plays" was: the bytes were
// already on the disk and the tile was waiting for the network to send
// them again.
//
// This went through the proxy once before and previews stopped playing at
// all, which is why it was reverted. The cause has since been found and it
// was not the proxy — the grid was holding fifteen of the phone's video
// decoders and there were none left to open anything with. The device log
// after that fix shows 93 decoders asked for and 93 granted, with no
// playback failures at all.
//
// So it goes back through the proxy, WITH a fallback this time, because
// "slow" and "broken" must never again be the same symptom.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/dart_source.dart';

void main() {
  final src = File('lib/pages/search_page.dart').readAsStringSync();

  group('a preview plays the bytes it already downloaded', () {
    test('the play url comes from the cache, not straight from origin', () {
      final body = bodyOf(src, 'String _previewUrl()');
      expect(body, contains('playbackUrlFor'),
          reason: 'warming the opening and then streaming the origin means '
              'downloading the same bytes twice and waiting for the second '
              'copy');
    });

    test('warming still keys on the origin, not the proxy address', () {
      // The cache files bytes under the origin url. Warm the loopback
      // address instead and the bytes are stored under a name nothing
      // looks up: cost paid, nobody helped.
      final warm = bodyOf(src, 'void _warmVisible()');
      expect(warm, isNot(contains('playbackUrlFor')),
          reason: 'warm and play must agree on WHICH file, and the cache '
              'names files by their origin url');
      expect(src, contains('widget.coordinator.report(_id, info.visibleFraction, url: _originUrl())'),
          reason: 'the coordinator collects the urls _warmVisible warms, so '
              'it has to collect origins too');
    });
  });

  group('slow must never turn back into broken', () {
    test('a failed proxied open retries on the origin', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('_originUrl()'));
      expect(body, contains('await _openAndPlay(origin)'),
          reason: 'without this a bad proxy address means the tile shows '
              'nothing for ever, which is exactly the failure that got the '
              'proxy blamed for a decoder bug');
    });

    test('the retry cannot loop', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('if (url != origin'),
          reason: 'retrying the origin WITH the origin would recurse until '
              'the stack gave out');
    });

    test('the failed player is released before the retry opens another', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      final release = body.indexOf('_releasePlayer()');
      final retry = body.indexOf('await _openAndPlay(origin)');
      expect(release, greaterThan(-1), reason: 'the dead player is leaked');
      expect(release, lessThan(retry),
          reason: 'the retry would compete with the player that just failed '
              'for one of the few decoders the phone has');
    });

    test('a tile that has moved on does not retry', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('mounted && _isActive'),
          reason: 'retrying for a tile that is no longer the active preview '
              'costs a decoder for a video nobody is looking at');
    });

    test('the failure is still reported, both times', () {
      final body = bodyOf(src, 'Future<void> _openAndPlay(String url)');
      expect(body, contains('search preview failed to open'));
      expect(body, contains('search preview retrying from origin'),
          reason: 'a preview that only plays on the second try looks '
              'identical to one that played first time, unless it says so');
    });
  });
}
