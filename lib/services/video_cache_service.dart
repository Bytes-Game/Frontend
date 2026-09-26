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
    // Saved videos grow while they play, which finishes no download, so the
    // size limit has to be checked from the proxy's side too.
    LocalMediaServer.instance.onHeadGrown = () => unawaited(_enforceSizeCap());
  }
  static final VideoCacheService instance = VideoCacheService._();

  /// Total bytes of cached video we keep on disk before evicting the
  /// least-recently-used entries. Reels are short; this holds a few
  /// hundred of them and is trivial next to a photo library.
  ///
  /// It covers everything in the folder: whole videos, and the saved
  /// openings the proxy serves from, which grow as a video is watched.
  /// See [_enforceSizeCap].
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
  ///
  /// Three, the same as [maxConcurrentDownloads], because in prefix mode a
  /// warm is a bounded slice and not an open-ended file. It was two, and
  /// that is where a session ended up spending most of its time: a device
  /// log shows the lane count walking 5 → 4 → 2 and staying at 2, with 41
  /// of 80 warms cancelled and one swipe in five landing on a reel that
  /// was not ready. Two lanes cannot get ahead of somebody scrolling.
  ///
  /// Safe because warming is not what protects the reel on screen —
  /// [holdWarming] is. The moment the playing reel starts waiting for
  /// bytes, every warm stands down until it recovers, so an extra lane
  /// cannot starve it. The lane count only decides how fast the app gets
  /// ahead while the thing on screen is healthy.
  static const int maxConcurrentDownloadsDuringBackfill = 3;

  /// The ceiling while a reel is back-filling and warming is fetching
  /// WHOLE files. A whole file is unbounded up to [maxPrefetchBytes], so
  /// one of them alongside a playing reel is already as much as the
  /// connection should carry.
  static const int maxConcurrentWholeFileDownloadsDuringBackfill = 1;

  /// How long a download may go WITHOUT RECEIVING A BYTE before it is given
  /// up.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// A STALLED DOWNLOAD USED TO HOLD ITS SLOT FOR EVER
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// There was no deadline of any kind on a warm. Not on getting a response,
  /// not on the bytes arriving afterwards. A connection that went quiet
  /// mid-body simply sat there, holding one of the download slots until the
  /// app was killed.
  ///
  /// Four of those and warming is over for the session. From a device log,
  /// each line a summary taken ten reels apart:
  ///
  ///   downloads=45  warmed=25  queue=0  active=4/4
  ///   downloads=47  warmed=26  queue=1  active=4/4
  ///   downloads=50  warmed=26  queue=3  active=4/4
  ///   downloads=50  warmed=26  queue=1  active=4/4
  ///   downloads=50  warmed=26  queue=1  active=4/4
  ///
  /// Downloads stop at 50 and warmed stops at 26 while reels keep opening.
  /// Every slot is busy and nothing finishes; the queue behind them grows.
  /// The hit rate fell through that session, 60% to 48%, as slots died one
  /// by one. That is "it sticks more the longer I use it".
  ///
  /// INACTIVITY, not total time. A slow link is not a broken one: at the
  /// 2.9 Mbps this app measures, a 768 KB slice legitimately takes a couple
  /// of seconds, and longer again when several share the link. What is never
  /// legitimate is bytes stopping and never resuming. So the clock resets on
  /// every chunk, and only a silence this long gives up.
  ///
  /// Ten seconds is far longer than any real gap between packets and short
  /// enough that a dead connection costs one slot for a moment rather than
  /// for the rest of the session.
  static const Duration stallTimeout = Duration(seconds: 10);

  /// How long to wait for the response headers before giving up.
  ///
  /// Separate from [stallTimeout] because nothing has started yet: there are
  /// no bytes to be idle between. Matches the ceiling the API client applies
  /// to its own requests — which this path does NOT get, because it uses the
  /// raw client rather than that wrapper.
  static const Duration responseTimeout = Duration(seconds: 30);

  /// Every byte stream in this file goes through here.
  ///
  /// Three download paths — the opening slice, the tail of a moov-at-end
  /// file, and a whole file — and all three had the same hole. One helper so
  /// a fourth cannot be added without it.
  ///
  /// The error lands on the same path a network failure already takes: the
  /// slot is freed, anything waiting is woken, and the reel falls back to
  /// streaming from origin.
  static Stream<List<int>> _bounded(Stream<List<int>> body) => body.timeout(
        stallTimeout,
        onTimeout: (sink) =>
            sink.addError(TimeoutException('download stalled', stallTimeout)),
      );

  /// How much of a reel to warm in prefix mode. Against the ladder the server
  /// encodes to — 2.5 Mbps at 720p, 3.5 at the fast-connection rung — this is
  /// between 1.8 and 2.5 seconds of video.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// RAISING THIS IS NOT A LOCAL CHANGE. IT WAS TRIED AND REVERTED.
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// 1.8 seconds looks thin, and the obvious move is to make it bigger. That
  /// was done — 768 KB to 2 MB — and it made the feed worse, twice, because
  /// this number is not just "how much of one reel we hold". It is the unit
  /// two other budgets are denominated in, and both were written down
  /// against 768 KB:
  ///
  ///   * [prefetchDepth] divides BY this to work out how many reels the
  ///     link can finish between swipes. Doubling it halves the window it
  ///     computes, and at the time this was tried the depth was a flat ten
  ///     on wifi, so the read-ahead budget went from 7.5 MB to 20 MB.
  ///   * [_downloadSlots] allowed extra parallel warms because "each warm is
  ///     a fixed small slice". At 2 MB they are not small.
  ///
  /// So the change tripled how much read-ahead competes with the reel on
  /// screen, and the reel on screen is what lost. Device logs, per reel
  /// played:
  ///
  ///   768 KB, 4 slots    22% opened cold    (baseline)
  ///   2 MB,   4 slots    22% opened cold    1.80 decoder starvations
  ///   2 MB,   2 slots    38% opened cold    2.41 decoder starvations
  ///
  /// The middle row was the attempt; the last row was the attempt to fix the
  /// attempt by cutting parallelism, which starved warming instead and made
  /// cold opens worse. Both are reverted.
  ///
  /// The blocker that used to be named here — that a reel counted as ready
  /// only when the WHOLE slice had landed, so a bigger slice meant a later
  /// start — is fixed. See [prefixReadyBytes]: a reel is playable once its
  /// opening quarter-megabyte is down, and the rest arrives behind it.
  ///
  /// That removes the "later to be ready" half of the argument but NOT the
  /// other half. This is still the unit [prefetchDepth] and [_downloadSlots]
  /// are budgeted in, and both are still written down against 768 KB. Raising
  /// it still multiplies read-ahead across every reel in the window, which is
  /// what the table above measures. Move all three or none.
  static const int prefixBytes = 768 * 1024;

  /// How much of the opening slice has to exist before a reel counts as
  /// ready, rather than waiting for the whole of [prefixBytes].
  ///
  /// This is what "it sticks when I scroll fast" was. Flicking through the
  /// feed cancels warms that are part-finished — 43 of 119 downloads in one
  /// session — and until this existed a part-finished warm was worth exactly
  /// nothing. The reel you stopped on opened as if nothing had been fetched
  /// at all, which at 5 Mbps is over a second of black.
  ///
  /// A player does not need the whole slice to start. It needs the header
  /// and enough media to decode a frame. A quarter of a megabyte covers
  /// that with room to spare on the sizes the server encodes to, and the
  /// rest keeps arriving behind it.
  ///
  /// Not smaller: too little and the player opens, runs out almost at once
  /// and stalls anyway, which looks worse than opening a moment later.
  /// Not larger: every extra byte here is time the viewer spends looking at
  /// nothing.
  ///
  /// Only for files with the index at the front. One with its index at the
  /// end is not playable from the head alone at any size — the player has to
  /// reach the end before it can decode anything, which is what [tailBytes]
  /// is for.
  static const int prefixReadyBytes = 256 * 1024;

  /// How many SECONDS of video the player should hold before it starts.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THE BYTE COUNT ABOVE WAS NOT ENOUGH ON ITS OWN
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// [prefixReadyBytes] is a quarter of a megabyte, chosen as "enough media
  /// to decode a frame, with room to spare". A quarter of a megabyte is not
  /// an amount of video, though — it is an amount of video DIVIDED BY THE
  /// BITRATE, and the app serves three:
  ///
  ///   480p     1.6 Mbps    256 KB = 1.29s of video
  ///   720p     2.7 Mbps    256 KB = 0.77s
  ///   720p_hq  3.1 Mbps    256 KB = 0.68s
  ///
  /// Under a second at the rungs most people are served. The player opens on
  /// that, and the rest of the slice — sharing the link with four other reels
  /// being warmed — is several seconds away:
  ///
  ///   link 2.1 Mbps, reel's share ~0.4 Mbps -> remaining 512 KB in 10.0s
  ///   link 4.5 Mbps, reel's share ~0.9 Mbps -> remaining 512 KB in  4.7s
  ///
  /// So it played for a moment, ran dry, and sat there. A device log caught
  /// it exactly: render intervals with a median of 131ms against the 33ms of
  /// a 30fps video, the worst windows reading `Render: 1` over five seconds —
  /// and `Drop: 0` throughout. Nothing was being dropped. The decoder was
  /// rendering every frame it was given and being given almost none.
  ///
  /// The comment on [prefixReadyBytes] predicted this failure in words — "too
  /// little and the player opens, runs out almost at once and stalls anyway,
  /// which looks worse than opening a moment later" — and then sized it in
  /// bytes, which cannot express it.
  ///
  /// Two seconds is what a short-video app opens on: long enough that the
  /// download has a runway to get ahead, short enough that the wait is not
  /// what anybody notices. It is bounded by [prefixBytes] at the top, so a
  /// high rung simply waits for the whole slice rather than asking for more
  /// than is being fetched.
  static const double prefixReadySeconds = 2.0;

  /// The least the player will ever be asked to wait for, whatever the
  /// arithmetic says. A file whose bitrate we cannot work out still has to
  /// open on something, and this is the old fixed threshold — the behaviour
  /// everything had before.
  static const int prefixReadyFloorBytes = prefixReadyBytes;

  /// How many bytes of actual VIDEO are worth waiting for before starting.
  ///
  /// Answered in seconds of video and converted to bytes, rather than the
  /// other way round. An unrecognised file — a raw upload, someone else's
  /// URL — is assumed to be the most expensive rung there is: guessing low
  /// means opening too early and stalling, which is the thing being fixed.
  ///
  /// This is media only. It says nothing about the file's index, which
  /// also has to be downloaded first and is not a fixed size — see
  /// [prefixReadyBytesFor], which adds the two together.
  static int mediaReadyBytesFor(String url) {
    final bps = NetworkQualityService.bitrateForVariantUrl(url) ??
        NetworkQualityService.bitrateNeededFor.values
            .reduce((a, b) => a > b ? a : b);
    final want = (bps * prefixReadySeconds / 8).round();
    if (want < prefixReadyFloorBytes) return prefixReadyFloorBytes;
    if (want > prefixBytes) return prefixBytes;
    return want;
  }

  /// How much of [url] is enough to start playing it: the file's index,
  /// then [prefixReadySeconds] of video behind it.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THE INDEX HAS TO BE COUNTED SEPARATELY
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// This used to be [mediaReadyBytesFor] on its own — "two seconds of
  /// video" — and it quietly assumed the index in front of that video was
  /// small enough not to matter.
  ///
  /// It is small enough for a ten-second clip, where it is about 12 KB. It
  /// is not for a long one. The index carries a row per frame, so it grows
  /// with the running time: 195 KB at three minutes, 653 KB at ten. See
  /// [mp4IndexEndsAt], where those are measured off this app's own catalog.
  ///
  /// What that did to a ten-minute upload in the feed: the threshold said
  /// 375 KB, so the reel was handed to the player at 375 KB — 57% of an
  /// index and not one byte of video. The player cannot decode from that.
  /// It went to the network for the rest of the index while the viewer
  /// looked at a black screen. Warming had made the reel SLOWER than not
  /// warming it, and the reel was counted as a cache hit while doing it.
  ///
  /// [indexEndsAt] is where the index finishes, read out of the opening
  /// bytes. Null means the file has not said — a short read, an index at
  /// the end of the file, something that is not an MP4 — and then this
  /// behaves exactly as it did before, because a guess in either direction
  /// would be worse than the behaviour that was already there.
  ///
  /// Still capped at [prefixBytes]: this decides when to hand over what is
  /// being fetched, not how much to fetch. A file whose index alone fills
  /// the slice is refused earlier, by [prefixWorthWarming].
  static int prefixReadyBytesFor(String url, {int? indexEndsAt}) {
    final media = mediaReadyBytesFor(url);
    if (indexEndsAt == null) return media;
    final want = indexEndsAt + media;
    if (want > prefixBytes) return prefixBytes;
    return want;
  }

  /// Whether warming the opening slice of a file with this index can
  /// actually make it start faster.
  ///
  /// It cannot if the index alone leaves no room for video. The player
  /// would read the whole slice, still have nothing to decode, and go to
  /// the network anyway — with the warm having competed for the link on
  /// the way. Saying no is the honest answer, and it keeps the reel out of
  /// the cache-hit count, which is the mistake [Mp4Layout.moovAtEnd] was
  /// added to stop making.
  ///
  /// The line is [prefixReadyFloorBytes] of room left over: the smallest
  /// amount of video the app will ever open on. Below that there is no
  /// version of this that helps.
  static bool prefixWorthWarming(int indexEndsAt) =>
      indexEndsAt + prefixReadyFloorBytes <= prefixBytes;

  /// How much of the END of a moov-at-end file to warm alongside its head.
  ///
  /// Those files keep their index (`moov`) after the media, so a player
  /// opening one reads the header, finds no index, and immediately seeks
  /// to the end for it. Warming only the head therefore bought nothing:
  /// the first thing the player did was go to the network anyway. This
  /// slice is what the seek lands in.
  ///
  /// Sized for the index of a short reel, which is dominated by the
  /// per-sample tables — a few KB per second per track, so tens of KB for
  /// a feed clip and comfortably inside this even for a long one. Being
  /// short is not a failure: the player's read simply runs past what we
  /// hold and the proxy serves the remainder from origin, which is the
  /// behaviour it had before any of this. Being generous is not free
  /// either — it is spent on every moov-at-end reel in the window,
  /// warmed or not — so this stays a fraction of [prefixBytes].
  static const int tailBytes = 256 * 1024;

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

  /// The reels most recently asked to be warmed: the next few, and the
  /// one or two behind. The size sweep never deletes their saved copies —
  /// they are where the viewer is about to be.
  Set<String> _window = const <String>{};

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
      // `.prefix` and `.tail` files are fragments that are only ever
      // useful via an in-memory proxy registration, and that registration
      // does not survive a restart. Nothing can play from them after that,
      // so they are dead weight from the moment the app starts, and the
      // size sweep would only get round to them once the cache was full.
      for (final f in dir.listSync()) {
        if (f is File &&
            (f.path.endsWith('.part') ||
                f.path.endsWith('.prefix') ||
                f.path.endsWith('.tail'))) {
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

  /// The most reels ahead we will ever warm, whatever the link measures.
  ///
  /// This is the depth the app already used on wifi, kept as a ceiling so
  /// the measured window can only ever come out the same or SHALLOWER than
  /// what shipped before it existed — never deeper. Whether a very fast
  /// link would benefit from more than ten is a separate question and is
  /// not answered here.
  static const int maxPrefetchDepth = 10;

  /// Fewest reels ahead we will warm, even on a link that cannot afford it.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// FOUR, BECAUSE THE APP KEEPS FOUR PLAYERS READY
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// This was 1, and for as long as nothing had been measured that did not
  /// matter: with no measurement the depth fell through to a table that
  /// answered 6. Then the app learned to remember how fast the link was
  /// last time, so a measurement exists from the first moment — and the
  /// measured branch started answering on the very first page.
  ///
  /// What it answered was 2, and the session got worse in exactly the way
  /// a shallow window does:
  ///
  ///     depth=6   proxy 93%   swipe 91/0 warm/cold
  ///     depth=2   proxy 72%   swipe 63/3 warm/cold
  ///
  /// The measured number is not wrong about what it measures — at 2 Mbps of
  /// spare, one dwell buys about two slices. It is answering the wrong
  /// question. That is a REFILL RATE, and a window is a BUFFER: if the link
  /// can fetch two reels in the time the viewer watches one, it has surplus
  /// and should be building a deeper buffer, not stopping at two. Sizing a
  /// buffer by its refill rate is backwards, and the faster the viewer
  /// scrolls the more backwards it gets.
  ///
  /// Rewriting that calculation is a bigger change than this needs. What it
  /// needs is a floor with a reason: never fewer reels of BYTES than the
  /// app holds PLAYERS. Below that the app is knowingly holding a player
  /// for a reel it has not downloaded, which is a cold open it chose to
  /// have.
  ///
  /// Four is [VideoPoolConfig.onScreenWorkingSet] — the reel on screen, one
  /// either side, and the opponent of a battle. It cannot be read from here
  /// because that file imports this one, so a test pins the two together
  /// instead; see prefetch_depth_test.
  ///
  /// Safe on a link that cannot afford it, because the depth is not what
  /// protects the reel being watched — [holdWarming] is. Every warm stands
  /// down the moment the playing reel starts waiting for bytes.
  static const int minPrefetchDepth = 4;

  /// How many reels ahead to warm.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY THIS IS MEASURED AND NOT READ OFF THE CONNECTION TYPE
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// It used to be a table against [NetworkQuality], which is the kind of
  /// connection — wifi, LTE, 3G. Wifi meant ten reels ahead.
  ///
  /// Wifi is not a speed. The device logs that prompted this were a wifi
  /// link measuring 2.1 to 4.5 Mbps, and the app read "wifi" and set out to
  /// warm ten reels ahead of the thumb. It could not. Of 175 warms started,
  /// 87 finished and 88 were thrown away when the window moved past them —
  /// half the read-ahead traffic bought nothing, while competing for the
  /// link with the reel actually on screen.
  ///
  /// This is the same mistake [NetworkQualityService.affordableLabel] was
  /// written to fix for picture quality, left standing for read-ahead. That
  /// file says so in as many words: "the connection TYPE still decides how
  /// much to read ahead; the measured speed decides which quality is safe
  /// to play." Both now come off the measurement.
  ///
  /// The sum is the obvious one, out of numbers that already exist:
  ///
  ///   one warm costs          [prefixBytes] × 8 bits
  ///   a swipe gives us        [NetworkQualityService.typicalDwellSeconds]
  ///   read-ahead can spend    [NetworkQualityService.spareBpsForReadAhead]
  ///
  ///   depth = spare × dwell ÷ (prefixBytes × 8)
  ///
  /// In words: how many reels the link can actually FINISH between one
  /// swipe and the next. Starting more than that is not depth, it is a
  /// queue of downloads that get cancelled.
  ///
  /// Prefix mode only. A whole-file warm is not [prefixBytes], it is the
  /// entire reel, so the sum above does not describe it — whole-file mode
  /// keeps the old table. So does the first moment after launch, before
  /// there are enough samples to have measured anything.
  int get prefetchDepth {
    if (_prefixMode) {
      final spare = NetworkQualityService.instance.spareBpsForReadAhead;
      if (spare != null) {
        final perDwell =
            spare * NetworkQualityService.typicalDwellSeconds / (prefixBytes * 8);
        final depth = perDwell.round();
        if (depth < minPrefetchDepth) return minPrefetchDepth;
        if (depth > maxPrefetchDepth) return maxPrefetchDepth;
        return depth;
      }
    }
    // Nothing measured yet, or whole-file mode. Fall back to the kind of
    // connection. Prefix mode pulls ~0.75 MB per reel instead of ~9 MB, so
    // the same data budget buys a deeper window.
    final deep = _prefixMode;
    switch (NetworkQualityService.instance.current) {
      case NetworkQuality.high:
        return deep ? maxPrefetchDepth : 6;
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
  ///
  /// The proxy alone is not enough to say yes. [clear] leaves the proxy
  /// still knowing about reels whose files it has just deleted (it has to,
  /// see there), so "the proxy knows it" and "we still hold its opening"
  /// are two different things after a clear. [_prefixed] is the second.
  bool isReady(String url) =>
      pathFor(url) != null ||
      (_prefixed.contains(url) &&
          LocalMediaServer.instance.localUrlFor(url) != null);

  /// Whether anything has acted on [url] yet: already warmed, being
  /// downloaded now, or waiting in the queue for a slot.
  ///
  /// Asked by the quality picker before it changes its mind about which
  /// rendition a reel should use. Changing to a different file after work
  /// has started on this one throws that work away and, if a player is
  /// already open on it, restarts the video under the viewer.
  bool isSpokenFor(String url) =>
      isReady(url) || _active.containsKey(url) || _queue.contains(url);

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
    _window = wantedSet;
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
  /// Extra slots granted on a connection that can clearly carry them.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// WHY THE OLD FIXED NUMBER WAS TOO LOW
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// Two slots was sized for a feed of single videos. A battle is TWO — the
  /// challenger and the opponent behind the flip — and the warmer queues
  /// every upcoming challenger first, then every opponent behind them. So a
  /// battle-heavy feed is double the work through the same two slots.
  ///
  /// A device run right after battles started ranking properly shows what
  /// that costs: eight downloads waiting with both slots busy, twenty warms
  /// cancelled before they finished, the cache hit rate down from 96% to 87%,
  /// and reels opening straight against the network up from 4% to 13%. Videos
  /// took 2.1 seconds to start moving in the Battles tab against 0.8 in
  /// Shorts.
  ///
  /// ════════════════════════════════════════════════════════════════════════
  /// WHY IT IS NOT JUST A BIGGER NUMBER
  /// ════════════════════════════════════════════════════════════════════════
  ///
  /// Concurrency is only free when there is bandwidth spare. On a saturated
  /// 3G link, more parallel downloads do not finish sooner — they finish
  /// LATER, all of them, and they take the reel on screen down with them,
  /// because it is sharing the same pipe. That is the whole reason this
  /// number was small.
  ///
  /// So it scales with what the connection has already proved it can do.
  /// Wifi gets the extra slots; a weak or unknown link keeps exactly the
  /// behaviour it had before. This is the same shape as the variant picker
  /// next door, which reads the same signal to decide 480p versus 720p — one
  /// measurement, two decisions.
  static const int extraSlotsOnFastNetwork = 2;

  /// True when the connection is good enough to be worth loading up.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WIFI IS NOT A SPEED — THE LAST PLACE THAT STILL BELIEVED IT WAS
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// This asked [NetworkQuality], which is the KIND of connection. Wifi meant
  /// extra download slots.
  ///
  /// The device this app is tested on reports wifi and measures 2.9 Mbps. It
  /// was being given five parallel warms on a link that cannot carry two —
  /// each one crawling, none finishing, all of them competing with the video
  /// on screen for the same 2.9 Mbps.
  ///
  /// [prefetchDepth] was fixed for exactly this and this was left behind, so
  /// the window narrowed while the number of things fetched at once did not.
  ///
  /// The measurement is already here. Extra slots are worth it when there is
  /// bandwidth spare after the picture — [spareBpsForReadAhead] is what that
  /// means — and the bar is one extra slot's worth of a reel arriving inside
  /// a dwell, which is the same arithmetic [prefetchDepth] uses.
  ///
  /// Falls back to the kind of connection only before anything is measured,
  /// which is the first seconds after launch.
  bool get _networkCanTakeMore {
    final spare = NetworkQualityService.instance.spareBpsForReadAhead;
    if (spare != null) {
      // Room for at least two reels inside one dwell: one for the window to
      // keep pace, one more to be worth fetching alongside it.
      final perDwell = spare *
          NetworkQualityService.typicalDwellSeconds /
          (prefixBytes * 8);
      return perDwell >= 2;
    }
    // Nothing measured yet. Wifi only, and deliberately NOT medium: LTE is
    // usually fine and sometimes suddenly is not, and the cost of guessing
    // wrong lands on the video the user is watching right now. `unknown` is
    // treated as slow for the same reason.
    return NetworkQualityService.instance.current == NetworkQuality.high;
  }

  /// The slot count, exposed so a test can assert it reacts to the network
  /// rather than asserting the constants add up.
  @visibleForTesting
  int get downloadSlotsForTest => _downloadSlots;

  int get _downloadSlots {
    final bonus = _networkCanTakeMore ? extraSlotsOnFastNetwork : 0;
    if (LocalMediaServer.instance.backfillsInFlight == 0) {
      return maxConcurrentDownloads + bonus;
    }
    if (!_prefixMode) {
      // Whole-file mode keeps its single slot on any connection. A whole file
      // is unbounded up to maxPrefetchBytes, so a second one alongside a
      // playing reel can be tens of megabytes racing the thing on screen —
      // which is the case this limit exists for, fast connection or not.
      return maxConcurrentWholeFileDownloadsDuringBackfill;
    }
    // Prefix mode: each warm is a fixed small slice, so more of them in
    // flight is bounded extra traffic rather than open-ended.
    return maxConcurrentDownloadsDuringBackfill + bonus;
  }

  /// True while read-ahead has stood down for the reel on screen.
  bool _held = false;

  /// Whether warming is currently standing down. Diagnostics and tests.
  bool get isHeld => _held;

  /// Stand read-ahead down: the reel on screen has run out of video.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// WHY READ-AHEAD HAS TO YIELD, AND WHY A STATIC RESERVE WAS NOT ENOUGH
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// The arithmetic on the device this app is tested on:
  ///
  ///   the link measures            2.9 Mbps
  ///   480p needs, sustained        1.6 Mbps
  ///   read-ahead runs              up to four downloads, flat out
  ///
  /// Five streams share one link, so the reel being WATCHED gets about a
  /// fifth of it — 0.58 Mbps against the 1.6 it needs. It plays from the
  /// slice already on disk, reaches the end of it, and starves.
  ///
  /// That is "it sticks at the start and then plays": the start is the part
  /// that was already downloaded.
  ///
  /// The decoder statistics say the same thing from the other side. Across
  /// one session, 2,661 frames rendered and ZERO dropped. A decoder that
  /// never drops a frame is never behind — it is always waiting.
  ///
  /// [NetworkQualityService.readAheadReserveBps] was meant to cover this and
  /// cannot: it is an input to choosing a RENDITION, and nothing downstream
  /// makes read-ahead actually stay inside it. Four sockets pulling as hard
  /// as TCP allows do not know a reserve exists.
  ///
  /// So the rule is not a budget, it is a priority: while the reel on screen
  /// has nothing to play, nothing else may use the link.
  ///
  /// Paused, NOT cancelled. A cancelled warm throws away everything already
  /// fetched, and the reel it was for is usually still coming. Pausing the
  /// subscription stops reading the socket, TCP closes its window, and the
  /// bandwidth goes to the reel that needs it — and Dart stops the stall
  /// clock on a paused subscription, so a held download is not mistaken for
  /// a dead one. That last part is verified rather than assumed; see the
  /// test.
  void holdWarming() {
    // Whatever was about to resume, do not. The reel is dry again.
    _resumeSettle?.cancel();
    _resumeSettle = null;
    if (_held) return;
    _held = true;
    ReelDiagnostics.instance.recordWarmingHeld();
    for (final d in _active.values) {
      d.subscription?.pause();
    }
  }

  /// How long the reel on screen has to keep playing before background
  /// downloads are allowed to start again.
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// A STAND-DOWN THAT LASTS NINETY MILLISECONDS IS NOT A STAND-DOWN
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// This defence was measured on a device, and it fired. It just did not
  /// last:
  ///
  ///     warming stood down n=43 for 3.9s
  ///
  /// Forty-three stand-downs sharing under four seconds — ninety
  /// milliseconds each, and forty-two of them nearer zero than that; almost
  /// all of the 3.9s is one single hold. Over the same session the decoder
  /// was still handed nothing to play 261 times, median a FULL SECOND,
  /// unchanged from the run before this defence was measured at all.
  ///
  /// So it was noticing and letting go again immediately. `isBuffering`
  /// does not stay true while a reel is dry — it flickers, true then false
  /// then true, and every flicker was a hold and an instant release. The
  /// downloads paused for a few milliseconds and went straight back to
  /// competing for the link the reel was starving for.
  ///
  /// Releasing on a settle rather than on the first good tick is what makes
  /// the hold mean something. A reel that is genuinely playing again keeps
  /// playing for half a second; one that is still struggling buffers again
  /// within that window and the pending resume is cancelled.
  ///
  /// Half a second, not longer: this is bandwidth taken from reading ahead,
  /// and read-ahead is what stops the NEXT swipe being cold. The cost of
  /// holding too long is a cold neighbour; the cost of not holding at all
  /// is the video in front of you stopping. But both are real.
  @visibleForTesting
  static Duration warmingResumesAfter = const Duration(milliseconds: 500);

  Timer? _resumeSettle;

  /// The reel on screen is playing again; read-ahead may resume.
  void releaseWarming() {
    if (!_held) return;
    // Already counting down. Re-arming on every good tick would push the
    // resume further away on each one and it would never arrive.
    if (_resumeSettle != null) return;
    _resumeSettle = Timer(warmingResumesAfter, () {
      _resumeSettle = null;
      if (!_held) return;
      _held = false;
      ReelDiagnostics.instance.recordWarmingReleased();
      for (final d in _active.values) {
        d.subscription?.resume();
      }
      _pump();
    });
  }

  /// Resume now, without waiting out the settle.
  ///
  /// For the paths that are not "the reel recovered" — the reel changed, or
  /// its player was disposed. There is nothing to protect any more, and
  /// making the next reel wait half a second for downloads it needs would
  /// turn a defence into a delay.
  void releaseWarmingNow() {
    _resumeSettle?.cancel();
    _resumeSettle = null;
    if (!_held) return;
    _held = false;
    ReelDiagnostics.instance.recordWarmingReleased();
    for (final d in _active.values) {
      d.subscription?.resume();
    }
    _pump();
  }

  /// Start downloads until the concurrency limit is reached.
  void _pump() {
    // Standing down for the reel on screen. Starting another download now
    // would take the bandwidth it is waiting for.
    if (_held) return;
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
    // Declared out here so the finally below can always close it. A lane
    // left open is worse than not counting it at all: the meter's busy
    // clock never stops, so every later reading is divided by time the link
    // spent idle and the app talks itself into a slower network than it has
    // — which is the very fault this meter was added to fix.
    var laneOpen = false;
    void closeLane() {
      if (!laneOpen) return;
      laneOpen = false;
      NetworkQualityService.instance.noteTransferFinished();
    }
    try {
      final request = http.Request('GET', Uri.parse(d.url))
        ..headers[HttpHeaders.rangeHeader] = 'bytes=0-${prefixBytes - 1}';
      // Bounded, because httpClient.send is the RAW client — the timeout the
      // API wrapper applies to its own calls is not on this path.
      final response = await ApiService.httpClient
          .send(request)
          .timeout(responseTimeout);
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
      // Time this download so the app can find out how fast the connection
      // really is. Warming already pulls a fixed slice and already knows
      // when it started and finished, so a throughput sample costs nothing
      // and measures the thing that matters — this phone, this network,
      // this CDN — rather than guessing from "is it wifi".
      // See NetworkQualityService.recordThroughput.
      // This download is now using the link. The meter counts busy time
      // only while at least one is, so a quiet stretch does not read as a
      // slow network.
      NetworkQualityService.instance.noteTransferStarted();
      laneOpen = true;
      final done = Completer<void>();
      d.done = done;
      // The opening bytes, kept as they stream past so the box order can
      // be read without going back to disk. Bounded — see
      // [mp4LayoutProbeBytes].
      final probe = BytesBuilder(copy: false);
      var openedEarly = false;
      // Where this file's index ends, once the opening bytes have said.
      // Null means they have not — see [prefixReadyBytesFor].
      int? indexEndsAt;
      var indexRead = false;
      d.subscription = _bounded(response.stream).listen(
        (chunk) {
          d.written += chunk.length;
          // Every byte off the network goes to the link meter, whichever
          // download it belongs to. That is what makes the reading the
          // LINK's speed rather than this one lane's — see
          // NetworkQualityService.noteBytesFromNetwork.
          NetworkQualityService.instance.noteBytesFromNetwork(chunk.length);
          if (probe.length < mp4LayoutProbeBytes) {
            probe.add(chunk.length > mp4LayoutProbeBytes
                ? chunk.sublist(0, mp4LayoutProbeBytes)
                : chunk);
          }
          sink!.add(chunk);

          // ════════════════════════════════════════════════════════════════
          // READY BEFORE FINISHED
          // ════════════════════════════════════════════════════════════════
          //
          // A reel used to count as ready only when the WHOLE slice had
          // landed. Everything before that was worth nothing: scroll onto a
          // reel whose warm was 90% done and it still opened cold.
          //
          // That is what "it sticks when I scroll fast" is. Flicking through
          // cancels warms in flight — 43 of 119 in one session — and the reel
          // you stop on starts from nothing, which at 5 Mbps is over a second
          // of black before the first frame.
          //
          // A player does not need the whole slice. It needs the header and
          // enough media to decode a frame. So we hand it over as soon as
          // that much exists and keep filling behind it.
          //
          // Safe by construction: the proxy serves min(bytes actually on
          // disk, length we claimed) and takes everything past that from
          // origin — see LocalMediaServer's range handling, which already
          // has to cope with a prefix evicted mid-playback.
          // The file's index has to be counted before "enough to start"
          // means anything — it sits in front of the video and it is not a
          // fixed size. Read once, off the opening bytes, and remembered:
          // the answer is in the first few dozen bytes, so it is settled
          // long before the index itself has finished arriving.
          if (!indexRead && probe.length >= mp4LayoutProbeBytes) {
            indexRead = true;
            indexEndsAt = mp4IndexEndsAt(probe.toBytes());
            // Now that the index is measured, this download knows how much
            // IT needs — which is what decides whether abandoning it wastes
            // the work. See [_Download.spareAtBytes].
            d.needBytes = prefixReadyBytesFor(d.url, indexEndsAt: indexEndsAt);
            // An index too big to leave room for any video means warming
            // this slice cannot make the reel start sooner. Stop, rather
            // than spend the link on a slice that will not be used and
            // then report it as a cache hit.
            if (indexEndsAt != null && !prefixWorthWarming(indexEndsAt!)) {
              ReelDiagnostics.instance.recordPrefixBailed('indexTooBig');
              d.cancelled = true;
              unawaited(d.subscription?.cancel());
              if (!done.isCompleted) done.complete();
              return;
            }
          }

          if (!openedEarly &&
              d.written >= prefixReadyBytesFor(d.url, indexEndsAt: indexEndsAt) &&
              probe.length >= mp4LayoutProbeBytes &&
              readMp4Layout(probe.toBytes()) != Mp4Layout.moovAtEnd) {
            openedEarly = true;
            // Flush first: the proxy reads the FILE, and bytes sitting in
            // this sink's buffer are not on it yet. Registering before that
            // would hand the player an empty file and it would go to origin
            // for everything, which is the cold open we are removing.
            // Hold the download still for the length of the flush.
            //
            // A sink cannot be written to while a flush on it is in flight —
            // Dart throws "StreamSink is bound to a stream" — and the next
            // chunk would arrive mid-flush and do exactly that. Pausing the
            // subscription stops chunks being delivered; they queue and
            // resume after. A flush of a few hundred kilobytes already
            // written is quick, and this happens once per reel.
            final sub = d.subscription;
            sub?.pause();
            final readyAt = d.written;
            unawaited(sink.flush().then((_) {
              // The reel may have left the window while the flush was in
              // flight. Registering it then would publish a slice we are
              // about to delete.
              if (d.cancelled) return;
              d.readyAt = readyAt;
              LocalMediaServer.instance.register(
                originUrl: d.url,
                prefixPath: prefixPath,
                prefixLength: readyAt,
                totalLength: total,
                tailPath: null,
              );
              _prefixed.add(d.url);
              _signalWarm(d.url);
            }).catchError((Object _) {
              // A flush that fails costs us the early open and nothing else
              // — the download carries on and registers normally when it
              // finishes.
            }).whenComplete(() => sub?.resume()));
          }
        },
        onDone: () => done.isCompleted ? null : done.complete(),
        onError: (Object e) => done.isCompleted ? null : done.completeError(e),
        cancelOnError: true,
      );
      await done.future;
      closeLane();
      await sink.flush();
      await sink.close();
      sink = null;

      // Nothing to record here any more. Throughput is measured across all
      // downloads at once by the link meter, which the chunk handler above
      // feeds — see the long note on NetworkQualityService's meter for why
      // timing one download at a time read a 12 Mbps link as 4.

      // ══════════════════════════════════════════════════════════════════
      // A CANCELLED DOWNLOAD USED TO DELETE WORK THAT WAS ALREADY WORKING
      // ══════════════════════════════════════════════════════════════════
      //
      // A slice is handed to the proxy the moment enough of it exists to
      // start a player — that is the early open above, and from then on the
      // reel opens from the device instead of the network. Then, if the
      // viewer scrolled past and the download was cancelled, THIS deleted
      // the file anyway. The registration survived and pointed at nothing.
      //
      // So the app did the work, banked it, announced it was warm, and then
      // threw it away. In one session 41 of 80 warms were cancelled, and
      // every one of them that had got this far was binned at the moment it
      // became useful.
      //
      // Scrolling fast is the normal way to use this app, not a mistake to
      // punish. Keep what arrived.
      if (d.cancelled && d.readyAt > 0) {
        // Nothing to re-register: the entry went in at the hand-over, and
        // the proxy measures the file itself rather than trusting the
        // length it was given — see LocalMediaServer's range handling and
        // the `usable` it computes there. So everything that landed
        // between the hand-over and the cancel is already being served.
        // Keeping the file IS the fix; there is no second step.
        ReelDiagnostics.instance.recordPrefixWarmed();
        unawaited(_enforceSizeCap());
        return true;
      }
      if (d.cancelled || d.written <= 0) {
        ReelDiagnostics.instance
            .recordPrefixBailed(d.cancelled ? 'cancelled' : 'empty');
        await _safeDelete(prefixPath);
        return false;
      }

      // An index at the end of the file makes the head ALONE pointless.
      // The player reads the warmed slice, finds no moov in it, and
      // range-requests the tail over the network before it can show a
      // single frame — and the reel is still counted as a proxy start, so
      // the summary reports it among the fast ones.
      //
      // This used to give up here and fall through to whole-file caching,
      // which is honest but expensive, and on a fast scroll it mostly did
      // not finish: a device profile bailed 23 of 38 warms this way and
      // converted only 5 of them into cached files, so two thirds of the
      // catalog was effectively uncached. The clips are what they are —
      // re-exporting them with the index at the front is a content fix we
      // do not control from here.
      //
      // So fetch the end of the file too. It is the one region the player
      // is guaranteed to want next, it is small, and with both ends
      // cached a moov-at-end reel starts exactly like a faststart one.
      // Only if THAT fails do we fall through to the whole file.
      final int prefixLength = d.written;
      String? tailPath;
      // `prefixLength < total` because a reel small enough to fit inside
      // the opening slice has already been fetched whole — its index came
      // with it, wherever in the file it sits, and asking for the end
      // again would re-fetch bytes we are holding.
      if (prefixLength < total &&
          readMp4Layout(probe.toBytes()) == Mp4Layout.moovAtEnd) {
        tailPath = await _fetchTail(d, total);
        if (tailPath == null) {
          ReelDiagnostics.instance
              .recordPrefixBailed(d.cancelled ? 'cancelled' : 'moovAtEnd');
          await _safeDelete(prefixPath);
          return false;
        }
      }

      LocalMediaServer.instance.register(
        originUrl: d.url,
        prefixPath: prefixPath,
        prefixLength: prefixLength,
        totalLength: total,
        tailPath: tailPath,
      );
      _prefixed.add(d.url);
      // Signal before the size sweep — a waiting spare should get its
      // proxy URL the instant the registration lands, not after disk
      // housekeeping.
      _signalWarm(d.url);
      ReelDiagnostics.instance.recordPrefixWarmed();
      if (tailPath != null) ReelDiagnostics.instance.recordTailWarmed();
      unawaited(_enforceSizeCap());
      return true;
    } catch (e) {
      ReelDiagnostics.instance.recordPrefixFailed();
      if (kDebugMode) debugPrint('prefix warm failed for ${d.url}: $e');
      await _safeDelete(prefixPath);
      return false;
    } finally {
      // Whatever happened — finished, threw, cancelled — this download has
      // stopped using the link and must say so exactly once.
      closeLane();
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
    }
  }

  /// Fetch the last [tailBytes] of [d]'s file, where a moov-at-end clip
  /// keeps its index. Returns the path on success, null on anything else.
  ///
  /// Null is never fatal — the caller falls through to the whole-file
  /// path, which is what the moov-at-end case did unconditionally before
  /// this existed.
  ///
  /// Runs on the same [_Download] as the head, so a reel that leaves the
  /// window mid-tail is cancelled by the same [_cancel] and gives its
  /// slot straight back. [_Download.written] is reset first so the cancel
  /// grace weighs this fetch's own progress rather than the head's.
  Future<String?> _fetchTail(_Download d, int total) async {
    // Never ask for bytes the head already holds: the two slices must not
    // overlap, or the proxy would serve the same region twice. The caller
    // has already excluded the case where the head covers everything.
    final headroom = total - prefixBytes;
    if (headroom <= 0) return null;
    final want = tailBytes < headroom ? tailBytes : headroom;
    final from = total - want;
    final tailPath = '${_fileFor(d.url)}.tail';
    IOSink? sink;
    d.written = 0;
    try {
      final request = http.Request('GET', Uri.parse(d.url))
        ..headers[HttpHeaders.rangeHeader] = 'bytes=$from-${total - 1}';
      // Bounded, because httpClient.send is the RAW client — the timeout the
      // API wrapper applies to its own calls is not on this path.
      final response = await ApiService.httpClient
          .send(request)
          .timeout(responseTimeout);
      // The head came back 206, so the origin does ranges; anything else
      // here is a transient we do not try to interpret.
      if (response.statusCode != HttpStatus.partialContent) return null;

      final file = File(tailPath);
      sink = file.openWrite();
      final done = Completer<void>();
      d.done = done;
      d.subscription = _bounded(response.stream).listen(
        (chunk) {
          d.written += chunk.length;
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

      // A partial tail is worse than none: the proxy derives the slice's
      // offset from its size on disk, so a truncated file would be served
      // as though it started later in the media than it does. Only a
      // complete one is registered.
      if (d.cancelled || d.written != want) {
        await _safeDelete(tailPath);
        return null;
      }
      return tailPath;
    } catch (e) {
      if (kDebugMode) debugPrint('tail warm failed for ${d.url}: $e');
      await _safeDelete(tailPath);
      return null;
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
      // Bounded, because httpClient.send is the RAW client — the timeout the
      // API wrapper applies to its own calls is not on this path.
      final response = await ApiService.httpClient
          .send(request)
          .timeout(responseTimeout);
      if (response.statusCode != 200) return;
      final declared = response.contentLength ?? 0;
      if (declared > maxPrefetchBytes) return;

      final part = File(partPath);
      sink = part.openWrite();
      final done = Completer<void>();
      d.done = done;

      d.subscription = _bounded(response.stream).listen(
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

    // Once a slice has been handed to the proxy its bytes are kept whether
    // this download finishes or not, so cancelling is free and gives the
    // slot straight to the next reel. Only work that is NOT yet usable is
    // worth protecting, and only when it is more than halfway there.
    if (d.isPrefix && d.readyAt == 0 && d.written >= d.spareAtBytes) {
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

  /// Delete the least recently used saved videos until the cache fits in
  /// [maxCacheBytes].
  ///
  /// THE LIMIT USED TO LEAVE OUT MOST OF WHAT IT WAS LIMITING
  ///
  /// The saved openings the proxy serves from (`.prefix`, `.tail`) were
  /// never deleted here, on the grounds that they were "bounded and tiny":
  /// three-quarters of a megabyte each, a handful at a time. That stopped
  /// being true when the proxy started keeping every byte it streams, so
  /// an opening now grows into the whole video once it is watched. In a
  /// session of eighty reels they were most of the folder, and the only
  /// part the limit could not touch. They were wiped at the next launch and
  /// nowhere before.
  ///
  /// Now a video's saved copy is one thing to delete, like a whole file,
  /// and the oldest go first. "Oldest" means least recently played or
  /// saved to — the proxy's [LocalMediaServer.lastServed], not just the
  /// file's age, because a reel looping on screen adds nothing to its file
  /// after the first pass and would otherwise look abandoned while it is
  /// being watched.
  ///
  /// Never deleted:
  ///   * a download still being written;
  ///   * a video the player is reading right now;
  ///   * the videos in the current warm window, which is where the viewer
  ///     is about to be.
  ///
  /// Deleting one that a player still holds is safe: the proxy keeps its
  /// address, finds the file gone, and streams from the internet (see
  /// [clear] for the same rule). It only costs data, which is why the
  /// three above are kept.
  Future<void> _enforceSizeCap() async {
    // It now also runs from the proxy while a video plays, so a surprise
    // here must be a log line, not an error thrown into playback.
    try {
      _sweep();
    } catch (e) {
      ReelDiagnostics.instance.log('cache sweep failed: $e');
    }
  }

  void _sweep() {
    final dir = _dir;
    if (dir == null) return;
    final List<File> all;
    try {
      all = dir.listSync().whereType<File>().toList();
    } on FileSystemException catch (e) {
      ReelDiagnostics.instance.log('cache sweep could not list the folder: $e');
      return;
    }
    int sizeOf(File f) {
      final n = f.statSync().size;
      return n < 0 ? 0 : n; // gone since the listing
    }

    var total = 0;
    for (final f in all) {
      total += sizeOf(f);
    }
    if (total <= maxCacheBytes) return;

    // Which reel each saved opening belongs to. Its file name is a hash of
    // the URL, so it has to be looked up from the URLs we know.
    final server = LocalMediaServer.instance;
    final urlByPath = <String, String>{};
    for (final url in {..._prefixed, ..._active.keys, ..._window}) {
      final base = _fileFor(url);
      urlByPath['$base.prefix'] = url;
      urlByPath['$base.tail'] = url;
    }
    bool keep(String? url) =>
        url != null &&
        (_active.containsKey(url) ||
            _window.contains(url) ||
            server.isServing(url));

    // One entry per thing that gets deleted together: a whole file, or a
    // reel's opening plus its end slice.
    final units = <String, _Evictable>{};
    for (final f in all) {
      final path = f.path;
      if (path.endsWith('.part')) continue; // a download mid-write
      final fragment = path.endsWith('.prefix') || path.endsWith('.tail');
      if (!fragment) {
        units[path] = _Evictable(url: null, lastUsed: f.statSync().accessed)
          ..files.add(f);
        continue;
      }
      final url = urlByPath[path];
      if (keep(url)) continue;
      var used = f.statSync().modified;
      final served = url == null ? null : server.lastServed(url);
      if (served != null && served.isAfter(used)) used = served;
      final unit =
          units.putIfAbsent(url ?? path, () => _Evictable(url: url, lastUsed: used));
      if (used.isAfter(unit.lastUsed)) unit.lastUsed = used;
      unit.files.add(f);
    }

    final order = units.values.toList()
      ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
    var stuck = 0;
    var evicted = 0;
    for (final u in order) {
      if (total <= maxCacheBytes) break;
      for (final f in u.files) {
        final size = sizeOf(f);
        try {
          f.deleteSync();
          total -= size;
        } on FileSystemException {
          stuck++;
        }
      }
      evicted++;
      final url = u.url;
      if (url != null) {
        // Forgotten here so the next warm saves it again and isReady stops
        // claiming it starts instantly. The proxy keeps the address.
        _prefixed.remove(url);
      } else {
        _ready.removeWhere((r) => _fileFor(r) == u.files.first.path);
      }
    }
    if (stuck > 0 || total > maxCacheBytes) {
      ReelDiagnostics.instance.log('cache sweep: removed $evicted, '
          '${(total / (1024 * 1024)).toStringAsFixed(0)} MB left'
          '${stuck > 0 ? ", $stuck files would not delete" : ""}'
          '${total > maxCacheBytes ? " — still over the limit, the rest is in use" : ""}');
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

  /// How much video the cache is holding on the phone right now, in bytes.
  ///
  /// Everything in the folder: whole videos, and the opening pieces the
  /// proxy serves from. Those pieces grow while a video is watched (the
  /// proxy keeps the bytes it streams), so during a long session they are
  /// most of the total, not a rounding error.
  Future<int> bytesOnDisk() async {
    final dir = _dir;
    if (dir == null) return 0;
    var total = 0;
    try {
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        try {
          total += f.lengthSync();
        } on FileSystemException {
          // Deleted between the listing and the size check — by the size
          // sweep, or by the app starting a new download over it. Gone
          // files take no space, so skipping it is the right answer.
        }
      }
    } on FileSystemException catch (e) {
      ReelDiagnostics.instance.log('cache size check failed: $e');
    }
    return total;
  }

  /// Empty the cache: every saved opening and every saved whole video.
  /// Called on logout and by the "Free up space" screen. Returns how many
  /// bytes it freed.
  ///
  /// The proxy is deliberately told nothing. A video on screen, or paused
  /// behind the settings page, is playing from a proxy address and will
  /// ask it for more bytes when it carries on. If the proxy had forgotten
  /// that address, the answer would be "not found" and the video would
  /// stop dead. Because it still knows it, it finds the file gone and
  /// fetches from the internet instead, exactly like a video that was
  /// never saved. LocalMediaServer's range handling says the same thing
  /// from the other side: a missing file is normal, a missing address is
  /// not.
  ///
  /// [_prefixed] IS forgotten, so the next swipe saves these videos
  /// again, and [isReady] stops claiming they start instantly.
  Future<int> clear() async {
    for (final url in _active.keys.toList()) {
      _cancel(url);
    }
    for (final url in [..._queue, ..._warmWaiters.keys]) {
      _signalWarm(url);
    }
    _queue.clear();
    _ready.clear();
    _prefixed.clear();
    final dir = _dir;
    if (dir == null) return 0;
    var freed = 0;
    var stuck = 0;
    try {
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        try {
          final size = f.lengthSync();
          f.deleteSync();
          freed += size;
        } on FileSystemException {
          stuck++;
        }
      }
    } on FileSystemException catch (e) {
      ReelDiagnostics.instance.log('cache clear could not list the folder: $e');
    }
    ReelDiagnostics.instance.log('cache cleared: freed '
        '${(freed / (1024 * 1024)).toStringAsFixed(1)} MB'
        '${stuck > 0 ? ", $stuck files would not delete" : ""}');
    return freed;
  }

  @visibleForTesting
  void debugSetDirectory(Directory dir) => _dir = dir;

  /// Where [url]'s saved files live, minus the `.prefix` / `.tail` ending.
  @visibleForTesting
  String debugFileFor(String url) => _fileFor(url);

  @visibleForTesting
  Set<String> get debugReady => _ready;

  /// Downloads still unwinding. [clear] cancels them but cannot wait for
  /// them, so a test that measures concurrency has to let the previous
  /// one's downloads drain or it measures the leftovers too.
  @visibleForTesting
  int get debugActive => _active.length;

  @visibleForTesting
  String get debugPipeline => _pipelineSnapshot();
}

/// Files the size sweep deletes together, and when they were last used.
class _Evictable {
  _Evictable({required this.url, required this.lastUsed});

  /// The reel a saved opening belongs to, or null for a whole file (and
  /// for an opening whose reel is no longer known).
  final String? url;
  DateTime lastUsed;
  final List<File> files = [];
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

  /// Bytes on disk when this slice was handed to the proxy, or 0 if that
  /// has not happened yet.
  ///
  /// Past zero the work is BANKED: the bytes stay on the device and the
  /// reel opens from them, whether this download finishes or is cancelled.
  /// That is what makes cancelling a banked download free — see
  /// [VideoCacheService._cancel].
  int readyAt = 0;

  /// How many bytes this particular file needs before a player can start
  /// on it — its index plus a couple of seconds of video. 0 until the
  /// index has been read.
  ///
  /// It is a per-file number, not a constant: the index sits in front of
  /// the video and grows with the running time, from about 12 KB on a
  /// ten-second clip to 192 KB on a three-minute one.
  int needBytes = 0;

  /// The point past which abandoning this download wastes more than it
  /// saves: half of what the file actually needs.
  ///
  /// This used to be a flat 384 KB for every file, which is a fixed byte
  /// count standing in for a question about a specific file — the same
  /// mistake, in the same service, that [prefixReadySeconds] was written
  /// to undo. Measured against this app's own catalog, 384 KB is 101% of
  /// what a ten-second 480p clip needs and 50% of what a 720p_hq one
  /// needs. So the rule spared one kind of file the moment it was usable
  /// and binned the other at 49% done, for no reason anybody chose.
  int get spareAtBytes => needBytes > 0
      ? needBytes ~/ 2
      : VideoCacheService.cancelGraceBytes;

  StreamSubscription<List<int>>? subscription;

  /// Completed when the body stream ends, errors, or is cancelled. The
  /// download's `await` on this is the only thing holding its slot, so
  /// every one of those three has to complete it — see
  /// [VideoCacheService._cancel].
  Completer<void>? done;
}
