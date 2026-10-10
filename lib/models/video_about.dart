/// What a video is about, as the server's model wrote it while it looked at
/// the video (see video_about.go on the server).
class VideoAbout {
  /// A sentence or two; empty when the model could not tell, or the video
  /// was looked at before it was asked to write one.
  final String about;

  /// The model's own short words for the video, for when there is no
  /// sentence.
  final List<String> topics;

  /// What the model went on: "said" (the words in the video), "shown" (its
  /// pictures), or "" when no model looked at it.
  final String from;

  /// Whether anything has looked at the video yet. False for one uploaded
  /// moments ago.
  final bool looked;

  const VideoAbout({
    this.about = '',
    this.topics = const [],
    this.from = '',
    this.looked = false,
  });

  factory VideoAbout.fromJson(Map<String, dynamic> j) => VideoAbout(
    about: '${j['about'] ?? ''}'.trim(),
    topics: [
      for (final t in (j['topics'] as List? ?? const []))
        if ('$t'.trim().isNotEmpty) '$t'.trim(),
    ],
    from: '${j['from'] ?? ''}',
    looked: j['looked'] == true,
  );
}
