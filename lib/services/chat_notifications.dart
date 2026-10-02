import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/session_store.dart';

/// Message notifications the app draws itself, on Android, with a Reply box
/// and a Mark as read button right in the notification.
///
/// Before, Android drew them: a title and one line, and a tap was the only
/// thing you could do. Now a new message shows like a chat — the sender's
/// name and picture, their last few messages under it — and you can answer
/// or clear it without opening the app.
///
/// How a message gets here: the server sends this phone the message as data
/// only (it does that only to phones whose app said it draws its own — see
/// PushService), Android wakes [chatPushArrived] even when the app is
/// closed, and that draws it. A Reply or Mark as read tap wakes
/// [chatNotificationAction], which signs in with the saved session and
/// tells the server — again without opening the app.
///
/// A push that arrives while the app is open is left alone, as before: the
/// message is already on screen, live.
///
/// iPhones keep the ordinary notification the server sends them; nothing
/// here runs there.
class ChatNotifications {
  ChatNotifications._();
  static final instance = ChatNotifications._();

  /// What draws on the phone. Swapped for a stand-in in tests.
  PhoneNotifier notifier = LocalPhoneNotifier();

  /// Where the last few lines of each chat are kept between pushes. The
  /// push that draws a notification runs separately from the app, so the
  /// lines live on disk, not in memory.
  Future<Directory> Function() directory = getApplicationSupportDirectory;

  /// The saved login, for answering from the notification with the app
  /// closed. Read fresh every time: the part of the app that answers can
  /// stay alive across a sign-out and a sign-in as somebody else.
  Future<StoredSession?> Function() session = SessionStore.loadFresh;

  /// Whether this phone draws its own (Android). Tests turn it on.
  bool supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// How many of a chat's messages a notification shows.
  static const keep = 6;

  final _taps = StreamController<Map<String, dynamic>>.broadcast();
  bool _started = false;

  /// A notification tapped while the app is running: what it is about.
  Stream<Map<String, dynamic>> get taps => _taps.stream;

  /// Whether the app on this phone draws message notifications itself. Told
  /// to the server with the phone's push address: only then does it send
  /// messages as data the app draws, instead of a notification Android
  /// draws on its own.
  bool get drawsOwn => supported && _started;

  /// In the app, after sign-in: ready to draw, and taps reported on [taps].
  Future<void> start() async {
    if (!supported || _started) return;
    _started = await notifier.start(onTap: (payload) {
      final data = _decode(payload);
      if (data != null) _taps.add(data);
    });
    if (!_started) {
      debugPrint('[push] could not set up message notifications with Reply; '
          'messages arrive as plain notifications instead');
    }
  }

  /// The notification that was tapped to start the app, if one was.
  Future<Map<String, dynamic>?> launchedFrom() async {
    if (!supported) return null;
    return _decode(await notifier.launchedFrom());
  }

  /// A push arrived with the app closed or in the background: draw it.
  Future<void> fromPush(Map<String, dynamic> data) async {
    if (!supported) return;
    final type = data['type'];
    final who = '${data['senderId'] ?? ''}';
    if (who.isEmpty || (type != 'chat' && type != 'missed_call')) return;
    final name = '${data['senderUsername'] ?? ''}'.isNotEmpty
        ? '${data['senderUsername']}'
        : '${data['title'] ?? 'Someone'}';
    final payload = {'type': type, 'senderId': who, 'senderUsername': name};
    if (type == 'missed_call') {
      await notifier.show(ChatNote(
        kind: NoteKind.missedCall,
        id: callNoteId,
        tag: 'call_$who',
        senderId: who,
        senderName: name,
        title: '${data['title'] ?? 'Missed call'}',
        body: '${data['body'] ?? '$name tried to call you'}',
        payload: payload,
      ));
      return;
    }
    final lines = await _remember(
      who,
      NoteLine('${data['body'] ?? ''}', DateTime.now(),
          id: '${data['messageId'] ?? ''}'),
    );
    await notifier.show(ChatNote(
      kind: NoteKind.chat,
      id: chatNoteId,
      tag: 'chat_$who',
      senderId: who,
      senderName: name,
      title: name,
      body: lines.last.text,
      lines: lines,
      payload: payload,
    ));
  }

  /// Reply or Mark as read was tapped on a notification.
  Future<void> answer(String? action, String? input, String? payload) async {
    final data = _decode(payload);
    final who = '${data?['senderId'] ?? ''}';
    if (data == null || who.isEmpty) return;
    final name = '${data['senderUsername'] ?? ''}';
    final me = await _signIn();
    if (me == null) {
      debugPrint('[push] answered a notification with nobody signed in; '
          'nothing was sent');
      return;
    }
    if (action == replyAction) {
      final text = (input ?? '').trim();
      if (text.isEmpty) return;
      final sent = await ApiService.sendChatMessage(
          senderId: me, receiverId: who, message: text);
      if (sent == null) {
        debugPrint('[push] a reply from the notification to $who did not '
            'send; telling the person');
        await notifier.show(ChatNote(
          kind: NoteKind.failed,
          id: chatNoteId,
          tag: 'chat_$who',
          senderId: who,
          senderName: name,
          title: "Couldn't send your reply",
          body: 'To $name: "$text". Tap to open the chat and try again.',
          payload: data,
        ));
        return;
      }
      // Answering means you read it.
      await ApiService.markChatRead(who, me);
      await forget(who);
      return;
    }
    if (action == readAction) {
      await ApiService.markChatRead(who, me);
      await forget(who);
    }
  }

