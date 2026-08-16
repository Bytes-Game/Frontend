import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/local_media_server.dart';
import 'package:myapp/services/mp4_layout.dart';
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
  VideoCacheService._() {
    ReelDiagnostics.instance.setPipelineProbe(_pipelineSnapshot);
  }
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

  /// How many downloads may run at once with nothing playing against
  /// origin. More than this and the warming downloads start competing
  /// with the reel the user is actually watching for bandwidth — which
  /// makes the app feel slower, not faster.
  static const int maxConcurrentDownloads = 3;

  /// The ceiling while a reel on screen is still pulling bytes from
  /// origin AND warming is fetching prefixes. See [_downloadSlots].
  static const int maxConcurrentDownloadsDuringBackfill = 2;

  /// The ceiling while a reel is back-filling and warming is fetching
  /// WHOLE files. A whole file is unbounded up to [maxPrefetchBytes], so
  /// one of them alongside a playing reel is already as much as the
  /// connection should carry.
  static const int maxConcurrentWholeFileDownloadsDuringBackfill = 1;

  /// How much of a reel to warm in prefix mode. Sized to cover roughly
  /// the first two seconds at the 720p bitrate the feed now caps at
  /// (2.5 Mbps ≈ 310 KB/s), which is comfortably enough for the player
  /// to open, decode a first frame, and start rendering before the
  /// back-fill from origin catches up.
  static const int prefixBytes = 768 * 1024;

  /// A prefix fetch this far along is finished instead of cancelled when
  /// its reel leaves the window.
  ///
  /// Cancelling is meant to stop wasted work, but past the halfway mark
  /// it starts causing it: the bytes already on the wire are thrown away,
  /// and the reel — which the user may well scroll back to — has to be
  /// fetched from scratch later. A device log showed the failure mode
  /// plainly, with far more cancellations than completed downloads and
  /// barely a third of the feed ever warmed. The remaining bytes here are
  /// at most [prefixBytes] / 2, so finishing is bounded and cheap.
  static const int cancelGraceBytes = prefixBytes ~/ 2;

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

  /// Every distinct URL [warm] has ever been asked for. This is the
  /// denominator `downloads` was missing: if the feed only ever offered
  /// fifteen URLs, a download count that stops climbing is warming having
  /// nothing left to fetch, not warming being stuck.
  final Set<String> _seen = <String>{};

  /// Downloads killed mid-flight because their reel left the window. High
  /// against a low `downloads` means warming is churning — starting work
  /// and abandoning it as the user scrolls past — which spends the one
  /// slot without ever warming anything.
  int _cancelled = 0;

  /// Cancellations declined because the prefix was nearly complete. See
  /// [cancelGraceBytes]. Read against `cancelled`: it is the share of
  /// abandoned work the grace period is now converting into warm reels.
  int _spared = 0;

  /// Instantaneous state of the warming pipeline, appended to the
  /// diagnostics summary. See [ReelDiagnostics.setPipelineProbe].
  ///
  /// `active=n/m` is the slot count, and m answers how far back-fill
  /// pressure is holding warming down — see [_downloadSlots].
  String _pipelineSnapshot() =>
      'queue=${_queue.length} active=${_active.length}/$_downloadSlots '
      'urls=${_seen.length} cancelled=$_cancelled spared=$_spared';

  /// Callers parked in [awaitReady], one completer per URL. Signalled by
  /// [_signalWarm] on every path a URL can leave the warming pipeline —
  /// warmed, failed, cancelled, or dropped from the window — so a waiter
  /// is never left sitting out its whole timeout for work that has
  /// already stopped.
  final Map<String, Completer<void>> _warmWaiters = {};

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

  /// Resolves once [url] can start without a network round-trip, or when
  /// [timeout] elapses — whichever lands first. The value is simply
  /// [isReady] at that moment, so the caller can choose between opening
  /// against the proxy and opening cold.
  ///
  /// The timeout is not an error path. A reel that never warms still has
  /// to get a player, or a slow connection would lose the ready-ahead
  /// controller entirely and every swipe would pay a full cold open —
  /// strictly worse than what it replaced.
  Future<bool> awaitReady(String url, Duration timeout) async {
    if (url.isEmpty) return false;
    if (isReady(url)) return true;
    final waiter = _warmWaiters.putIfAbsent(url, Completer<void>.new);
    try {
      await waiter.future.timeout(timeout);
    } catch (_) {
      // Timed out, or warming ended without producing anything playable.
      // Either way the answer is whatever isReady says below.
    }
    return isReady(url);
  }

  /// Wake anything parked on [url].
  void _signalWarm(String url) {
    final waiter = _warmWaiters.remove(url);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

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
    // Diagnostics only, and it grows with every reel the session sees, so
    // release builds — which never print the summary — don't carry it.
    if (!kReleaseMode) _seen.addAll(wanted);

    for (final url in _active.keys.toList()) {
      if (!wantedSet.contains(url)) _cancel(url);
    }
    // Dequeued without ever running, so nothing downstream will signal
    // it — wake its waiter here or that caller waits out the full
    // timeout for a download that is no longer going to happen.
    _queue.removeWhere((u) {
      final drop = !wantedSet.contains(u);
      if (drop) _signalWarm(u);
      return drop;
    });

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

  /// How many warms may run right now.
  ///
  /// Every download here is speculative: it is for a reel the user has
  /// not swiped to and may never swipe to. A back-fill is not — it is
  /// feeding a decoder that is rendering to the screen this instant, and
  /// if it loses the race the user sees a freeze. They share one
  /// connection to the CDN and therefore one congestion window, so
  /// "equal priority" in practice means the reel being watched gets a
  /// third of the bandwidth while two reels nobody has asked for take
  /// the rest.
  ///
  /// So warming stands down — but how far depends on what a warm costs.
  ///
  /// In prefix mode a warm is [prefixBytes] and no more, whatever the
  /// video weighs: two of them together are about 1.5 MB, which is a
  /// rounding error against a reel streaming for its whole duration. The
  /// original single slot was sized for the whole-file era, when one warm
  /// could be tens of megabytes, and it throttled the wrong thing once
  /// prefixes shipped. A device log made the cost of that concrete —
  /// five URLs queued behind a single slot that back-fill pressure never
  /// released, so most reels opened cold while the cache sat idle.
  ///
  /// Whole-file mode keeps the one slot, because there the old reasoning
  /// still holds. Neither mode stands down to zero: a long reel
  /// back-fills for its whole duration, and a feed that only warms
  /// between reels is a feed with no warm reels.
  int get _downloadSlots {
    if (LocalMediaServer.instance.backfillsInFlight == 0) {
      return maxConcurrentDownloads;
    }
    return _prefixMode
        ? maxConcurrentDownloadsDuringBackfill
        : maxConcurrentWholeFileDownloadsDuringBackfill;
  }

  /// Start downloads until the concurrency limit is reached.
  void _pump() {
    while (_active.length < _downloadSlots && _queue.isNotEmpty) {
      final url = _queue.removeAt(0);
      _start(url);
    }
  }

  void _start(String url) {
    final download = _Download(url);
    _active[url] = download;
    ReelDiagnostics.instance.recordDownloadStarted();
    unawaited(_run(download).whenComplete(() {
      _active.remove(url);
      // One signal that covers success, failure and cancellation alike.
      // _runPrefix also signals the moment it registers with the proxy,
      // which is earlier — this is the guarantee that every download
      // ends in exactly one wake-up no matter which way it ended.
      _signalWarm(url);
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
    d.isPrefix = true;
    d.written = 0;
    try {
      final request = http.Request('GET', Uri.parse(d.url))
        ..headers[HttpHeaders.rangeHeader] = 'bytes=0-${prefixBytes - 1}';
      final response = await ApiService.httpClient.send(request);
      // No 206 means the origin ignored the range and is about to send
      // the whole file — not what we asked for, so let the whole-file
      // path own it rather than half-handling it here.
      if (response.statusCode != HttpStatus.partialContent) {
        ReelDiagnostics.instance
            .recordPrefixBailed('status${response.statusCode}');
        return false;
      }

      final total = _totalFromContentRange(
          response.headers[HttpHeaders.contentRangeHeader.toLowerCase()] ??
              response.headers['content-range']);
      // Only the total's *validity* matters here, not its size. We keep
      // exactly prefixBytes on disk either way; the proxy back-fills the
      // rest from origin as the player asks for it. See maxPrefetchBytes.
      if (total <= 0) {
        ReelDiagnostics.instance.recordPrefixBailed('noTotal');
        return false;
      }

      final file = File(prefixPath);
      sink = file.openWrite();
      final done = Completer<void>();
      d.done = done;
      // The opening bytes, kept as they stream past so the box order can
      // be read without going back to disk. Bounded — see
      // [mp4LayoutProbeBytes].
      final probe = BytesBuilder(copy: false);
      d.subscription = response.stream.listen(
        (chunk) {
          d.written += chunk.length;
          if (probe.length < mp4LayoutProbeBytes) {
            probe.add(chunk.length > mp4LayoutProbeBytes
                ? chunk.sublist(0, mp4LayoutProbeBytes)
                : chunk);
          }
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

      if (d.cancelled || d.written <= 0) {
        ReelDiagnostics.instance
            .recordPrefixBailed(d.cancelled ? 'cancelled' : 'empty');
        await _safeDelete(prefixPath);
        return false;
      }

      // An index at the end of the file makes this whole path pointless.
      // The player would read the warmed slice, find no moov in it, and
      // range-request the tail over the network before it could show a
      // single frame — and the reel would still have been counted as a
      // proxy start, so the summary would report it among the fast ones.
      //
      // Falling through to whole-file caching is the honest answer: it
      // costs more bytes up front, but the player needs the tail either
      // way, and after the first play the file is local. The bail tag
      // names the file count in the summary so a badly exported clip is
      // visible as a content fix rather than a mystery slow reel.
      if (readMp4Layout(probe.toBytes()) == Mp4Layout.moovAtEnd) {
        ReelDiagnostics.instance.recordPrefixBailed('moovAtEnd');
        await _safeDelete(prefixPath);
        return false;
      }

      LocalMediaServer.instance.register(
        originUrl: d.url,
        prefixPath: prefixPath,
        prefixLength: d.written,
        totalLength: total,
      );
      _prefixed.add(d.url);
      // Signal before the size sweep — a waiting spare should get its
      // proxy URL the instant the registration lands, not after disk
      // housekeeping.
      _signalWarm(d.url);
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
    // A failed prefix falls through to here on the same download, so the
    // byte count starts again and the cancel grace stops applying — a
    // whole file has no bounded "nearly done".
    d.isPrefix = false;
    d.written = 0;
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
      final done = Completer<void>();
      d.done = done;

      d.subscription = response.stream.listen(
        (chunk) {
          d.written += chunk.length;
          if (d.written > maxPrefetchBytes) {
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
      _signalWarm(d.url);
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
    // Already cancelled: the download stays in [_active] until it unwinds,
    // so the window can sweep past it several times. Counting each sweep
    // reported more cancellations than there were downloads.
    if (d == null || d.cancelled) return;

    if (d.isPrefix && d.written >= cancelGraceBytes) {
      if (!d.spared) {
        d.spared = true;
        _spared++;
      }
      return;
    }

    _cancelled++;
    d.cancelled = true;
    unawaited(d.subscription?.cancel());

    // A cancelled subscription fires neither onDone nor onError, so the
    // download's `await done.future` would wait forever — holding its
    // slot, and with it the whole queue, for the rest of the session.
    // The device log that prompted this read `queue=5 active=1/1` with
    // fourteen cancellations: one cancel was enough to wedge warming
    // permanently, because during back-fill there was only ever the one
    // slot to lose.
    final done = d.done;
    if (done != null && !done.isCompleted) done.complete();
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
    for (final url in [..._queue, ..._warmWaiters.keys]) {
      _signalWarm(url);
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

  /// Downloads still unwinding. [clear] cancels them but cannot wait for
  /// them, so a test that measures concurrency has to let the previous
  /// one's downloads drain or it measures the leftovers too.
  @visibleForTesting
  int get debugActive => _active.length;
}

class _Download {
  _Download(this.url);
  final String url;
  bool cancelled = false;

  /// True while this download is fetching an opening slice rather than a
  /// whole file. Only a prefix has a bounded size, so only a prefix can
  /// be judged "nearly done" — see [VideoCacheService.cancelGraceBytes].
  bool isPrefix = false;

  /// Bytes received so far, reset when the prefix path falls through to
  /// the whole-file path.
  int written = 0;

  /// Set once when a cancellation was declined, so the tally counts the
  /// download rather than the number of times the window moved past it.
  bool spared = false;

  StreamSubscription<List<int>>? subscription;

  /// Completed when the body stream ends, errors, or is cancelled. The
  /// download's `await` on this is the only thing holding its slot, so
  /// every one of those three has to complete it — see
  /// [VideoCacheService._cancel].
  Completer<void>? done;
}
