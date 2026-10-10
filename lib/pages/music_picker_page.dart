import 'dart:async';

import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/music_track.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/music_library.dart';

/// A song chosen for a video: what it is, and the file on the phone once
/// it has downloaded.
///
/// The picker closes as soon as the server has kept the song, without
/// waiting for the song itself. It plays straight from the internet while
/// the whole file downloads behind the editor, and only Done waits for the
/// file, if it is not there yet. Waiting for the download first held the
/// person on the picker for 14 seconds on a slow connection.
///
/// The whole song is fetched, not only the part under the video, so that
/// moving the song to another part later never has to wait.
class PickedMusic {
  final MusicTrack track;
  Future<String> _file;
  String? _path;

  PickedMusic(this.track, Future<String> file) : _file = file {
    _follow(file);
  }

  void _follow(Future<String> file) {
    final clock = Stopwatch()..start();
    file.then(
      (p) {
        _path = p;
        debugPrint(
          '[music] the song ${track.id} is on the phone after '
          '${clock.elapsedMilliseconds}ms',
        );
      },
      onError: (Object e) => debugPrint(
        '[music] the song ${track.id} did not download behind the editor: $e',
      ),
    );
  }

  /// The song on the phone, once it is there.
  String? get path => _path;

  /// What to play now: the file once it is here, the song's address on the
  /// internet until then.
  String get playable => _path ?? track.audioUrl;

  /// The file, for saving. Waits for the download, and tries once more if
  /// it failed.
  Future<String> file() async {
    final here = _path;
    if (here != null) return here;
    try {
      return await _file;
    } catch (e) {
      debugPrint('[music] downloading the song again: $e');
      final again = MusicLibrary.instance.download(track);
      _file = again;
      _follow(again);
      return await again;
    }
  }
}

/// The video editor's Music button: search every free song, hear one, use
/// it.
///
/// "Free" is a licence that lets anybody put the song under their own
/// video, in an app that may make money, without paying — a few hundred
/// thousand songs from Jamendo, Freesound and Wikimedia Commons. Film songs
/// and chart hits are not among them: they belong to record labels.
///
/// Opens on the songs people here have used most, then every free song;
/// typing searches. Pops with a [PickedMusic], or nothing.
class MusicPickerPage extends StatefulWidget {
  const MusicPickerPage({super.key});

  @override
  State<MusicPickerPage> createState() => _MusicPickerPageState();
}

