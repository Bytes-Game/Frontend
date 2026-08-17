// Puts extra videos into the feed so the reels player can be tested against
// a catalogue bigger than the handful we have now.
//
// WHY THIS EXISTS
//
// The last profile run scrolled through only 14 distinct videos. That is too
// small to trust: with a pool of four players and a catalogue of fourteen, a
// user scrolling for a minute keeps landing on videos that are still warm, so
// the numbers look better than they would in the real world. To find out what
// the player pool and the decoder budget actually do, the feed needs more
// videos than a session can exhaust.
//
// WHAT IT DOES
//
// For each video it is asked to add:
//   1. asks the backend for a signed upload link  (POST /api/v1/media/presign)
//   2. PUTs the file straight to R2 using that link
//   3. creates a feed item pointing at it         (POST /api/v1/challenges)
//
// This is exactly the path the phone app uses when someone posts a video, so
// what lands in the bucket looks like real content, not a special test case.
// The backend never sees the bytes; it only hands out the upload link.
//
// It writes down every item it creates, so `--cleanup` can delete them all
// again. Nothing else in the app is touched.
//
// USAGE (run from the project folder)
//
//   dart run tools/seed_feed.dart --user NAME --password PASS --count 40
//       Shows a plan and stops. Nothing is uploaded.
//
//   dart run tools/seed_feed.dart --user NAME --password PASS --count 40 --yes
//       Actually does it.
//
//   ... --battles 12
//       Also turns 12 of the new items into battles (two videos, the case
//       that makes the app flip between two players at once).
//
//   ... --source urls --urls-file clips.txt
//       Uploads from your own list of video links, one per line, instead of
//       reusing what is already in the feed.
//
//   dart run tools/seed_feed.dart --user NAME --password PASS --cleanup --yes
//       Deletes everything this script created, newest first.
//
// The password can also come from the BYTES_PASSWORD environment variable so
// it does not end up in your shell history. Nothing is ever written to disk
// except the list of created item IDs.

import 'dart:convert';
import 'dart:io';

/// Which backend to talk to. Overridable with --api-base so this can be
/// pointed at a staging server, or at a stub while testing the script itself.
var _apiBase = 'https://gobackend-9nd8.onrender.com';

/// Where we remember what we created, so `--cleanup` can undo it.
const _ledgerPath = 'tools/seeded_challenges.json';

/// Render's free tier sleeps after ~15 minutes idle and holds the first
/// request while it wakes up, which can take a minute. Every call gets a
/// generous ceiling so a cold start is a slow success, not a failure.
const _timeout = Duration(seconds: 90);

/// A single video we are going to upload, already in memory.
class _Clip {
  _Clip(this.name, this.bytes);
  final String name;
  final List<int> bytes;
}

