import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/network_quality_service.dart';
import 'package:myapp/services/reel_diagnostics.dart';

/// Downloads upcoming reels to disk BEFORE the user swipes to them, so a
/// swipe starts a player against a local file instead of the network.
///
/// Why this exists
/// ---------------
/// The old design had exactly one way to make a video "ready": start a
/// player for it. Five ready reels meant five live ExoPlayer instances,
/// each holding a video decoder AND an audio decoder, each buffering.
/// On a mid-range phone that is the dominant cost of the feed — device
/// logs showed render intervals of 5-9 SECONDS on background players and
/// audio decoders that decoded 144 buffers and dropped all 144 (the
/// prefetched reels are silent, so every one of those was wasted work).
///
/// This service splits "ready" into its two real halves:
///
///   * getting the BYTES onto the phone — cheap, no codec, done here
///   * running a DECODER — expensive, so VideoPlayerService now keeps
///     only the current reel plus one
///
/// Because a warmed reel has no player at all, the wasted audio decoding
/// disappears rather than needing its own fix. And because we fetch
/// through [ApiService.httpClient] — the Cronet client main() installs on
/// Android — these downloads ride HTTP/3 where the edge offers it, which
/// ExoPlayer's own network stack does not do.
///
/// Two modes, and it moves between them on its own:
///
///   * **Prefix mode (preferred).** Fetch only the opening slice of each
///     reel and let [LocalMediaServer] serve it to the player, streaming
///     the rest from origin behind it. This is TikTok's approach and
///     costs roughly a TENTH of the data, because most warmed reels are
///     skipped past and we never pull their bulk.
///   * **Whole-file mode (fallback).** If the proxy will not bind, or
///     demotes itself after repeated trouble, we download entire files
///     and play them straight off disk. Slower on data, but it has no
///     moving parts on the playback path.
///
/// And underneath both, a plain cache miss just streams from origin —
/// exactly the behaviour that shipped before any of this existed. There
/// is no state in which a cache problem stops a video from playing.
class VideoCacheService {
  VideoCacheService._();
  static final VideoCacheService instance = VideoCacheService._();

  /// Total bytes of cached video we keep on disk before evicting the
  /// least-recently-used entries. Reels are short; this holds a few
  /// hundred of them and is trivial next to a photo library.
  static const int maxCacheBytes = 300 * 1024 * 1024;

  /// Refuse to download a WHOLE file larger than this. A reel is seconds
  /// long; anything this big is a mis-tagged upload or a legacy full-length
  /// video, and pulling it would blow the user's data for one swipe.
  ///
  /// Deliberately NOT applied to prefix warming. A prefix is
  /// [prefixBytes] no matter how big the file behind it is, so the
  /// cost of warming a 250 MB video is identical to warming a 2 MB one —
  /// and the big one is precisely the one that cannot afford a cold
  /// start. Gating the prefix on total size meant every oversized reel
  /// got no warming at all and opened straight against the network,
  /// which is the slowest possible outcome for the slowest content.
  static const int maxPrefetchBytes = 40 * 1024 * 1024;

  /// How many downloads may run at once. More than this and the warming
  /// downloads start competing with the reel the user is actually
  /// watching for bandwidth — which makes the app feel slower, not
  /// faster.
  static const int maxConcurrentDownloads = 2;

  /// How much of a reel to warm in prefix mode. Sized to cover roughly
  /// the first two seconds at the 720p bitrate the feed now caps at
  /// (2.5 Mbps ≈ 310 KB/s), which is comfortably enough for the player
  /// to open, decode a first frame, and start rendering before the
  /// back-fill from origin catches up.
  static const int prefixBytes = 768 * 1024;

  /// True while the loopback proxy is usable. When it stops being usable
  /// — never bound, or demoted after repeated failures — warming falls
  /// back to whole files, which need no proxy to play.
  bool get _prefixMode => LocalMediaServer.instance.healthy;

  Directory? _dir;
  bool _initialising = false;

  /// URLs whose file is fully downloaded and playable.
  final Set<String> _ready = <String>{};

