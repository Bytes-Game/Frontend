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
  });

  /// Parse from backend JSON sent over WebSocket.
  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    return NotificationModel(
      type: json['type'] ?? 'unknown',
      message: json['message'] ?? 'No message content',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp']) ?? DateTime.now()
          : DateTime.now(),
      senderId: json['senderId'],
      senderUsername: json['senderUsername'],
      receiverId: json['receiverId'],
      receiverUsername: json['receiverUsername'],
      messageId: json['messageId'],
      videoUrl: json['videoUrl'],
    );
  }
}