Future<int> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args.error != null) {
    stderr.writeln('${args.error}\n');
    stderr.writeln(_usage);
    return 2;
  }
  if (args.apiBase != null) _apiBase = args.apiBase!;
  stdout.writeln('Backend: $_apiBase');

  final http = _makeClient();
  try {
    final session = await _login(http, args.user, args.password);
    if (session == null) {
      stderr.writeln(
          'Could not sign in. Check the username and password, and that the '
          'backend is awake (the first request after a quiet spell can take '
          'a minute).');
      return 1;
    }
    stdout.writeln('Signed in as ${args.user} (id ${session.userId}).');

    // A battle needs someone to answer the challenge. Most backends refuse to
    // let you answer your own, so a second account is worth having. Without
    // one we still try with the same account and say plainly if it is turned
    // down, rather than failing the whole run.
    if (args.responderUser != null && args.responderPassword != null) {
      final other =
          await _login(http, args.responderUser!, args.responderPassword!);
      if (other == null) {
        stderr.writeln('Could not sign in as ${args.responderUser} — '
            'battles will be attempted as ${args.user} instead.');
      } else {
        session.responderId = other.userId;
        session.responderToken = other.token;
        stdout.writeln('Battles will be answered by ${args.responderUser} '
            '(id ${other.userId}).');
      }
    }

    if (args.cleanup) {
      return await _runCleanup(http, session, args);
    }
    return await _runSeed(http, session, args);
  } finally {
    http.close(force: true);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Adding videos
// ─────────────────────────────────────────────────────────────────────────

Future<int> _runSeed(HttpClient http, _Session session, _Args args) async {
  // Step 1: work out what we are going to upload.
  final clips = args.source == 'urls'
      ? await _clipsFromUrlFile(http, args.urlsFile!)
      : await _clipsFromExistingFeed(http, session);

  if (clips.isEmpty) {
    stderr.writeln(
        'No source videos to upload. '
        '${args.source == 'urls' ? 'The list file was empty or nothing downloaded.' : 'The feed came back with no videos to copy — try --source urls with your own list.'}');
    return 1;
  }

  final totalMb =
      clips.fold<int>(0, (sum, c) => sum + c.bytes.length) / (1024 * 1024);
  stdout.writeln('\nPlan');
  stdout.writeln('  source videos : ${clips.length} '
      '(${totalMb.toStringAsFixed(1)} MB held in memory)');
  stdout.writeln('  new feed items: ${args.count}');
  stdout.writeln('  of those, battles: ${args.battles}');
  stdout.writeln('  uploading to  : R2, via $_apiBase');
  final uploadMb = totalMb / clips.length * args.count;
  stdout.writeln(
      '  rough upload  : ${uploadMb.toStringAsFixed(1)} MB total');

  if (!args.yes) {
    stdout.writeln('\nNothing was uploaded. Re-run with --yes to go ahead.');
    return 0;
  }

  // Step 2: upload, one item at a time. Serial on purpose — this runs once
  // in a while on a desktop, and a steady pace is easier to read and easier
  // on a backend that is sharing one free-tier instance with the app.
  final created = <Map<String, dynamic>>[];

  /// Files that reached the bucket but that no feed item points at. Reported
  /// at the end so they can be deleted by hand — the upload link the backend
  /// hands out is write-only, so this script cannot remove them itself.
  final orphaned = <String>[];
  var consecutiveFailures = 0;

  for (var i = 0; i < args.count; i++) {
    final clip = clips[i % clips.length];
    final label = 'seed ${i + 1}/${args.count}';
    stdout.write('  $label  ${clip.name} ... ');

    final url = await _uploadOne(http, session, clip);
    if (url == null) {
      stdout.writeln('upload failed — ${_lastError ?? 'unknown reason'}');
      continue;
    }

    final id = await _createChallenge(http, session, url, i);
    if (id == null) {
      final why = _lastError;
      stdout.writeln('uploaded, but the feed item was refused — '
          '${why ?? 'unknown reason'}');

      // The file is in the bucket and nothing points at it. Write it down:
      // an upload nobody can reach is invisible otherwise, and it still
      // costs storage.
      orphaned.add(url);

      if (why != null && why.isRateLimit) {
        stdout.writeln('\nThe backend is rate limiting new posts, so every '
            'further attempt would upload a file and then be turned down '
            'the same way. Stopping here rather than filling the bucket '
            'with videos nothing links to.');
        break;
      }
      // Something other than a rate limit. Give it a few tries in case it is
      // a blip, then stop for the same reason.
      if (++consecutiveFailures >= 3) {
        stdout.writeln('\nThree refusals in a row. Stopping rather than '
            'uploading more files nothing will point at.');
        break;
      }
      continue;
    }
    consecutiveFailures = 0;
    created.add({'id': id, 'videoUrl': url});
    stdout.writeln('ok');

    // Save after every item. If this run dies halfway, cleanup still knows
    // about everything it managed to create.
    await _writeLedger(created);
  }

  // Step 3: turn some of them into battles, so the flip case is covered.
  var battlesMade = 0;
  final responder = session.responder;
  for (var i = 0; i < args.battles && i < created.length; i++) {
    final clip = clips[(i + 1) % clips.length];
    stdout.write('  battle ${i + 1}/${args.battles} ... ');
    // Uploaded as the responder, because the storage key is built from the
    // uploader's ID and the answer belongs to them.
    final url = await _uploadOne(http, responder, clip);
    if (url == null) {
      stdout.writeln('upload failed, skipping');
      continue;
    }
    final ok = await _acceptChallenge(
        http, responder, created[i]['id'] as String, url);
    stdout.writeln(ok
        ? 'ok'
        : 'rejected — the backend may not let you answer your own challenge; '
            'pass --responder-user/--responder-password for a second account');
    if (ok) battlesMade++;
  }

  stdout.writeln('\nDone. ${created.length} new feed items, '
      '$battlesMade of them battles.');
  if (created.isNotEmpty) {
    stdout.writeln('Written to $_ledgerPath — '
        'run with --cleanup --yes to remove them again.');
  }
  if (orphaned.isNotEmpty) {
    stdout.writeln('\n${orphaned.length} file(s) reached the bucket but have '
        'no feed item pointing at them. Nothing in the app will ever load '
        'them, but they still take up space, so delete them from R2 by hand:');
    for (final url in orphaned) {
      stdout.writeln('  $url');
    }
  }
  return created.isEmpty && orphaned.isNotEmpty ? 1 : 0;
}

/// Signed link, then PUT the bytes to R2. Returns the public URL.
Future<String?> _uploadOne(
    HttpClient http, _Session session, _Clip clip) async {
  final presign = await _postJson(http, '/api/v1/media/presign', session, {
    'userId': session.userId,
    'items': [
      {'kind': 'video', 'variant': '720p', 'contentType': 'video/mp4'},
    ],
  });
  if (presign == null) return null;

  final items = (presign['items'] as List?) ?? const [];
  if (items.isEmpty) return null;
  final item = items.first as Map<String, dynamic>;
  final uploadUrl = item['uploadUrl'] as String?;
  final publicUrl = item['publicUrl'] as String?;
  if (uploadUrl == null || publicUrl == null) return null;

  try {
    final req = await http.putUrl(Uri.parse(uploadUrl));
    req.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    req.headers.set(HttpHeaders.contentLengthHeader, clip.bytes.length);
    req.add(clip.bytes);
    final res = await req.close().timeout(_timeout);
    await res.drain<void>();
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
  } catch (_) {
    return null;
  }
  return publicUrl;
}

Future<String?> _createChallenge(
    HttpClient http, _Session session, String videoUrl, int index) async {
  const prefixes = [
    'Who is better at',
    'Who is the best at',
    'Who has the cleanest',
    'Who can pull off',
    'Who would win at',
  ];
  const subjects = [
    'a cold start', 'the second lap', 'holding a note', 'a slow pan',
    'the last five seconds', 'a quiet entrance', 'the wide shot',
    'a one-take run', 'the handoff', 'a soft landing',
  ];
  const categories = [
    'comedy', 'motivation', 'sports', 'dance', 'music',
    'gaming', 'art', 'education', 'story', 'other',
  ];

  final body = await _postJson(http, '/api/v1/challenges', session, {
    'creatorId': session.userId,
    'videoUrl': videoUrl,
    'videoVariants': {'720p': videoUrl},
    'thumbnailUrl': '',
    'prefix': prefixes[index % prefixes.length],
    // The number keeps every title distinct, which matters because the feed
    // de-duplicates and we are deliberately reusing the same few videos.
    'subject': '${subjects[index % subjects.length]} #${index + 1}',
    'visibility': 'arena',
    'visibleTo': <String>[],
    'category': categories[index % categories.length],
    'emotionTags': <String>[],
  });
  if (body == null) return null;
  final id = body['id'] ?? (body['challenge'] as Map?)?['id'];
  return id is String && id.isNotEmpty ? id : null;
}

Future<bool> _acceptChallenge(HttpClient http, _Session responder,
    String challengeId, String videoUrl) async {
  final body = await _postJson(http, '/api/v1/challenges/accept', responder, {
    'challengeId': challengeId,
    'responderId': responder.userId,
    'videoUrl': videoUrl,
    'videoVariants': {'720p': videoUrl},
    'thumbnailUrl': '',
  });
  return body != null;
}

// ─────────────────────────────────────────────────────────────────────────
// Where the videos come from
// ─────────────────────────────────────────────────────────────────────────

/// Default source: download what the feed already serves and re-post it under
/// new IDs.
///
/// This is deliberately boring. The videos are already yours, already the
/// right shape, already sitting in your bucket, and already representative of
/// the decoding load real content puts on the phone. Copying them sidesteps
/// every question about someone else's licence, and a copy is a genuinely new
/// video as far as the player pool and the download cache are concerned —
/// different URL, different cache key, different feed item.
Future<List<_Clip>> _clipsFromExistingFeed(
    HttpClient http, _Session session) async {
  stdout.writeln('Reading the videos already in your feed ...');
  final urls = <String>{};
  for (var page = 1; page <= 10; page++) {
    final body = await _getJson(http,
        '/api/v1/feed/recommended?userId=${session.userId}&page=$page&limit=20',
        session);
    if (body == null) break;
    _collectVideoUrls(body, urls);
    if (body['hasMore'] != true) break;
  }
  stdout.writeln('  found ${urls.length} distinct videos.');
  return _download(http, urls.toList());
}

Future<List<_Clip>> _clipsFromUrlFile(HttpClient http, String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('No such file: $path');
    return const [];
  }
  // A "#" starts a comment, whether it opens the line or trails a link, so
  // the list can carry notes about sizes and licences next to each URL.
  final urls = file
      .readAsLinesSync()
      .map((l) => l.split('#').first.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  stdout.writeln('Reading ${urls.length} links from $path ...');
  return _download(http, urls);
}

Future<List<_Clip>> _download(HttpClient http, List<String> urls) async {
  final out = <_Clip>[];
  for (final url in urls) {
    try {
      final req = await http.getUrl(Uri.parse(url));
      final res = await req.close().timeout(_timeout);
      if (res.statusCode != 200) {
        stdout.writeln('  skipped (HTTP ${res.statusCode}): $url');
        await res.drain<void>();
        continue;
      }
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      final name = Uri.parse(url).pathSegments.isEmpty
          ? 'clip'
          : Uri.parse(url).pathSegments.last;
      out.add(_Clip(name, bytes));
      stdout.writeln(
          '  got ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB  $name');
    } catch (e) {
      stdout.writeln('  skipped (could not download): $url');
    }
  }
  return out;
}

/// Walks a decoded JSON tree and picks up every `videoUrl` it finds, at any
/// depth. Written this way so it keeps working if the feed wraps challenges
/// in a different envelope, or nests opponent videos under responses.
void _collectVideoUrls(Object? node, Set<String> into) {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key == 'videoUrl' &&
          entry.value is String &&
          (entry.value as String).startsWith('http')) {
        into.add(entry.value as String);
      } else {
        _collectVideoUrls(entry.value, into);
      }
    }
  } else if (node is List) {
    for (final child in node) {
      _collectVideoUrls(child, into);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Undo
// ─────────────────────────────────────────────────────────────────────────

Future<int> _runCleanup(
    HttpClient http, _Session session, _Args args) async {
  final file = File(_ledgerPath);
  if (!file.existsSync()) {
    stdout.writeln('Nothing to clean up — $_ledgerPath does not exist.');
    return 0;
  }
  final rows = (json.decode(file.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  stdout.writeln('${rows.length} items were created by this script.');
  if (!args.yes) {
    stdout.writeln('Nothing deleted. Re-run with --yes to go ahead.');
    return 0;
  }

  // Newest first, so a run that is interrupted leaves the oldest items — the
  // ones most likely to have been shared or linked — for last.
  var deleted = 0;
  for (final row in rows.reversed) {
    final id = row['id'] as String;
    final ok = await _postJson(http, '/api/v1/challenges/delete', session, {
          'challengeId': id,
          'userId': session.userId,
        }) !=
        null;
    stdout.writeln('  $id  ${ok ? 'deleted' : 'FAILED'}');
    if (ok) deleted++;
  }
  if (deleted == rows.length) {
    file.deleteSync();
    stdout.writeln('\nAll $deleted removed. $_ledgerPath deleted.');
  } else {
    stdout.writeln('\n$deleted of ${rows.length} removed. '
        '$_ledgerPath kept so you can retry the rest.');
  }
  return deleted == rows.length ? 0 : 1;
}

Future<void> _writeLedger(List<Map<String, dynamic>> rows) async {
  final file = File(_ledgerPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(const JsonEncoder.withIndent('  ').convert(rows));
}

// ─────────────────────────────────────────────────────────────────────────
// Small HTTP helpers
// ─────────────────────────────────────────────────────────────────────────

/// Builds the HTTP client.
///
/// Two things here are only for people behind a company proxy, and do nothing
/// at all for everyone else:
///
///   * Dart ignores the http_proxy / https_proxy environment variables unless
///     you ask it to read them. Every other tool on the machine honours them,
///     so a laptop that can reach the internet everywhere else would fail here
///     for no visible reason.
///   * A proxy that inspects HTTPS presents its own certificate, which Dart
///     will refuse unless it is told to trust it. SSL_CERT_FILE is the usual
///     place that certificate lives.
///
/// Note what is NOT here: any option to skip certificate checking. If the
/// certificate cannot be verified the upload fails, loudly.
HttpClient _makeClient() {
  final caFile = _env('SSL_CERT_FILE');
  SecurityContext? context;
  if (caFile != null && caFile.isNotEmpty && File(caFile).existsSync()) {
    context = SecurityContext(withTrustedRoots: true)
      ..setTrustedCertificates(caFile);
    stdout.writeln('Trusting extra certificates from $caFile');
  }
  final client = HttpClient(context: context)..connectionTimeout = _timeout;
  client.findProxy = HttpClient.findProxyFromEnvironment;
  return client;
}

class _Session {
  _Session(this.token, this.userId);
  final String token;
  final String userId;

  /// The second account used to answer battles, when one was given.
  String? responderId;
  String? responderToken;

  /// The identity a battle answer should be sent as: the second account if
  /// we have one, otherwise us.
  _Session get responder => responderId == null
      ? this
      : (_Session(responderToken!, responderId!)..responderId = responderId);
}

Future<_Session?> _login(
    HttpClient http, String user, String password) async {
  stdout.writeln('Signing in (this can take a minute if the backend is '
      'asleep) ...');
  final body = await _postJson(http, '/login', null, {
    'username': user,
    'password': password,
  });
  if (body == null) return null;
  final token = body['token'] as String?;
  final id = (body['user'] as Map?)?['id'];
  if (token == null || id is! String) return null;
  return _Session(token, id);
}

Future<Map<String, dynamic>?> _getJson(
    HttpClient http, String path, _Session? session) async {
  try {
    final req = await http.getUrl(Uri.parse('$_apiBase$path'));
    if (session != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${session.token}');
    }
    final res = await req.close().timeout(_timeout);
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final decoded = json.decode(text);
    return decoded is Map<String, dynamic> ? decoded : {'items': decoded};
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _postJson(HttpClient http, String path,
    _Session? session, Map<String, dynamic> payload) async {
  try {
    final req = await http.postUrl(Uri.parse('$_apiBase$path'));
    req.headers.contentType = ContentType.json;
    if (session != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${session.token}');
    }
    req.write(json.encode(payload));
    final res = await req.close().timeout(_timeout);
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      // Remember why, so the caller can say something useful. The first
      // version of this script threw the status away and reported every
      // refusal as "failed", which hid a plain 429 behind a shrug and cost
      // a pile of uploads before anyone knew what was wrong.
      _lastError = _HttpError(res.statusCode, text.trim());
      return null;
    }
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = json.decode(text);
    return decoded is Map<String, dynamic> ? decoded : {'value': decoded};
  } catch (e) {
    _lastError = _HttpError(0, '$e');
    return null;
  }
}

/// Why the most recent request failed. Read straight after a call returns
/// null, before anything else runs.
_HttpError? _lastError;

class _HttpError {
  _HttpError(this.status, this.body);

  /// The HTTP status, or 0 if the request never got an answer at all.
  final int status;
  final String body;

  /// True when the server is telling us to slow down or stop for now.
  bool get isRateLimit => status == 429;

  @override
  String toString() {
    if (status == 0) return 'no answer from the server ($body)';
    final short = body.length > 160 ? '${body.substring(0, 160)}...' : body;
    return 'HTTP $status${short.isEmpty ? '' : ' — $short'}';
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Arguments
// ─────────────────────────────────────────────────────────────────────────

const _usage = '''
Add videos to the feed so the reels player can be tested on a bigger catalogue.

  --user NAME              account to post as (required)
  --password PASS          its password, or set BYTES_PASSWORD (required)
  --count N                how many feed items to add (default 40)
  --battles N              how many of them to turn into battles (default 0)
  --source clone|urls      clone: reuse videos already in your feed (default)
                           urls:  upload from --urls-file
  --urls-file PATH         one video link per line, # for comments
  --responder-user NAME    second account, used to answer battles
  --responder-password P   its password
  --cleanup                delete everything this script created
  --api-base URL           talk to a different backend (staging, or a stub)
  --yes                    actually do it (without this you only see a plan)

Examples
  dart run tools/seed_feed.dart --user me --password pw --count 60 --battles 15
  dart run tools/seed_feed.dart --user me --password pw --cleanup --yes
''';

class _Args {
  String user = '';
  String password = '';
  int count = 40;
  int battles = 0;
  String source = 'clone';
  String? urlsFile;
  String? responderUser;
  String? responderPassword;
  bool cleanup = false;
  bool yes = false;
  String? apiBase;
  String? error;

  static _Args parse(List<String> argv) {
    final a = _Args();
    String? next(int i) => i + 1 < argv.length ? argv[i + 1] : null;
    for (var i = 0; i < argv.length; i++) {
      switch (argv[i]) {
        case '--user':
          a.user = next(i) ?? '';
          i++;
        case '--password':
          a.password = next(i) ?? '';
          i++;
        case '--count':
          a.count = int.tryParse(next(i) ?? '') ?? a.count;
          i++;
        case '--battles':
          a.battles = int.tryParse(next(i) ?? '') ?? a.battles;
          i++;
        case '--source':
          a.source = next(i) ?? 'clone';
          i++;
        case '--urls-file':
          a.urlsFile = next(i);
          i++;
        case '--responder-user':
          a.responderUser = next(i);
          i++;
        case '--responder-password':
          a.responderPassword = next(i);
          i++;
        case '--api-base':
          a.apiBase = next(i);
          i++;
        case '--cleanup':
          a.cleanup = true;
        case '--yes':
          a.yes = true;
        case '-h':
        case '--help':
          a.error = 'Usage:';
        default:
          a.error = 'Unknown option: ${argv[i]}';
      }
    }
    a.password =
        a.password.isNotEmpty ? a.password : (_env('BYTES_PASSWORD') ?? '');
    if (a.error != null) return a;
    if (a.user.isEmpty || a.password.isEmpty) {
      a.error = 'Both --user and a password are required '
          '(--password, or set BYTES_PASSWORD).';
    }
    if (a.source == 'urls' && a.urlsFile == null) {
      a.error = '--source urls also needs --urls-file PATH.';
    }
    if (a.source != 'urls' && a.source != 'clone') {
      a.error = '--source must be "clone" or "urls".';
    }
    if (a.count < 1 && !a.cleanup) {
      a.error = '--count must be at least 1.';
    }
    return a;
  }
}

String? _env(String name) => Platform.environment[name];