  /// In-flight downloads, so a URL is never fetched twice and so a URL
  /// that leaves the prefetch window can be cancelled mid-flight.
  final Map<String, _Download> _active = {};

  /// Queued URLs waiting for a download slot, highest priority first.
  final List<String> _queue = [];

  /// URLs whose opening slice is cached and registered with the proxy.
  final Set<String> _prefixed = <String>{};

  /// Resolve the cache directory and adopt anything a previous run left
  /// behind. Safe to call repeatedly; only the first call does work.
  Future<void> init() async {
    if (_dir != null || _initialising) return;
    _initialising = true;
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/reel_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      // Two kinds of leftovers from a previous run get dropped here.
      //
      // `.part` files are half-written whole-file downloads (app killed
      // mid-download) — not playable, and handing the player a truncated
      // MP4 is worse than a cache miss.
      //
      // `.prefix` files are fragments that are only ever useful via an
      // in-memory proxy registration, and that registration does not
      // survive a restart. Since prefixes are exempt from LRU eviction,
      // nothing else would ever reclaim them, so they would accumulate
      // across every launch of the app.
      for (final f in dir.listSync()) {
        if (f is File &&
            (f.path.endsWith('.part') || f.path.endsWith('.prefix'))) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
      // Bring the proxy up. If it refuses to bind we simply stay in
      // whole-file mode for the session — nothing else changes.
      await LocalMediaServer.instance.start();
      ReelDiagnostics.instance.log(
          'cache ready: mode=${_prefixMode ? "prefix (sliver)" : "whole-file"} '
          'depth=$prefetchDepth');
      unawaited(_enforceSizeCap());
    } catch (e) {
      if (kDebugMode) debugPrint('video cache init failed: $e');
    } finally {
      _initialising = false;
    }
  }

  /// How many reels ahead to warm, given the current connection. Wifi
  /// gets real depth (this is the whole point — many ready reels); on
  /// cellular we stay shallow because every warmed reel the user never
  /// reaches is data spent on nothing.
  int get prefetchDepth {
    // Prefix mode pulls ~0.75 MB per reel instead of ~9 MB, so the same
    // data budget buys a much deeper window — which is the entire reason
    // for the proxy. Whole-file mode keeps the conservative numbers.
    final deep = _prefixMode;
    switch (NetworkQualityService.instance.current) {
      case NetworkQuality.high:
        return deep ? 10 : 6;
      case NetworkQuality.medium:
      case NetworkQuality.unknown:
        return deep ? 6 : 3;
      case NetworkQuality.low:
        return deep ? 2 : 1;
    }
  }

  /// Local file for [url] if it is fully downloaded, else null. Callers
  /// treat null as "stream it from the network like before" — the cache
  /// is an accelerator, never a requirement.
  String? pathFor(String url) {
    if (url.isEmpty || _dir == null) return null;
    if (!_ready.contains(url)) return null;
    final f = File(_fileFor(url));
    if (!f.existsSync()) {
      _ready.remove(url);
      return null;
    }
    // Touch so the size-cap eviction treats recently-played reels as hot.
    try {
      f.setLastAccessedSync(DateTime.now());
    } catch (_) {}
    return f.path;
  }

  /// Whether [url] can start without a network round-trip — either a
  /// whole file on disk, or an opening slice the proxy can serve.
  bool isReady(String url) =>
      pathFor(url) != null || LocalMediaServer.instance.localUrlFor(url) != null;

  /// The URL the player should actually open for [url].
  ///
  /// Prefers the proxy (instant start from the cached opening), then a
  /// whole cached file, then the origin itself. Every step degrades to
  /// the next, so there is no failure here that stops playback.
  String playbackUrlFor(String url) {
    final proxied = LocalMediaServer.instance.localUrlFor(url);
    if (proxied != null) return proxied;
    return url;
  }

