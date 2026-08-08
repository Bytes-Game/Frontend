import 'dart:async';
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

  HttpServer? _server;
  final Map<String, _Entry> _byId = {};
  final Map<String, String> _idByOrigin = {};
  int _failures = 0;
  bool _demoted = false;
  bool _starting = false;

  /// True when the proxy is bound and has not demoted itself.
  bool get healthy => _server != null && !_demoted;

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
  void register({
    required String originUrl,
    required String prefixPath,
    required int prefixLength,
    required int totalLength,
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
      var cursor = start;
      if (cursor < entry.prefixLength) {
        final file = File(entry.prefixPath);
        // Trust the file on disk over the length we recorded at
        // registration. If they disagree we would otherwise promise the
        // player Content-Length bytes and then deliver fewer, which does
        // not surface as an error — the player just waits forever for a
        // response that already ended.
        final onDisk = file.existsSync() ? file.lengthSync() : 0;
        final usable = onDisk < entry.prefixLength ? onDisk : entry.prefixLength;
        if (usable <= cursor) {
          // Prefix gone or unusable. Fall through and serve the whole
          // range from origin — exactly what an uncached reel does.
          //
          // Deliberately NOT a failure and deliberately NOT an unregister.
          // Not a failure because a vanished cache file is the cache tier
          // doing its job, and spending the demotion budget on it would
          // let one sweep turn the feature off for the session. Not an
          // unregister because a player that is already mid-reel holds
          // this URL and will issue more range requests against it; drop
          // the entry and those 404, which breaks playback outright
          // instead of merely making it slower.
        } else {
          final prefixEnd = (end < usable - 1) ? end : usable - 1;
          await res.addStream(file.openRead(cursor, prefixEnd + 1));
          cursor = prefixEnd + 1;
        }
      }

      // Remainder straight from origin.
      if (cursor <= end) {
        await _pipeOrigin(entry.originUrl, cursor, end, res);
      }

      await res.close();
      _failures = 0; // a clean response clears the demotion budget
    } catch (e) {
      // A client that closes the socket mid-stream (user swiped away) is
      // normal, not a fault — but we cannot reliably tell it apart from a
      // real error here, so we count it and rely on the fact that
      // successful responses reset the counter. Only sustained failure
      // demotes.
      _noteFailure('$e');
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _pipeOrigin(
      String url, int start, int end, HttpResponse out) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers[HttpHeaders.rangeHeader] = 'bytes=$start-$end';
    final response = await ApiService.httpClient.send(request);
    if (response.statusCode != HttpStatus.partialContent &&
        response.statusCode != HttpStatus.ok) {
      throw HttpException('origin returned ${response.statusCode}');
    }
    await out.addStream(response.stream);
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

  @visibleForTesting
  void debugReset() {
    _failures = 0;
    _demoted = false;
    demotionReason = null;
  }
}

class _Entry {
  _Entry({
    required this.originUrl,
    required this.prefixPath,
    required this.prefixLength,
    required this.totalLength,
  });
  final String originUrl;
  final String prefixPath;
  final int prefixLength;
  final int totalLength;
}

class _Range {
  const _Range(this.start, this.end);
  final int start;
  final int end;
}
