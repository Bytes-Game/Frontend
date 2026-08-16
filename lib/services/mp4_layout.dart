import 'dart:typed_data';

/// Where an MP4 keeps its index, read from the opening bytes.
///
/// An MP4 is a flat list of boxes. Two matter here: `moov` is the index —
/// sample tables, durations, codec configuration, everything a player
/// needs before it can decode a single frame — and `mdat` is the media
/// itself. Their ORDER is not fixed by the format, and it decides
/// whether a video can start playing before it has finished downloading.
///
///   ftyp moov mdat  → "faststart". The index arrives first, so a player
///                     can begin as soon as the opening bytes land.
///   ftyp mdat moov  → the index is at the END. A player must reach the
///                     last bytes of the file before it can start.
///
/// Nothing in the app's warming path knew the difference, and that made
/// the second shape quietly expensive. [VideoCacheService] warms the
/// first 768 KB of every reel and hands it to the loopback proxy, which
/// is exactly the right move for a faststart file and completely useless
/// for the other: the player reads the warmed slice, finds no index in
/// it, and immediately range-requests the tail — over the network, while
/// the user waits. Worse, the reel was then COUNTED as a proxy start, so
/// the diagnostics reported it among the fast ones. A file that was
/// slower than an uncached reel was being logged as a cache hit.
///
/// Detecting it costs a walk over a few dozen bytes, and it is worth
/// doing rather than assuming, because the shape is a property of how a
/// given file was encoded — not of the app, the CDN, or anything the
/// client controls. One badly exported clip in a catalog is enough.
enum Mp4Layout {
  /// `moov` comes before `mdat`. Warming the opening slice is useful.
  fastStart,

  /// `mdat` comes before `moov`. The opening slice is not enough to
  /// start playback, whatever the proxy does with it.
  moovAtEnd,

  /// Neither box appeared in the bytes given. Not a verdict — treat it
  /// the same as [fastStart], because guessing "bad" would push healthy
  /// reels onto the slower whole-file path on the strength of a short
  /// read.
  unknown,
}

/// Every box header is at least a 4-byte size and a 4-byte type.
const int _headerBytes = 8;

/// Read the top-level box order out of [head], the opening bytes of a
/// file.
///
/// Only the headers are walked, never the contents, so a few dozen bytes
/// is normally enough: the boxes that can precede `moov` in a faststart
/// file (`ftyp`, and sometimes `free`/`skip`/`wide` padding) are small,
/// and in the other layout `mdat` is the second box.
///
/// Returns [Mp4Layout.unknown] rather than throwing on anything it does
/// not understand — a truncated read, a nonsense size, a file that is not
/// an MP4 at all. This runs on the warming path, where being wrong must
/// cost nothing worse than the behaviour that was there before it.
Mp4Layout readMp4Layout(Uint8List head) {
  var offset = 0;
  while (offset + _headerBytes <= head.length) {
    final declared = _uint32(head, offset);
    final type = _boxType(head, offset + 4);

    if (type == 'moov') return Mp4Layout.fastStart;
    if (type == 'mdat') return Mp4Layout.moovAtEnd;

    final int size;
    if (declared == 1) {
      // 64-bit size, in the 8 bytes after the type. The high word is
      // beyond anything a reel will ever be, so a file claiming one is
      // not something to reason further about.
      if (offset + 16 > head.length) return Mp4Layout.unknown;
      if (_uint32(head, offset + 8) != 0) return Mp4Layout.unknown;
      size = _uint32(head, offset + 12);
    } else if (declared == 0) {
      // "Extends to end of file", so nothing follows it. If we have not
      // found either box by now we never will.
      return Mp4Layout.unknown;
    } else {
      size = declared;
    }

    // A box cannot be smaller than its own header. Anything claiming to
    // be would either loop forever or walk backwards.
    if (size < _headerBytes) return Mp4Layout.unknown;
    offset += size;
  }
  return Mp4Layout.unknown;
}

int _uint32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

String _boxType(Uint8List b, int at) =>
    String.fromCharCodes(b, at, at + 4);

/// How many opening bytes [readMp4Layout] needs in practice.
///
/// `ftyp` is a few dozen bytes and padding boxes are small, so the box
/// that settles the question is normally within the first hundred. This
/// is generous enough to survive an unusual amount of leading padding
/// while staying small enough to hold in memory for every warming reel.
const int mp4LayoutProbeBytes = 4096;