  /// Warm [urls] in the order given (nearest reel first) and cancel any
  /// download for a URL that has dropped out of the window — the user
  /// scrolled past it, so finishing it would waste the bandwidth the
  /// next reel needs.
  void warm(List<String> urls) {
    if (_dir == null) {
      // Not ready yet — kick init and let the next swipe warm things.
      unawaited(init());
      return;
    }
    final wanted = urls.where((u) => u.isNotEmpty).toList();
    final wantedSet = wanted.toSet();

    for (final url in _active.keys.toList()) {
      if (!wantedSet.contains(url)) _cancel(url);
    }
    _queue.removeWhere((u) => !wantedSet.contains(u));

    for (final url in wanted) {
      if (_ready.contains(url)) continue;
      if (_prefixed.contains(url)) continue;
      if (_active.containsKey(url)) continue;
      if (_queue.contains(url)) continue;
      // Adopt a file a previous session already fetched.
      if (File(_fileFor(url)).existsSync()) {
        _ready.add(url);
        continue;
      }
      _queue.add(url);
    }
    _pump();
  }

  /// Start downloads until the concurrency limit is reached.
  void _pump() {
    while (_active.length < maxConcurrentDownloads && _queue.isNotEmpty) {
      final url = _queue.removeAt(0);
      _start(url);
    }
  }

  void _start(String url) {
    final download = _Download(url);
    _active[url] = download;
    unawaited(_run(download).whenComplete(() {
      _active.remove(url);
      _pump();
    }));
  }

  Future<void> _run(_Download d) async {
    if (_prefixMode) {
      final ok = await _runPrefix(d);
      // A prefix fetch that fails (origin can't do ranges, say) must not
      // leave the reel cold — drop through to the whole-file path, which
      // works against any HTTP server.
      if (ok || d.cancelled) return;
    }
    await _runWholeFile(d);
  }

  /// Fetch just the opening slice and hand it to the proxy. Returns false
  /// if this reel can't be served this way, so the caller can fall back.
  Future<bool> _runPrefix(_Download d) async {
    final prefixPath = '${_fileFor(d.url)}.prefix';
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(d.url))
        ..headers[HttpHeaders.rangeHeader] = 'bytes=0-${prefixBytes - 1}';
      final response = await ApiService.httpClient.send(request);
      // No 206 means the origin ignored the range and is about to send
      // the whole file — not what we asked for, so let the whole-file
      // path own it rather than half-handling it here.
      if (response.statusCode != HttpStatus.partialContent) return false;

      final total = _totalFromContentRange(
          response.headers[HttpHeaders.contentRangeHeader.toLowerCase()] ??
              response.headers['content-range']);
      // Only the total's *validity* matters here, not its size. We keep
      // exactly prefixBytes on disk either way; the proxy back-fills the
      // rest from origin as the player asks for it. See maxPrefetchBytes.
      if (total <= 0) return false;

      final file = File(prefixPath);
      sink = file.openWrite();
      var written = 0;
      final done = Completer<void>();
      d.subscription = response.stream.listen(
        (chunk) {
          written += chunk.length;
          sink!.add(chunk);
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object e) => done.isCompleted ? null : done.completeError(e),
        cancelOnError: true,
      );
      await done.future;
      await sink.flush();
      await sink.close();
      sink = null;

      if (d.cancelled || written <= 0) {
        await _safeDelete(prefixPath);
        return false;
      }

