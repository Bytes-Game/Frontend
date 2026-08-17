import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/reel_diagnostics.dart';

/// A tiny HTTP server on loopback that lets the player start a reel from
/// bytes we already hold, then transparently back-fills the rest from the
/// CDN as playback continues.
///
/// Why this exists
/// ---------------
/// A player cannot play half a file. Hand it the first 1.5 s of an MP4 and
/// it does not see "a video still arriving" — it sees a two-second video.
/// That is the one thing standing between us and TikTok's actual trick,
/// which is to warm a *sliver* of many upcoming reels rather than all of
/// a few. Warming slivers is ~10x less data for the same instant start,
/// which matters enormously on a metered connection where most warmed
/// reels are skipped past.
///
/// So the player is pointed at `http://127.0.0.1:<port>/m/<id>` instead of
/// the CDN. This server answers that request out of the cached prefix
/// first — no network, no wait — and streams the remainder from origin
/// behind it. The player believes it is doing an ordinary ranged HTTP
/// fetch and never learns a cache was involved.
///
/// Safety posture
/// --------------
/// This sits on the critical path of every video, so it is built to get
/// out of the way rather than to be clever:
///
///   * **Prefix caching, not sparse ranges.** We only ever cache a
///     contiguous head of the file. Sequential playback — the entire
///     access pattern of a reels feed — is served from it; a seek past
///     the prefix is proxied straight through. No block map, no
///     bookkeeping to get wrong.
///   * **The origin fetch overlaps the cached head, and runs ahead of
///     the player.** See [_handle] and [_pipeReadAhead]. Together these
///     are what stop a reel from freezing a couple of seconds in.
///   * **Loopback only.** Bound to 127.0.0.1 with an ephemeral port, and
///     it will only serve ids it has been explicitly handed, so it can
///     never act as an open proxy.
///   * **It demotes itself.** After [maxFailuresBeforeDemote] failures it
///     declares itself unhealthy, [localUrlFor] starts returning null,
///     and every caller silently reverts to whole-file caching or plain
///     streaming. A bug here degrades the feed; it does not break it.
class LocalMediaServer {
  LocalMediaServer._();
  static final LocalMediaServer instance = LocalMediaServer._();

  /// Consecutive failures tolerated before we stop trusting the proxy for
  /// the rest of the session.
  static const int maxFailuresBeforeDemote = 3;

  /// How far the back-fill is allowed to run ahead of the player, in
  /// bytes held in memory. See [_pipeReadAhead] for why running ahead is
  /// the point; this constant is only about the ceiling.
  ///
  /// At the feed's 720p bitrate (~310 KB/s) this is roughly 13 seconds of
  /// cushion, which covers a slow patch of network or a busy isolate
  /// without being a meaningful allocation next to a decoder's own buffer
  /// pool. It is a per-response cap and only one or two responses are
  /// ever live at once, since VideoPlayerService keeps one player plus a
  /// spare.
  static const int readAheadBytes = 4 * 1024 * 1024;

  HttpServer? _server;
  final Map<String, _Entry> _byId = {};
  final Map<String, String> _idByOrigin = {};
  int _failures = 0;
  bool _demoted = false;
  bool _starting = false;
  int _backfills = 0;

  /// True when the proxy is bound and has not demoted itself.
  bool get healthy => _server != null && !_demoted;

  /// How many responses are streaming origin bytes right now.
  ///
  /// A back-fill belongs to a reel that is on screen *at this moment*, so
  /// it is the one download in the app with a hard deadline. The cache
  /// tier reads this to stand down its speculative warming while one is
  /// running — see [VideoCacheService.maxConcurrentDownloads].
  int get backfillsInFlight => _backfills;

  /// Why the proxy stopped being used, for logging/diagnostics.
  String? demotionReason;

