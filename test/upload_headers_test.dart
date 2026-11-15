// What an uploaded file says about how long a copy of it may be kept.
//
// The file itself carries the line, and storage hands it out with every
// copy. A phone may keep the file for a year. Cloudflare, which stands
// between storage and the phones, may keep its copy for two hours: a video
// that has been deleted must stop opening.
//
// Every test here sends a real upload through one of the app's three
// upload paths, with only the network faked, and reads the line off the
// request storage would get. None of them compares with the app's own
// constant: a test that did would still pass if the constant were wrong.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/media_upload_service.dart';
import 'package:myapp/services/stored_file_headers.dart';
import 'package:myapp/services/video_processor_service.dart';

/// The line every upload must carry, written out here on purpose.
const expected = 'public, max-age=31536000, s-maxage=7200, immutable';

/// Every request that reached storage.
final List<http.Request> stored = [];

http.Response _json(Object body) => http.Response.bytes(
  utf8.encode(json.encode(body)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// The server and storage, faked: the server hands out a place for each
/// file, and storage takes whatever is put there.
http.Client fakeNetwork() => MockClient((req) async {
  if (req.url.host == 'storage.test') {
    stored.add(req);
    return http.Response('', 200);
  }
  final path = req.url.path;
  if (path == '/api/v1/chat/media') {
    final kind = json.decode(req.body)['kind'];
    return _json({
      'uploadUrl': 'https://storage.test/put/chat-$kind',
      'publicUrl': 'https://cdn.test/chat/1/abcdefgh/$kind',
      'contentType': kind == 'photo' ? 'image/jpeg' : 'audio/mp4',
    });
  }
  if (path == '/api/v1/media/presign') {
    final items = (json.decode(req.body)['items'] as List)
        .cast<Map<String, dynamic>>();
    return _json({
      'uploadId': 'up1',
      'items': [
        for (final i in items)
          {
            'kind': i['kind'],
            'variant': i['variant'],
            'uploadUrl':
                'https://storage.test/put/${i['kind']}-${i['variant']}',
            'publicUrl': 'https://cdn.test/u/1/up1/${i['variant']}',
          },
      ],
    });
  }
  return _json({});
});

void main() {
  late Directory dir;

  File file(String name) =>
      File('${dir.path}/$name')..writeAsBytesSync(List.filled(64, 7));

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    stored.clear();
    dir = Directory.systemTemp.createTempSync('upload_headers');
    ApiService.useClient(fakeNetwork());
    MediaUploadService.storageClient = fakeNetwork;
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    MediaUploadService.storageClient = http.Client.new;
    dir.deleteSync(recursive: true);
  });

  test('the line itself: a year on a phone, two hours at Cloudflare', () {
    expect(uploadCacheControl, expected);
    // The two hours are what makes a deleted video stop opening. Without
    // them Cloudflare keeps its copy for the year the phone is given.
    expect(uploadCacheControl, contains('s-maxage=7200'));
    expect(uploadCacheControl, contains('max-age=31536000'));
    expect(uploadCacheControl, contains('public'));
    expect(uploadCacheControl, contains('immutable'));
  });

  test('a video and its picture carry it', () async {
    final result = await MediaUploadService.instance.upload(
      userId: '1',
      processed: ProcessedVideo(
        variants: [
          for (final label in ['480p', '720p'])
            VideoVariantFile(
              label: label,
              path: file('$label.mp4').path,
              sizeBytes: 64,
            ),
        ],
        thumbnailPath: file('thumb.jpg').path,
        thumbnailSizeBytes: 64,
        sourceDuration: const Duration(seconds: 5),
        uploadedDuration: const Duration(seconds: 5),
      ),
    );
    expect(result, isNotNull, reason: 'the upload itself did not go');
    expect([for (final r in stored) r.url.path]..sort(), [
      '/put/thumbnail-default',
      '/put/video-480p',
      '/put/video-720p',
    ]);
    for (final r in stored) {
      expect(r.method, 'PUT');
      expect(r.headers['Cache-Control'], expected, reason: r.url.path);
    }
  });

  test('a photo post carries it', () async {
    final result = await MediaUploadService.instance.uploadPhoto(
      userId: '1',
      photo: file('photo.jpg'),
    );
    expect(result, isNotNull, reason: 'the upload itself did not go');
    expect(stored, hasLength(1));
    expect(stored.single.url.path, '/put/photo-default');
    expect(stored.single.headers['Cache-Control'], expected);
  });

  test('a chat photo and a voice message carry it', () async {
    for (final kind in ['photo', 'voice']) {
      stored.clear();
      final address = await ChatMedia.instance.upload(file(kind), kind);
      expect(address, isNotNull, reason: 'the $kind did not go');
      expect(stored, hasLength(1));
      expect(stored.single.url.path, '/put/chat-$kind');
      expect(stored.single.headers['Cache-Control'], expected, reason: kind);
    }
  });

  test('no upload in the app writes the line by hand', () {
    // A fourth upload path added one day should use the shared line too.
    // Comments are left out: several explain the old one-year line.
    final byHand = <String>[];
    for (final f
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('stored_file_headers.dart')) continue;
      final code = f
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      if (RegExp(r'''max-age=\d''').hasMatch(code)) byHand.add(f.path);
    }
    expect(byHand, isEmpty);
  });
}
