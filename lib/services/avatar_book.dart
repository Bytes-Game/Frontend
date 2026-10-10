import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';

/// Everybody's profile photo, by username.
///
/// A person appears in about thirty places — chats, comments, search, the
/// reel, the lists of who liked and who voted — and nearly all of them know
/// only a username. Rather than every one of those carrying a photo, they
/// all ask here ([photoOf]), and the book answers with what it knows and
/// asks the server, many names at once, for the ones it does not.
///
/// What it learns is kept on the phone, so the next app open shows the
/// photos straight away; an answer older than [fresh] is asked again in
/// the background, which is how somebody's new photo reaches everyone
/// else. Your own photo is learned the moment you change it (see
/// DataProvider.setUser), so it changes everywhere at once.
///
/// It asks nothing until [start] — the app calls it as it opens. Before
/// that it still answers with what it was told ([learn]).
class AvatarBook {
  AvatarBook._();
  static final AvatarBook instance = AvatarBook._();

  /// What asks the server. A seam: tests answer for it.
  @visibleForTesting
  static Future<Map<String, String>?> Function(List<String> names) ask =
      ApiService.getAvatars;

  /// Where the book is kept. A seam, like the other stores'.
  @visibleForTesting
  static Future<Directory> Function() directory = getApplicationSupportDirectory;

  /// The time. A seam: tests move it on rather than wait six hours.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static const _fileName = 'avatar_book.json';

  /// How long an answer is trusted before it is asked again.
  static const fresh = Duration(hours: 6);

  /// How soon a server that could not be reached is asked again.
  static const retry = Duration(minutes: 1);

  /// How long names are gathered before one question goes. Long enough for
  /// a screenful of avatars to ask together, short enough not to be seen.
  static const gather = Duration(milliseconds: 60);

  /// The most names in one question; the server takes no more.
  static const perQuestion = 100;

  /// The most people kept on the phone. The least recently answered go
  /// first.
  static const keep = 2000;

  final Map<String, ValueNotifier<String>> _photos = {};
  final Map<String, DateTime> _answeredAt = {};
  final Set<String> _wanted = {};
  Timer? _gathering;
  Timer? _saving;
  bool _started = false;
  bool _asking = false;

  /// [name]'s photo address as it is known now, and as it changes: "" for
  /// no photo, or not known yet. Asks the server when it has no recent
  /// answer.
  ValueListenable<String> photoOf(String name) {
    final photo = _photos.putIfAbsent(name, () => ValueNotifier(''));
    if (name.isNotEmpty && _stale(name)) _want(name);
    return photo;
  }

  /// [name]'s photo, from an answer that carried it — a profile, a list of
  /// who liked. "" means they have none.
  void learn(String name, String url) {
    if (name.isEmpty) return;
    _photos.putIfAbsent(name, () => ValueNotifier('')).value = url;
    _answeredAt[name] = now();
    _wanted.remove(name);
    _saveSoon();
  }

  /// [user]'s photo, from their profile.
  void learnUser(UserModel? user) {
    if (user != null) learn(user.username, user.avatarUrl);
  }

  /// Start asking the server, after reading what was kept from last time.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _load();
    if (_wanted.isNotEmpty) _gathering ??= Timer(gather, _askNow);
  }

  bool _stale(String name) {
    final at = _answeredAt[name];
    return at == null || now().difference(at) > fresh;
  }

  void _want(String name) {
    _wanted.add(name);
    if (_started && !_asking) _gathering ??= Timer(gather, _askNow);
  }

  Future<void> _askNow() async {
    _gathering = null;
    if (_wanted.isEmpty || _asking) return;
    final names = _wanted.take(perQuestion).toList();
    _wanted.removeAll(names);
    _asking = true;
    final Map<String, String>? got;
    try {
      got = await ask(names);
    } finally {
      _asking = false;
    }
    final at = now();
    if (got == null) {
      // Not reachable just now: try these again in a minute rather than on
      // every redraw, and rather than not for six hours.
      for (final n in names) {
        _answeredAt[n] = at.subtract(fresh).add(retry);
      }
      debugPrint('[avatars] the server could not say ${names.length} '
          'people\'s photos; asking again in ${retry.inSeconds}s');
    } else {
      for (final n in names) {
        _photos.putIfAbsent(n, () => ValueNotifier('')).value = got[n] ?? '';
        _answeredAt[n] = at;
      }
      _saveSoon();
    }
    if (_wanted.isNotEmpty) _gathering ??= Timer(gather, _askNow);
  }

  // ── Kept on the phone ─────────────────────────────────────────────────

  Future<File?> _file() async {
    try {
      final dir = await directory();
      return File('${dir.path}/$_fileName');
    } catch (e) {
      debugPrint('[avatars] nowhere to keep photos on this phone: $e');
      return null;
    }
  }

  Future<void> _load() async {
    final f = await _file();
    if (f == null || !f.existsSync()) return;
    try {
      final j = json.decode(await f.readAsString());
      final photos = j is Map ? j['photos'] : null;
      if (photos is! Map) return;
      for (final e in photos.entries) {
        final v = e.value;
        if (v is! List || v.length != 2) continue;
        final name = '${e.key}';
        // What arrived while this was reading is newer: keep it.
        if (_answeredAt.containsKey(name)) continue;
        _photos.putIfAbsent(name, () => ValueNotifier('')).value = '${v[0]}';
        _answeredAt[name] =
            DateTime.fromMillisecondsSinceEpoch((v[1] as num).toInt());
      }
    } catch (e) {
      debugPrint('[avatars] the kept photos could not be read: $e');
    }
  }

  void _saveSoon() {
    if (!_started) return;
    _saving?.cancel();
    _saving = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    final f = await _file();
    if (f == null) return;
    final names = _answeredAt.keys.toList()
      ..sort((a, b) => _answeredAt[b]!.compareTo(_answeredAt[a]!));
    final photos = {
      for (final n in names.take(keep))
        n: [_photos[n]?.value ?? '', _answeredAt[n]!.millisecondsSinceEpoch],
    };
    try {
      await f.writeAsString(json.encode({'v': 1, 'photos': photos}),
          flush: true);
    } catch (e) {
      debugPrint('[avatars] the photos could not be kept: $e');
    }
  }

  /// For tests: forget everything, and stop asking.
  @visibleForTesting
  void debugReset() {
    _gathering?.cancel();
    _saving?.cancel();
    _gathering = null;
    _saving = null;
    _photos.clear();
    _answeredAt.clear();
    _wanted.clear();
    _started = false;
    _asking = false;
  }
}