      LocalMediaServer.instance.register(
        originUrl: d.url,
        prefixPath: prefixPath,
        prefixLength: written,
        totalLength: total,
      );
      _prefixed.add(d.url);
      ReelDiagnostics.instance.recordPrefixWarmed();
      unawaited(_enforceSizeCap());
      return true;
    } catch (e) {
      ReelDiagnostics.instance.recordPrefixFailed();
      if (kDebugMode) debugPrint('prefix warm failed for ${d.url}: $e');
      await _safeDelete(prefixPath);
      return false;
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
    }
  }

  /// `Content-Range: bytes 0-767/1234567` → 1234567.
  int _totalFromContentRange(String? header) {
    if (header == null) return 0;
    final slash = header.lastIndexOf('/');
    if (slash < 0) return 0;
    return int.tryParse(header.substring(slash + 1).trim()) ?? 0;
  }

  Future<void> _runWholeFile(_Download d) async {
    final partPath = '${_fileFor(d.url)}.part';
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(d.url));
      // Raw client, NOT the authed wrapper: media lives on R2 behind
      // presigned/public URLs and must not carry our bearer token.
      final response = await ApiService.httpClient.send(request);
      if (response.statusCode != 200) return;
      final declared = response.contentLength ?? 0;
      if (declared > maxPrefetchBytes) return;

      final part = File(partPath);
      sink = part.openWrite();
      var written = 0;
      final done = Completer<void>();

      d.subscription = response.stream.listen(
        (chunk) {
          written += chunk.length;
          if (written > maxPrefetchBytes) {
            // Server lied about (or omitted) content-length. Stop
            // rather than let one video eat the cache.
            if (!done.isCompleted) done.completeError(StateError('too large'));
            return;
          }
          sink!.add(chunk);
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object e) =>
            done.isCompleted ? null : done.completeError(e),
        cancelOnError: true,
      );

      await done.future;
      await sink.flush();
      await sink.close();
      sink = null;

      if (d.cancelled) {
        await _safeDelete(partPath);
        return;
      }
      // Rename only once the bytes are all there — a file under the
      // final name is, by construction, complete and playable.
      await part.rename(_fileFor(d.url));
      _ready.add(d.url);
      unawaited(_enforceSizeCap());
    } catch (e) {
      if (kDebugMode) debugPrint('video cache miss for ${d.url}: $e');
      await _safeDelete(partPath);
    } finally {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
    }
  }

  void _cancel(String url) {
    final d = _active[url];
    if (d == null) return;
    d.cancelled = true;
    unawaited(d.subscription?.cancel());
  }

  /// Evict least-recently-used files until the cache fits in
  /// [maxCacheBytes].
  Future<void> _enforceSizeCap() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final all = dir.listSync().whereType<File>().toList();
      var total = 0;
      for (final f in all) {
        total += f.statSync().size;
      }
      if (total <= maxCacheBytes) return;

      // In-flight downloads and registered prefixes are not eviction
      // candidates. Prefixes especially: a player that is mid-reel holds a
      // loopback URL pointing at one, and deleting it underneath forces
      // that reel back to a cold origin fetch at the worst possible
      // moment. They are also bounded and tiny — prefetchDepth * 768 KB is
      // single-digit megabytes against a 300 MB cap — so exempting them
      // costs nothing worth reclaiming. Their bytes still count toward
      // [total] above, so the cap stays honest about real disk use.
      final files = all
          .where((f) => !f.path.endsWith('.part') && !f.path.endsWith('.prefix'))
          .toList();

      files.sort((a, b) =>
          a.statSync().accessed.compareTo(b.statSync().accessed));
      for (final f in files) {
        if (total <= maxCacheBytes) break;
        final size = f.statSync().size;
        try {
          f.deleteSync();
          total -= size;
          _ready.removeWhere((u) => _fileFor(u) == f.path);
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('video cache sweep failed: $e');
    }
  }

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  String _fileFor(String url) => '${_dir!.path}/${_hash(url)}.mp4';

  /// FNV-1a. We need a filename that is stable ACROSS RUNS so a cached
  /// file can be found again after a restart; Dart's String.hashCode
  /// carries no such guarantee.
  String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  /// Drop everything (settings "clear cache", logout).
  Future<void> clear() async {
    for (final url in _active.keys.toList()) {
      _cancel(url);
    }
    _queue.clear();
    _ready.clear();
    for (final url in _prefixed) {
      LocalMediaServer.instance.unregister(url);
    }
    _prefixed.clear();
    final dir = _dir;
    if (dir == null) return;
    try {
      for (final f in dir.listSync()) {
        if (f is File) f.deleteSync();
      }
    } catch (_) {}
  }

  @visibleForTesting
  void debugSetDirectory(Directory dir) => _dir = dir;

  @visibleForTesting
  Set<String> get debugReady => _ready;
}

class _Download {
  _Download(this.url);
  final String url;
  bool cancelled = false;
  StreamSubscription<List<int>>? subscription;
}
