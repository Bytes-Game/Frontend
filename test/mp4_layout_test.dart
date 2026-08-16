// Tests for reading an MP4's box order out of its opening bytes.
//
// Background: one clip in the live catalog (4e1dee73db81e09b.mp4, used by
// challenges 108 and 109) keeps its `moov` index at the END of the file.
// The warming path fetches the first 768 KB of every reel and hands it to
// the loopback proxy, which is the right move for a faststart file and
// useless for that one — the player reads the warmed slice, finds no
// index, and range-requests the tail over the network before it can show
// a frame. It was then counted as a proxy start, so the reel that was
// SLOWER than an uncached one was logged among the fast ones.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/mp4_layout.dart';

/// A top-level box header: 4-byte big-endian size, 4-byte ASCII type,
/// then [payload] bytes of filler. Only headers are ever walked, so the
/// filler's contents are irrelevant — its LENGTH is what moves the
/// cursor, and getting that wrong is the bug these tests exist for.
Uint8List box(String type, {int payload = 0, int? declaredSize}) {
  final size = declaredSize ?? (8 + payload);
  final b = BytesBuilder()
    ..add([(size >> 24) & 0xff, (size >> 16) & 0xff, (size >> 8) & 0xff,
        size & 0xff])
    ..add(type.codeUnits)
    ..add(List<int>.filled(payload, 0));
  return b.toBytes();
}

Uint8List concat(List<Uint8List> parts) {
  final b = BytesBuilder();
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

void main() {
  group('the ordinary shapes', () {
    test('moov before mdat is faststart', () {
      expect(
        readMp4Layout(concat([
          box('ftyp', payload: 24),
          box('moov', payload: 900),
          box('mdat', payload: 64),
        ])),
        Mp4Layout.fastStart,
      );
    });

    test('mdat before moov is not', () {
      // The live shape being detected. mdat's declared size runs far past
      // anything we hold in memory, which is exactly why the verdict has
      // to come from the header rather than from finding moov.
      expect(
        readMp4Layout(concat([
          box('ftyp', payload: 24),
          box('mdat', declaredSize: 4 * 1024 * 1024, payload: 64),
        ])),
        Mp4Layout.moovAtEnd,
      );
    });

    test('padding boxes before moov are skipped, not tripped over', () {
      // free/skip/wide legitimately sit between ftyp and moov — often
      // precisely because a faststart rewrite left a gap behind.
      expect(
        readMp4Layout(concat([
          box('ftyp', payload: 24),
          box('free', payload: 512),
          box('skip', payload: 8),
          box('wide', payload: 8),
          box('moov', payload: 100),
        ])),
        Mp4Layout.fastStart,
      );
    });
  });

  group('a verdict is not guessed', () {
    test('neither box in range is unknown, not a failure', () {
      // Must NOT read as moovAtEnd: that would push a healthy reel onto
      // the slower whole-file path on the strength of a short read.
      expect(
        readMp4Layout(concat([box('ftyp', payload: 24), box('free')])),
        Mp4Layout.unknown,
      );
    });

    test('a truncated header decides nothing', () {
      expect(readMp4Layout(Uint8List(0)), Mp4Layout.unknown);
      expect(readMp4Layout(Uint8List.fromList([0, 0, 0, 32, 0x66])),
          Mp4Layout.unknown);
    });

    test('bytes that are not an mp4 at all decide nothing', () {
      expect(
        readMp4Layout(Uint8List.fromList(List<int>.filled(64, 0xff))),
        Mp4Layout.unknown,
        reason: 'a 0xffffffff size walks past the buffer and stops there',
      );
    });
  });

  group('sizes that could hang or walk backwards', () {
    test('a box smaller than its own header stops the walk', () {
      // The loop guard. Sizes 0-7 cannot advance the cursor past the
      // header that declared them, so without the floor this spins.
      for (final bad in [1, 2, 7]) {
        expect(
          readMp4Layout(concat([
            box('ftyp', declaredSize: bad, payload: 24),
            box('moov', payload: 8),
          ])),
          isNot(Mp4Layout.fastStart),
          reason: 'a box declaring size $bad must not be walked through',
        );
      }
    });

    test('size 0 means the box runs to EOF, so nothing follows it', () {
      expect(
        readMp4Layout(concat([
          box('ftyp', declaredSize: 0, payload: 24),
          box('moov', payload: 8),
        ])),
        Mp4Layout.unknown,
      );
    });

    test('a 64-bit size is read from the right place', () {
      // size==1 means the real size is the 8 bytes AFTER the type, so the
      // cursor must advance by that, not by 1 and not by 16.
      final large = BytesBuilder()
        ..add([0, 0, 0, 1])
        ..add('free'.codeUnits)
        ..add([0, 0, 0, 0, 0, 0, 0, 32])
        ..add(List<int>.filled(16, 0));
      expect(
        readMp4Layout(concat([large.toBytes(), box('moov', payload: 8)])),
        Mp4Layout.fastStart,
      );
    });

    test('a 64-bit size too large to be a reel decides nothing', () {
      final huge = BytesBuilder()
        ..add([0, 0, 0, 1])
        ..add('free'.codeUnits)
        ..add([0, 0, 0, 1, 0, 0, 0, 0]);
      expect(readMp4Layout(huge.toBytes()), Mp4Layout.unknown);
    });
  });

  test('the probe budget covers a realistic amount of leading padding', () {
    // The warming path holds this many opening bytes in memory to decide.
    // ftyp plus padding before moov is normally under a hundred bytes; a
    // budget below that would report unknown for ordinary files and the
    // detection would silently never fire.
    expect(mp4LayoutProbeBytes, greaterThanOrEqualTo(1024));
  });
}
