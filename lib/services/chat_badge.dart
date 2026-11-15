import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:myapp/services/api_service.dart';

/// The number on the Messages button: how many PEOPLE have sent you
/// messages you have not read yet, not how many messages. A muted chat is
/// not counted: muting it means you do not want to be told.
///
/// It comes from the server (GET /chat/unread), and from the chat list
/// whenever that loads, since the list says the same thing chat by chat.
/// It is asked again:
///   * when the app opens and when it comes back to the front;
///   * a moment after a message arrives live (one ask for a burst), unless
///     it is from a muted chat (the server says which);
///   * once a chat's messages are marked read, and when the chat closes.
///
/// Signing out sets it to nothing.
class ChatBadge {
  ChatBadge._();
  static final ChatBadge instance = ChatBadge._();

  /// The number shown. 0: no badge.
  final ValueNotifier<int> people = ValueNotifier<int>(0);

  Timer? _soon;

  /// The chat on screen right now, by the other person's id. Its messages
  /// are marked read as they arrive, so it is never counted.
  String? _open;

  /// A chat opened on screen.
  void chatOpened(String otherId) => _open = otherId;

  /// The chat on screen closed: everything in it was read. Asked again.
  void chatClosed(String otherId) {
    if (_open == otherId) _open = null;
    unawaited(refresh());
  }

  /// Counts sign-outs, so an answer still on its way is not shown to the
  /// next person.
  int _generation = 0;

  /// Ask the server for the number. When the request fails the number on
  /// screen stays as it was (ApiService says why in the log).
  Future<void> refresh() async {
    _soon?.cancel();
    final generation = _generation;
    final n = await ApiService.unreadChatPeople();
    if (n == null || generation != _generation) return;
    people.value = n;
  }

  /// Ask the server in a moment: several reasons in a row (a burst of
  /// messages) make one request.
  void refreshSoon([Duration wait = const Duration(milliseconds: 500)]) {
    _soon?.cancel();
    _soon = Timer(wait, () => unawaited(refresh()));
  }

  /// The number from a chat list just read: the chats with something
  /// unread that are not muted.
  void fromChats(List<Map<String, dynamic>> chats) {
    people.value = chats
        .where(
          (c) =>
              ((c['unreadCount'] as num?)?.toInt() ?? 0) > 0 &&
              c['muted'] != true &&
              '${c['userId']}' != _open,
        )
        .length;
  }

  /// Something arrived on the live connection. A message to [myId] that is
  /// not from a muted chat may change the number.
  void onLive(Map<String, dynamic> ev, String myId) {
    if (ev['type'] != 'chat') return;
    final from = '${ev['senderId']}';
    if (from == myId) return; // one of your own, elsewhere
    if (ev['muted'] == true) return; // a muted chat is not counted
    if (from == _open) return; // on screen: read as it arrives
    refreshSoon();
  }

  /// Signed out: nothing to show, and nothing still on its way is shown.
  void clear() {
    _generation++;
    _soon?.cancel();
    _open = null;
    people.value = 0;
  }
}
