import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/services/api_service.dart';

/// Your chats, kept between visits, so Messages opens on them at once.
///
/// The Messages tab is built fresh every time it is tapped, and it asked
/// the server for the list of chats every time — showing grey placeholder
/// rows until the answer came. Now the list lives here:
///
///   * it is written down on the phone, so even the first visit after the
///     app opens shows last time's chats on the first frame;
///   * a few seconds after the app opens, [prefetch] asks for a fresh list
///     quietly, so it is usually up to date by the time anyone looks;
///   * the page shows what is kept and swaps in the fresh list when it
///     arrives.
///
/// A conversation you have opened keeps its messages here too, in memory,
/// so opening it again shows them at once. Those are NOT fetched ahead of
/// time: fetching a chat's messages tells the other person you have read
/// them (GetMessagesHandler on the server), and a chat you never opened
/// must not say "Seen".
///
/// Signing out empties all of it, on the phone too.
class ChatCache {
  ChatCache._();
  static final ChatCache instance = ChatCache._();

  static const String _fileName = 'chat_list.json';

  /// Messages kept per chat: the newest screenful, which is what the chat
  /// opens on.
  static const int keptMessages = 50;

  /// Where the list is written down. A seam: tests point it at a folder.
  @visibleForTesting
  static Future<Directory> Function() directory =
      getApplicationSupportDirectory;

  String _owner = '';
  List<Map<String, dynamic>>? _chats;
  final Map<String, bool> _online = {};
  final Map<String, List<Map<String, dynamic>>> _messages = {};

  /// The chats to open Messages on for [userId], or null when there is
  /// nothing to show yet — the very first time, on a new phone.
  List<Map<String, dynamic>>? chatsFor(String userId) =>
      userId.isNotEmpty && userId == _owner ? _chats : null;

  /// Who was online the last time it was asked, by username.
  Map<String, bool> get online => _online;

  /// [userId]'s chats, as the server just sent them. Written down for the
  /// next time the app opens.
  void keepChats(String userId, List<Map<String, dynamic>> chats) {
    if (userId.isEmpty) return;
    _owner = userId;
    _chats = [for (final c in chats) Map<String, dynamic>.of(c)];
    debugLastSave = _save(userId, _chats!);
  }

  /// A chat was deleted on this phone: it goes from what is kept too.
  void forgetChat(String userId, String otherId) {
    final chats = chatsFor(userId);
    if (chats == null) return;
    keepChats(userId, [
      for (final c in chats)
        if ('${c['userId']}' != otherId) c,
    ]);
    _messages.remove(otherId);
  }

  /// The messages kept for the chat with [otherId], oldest first, or null.
  List<Map<String, dynamic>>? messagesWith(String otherId) =>
      _messages[otherId];

  /// The messages of the chat with [otherId], oldest first, as the chat
  /// shows them. Only the newest [keptMessages] are kept.
  void keepMessages(String otherId, List<Map<String, dynamic>> messages) {
    if (otherId.isEmpty) return;
    final from = messages.length > keptMessages
        ? messages.length - keptMessages
        : 0;
    _messages[otherId] = [
      for (final m in messages.sublist(from)) Map<String, dynamic>.of(m),
    ];
  }

  /// Ask the server for [userId]'s chats and keep them. Null when the
  /// request failed (ApiService says why); what was kept stays.
  Future<List<Map<String, dynamic>>?> load(String userId) async {
    final started = DateTime.now();
    final generation = _generation;
    final chats = await ApiService.fetchConversations(userId);
    if (chats == null) return null;
    debugPrint(
      '[chats] ${chats.length} chats from the server in '
      '${DateTime.now().difference(started).inMilliseconds}ms',
    );
    // Signed out while it was on its way: not theirs to keep.
    if (generation != _generation) return chats;
    keepChats(userId, chats);
    return chats;
  }

  /// Fetch a fresh list in the background, soon after the app opens.
  Future<void> prefetch(String userId) async {
    if (userId.isEmpty) return;
    await load(userId);
  }

  /// Counts sign-outs, so an answer still on its way when somebody signs
  /// out is not kept for the next person.
  int _generation = 0;

  /// Read what the last run wrote down. Started in main(), before the first
  /// frame.
  Future<void> restore() => _reading ??= _restore();
  Future<void>? _reading;

  Future<void> _restore() async {
    try {
      final file = File('${(await directory()).path}/$_fileName');
      if (!file.existsSync()) return;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return;
      final owner = '${data['owner'] ?? ''}';
      final chats = data['chats'];
      if (owner.isEmpty || chats is! List) return;
      // A fresher list already arrived while the file was being read.
      if (_chats != null) return;
      _owner = owner;
      _chats = [
        for (final c in chats)
          if (c is Map<String, dynamic>) c,
      ];
    } catch (e) {
      // Losing this costs one ordinary open, the way every open was before.
      debugPrint('[chats] could not read the kept chats: $e');
    }
  }

  Future<void> _save(String userId, List<Map<String, dynamic>> chats) async {
    try {
      final file = File('${(await directory()).path}/$_fileName');
      await file.writeAsString(json.encode({'owner': userId, 'chats': chats}));
    } catch (e) {
      debugPrint('[chats] could not keep the chats for next time: $e');
    }
  }

  /// Forget everything: a different person may sign in next. What was
  /// written down on the phone goes too.
  void clear() {
    _generation++;
    _owner = '';
    _chats = null;
    _online.clear();
    _messages.clear();
    unawaited(_forgetKept());
  }

  Future<void> _forgetKept() async {
    try {
      final file = File('${(await directory()).path}/$_fileName');
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('[chats] could not empty the kept chats: $e');
    }
  }

  /// The last write to the phone, so a test can wait for it.
  @visibleForTesting
  Future<void>? debugLastSave;

  /// Start a test from nothing, without touching the phone.
  @visibleForTesting
  void debugReset() {
    _generation++;
    _owner = '';
    _chats = null;
    _online.clear();
    _messages.clear();
    _reading = null;
    debugLastSave = null;
  }
}
