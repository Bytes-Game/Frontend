/// A chat message as one line: a reply's quote, the chat list, a
/// notification. A photo reads "📷 Photo" (or "📷" and its caption), a
/// voice note "🎤 Voice message", a shared video "🎬 Shared a video" (or its
/// note) — the same words the server uses.
String chatPreviewText(Map<String, dynamic> m) {
  final text = '${m['message'] ?? ''}';
  switch (m['kind']) {
    case 'photo':
      return text.trim().isEmpty ? '📷 Photo' : '📷 $text';
    case 'voice':
      return '🎤 Voice message';
    case 'share':
      return text.trim().isEmpty ? '🎬 Shared a video' : '🎬 $text';
  }
  return text;
}