class _MusicPickerPageState extends State<MusicPickerPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final MusicPlayer _player = MusicPlayer.create();
  Timer? _typing;

  String _query = '';
  int _page = 0;
  bool _loading = false;
  bool _hasMore = true;
  bool _busy = false;
  bool _failed = false;
  List<MusicTrack> _popular = const [];
  final List<MusicTrack> _tracks = [];

  /// The song playing in the list, by its id at the source.
  String? _playing;

  /// The song being got ready to use.
  String? _picking;

  /// Which search the answers on screen belong to, so a slow answer to an
  /// old search never lands under a new one.
  int _searchNo = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _typing?.cancel();
    _search.dispose();
    _scroll.dispose();
    unawaited(_player.dispose());
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      unawaited(_load());
    }
  }

  void _onTyped(String text) {
    _typing?.cancel();
    // Searching on every key would spend the library's allowance on
    // half-typed words.
    _typing = Timer(const Duration(milliseconds: 450), () {
      final q = text.trim();
      if (q == _query) return;
      _query = q;
      unawaited(_load(reset: true));
    });
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _searchNo++;
      _page = 0;
      _hasMore = true;
      _tracks.clear();
      _popular = const [];
      _failed = false;
      _busy = false;
      _loading = false;
    }
    if (_loading || !_hasMore) return;
    final no = _searchNo;
    setState(() => _loading = true);
    try {
      final got = await MusicLibrary.instance.search(_query, page: _page + 1);
      if (!mounted || no != _searchNo) return;
      setState(() {
        _page++;
        if (_page == 1) _popular = got.popular;
        final seen = {for (final t in _tracks) t.sourceId};
        _tracks.addAll(got.tracks.where((t) => seen.add(t.sourceId)));
        _hasMore = got.hasMore;
        _busy = got.busy;
        _loading = false;
      });
    } catch (e) {
      debugPrint('[music] the list could not load: $e');
      if (!mounted || no != _searchNo) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  Future<void> _togglePlay(MusicTrack t) async {
    try {
      if (_playing == t.sourceId) {
        setState(() => _playing = null);
        await _player.pause();
        return;
      }
      setState(() => _playing = t.sourceId);
      await _player.play(t.audioUrl);
    } catch (e) {
      debugPrint('[music] could not play ${t.sourceId}: $e');
      if (mounted) {
        setState(() => _playing = null);
        _toast("Couldn't play that song.");
      }
    }
  }

  Future<void> _use(MusicTrack t) async {
    if (_picking != null) return;
    setState(() {
      _picking = t.sourceId;
      _playing = null;
    });
    unawaited(_player.stop());
    try {
      final kept = await MusicLibrary.instance.pick(t);
      // Not waited for: see PickedMusic.
      final picked = PickedMusic(kept, MusicLibrary.instance.download(kept));
      EventTracker.instance.track(
        eventType: 'music_picked',
        contentId: kept.id,
        contentType: 'music',
        metadata: {'query': _query, 'licence': kept.licence},
      );
      if (mounted) Navigator.of(context).pop(picked);
    } on ApiRefused catch (e) {
      if (mounted) _toast(e.reason);
    } catch (e) {
      debugPrint('[music] could not get ${t.sourceId} ready: $e');
      EventTracker.instance.trackError(
        surface: 'music_picker_page',
        errorType: 'music_pick_failed',
        message: '$e',
      );
      if (mounted) _toast("Couldn't get that song. Try again.");
    } finally {
      if (mounted) setState(() => _picking = null);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Add music'),
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const ValueKey('music_search'),
              controller: _search,
              onChanged: _onTyped,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Colors.white),
              cursorColor: AppTheme.primary,
              decoration: InputDecoration(
                hintText: 'Search free songs',
                hintStyle: const TextStyle(color: AppTheme.textMutedDark),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppTheme.textMutedDark,
                ),
                filled: true,
                fillColor: AppTheme.surfaceDark,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_busy)
            const _Notice(
              key: ValueKey('music_busy'),
              text:
                  'Music search is busy right now. Showing what it found '
                  'earlier — try again in a minute.',
            ),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _list() {
    final empty = _tracks.isEmpty && _popular.isEmpty;
    if (empty && _loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white54),
      );
    }
    if (empty && _failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Couldn't load music.",
              style: TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('music_retry'),
              onPressed: () => _load(reset: true),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (empty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _query.isEmpty
                ? 'No songs to show.'
                : 'No free songs found for "$_query". Try another word.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMutedDark),
          ),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      children: [
        if (_popular.isNotEmpty) ...[
          const _Header('Popular here'),
          for (final t in _popular) _tile(t),
          const _Header('All free songs'),
        ],
        for (final t in _tracks) _tile(t),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: CircularProgressIndicator(color: Colors.white38),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Text(
            'Free songs from Jamendo, Freesound and Wikimedia Commons, '
            'found with Openverse. The artist is credited on your post.',
            style: TextStyle(color: AppTheme.textMutedDark, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _tile(MusicTrack t) {
    final playing = _playing == t.sourceId;
    final picking = _picking == t.sourceId;
    final parts = [
      if (t.artist.isNotEmpty) t.artist,
      if (t.duration > Duration.zero) _clock(t.duration),
      t.licenceLabel,
    ];
    return ListTile(
      key: ValueKey('music_track_${t.sourceId}'),
      leading: IconButton(
        key: ValueKey('music_play_${t.sourceId}'),
        tooltip: playing ? 'Pause' : 'Play',
        icon: Icon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
          color: Colors.white,
          size: 34,
        ),
        onPressed: () => _togglePlay(t),
      ),
      title: Text(
        t.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 12),
      ),
      trailing: picking
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : FilledButton(
              key: ValueKey('music_use_${t.sourceId}'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: _picking == null ? () => _use(t) : null,
              child: const Text('Use'),
            ),
      onTap: () => _togglePlay(t),
    );
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  final String text;
  const _Notice({super.key, required this.text});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppTheme.surfaceDark,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      style: const TextStyle(color: AppTheme.textMutedDark, fontSize: 12),
    ),
  );
}
