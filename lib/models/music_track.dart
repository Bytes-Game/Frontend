/// A free song from the music library (the video editor's Music button),
/// and the credit a post with one carries.
///
/// "Free" here means a licence that lets anybody put the song under their
/// own video, in an app that may make money, without paying: CC0, public
/// domain, or CC BY — free as long as the artist is credited. The server
/// only ever offers those (free_music.go).
library;

/// How a licence reads on screen.
String licenceName(String licence, String version) {
  switch (licence) {
    case 'cc0':
      return 'CC0 — free to use';
    case 'pdm':
      return 'Public domain';
    case 'by':
      return version.isEmpty ? 'CC BY' : 'CC BY $version';
  }
  return licence.toUpperCase();
}

/// What a post says about its song: enough to show "♪ title · artist" and,
/// tapped, the full credit the licence asks for.
class MusicCredit {
  final String id;
  final String title;
  final String artist;
  final String licence;
  final String licenceVersion;
  final String licenceUrl;

  /// The song's own page, where it came from.
  final String sourceUrl;

  /// The full credit line, as the licence asks for it.
  final String attribution;

  const MusicCredit({
    required this.id,
    required this.title,
    required this.artist,
    required this.licence,
    this.licenceVersion = '',
    this.licenceUrl = '',
    this.sourceUrl = '',
    this.attribution = '',
  });

  /// Null for a post with no song.
  static MusicCredit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = (raw['title'] ?? '').toString();
    if (title.isEmpty) return null;
    return MusicCredit(
      id: (raw['id'] ?? '').toString(),
      title: title,
      artist: (raw['artist'] ?? '').toString(),
      licence: (raw['license'] ?? '').toString(),
      licenceVersion: (raw['licenseVersion'] ?? '').toString(),
      licenceUrl: (raw['licenseUrl'] ?? '').toString(),
      sourceUrl: (raw['sourceUrl'] ?? '').toString(),
      attribution: (raw['attribution'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'license': licence,
    if (licenceVersion.isNotEmpty) 'licenseVersion': licenceVersion,
    if (licenceUrl.isNotEmpty) 'licenseUrl': licenceUrl,
    if (sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
    if (attribution.isNotEmpty) 'attribution': attribution,
  };

  /// "Title · Artist".
  String get line => artist.isEmpty ? title : '$title · $artist';

  String get licenceLabel => licenceName(licence, licenceVersion);
}

/// A song the picker can offer.
class MusicTrack {
  /// Our own id, once somebody here has picked it. Empty in search results
  /// for a song nobody has used yet.
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String artist;
  final Duration duration;

  /// The song itself, to play in the picker and mix into the video.
  final String audioUrl;
  final String licence;
  final String licenceVersion;
  final String licenceUrl;
  final String sourceUrl;

  /// Who hosts it: jamendo, freesound, wikimedia_audio.
  final String provider;
  final String attribution;
  final List<String> genres;

  const MusicTrack({
    this.id = '',
    this.source = 'openverse',
    required this.sourceId,
    required this.title,
    required this.artist,
    this.duration = Duration.zero,
    required this.audioUrl,
    required this.licence,
    this.licenceVersion = '',
    this.licenceUrl = '',
    this.sourceUrl = '',
    this.provider = '',
    this.attribution = '',
    this.genres = const [],
  });

  factory MusicTrack.fromJson(Map<String, dynamic> j) => MusicTrack(
    id: (j['id'] ?? '').toString(),
    source: (j['source'] ?? 'openverse').toString(),
    sourceId: (j['sourceId'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    artist: (j['artist'] ?? '').toString(),
    duration: Duration(milliseconds: (j['durationMs'] as num?)?.toInt() ?? 0),
    audioUrl: (j['audioUrl'] ?? '').toString(),
    licence: (j['license'] ?? '').toString(),
    licenceVersion: (j['licenseVersion'] ?? '').toString(),
    licenceUrl: (j['licenseUrl'] ?? '').toString(),
    sourceUrl: (j['sourceUrl'] ?? '').toString(),
    provider: (j['provider'] ?? '').toString(),
    attribution: (j['attribution'] ?? '').toString(),
    genres: [for (final g in (j['genres'] as List? ?? const [])) g.toString()],
  );

  /// The credit a post with this song carries.
  MusicCredit get credit => MusicCredit(
    id: id,
    title: title,
    artist: artist,
    licence: licence,
    licenceVersion: licenceVersion,
    licenceUrl: licenceUrl,
    sourceUrl: sourceUrl,
    attribution: attribution,
  );

  String get licenceLabel => licenceName(licence, licenceVersion);
}
