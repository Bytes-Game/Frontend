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

/// Where the index ends — the first byte after `moov` — or null when the
/// bytes given do not say.
///
/// ══════════════════════════════════════════════════════════════════════
/// WHY THIS MATTERS, AND WHY IT IS NOT A CONSTANT
/// ══════════════════════════════════════════════════════════════════════
///
/// [readMp4Layout] answers "is the index at the front?". That is not the
/// whole question. A faststart file is only playable from its opening
/// bytes once ALL of the index is in them, and how much that is depends
/// entirely on how long the video runs.
///
/// `moov` holds a table with an entry per frame. It grows with the
/// running time, and it grows fast:
///
///   10 seconds      ~12 KB
///   30 seconds      ~35 KB
///   3 minutes      ~195 KB
///   10 minutes     ~653 KB
///
/// Those are measured off this app's own catalog, not estimated.
///
/// Everything warming-related was written against the first line of that
/// table. The reel is handed to the player once a couple of seconds'
/// worth of BYTES have landed — 375 KB at 480p — on the reasoning that a
/// player needs "the header and enough media to decode a frame". For a
/// ten-second clip whose header is 12 KB that is true. For a ten-minute
/// one it is not: at 375 KB the player has 57% of an index and no media
/// at all. It cannot decode anything, so it goes to the network for the
/// rest of the header while the viewer looks at black — which is slower
/// than never having warmed it, and was being counted as a cache hit.
///
/// Reading the real number costs nothing. `moov` declares its own size in
/// its header, so the answer is in the first few dozen bytes of the file,
/// long before the index itself has arrived.
///
/// Returns null when the opening bytes do not settle it — a short read, a
/// file whose index is at the end, or anything not an MP4. Null means "no
/// opinion", and callers must carry on as they did before this existed.
int? mp4IndexEndsAt(Uint8List head) {
  var offset = 0;
  while (offset + _headerBytes <= head.length) {
    final declared = _uint32(head, offset);
    final type = _boxType(head, offset + 4);

    final int size;
    if (declared == 1) {
      if (offset + 16 > head.length) return null;
      // A 64-bit size whose high word is set is larger than any reel, and
      // larger than an int can hold on the web. Not something to reason
      // further about.
      if (_uint32(head, offset + 8) != 0) return null;
      size = _uint32(head, offset + 12);
    } else if (declared == 0) {
      // "Extends to the end of the file", so nothing follows it.
      return null;
    } else {
      size = declared;
    }

    // A box cannot be smaller than its own header. One claiming to be
    // would either loop forever or walk backwards.
    if (size < _headerBytes) return null;

    // The index ends where its box ends. This is reachable long before
    // the index itself has been downloaded — the size is in the header.
    if (type == 'moov') return offset + size;

    // Media before the index: the file is moov-at-end and there is no
    // index up here to wait for. Caller handles that shape separately.
    if (type == 'mdat') return null;

    offset += size;
  }
  return null;
}