  /// Bind the server. Returns false if binding fails, in which case
  /// callers simply never get a proxied URL and behave as before.
  Future<bool> start() async {
    if (_server != null) return true;
    if (_starting) return false;
    _starting = true;
    try {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0,
          shared: false);
      s.listen(
        (req) => unawaited(_handle(req)),
        onError: (Object e) => _noteFailure('listen error: $e'),
        cancelOnError: false,
      );
      _server = s;
      ReelDiagnostics.instance.log('proxy listening on 127.0.0.1:${s.port}');
      return true;
    } catch (e) {
      _demote('bind failed: $e');
      return false;
    } finally {
      _starting = false;
    }
  }

  /// Publish a cached prefix so the proxy can serve it.
  ///
  /// [prefixLength] is how many leading bytes of the file are on disk;
  /// [totalLength] is the full size the origin reported. A totalLength of
  /// 0 means the origin would not tell us, and we refuse to register —
  /// without it we cannot answer a range request honestly.
  ///
  /// [tailPath] is an optional cached slice of the END of the file, whose
  /// last byte is the file's last byte. It exists for one shape of MP4:
  /// the one that keeps its `moov` index after the media rather than
  /// before it (see `mp4_layout.dart`). A player opening such a file reads the
  /// header, finds no index, and seeks to the end for it — so with a head
  /// alone the very first thing it does is a network round-trip, and the
  /// warmed head buys nothing at all. Caching the tail as well means the
  /// index is already here when it asks, which is what makes those files
  /// start as fast as a faststart one.
  ///
  /// Its offset is derived from the file's own size at serve time rather
  /// than recorded here, so a short read cannot make us promise bytes we
  /// do not hold — see [_handle].
  void register({
    required String originUrl,
    required String prefixPath,
    required int prefixLength,
    required int totalLength,
    String? tailPath,
  }) {
    if (!healthy) return;
    if (totalLength <= 0 || prefixLength <= 0) return;
    final id = _idByOrigin[originUrl] ??
        (_idByOrigin[originUrl] = '${_idByOrigin.length}_${originUrl.hashCode}');
    _byId[id] = _Entry(
      originUrl: originUrl,
      prefixPath: prefixPath,
      prefixLength: prefixLength,
      totalLength: totalLength,
      tailPath: tailPath,
    );
  }

  void unregister(String originUrl) {
    final id = _idByOrigin.remove(originUrl);
    if (id != null) _byId.remove(id);
  }

  /// The loopback URL the player should open for [originUrl], or null if
  /// the proxy can't serve it — which every caller treats as "just use
  /// the origin".
  String? localUrlFor(String originUrl) {
    if (!healthy) return null;
    final id = _idByOrigin[originUrl];
    if (id == null || !_byId.containsKey(id)) return null;
    return 'http://127.0.0.1:${_server!.port}/m/$id';
  }

  void _noteFailure(String why) {
    _failures++;
    ReelDiagnostics.instance.log('proxy failure $_failures/$maxFailuresBeforeDemote: $why');
    if (_failures >= maxFailuresBeforeDemote) _demote(why);
  }

  /// Stop serving for the rest of the session. Everything falls back.
  void _demote(String why) {
    if (_demoted) return;
    _demoted = true;
    demotionReason = why;
    ReelDiagnostics.instance.log('proxy DEMOTED ($why) — reverting to direct '
        'playback for the rest of this session');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // Hoisted out of the try so the catch below can release an origin
    // response we opened but never got around to reading.
    Future<http.StreamedResponse>? tail;
    var tailConsumed = false;
    try {
      final segments = req.uri.pathSegments;
      final entry =
          segments.length == 2 && segments.first == 'm' ? _byId[segments[1]] : null;
      if (entry == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }

      final total = entry.totalLength;
      final rangeHeader = req.headers.value(HttpHeaders.rangeHeader);
      final range = _parseRange(rangeHeader, total);
      if (range == null && rangeHeader != null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }

      final start = range?.start ?? 0;
      final end = range?.end ?? total - 1;
      final length = end - start + 1;

      // Work out how much of this range the cached head actually covers
      // BEFORE a single byte goes out. Two things depend on the answer,
      // and both want it up front: the Content-Length we are about to
      // promise, and — the reason this is hoisted — whether we need
      // origin at all.
      //
      // Trust the file on disk over the length we recorded at
      // registration. If they disagree we would otherwise promise the
      // player Content-Length bytes and then deliver fewer, which does
      // not surface as an error — the player just waits forever for a
      // response that already ended.
      File? prefixFile;
      var prefixEnd = -1; // last byte index we can serve from disk
      if (start < entry.prefixLength) {
        final file = File(entry.prefixPath);
        final onDisk = file.existsSync() ? file.lengthSync() : 0;
        final usable = onDisk < entry.prefixLength ? onDisk : entry.prefixLength;
        if (usable > start) {
          prefixFile = file;
          prefixEnd = (end < usable - 1) ? end : usable - 1;
        }
        // Otherwise the prefix is gone or unusable, and the whole range
        // comes from origin — exactly what an uncached reel does.
        //
        // Deliberately NOT a failure and deliberately NOT an unregister.
        // Not a failure because a vanished cache file is the cache tier
        // doing its job, and spending the demotion budget on it would
        // let one sweep turn the feature off for the session. Not an
        // unregister because a player that is already mid-reel holds
        // this URL and will issue more range requests against it; drop
        // the entry and those 404, which breaks playback outright
        // instead of merely making it slower.
      }
      // First byte the cached head does not cover.
      final afterPrefix = prefixEnd < 0 ? start : prefixEnd + 1;

      // THE TAIL, where a moov-at-end file keeps its index.
      //
      // Same treatment as the head and for the same reason: bytes we
      // already hold go out without touching the network. This is the
      // half that makes warming those files worth anything — the player's
      // FIRST read after the header is a seek to the end for the index,
      // so a proxy that could only answer from the front sent it to
      // origin before it could decode a single frame.
      //
      // The offset comes from the file's own length, not from a number
      // recorded at registration: the slice ends at the last byte of the
      // media, so whatever is on disk occupies the final `onDisk` bytes.
      // A short read therefore narrows the window we claim instead of
      // shifting it, and we can never promise a byte we do not have.
      File? tailFile;
      var tailBegin = -1; // first byte index served from the tail file
      var tailFileOffset = 0; // absolute offset of the tail file's byte 0
      final tailPath = entry.tailPath;
      if (tailPath != null && afterPrefix <= end) {
        final file = File(tailPath);
        final onDisk = file.existsSync() ? file.lengthSync() : 0;
        if (onDisk > 0 && onDisk <= total) {
          final from = total - onDisk;
          final begin = afterPrefix > from ? afterPrefix : from;
          if (begin <= end) {
            tailFile = file;
            tailBegin = begin;
            tailFileOffset = from;
          }
        }
      }

      // Whatever sits between the two cached ends. For the common reel
      // this is the bulk of the media and streams from origin; for a
      // range that lands wholly inside the head or wholly inside the
      // tail it is empty and no network is touched at all.
      final originStart = afterPrefix;
      final originEnd = tailBegin < 0 ? end : tailBegin - 1;

      // THE OVERLAP.
      //
      // This request used to be issued only after the last cached byte
      // had been handed over. That put a full origin round-trip — DNS,
      // possibly TLS, and the edge's time-to-first-byte — in series
      // *after* the prefix, on every single reel. The cushion that was
      // supposed to absorb network latency was instead spent waiting for
      // it to start, and a slow TTFB landed as a freeze a couple of
      // seconds into playback, right where the cached head ran out.
      //
      // Firing it here costs nothing and hides that entire round-trip
      // under the ~2s of cached video we are about to deliver anyway. By
      // the time the player has swallowed the prefix, the origin bytes
      // are already arriving.
      //
      // Only when the range genuinely extends past the cached head: a
      // read that lands wholly inside the prefix must still cost no
      // network at all.
      if (originStart <= originEnd) {
        tail = _openOrigin(entry.originUrl, originStart, originEnd);
        // Park a listener on it immediately. If writing the prefix throws,
        // nothing below ever awaits this future, and an origin error with
        // no listener becomes an unhandled async error that takes down the
        // zone — the failure worth reporting is the one the catch block is
        // about to see, not this one.
        //
        // Note this deliberately does NOT touch `tail`'s stream. The
        // prefix write above is an await, so this callback can run while
        // we are still inside it; reading the stream here would consume a
        // response the code below is about to legitimately read, and a
        // streamed response can only be listened to once. Releasing an
        // abandoned connection is the catch block's job, where "abandoned"
        // is actually known.
        unawaited(tail.then((_) {}, onError: (_) {}));
      }

      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.contentType = ContentType('video', 'mp4');
      res.headers.set(HttpHeaders.contentLengthHeader, '$length');
      if (rangeHeader != null) {
        res.statusCode = HttpStatus.partialContent;
        res.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
      } else {
        res.statusCode = HttpStatus.ok;
      }

      // Head of the response that we already hold locally. This is the
      // part that makes the swipe feel instant: it goes out with no
      // network round-trip at all.
      if (prefixFile != null) {
        await res.addStream(prefixFile.openRead(start, prefixEnd + 1));
      }

      // Middle from origin, already in flight.
      if (tail != null) {
        final origin = await tail;
        if (origin.statusCode != HttpStatus.partialContent &&
            origin.statusCode != HttpStatus.ok) {
          // Left unconsumed on purpose: the catch block drains it.
          throw HttpException('origin returned ${origin.statusCode}');
        }
        tailConsumed = true;
        _backfills++;
        try {
          await _pipeReadAhead(origin.stream, res);
        } finally {
          _backfills--;
        }
      }

      // And the cached end of the file, if this range reaches it.
      if (tailFile != null) {
        await res.addStream(tailFile.openRead(
          tailBegin - tailFileOffset,
          end - tailFileOffset + 1,
        ));
      }

      await res.close();
      _failures = 0; // a clean response clears the demotion budget
    } catch (e) {
      // A client that closes the socket mid-stream (user swiped away) is
      // normal, not a fault — but we cannot reliably tell it apart from a
      // real error here, so we count it and rely on the fact that
      // successful responses reset the counter. Only sustained failure
      // demotes.
      //
      // If we opened an origin response and never read it — the prefix
      // write threw, or the origin answered with a status we refuse —
      // drain it now. Overlapping the fetch means we can be holding a
      // live connection at this point, and dropping it on the floor
      // would leak a socket out of the pool on every failure.
      if (tail != null && !tailConsumed) {
        unawaited(tail.then(
          (r) => r.stream.drain<void>().catchError((_) {}),
          onError: (_) {},
        ));
      }
      _noteFailure('$e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<http.StreamedResponse> _openOrigin(String url, int start, int end) {
    final request = http.Request('GET', Uri.parse(url))
      ..headers[HttpHeaders.rangeHeader] = 'bytes=$start-$end';
    return ApiService.httpClient.send(request);
  }

  /// Copy [source] to [out], pulling from origin as fast as it will go
  /// rather than only as fast as the player happens to be reading.
  ///
  /// Why not `out.addStream(source)`
  /// ------------------------------
  /// That is one line and it is what this replaced, but it welds the two
  /// rates together: `addStream` pauses the origin subscription whenever
  /// the loopback socket is momentarily full, so the download stops every
  /// time the player pauses for breath. On a phone those pauses are
  /// constant — a busy isolate, a decoder flush mid-swipe, the player's
  /// own buffer briefly topping out — and each one idles the connection.
  /// TCP punishes an idle connection by collapsing the congestion window,
  /// so throughput after the resume is worse than before it, and the
  /// stall compounds instead of recovering. That is the shape of the
  /// device logs: `queueInputBuffer: Input time interval reaches ~1000ms`
  /// over and over, a decoder asleep waiting for bytes rather than one
  /// struggling to keep up.
  ///
  /// So the two rates are decoupled by a buffer. Origin fills it at full
  /// speed; the player drains it at its own pace; only when the player
  /// falls [readAheadBytes] behind does backpressure finally reach the
  /// socket. The cushion is what the player spends during the next slow
  /// patch, which is the whole point — read-ahead is only useful if it
  /// was allowed to get ahead.
  Future<void> _pipeReadAhead(Stream<List<int>> source, IOSink out) {
    final done = Completer<void>();
    final queue = Queue<List<int>>();
    var queued = 0;
    var paused = false;
    var ended = false;
    var draining = false;
    Object? sourceError;
    late StreamSubscription<List<int>> sub;

    void finish([Object? e]) {
      if (done.isCompleted) return;
      if (e != null) {
        done.completeError(e);
      } else {
        done.complete();
      }
    }

    Future<void> drain() async {
      if (draining) return; // a drain loop is already running
      draining = true;
      try {
        while (queue.isNotEmpty) {
          final chunk = queue.removeFirst();
          queued -= chunk.length;
          // Resume well before empty. Waiting for the buffer to drain
          // fully would leave the socket idle exactly when the player is
          // consuming fastest.
          if (paused && queued <= readAheadBytes ~/ 2) {
            paused = false;
            sub.resume();
          }
          out.add(chunk);
          await out.flush();
        }
      } catch (e) {
        // The player hung up (a swipe) or the socket broke. Stop pulling
        // bytes nobody will read.
        await sub.cancel();
        finish(e);
        return;
      } finally {
        draining = false;
      }
      if (ended) finish(sourceError);
    }

    sub = source.listen(
      (chunk) {
        queue.add(chunk);
        queued += chunk.length;
        if (!paused && queued >= readAheadBytes) {
          paused = true;
          sub.pause();
        }
        unawaited(drain());
      },
      onError: (Object e) {
        ended = true;
        sourceError = e;
        unawaited(drain());
      },
      onDone: () {
        ended = true;
        unawaited(drain());
      },
      cancelOnError: true,
    );

    return done.future;
  }

  /// Parse a single `bytes=start-end` range. Multi-range requests (which
  /// players do not issue for progressive video) are rejected so we never
  /// answer one incorrectly.
  _Range? _parseRange(String? header, int total) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final spec = header.substring(6);
    if (spec.contains(',')) return null;
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final startStr = spec.substring(0, dash).trim();
    final endStr = spec.substring(dash + 1).trim();

    int start;
    int end;
    if (startStr.isEmpty) {
      // Suffix form: "bytes=-N" means the LAST n bytes.
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return null;
      start = total - n < 0 ? 0 : total - n;
      end = total - 1;
    } else {
      final s = int.tryParse(startStr);
      if (s == null) return null;
      start = s;
      end = endStr.isEmpty ? total - 1 : (int.tryParse(endStr) ?? total - 1);
    }
    if (start < 0 || start >= total) return null;
    if (end >= total) end = total - 1;
    if (end < start) return null;
    return _Range(start, end);
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _byId.clear();
    _idByOrigin.clear();
    await s?.close(force: true);
  }

  @visibleForTesting
  int? get debugPort => _server?.port;

  @visibleForTesting
  void debugDemote(String why) => _demote(why);

  /// Pretend [n] reels are back-filling, so the cache tier's response to
  /// a live back-fill can be tested without standing up a playback.
  @visibleForTesting
  void debugSetBackfills(int n) => _backfills = n;

  /// The read-ahead pipe on its own, against a sink the caller controls.
  ///
  /// Through a real socket this property is untestable: loopback buffers
  /// megabytes, so a stalled reader still absorbs everything a test can
  /// reasonably produce and the coupled and decoupled pipes look
  /// identical. A sink that is genuinely not draining is the only way to
  /// see the difference.
  @visibleForTesting
  Future<void> debugPipeReadAhead(Stream<List<int>> source, IOSink out) =>
      _pipeReadAhead(source, out);

  @visibleForTesting
  void debugReset() {
    _failures = 0;
    _demoted = false;
    _backfills = 0;
    demotionReason = null;
  }
}

class _Entry {
  _Entry({
    required this.originUrl,
    required this.prefixPath,
    required this.prefixLength,
    required this.totalLength,
    this.tailPath,
  });
  final String originUrl;
  final String prefixPath;
  final int prefixLength;
  final int totalLength;

  /// Cached slice of the end of the file, or null. Its last byte is the
  /// file's last byte, so the absolute offset it starts at is
  /// `totalLength - <its size on disk>`. See [LocalMediaServer.register].
  final String? tailPath;
}

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}
