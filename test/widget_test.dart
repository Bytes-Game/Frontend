// Hermetic unit tests for pure logic — no platform channels, no network.
// (The default counter test this file shipped with referenced a widget
// that never existed in this app and failed on any run.)

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/session_store.dart';

void main() {
  group('ChallengeModel.fromJson', () {
    test('parses battle payload including opponent HLS manifest', () {
      final c = ChallengeModel.fromJson({
        'id': '42',
        'creatorId': '7',
        'creatorUsername': 'alice',
        'creatorLeague': 'Gold',
        'videoUrl': 'https://cdn/x.mp4',
        'hlsManifestUrl': 'https://cdn/x/master.m3u8',
        'prefix': 'I bet you can\'t',
        'subject': 'do a backflip',
        'visibility': 'arena',
        'status': 'open',
        'likes': 3,
        'views': 100,
        'createdAt': '2026-07-01T00:00:00Z',
        'responseCount': 1,
        'topResponseId': '9',
        'topResponseVideoUrl': 'https://cdn/y.mp4',
        'topResponseHlsManifestUrl': 'https://cdn/y/master.m3u8',
      });
      expect(c.id, '42');
      expect(c.title, "I bet you can't do a backflip");
      expect(c.hlsManifestUrl, 'https://cdn/x/master.m3u8');
      expect(c.topResponseHlsManifestUrl, 'https://cdn/y/master.m3u8');
      expect(c.responseCount, 1);
    });

    test('absent optional fields default safely', () {
      final c = ChallengeModel.fromJson({
        'id': '1',
        'creatorId': '2',
        'videoUrl': 'u',
      });
      expect(c.hlsManifestUrl, '');
      expect(c.topResponseHlsManifestUrl, '');
      expect(c.creatorLeague, 'Unranked');
      expect(c.emotionTags, isEmpty);
    });
  });

  group('EventTracker.makeConversationId', () {
    test('is symmetric — both participants compute the same id', () {
      expect(
        EventTracker.makeConversationId('7', '3'),
        EventTracker.makeConversationId('3', '7'),
      );
      expect(EventTracker.makeConversationId('3', '7'), 'conv_3_7');
    });
  });

  group('StoredSession.shouldRefresh', () {
    test('fresh token does not refresh, old token does', () {
      final fresh = StoredSession(
        token: 't',
        userJson: const {},
        issuedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      final old = StoredSession(
        token: 't',
        userJson: const {},
        issuedAt: DateTime.now().subtract(const Duration(days: 4)),
      );
      expect(fresh.shouldRefresh, isFalse);
      expect(old.shouldRefresh, isTrue);
    });
  });
}
