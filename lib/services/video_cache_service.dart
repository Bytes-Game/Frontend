import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/network_quality_service.dart';

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
/// Deliberately simple: whole files, not byte ranges. Serving a partial
/// file to the player would need a local HTTP proxy to back-fill the
/// remainder on demand; that is the right eventual design (it is what
/// TikTok does, and it is why they can warm ~1 s of many videos instead
/// of all of a few) but it puts a hand-rolled range server on the
/// critical path of every video in the app. Whole-file caching gets the
/// same instant start with far less that can go wrong; [maxPrefetchBytes]
/// and the network-aware depth keep the data cost honest in the meantime.
class VideoCacheService {
  VideoCacheService._();
  static final VideoCacheService instance = VideoCacheService._();

  /// Total bytes of cached video we keep on disk before evicting the
  /// least-recently-used entries. Reels are short; this holds a few
  /// hundred of them and is trivial next to a photo library.
  static const int maxCacheBytes = 300 * 1024 * 1024;

  /// Refuse to cache anything larger than this. A reel is seconds long;
  /// anything this big is a mis-tagged upload or a legacy full-length
  /// video, and pulling it would blow the user's data for one swipe.
  static const int maxPrefetchBytes = 40 * 1024 * 1024;

  /// How many downloads may run at once. More than this and the warming
  /// downloads start competing with the reel the user is actually
  /// watching for bandwidth — which makes the app feel slower, not
  /// faster.
  static const int maxConcurrentDownloads = 2;

  Directory? _dir;
  bool _initialising = false;

  /// URLs whose file is fully downloaded and playable.
  final Set<String> _ready = <String>{};

  /// In-flight downloads, so a URL is never fetched twice and so a URL
  /// that leaves the prefetch window can be cancelled mid-flight.
  final Map<String, _Download> _active = {};

  /// Queued URLs waiting for a download slot, highest priority first.
  final List<String> _queue = [];

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
      // Half-written files from a previous run (app killed mid-download)
      // are not playable — drop them rather than risk handing the player
      // a truncated MP4.
      for (final f in dir.listSync()) {
        if (f is File && f.path.endsWith('.part')) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
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
    switch (NetworkQualityService.instance.current) {
      case NetworkQuality.high:
        return 6;
      case NetworkQuality.medium:
      case NetworkQuality.unknown:
        return 3;
      case NetworkQuality.low:
        return 1;
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

  /// Whether [url] is already on disk and ready to play instantly.
  bool isReady(String url) => pathFor(url) != null;

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
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      var total = 0;
      for (final f in files) {
        total += f.statSync().size;
      }
      if (total <= maxCacheBytes) return;

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