  /// A chat was opened (or answered): its notifications go, and so do the
  /// lines kept for the next one.
  Future<void> forget(String otherUserId) async {
    if (!supported || otherUserId.isEmpty) return;
    await notifier.remove(chatNoteId, 'chat_$otherUserId');
    await notifier.remove(callNoteId, 'call_$otherUserId');
    await _edit((all) => all.remove(otherUserId));
  }

  /// At sign-out: every message notification goes, with what was kept.
  Future<void> clearAll() async {
    if (!supported) return;
    await notifier.removeAll();
    await _edit((all) => all.clear());
  }

  /// The signed-in person's id, and their token on every request — in a
  /// notification's answer the app may not be running, so nobody has set
  /// it yet.
  Future<String?> _signIn() async {
    final s = await session();
    if (s == null || s.isExpired) return null;
    final id = '${s.userJson['id'] ?? ''}';
    if (id.isEmpty) return null;
    ApiService.authToken = s.token;
    return id;
  }

  // ── The kept lines ──────────────────────────────────────────────────────

  /// The edit in progress, if one is. Null when idle, so nothing is left
  /// waiting on an edit from long ago.
  Future<void>? _busy;

  Future<File> _file() async =>
      File('${(await directory()).path}/chat_notifications.json');

  /// Adds [line] to [senderId]'s chat; the chat's last [keep] lines.
  Future<List<NoteLine>> _remember(String senderId, NoteLine line) async {
    var lines = <NoteLine>[line];
    await _edit((all) {
      final kept = [
        for (final l in (all[senderId] as List?) ?? const [])
          if (l is Map) NoteLine.fromJson(l.cast<String, dynamic>()),
      ];
      if (line.id.isNotEmpty && kept.any((l) => l.id == line.id)) {
        lines = kept; // the same message twice: drawn once
      } else {
        lines = [...kept, line];
      }
      if (lines.length > keep) lines = lines.sublist(lines.length - keep);
      all[senderId] = [for (final l in lines) l.toJson()];
    });
    return lines;
  }

  /// Read, change, write, one at a time.
  Future<void> _edit(void Function(Map<String, dynamic> all) change) async {
    while (_busy != null) {
      await _busy;
    }
    final done = Completer<void>();
    _busy = done.future;
    try {
      final f = await _file();
      var all = <String, dynamic>{};
      if (await f.exists()) {
        try {
          final raw = json.decode(await f.readAsString());
          if (raw is Map<String, dynamic>) all = raw;
        } catch (e) {
          debugPrint('[push] the kept chat lines were unreadable ($e); '
              'starting again');
        }
      }
      change(all);
      await f.writeAsString(json.encode(all));
    } catch (e) {
      debugPrint('[push] could not keep the chat lines ($e); the '
          'notification shows only the newest message');
    } finally {
      _busy = null;
      done.complete();
    }
  }

  static Map<String, dynamic>? _decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final d = json.decode(payload);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      debugPrint('[push] a notification carried an unreadable payload');
      return null;
    }
  }

  @visibleForTesting
  void debugReset() {
    notifier = LocalPhoneNotifier();
    directory = getApplicationSupportDirectory;
    session = SessionStore.loadFresh;
    supported = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    _started = false;
    _busy = null;
  }

  /// Android tells a notification apart by its number AND its tag; the tag
  /// is the chat ("chat_9"), so each chat has one notification of each kind.
  static const chatNoteId = 1;
  static const callNoteId = 2;

  static const replyAction = 'reply';
  static const readAction = 'read';
}

enum NoteKind { chat, missedCall, failed }

/// One line of a chat in a notification.
class NoteLine {
  final String text;
  final DateTime at;

  /// The message's id, so the same message twice shows once.
  final String id;
  const NoteLine(this.text, this.at, {this.id = ''});

  factory NoteLine.fromJson(Map<String, dynamic> j) => NoteLine(
        '${j['t'] ?? ''}',
        DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        id: '${j['id'] ?? ''}',
      );

  Map<String, dynamic> toJson() =>
      {'t': text, 'at': at.millisecondsSinceEpoch, 'id': id};
}

/// What one notification says, before it is turned into Android's terms.
class ChatNote {
  final NoteKind kind;
  final int id;
  final String tag;
  final String senderId;
  final String senderName;
  final String title;
  final String body;
  final List<NoteLine> lines;

  /// Handed back when it is tapped: which chat to open.
  final Map<String, dynamic> payload;

