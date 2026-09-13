// Waiting for the file's INDEX, not just for some bytes.
//
// An MP4 keeps a table with a row per frame, in front of the video. A
// player cannot decode anything until it has all of it. That table grows
// with how long the video runs. Measured off this app's own catalog, the
// 480p renditions the feed actually plays:
//
//   10 seconds       12 KB
//   30 seconds       35 KB
//   3 minutes       195 KB
//   10 minutes      653 KB
//
// The app handed a reel to the player once "two seconds of video" worth of
// bytes had landed — 375 KB at 480p — and counted the index as part of
// that two seconds. On a ten-second clip nobody notices 12 KB. On the
// ten-minute upload in this feed, 375 KB is 57% of the index and no video
// at all. The player had nothing it could decode, went back to the network
// for the rest, and the viewer watched a black screen — while the app
// recorded it as a cache hit.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/mp4_layout.dart';
import 'package:myapp/services/video_cache_service.dart';

/// A top-level MP4 box header: 4 bytes of size, 4 bytes of name.
Uint8List _box(String type, int size) {
  final b = BytesBuilder();
  b.add([(size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff, size & 0xff]);
  b.add(type.codeUnits);
  return b.toBytes();
}

/// The opening bytes of a faststart file: ftyp, then an index of
/// [moovSize], then the media. Only the headers matter — the parser never
/// reads box contents, which is the point: the answer is available long
/// before the index itself has downloaded.
Uint8List _fastStartHead({int ftypSize = 32, required int moovSize}) {
  final b = BytesBuilder();
  b.add(_box('ftyp', ftypSize));
  b.add(Uint8List(ftypSize - 8));
  b.add(_box('moov', moovSize));
  return b.toBytes();
}

void main() {
  group('reading where the index ends', () {
    test('off a real ten-minute file', () {
      // The exact numbers from the upload that stuck: ftyp 32 bytes, then
      // an index of 653,013.
      final head = _fastStartHead(moovSize: 653013);
      expect(mp4IndexEndsAt(head), 32 + 653013);
    });

    test('off a short clip', () {
      expect(mp4IndexEndsAt(_fastStartHead(moovSize: 12288)), 32 + 12288);
    });

    test('without downloading the index itself', () {
      // The whole point. 40 bytes in hand, an index of 653 KB, and the
      // answer is already known.
      final head = _fastStartHead(moovSize: 653013);
      expect(head.length, lessThan(64));
      expect(mp4IndexEndsAt(head), greaterThan(650000));
    });

    test('past padding boxes that come before the index', () {
      final b = BytesBuilder();
      b.add(_box('ftyp', 24));
      b.add(Uint8List(16));
      b.add(_box('free', 16));
      b.add(Uint8List(8));
      b.add(_box('moov', 50000));
      expect(mp4IndexEndsAt(b.toBytes()), 24 + 16 + 50000);
    });

    test('says nothing when the index is at the end of the file', () {
      final b = BytesBuilder();
      b.add(_box('ftyp', 24));
      b.add(Uint8List(16));
      b.add(_box('mdat', 900000));
      expect(mp4IndexEndsAt(b.toBytes()), isNull,
          reason: 'there is no index up here to wait for; that shape is '
              'handled separately');
    });

    test('says nothing rather than throwing on rubbish', () {
      expect(mp4IndexEndsAt(Uint8List(0)), isNull);
      expect(mp4IndexEndsAt(Uint8List.fromList([1, 2, 3])), isNull);
      // A box smaller than its own header would walk backwards forever.
      expect(mp4IndexEndsAt(_box('ftyp', 4)), isNull);
      // A box that declares "to the end of the file".
      expect(mp4IndexEndsAt(_box('ftyp', 0)), isNull);
      // Truncated 64-bit size.
      expect(mp4IndexEndsAt(_box('ftyp', 1)), isNull);
    });
  });

  group('how much has to land before a reel can start', () {
    const url = 'https://cdn/x/480p.mp4';

    test('the index is added to the video, not counted as part of it', () {
      final media = VideoCacheService.mediaReadyBytesFor(url);
      const indexEnd = 32 + 195000; // the three-minute reel in this feed

      expect(VideoCacheService.prefixReadyBytesFor(url, indexEndsAt: indexEnd),
          indexEnd + media,
          reason: 'the viewer gets the seconds of video they were promised, '
              'not seconds minus however long the index happens to be');
    });

    test('a short clip is barely affected', () {
      final media = VideoCacheService.mediaReadyBytesFor(url);
      const indexEnd = 32 + 12288; // ten seconds

      final withIndex =
          VideoCacheService.prefixReadyBytesFor(url, indexEndsAt: indexEnd);
      expect(withIndex - media, lessThan(16 * 1024),
          reason: 'this must not slow down the reels that were already fine');
    });

    test('nothing is claimed when the file has not said', () {
      expect(VideoCacheService.prefixReadyBytesFor(url, indexEndsAt: null),
          VideoCacheService.mediaReadyBytesFor(url),
          reason: 'a short read or a file we cannot parse has to behave '
              'exactly as it did before this existed');
    });

    test('never waits for more than the slice being fetched', () {
      // This decides when to hand over what is being downloaded. Asking for
      // more than is being downloaded would mean never handing it over.
      expect(
          VideoCacheService.prefixReadyBytesFor(url, indexEndsAt: 700000),
          lessThanOrEqualTo(VideoCacheService.prefixBytes));
    });
  });

  group('refusing a file the slice cannot help', () {
    test('an index too big to leave room for video is not worth warming', () {
      // The ten-minute upload: a 653 KB index inside a 768 KB slice leaves
      // 115 KB. Reading all of it still leaves the player going to the
      // network, so warming it only spends bandwidth the reel on screen
      // wanted.
      expect(VideoCacheService.prefixWorthWarming(32 + 653013), isFalse);
    });

    test('an ordinary reel is', () {
      expect(VideoCacheService.prefixWorthWarming(32 + 12288), isTrue);
      expect(VideoCacheService.prefixWorthWarming(32 + 195000), isTrue);
    });

    test('the line is where no video would be left', () {
      const room = VideoCacheService.prefixBytes -
          VideoCacheService.prefixReadyFloorBytes;
      expect(VideoCacheService.prefixWorthWarming(room), isTrue);
      expect(VideoCacheService.prefixWorthWarming(room + 1), isFalse);
    });
  });

  group('it is actually wired up', () {
    final src = File('lib/services/video_cache_service.dart').readAsStringSync();

    test('the index is read off the opening bytes', () {
      expect(src.contains('mp4IndexEndsAt(probe.toBytes())'), isTrue,
          reason: 'the index size is never read, so the threshold is a flat '
              'byte count however good the arithmetic is');
    });

    test('a file the slice cannot help is dropped', () {
      expect(src.contains('!prefixWorthWarming('), isTrue,
          reason: 'a reel whose index fills the slice is still warmed and '
              'still counted as a cache hit');
      expect(src.contains("recordPrefixBailed('indexTooBig')"), isTrue,
          reason: 'dropping it silently puts the diagnostics back to '
              'reporting a slow reel among the fast ones');
    });
  });
}
