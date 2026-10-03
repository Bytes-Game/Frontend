import 'package:myapp/models/chat_preview.dart';

/// Represents a notification received via WebSocket or fetched from storage.
/// Also used for real-time chat messages (type == 'chat') and for
/// invisible prefetch hints (type == 'next_reel_hint').
class NotificationModel {
  final String type; // 'follow', 'like', 'challenge', 'chat', 'next_reel_hint', etc.
  final String message;
  final DateTime timestamp;

  // Chat-specific fields (only populated when type == 'chat')
  final String? senderId;
  final String? senderUsername;
  final String? receiverId;
  final String? receiverUsername;
  final String? messageId;

  /// Carried by `next_reel_hint` notifications — the URL of a reel the
  /// backend ranker thinks the user is likely to swipe to next. The
  /// WebSocket wrapper hands this to VideoPlayerService.prefetch() and
  /// suppresses surfacing the notification to the user.
  final String? videoUrl;

  // What the notifications page shows, from the server's list (or the same
  // shape live down the socket). Empty for chat and prefetch hints.

  /// The server's id for it: how a live one is recognised when the list is
  /// loaded again.
  final String id;

  /// The sentence without the name in front: "started following you." The
  /// page sets [actorUsername] in bold ahead of it.
  final String text;
  final bool read;
  final String actorId;
  final String actorUsername;
  final String actorLeague;
  final String challengeId;
  final String challengeTitle;
  final String thumbnailUrl;

  NotificationModel({
    required this.type,
    required this.message,
    required this.timestamp,
    this.senderId,
    this.senderUsername,
    this.receiverId,
    this.receiverUsername,
    this.messageId,
    this.videoUrl,
    this.id = '',
    this.text = '',
    this.read = false,
    this.actorId = '',
    this.actorUsername = '',
    this.actorLeague = '',
    this.challengeId = '',
    this.challengeTitle = '',
    this.thumbnailUrl = '',
  });

  /// The same notification, seen.
  NotificationModel asRead() => NotificationModel(
    type: type,
    message: message,
    timestamp: timestamp,
    senderId: senderId,
    senderUsername: senderUsername,
    receiverId: receiverId,
    receiverUsername: receiverUsername,
    messageId: messageId,
    videoUrl: videoUrl,
    id: id,
    text: text,
    read: true,
    actorId: actorId,
    actorUsername: actorUsername,
    actorLeague: actorLeague,
    challengeId: challengeId,
    challengeTitle: challengeTitle,
    thumbnailUrl: thumbnailUrl,
  );

  /// Parse from backend JSON sent over WebSocket.
  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      type: json['type'] ?? 'unknown',
      // A photo or voice message reads as one line ("📷 Photo", "🎤 Voice
      // message") wherever a notification's text is shown; a voice note
      // has no text of its own.
      message: json['type'] == 'chat' &&
              (json['kind'] == 'photo' || json['kind'] == 'voice')
          ? chatPreviewText(json)
          : json['message'] ?? 'No message content',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp']) ?? DateTime.now()
          : DateTime.now(),
      senderId: json['senderId'],
      senderUsername: json['senderUsername'],
      receiverId: json['receiverId'],
      receiverUsername: json['receiverUsername'],
      messageId: json['messageId'],
      videoUrl: json['videoUrl'],
      id: '${json['id'] ?? ''}',
      text: '${json['text'] ?? ''}',
      read: json['read'] == true,
      actorId: '${json['actorId'] ?? ''}',
      actorUsername: '${json['actorUsername'] ?? ''}',
      actorLeague: '${json['actorLeague'] ?? ''}',
      challengeId: '${json['challengeId'] ?? ''}',
      challengeTitle: '${json['challengeTitle'] ?? ''}',
      thumbnailUrl: '${json['thumbnailUrl'] ?? ''}',
    );
  }
}