  const ChatNote({
    required this.kind,
    required this.id,
    required this.tag,
    required this.senderId,
    required this.senderName,
    required this.title,
    required this.body,
    this.lines = const [],
    required this.payload,
  });

  /// How it looks on Android: a conversation (the sender's name, their
  /// picture — Android draws their first letter in a coloured circle — and
  /// their last few messages), in Battle Arena blue, on the Messages
  /// channel that pops up and makes a sound, with Reply and Mark as read.
  AndroidNotificationDetails get android {
    final sender = Person(name: senderName, key: senderId, important: true);
    final actions = <AndroidNotificationAction>[
      if (kind != NoteKind.failed)
        AndroidNotificationAction(
          ChatNotifications.replyAction,
          kind == NoteKind.missedCall ? 'Message' : 'Reply',
          inputs: [
            AndroidNotificationActionInput(label: 'Message $senderName'),
          ],
          semanticAction: SemanticAction.reply,
          allowGeneratedReplies: true,
          // Gone the moment you press send; if the reply does not go, a
          // notification says so.
          cancelNotification: true,
        ),
      if (kind == NoteKind.chat)
        const AndroidNotificationAction(
          ChatNotifications.readAction,
          'Mark as read',
          semanticAction: SemanticAction.markAsRead,
          cancelNotification: true,
        ),
    ];
    return AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'New messages and missed calls',
      importance: Importance.high,
      priority: Priority.high,
      icon: 'ic_notification',
      color: AppTheme.primary,
      category: kind == NoteKind.missedCall
          ? AndroidNotificationCategory.missedCall
          : AndroidNotificationCategory.message,
      tag: tag,
      when: (lines.isNotEmpty ? lines.last.at : DateTime.now())
          .millisecondsSinceEpoch,
      styleInformation: kind == NoteKind.chat
          ? MessagingStyleInformation(
              const Person(name: 'You', key: 'me'),
              groupConversation: false,
              messages: [
                for (final l in lines) Message(l.text, l.at, sender),
              ],
            )
          : BigTextStyleInformation(body),
      actions: actions,
    );
  }
}

/// What draws on the phone, as [ChatNotifications] needs it.
abstract class PhoneNotifier {
  /// Gets ready, in the app. [onTap] gets the payload of a notification
  /// tapped while the app runs. False when it could not.
  Future<bool> start({required void Function(String? payload) onTap});

  /// The payload of the notification that started the app, if one did.
  Future<String?> launchedFrom();

  Future<void> show(ChatNote note);
  Future<void> remove(int id, String tag);
  Future<void> removeAll();
}

/// Android's notifications, through flutter_local_notifications.
class LocalPhoneNotifier implements PhoneNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _ready;

  /// Set up once in each place it runs — the app, the push that arrived
  /// with the app closed, an answer from a notification.
  Future<bool> _setUp({void Function(String? payload)? onTap}) {
    return _ready ??= () async {
      try {
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('ic_notification'),
          ),
          onDidReceiveNotificationResponse: (r) {
            if (r.notificationResponseType ==
                NotificationResponseType.selectedNotification) {
              onTap?.call(r.payload);
            }
          },
          onDidReceiveBackgroundNotificationResponse: chatNotificationAction,
        );
        return true;
      } catch (e) {
        debugPrint('[push] notifications would not start: $e');
        return false;
      }
    }();
  }

  @override
  Future<bool> start({required void Function(String? payload) onTap}) =>
      _setUp(onTap: onTap);

  @override
  Future<String?> launchedFrom() async {
    try {
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d == null || !d.didNotificationLaunchApp) return null;
      return d.notificationResponse?.payload;
    } catch (e) {
      debugPrint('[push] could not read the notification that opened the '
          'app: $e');
      return null;
    }
  }

  @override
  Future<void> show(ChatNote note) async {
    if (!await _setUp()) return;
    try {
      await _plugin.show(
        id: note.id,
        title: note.title,
        body: note.body,
        notificationDetails: NotificationDetails(android: note.android),
        payload: json.encode(note.payload),
      );
    } catch (e) {
      debugPrint('[push] could not show a message notification: $e');
    }
  }

  @override
  Future<void> remove(int id, String tag) async {
    try {
      await _plugin.cancel(id: id, tag: tag);
    } catch (e) {
      debugPrint('[push] could not take a message notification away: $e');
    }
  }

  @override
  Future<void> removeAll() async {
    try {
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('[push] could not take the message notifications away: $e');
    }
  }
}

/// A push arrived with the app closed or in the background. Android runs
/// this on its own, outside the app.
@pragma('vm:entry-point')
Future<void> chatPushArrived(RemoteMessage message) async {
  DartPluginRegistrant.ensureInitialized();
  await ChatNotifications.instance.fromPush(message.data);
}

/// Reply or Mark as read was tapped. Android runs this on its own too,
/// whether or not the app is open.
@pragma('vm:entry-point')
void chatNotificationAction(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  // ignore: discarded_futures
  ChatNotifications.instance
      .answer(response.actionId, response.input, response.payload);
}
