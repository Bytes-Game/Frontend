// Battles: which side a view, like, share or vote was for.
//
// A battle reel is one card with two videos. The server can only split the
// card's views, likes and shares fairly if the app says which side was on
// screen. These tests pin the three pieces of that:
//
//   1. BattleFaceClock times each side correctly.
//   2. The API calls send what the server reads (battles.go in the backend).
//   3. The reel actually uses them — checked on the source with comments
//      stripped, because the reel's state is private and a test that only
//      called the clock by hand would pass with the reel never calling it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/models/battle_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/battle_face_clock.dart';

void main() {
  final t0 = DateTime(2026, 9, 26, 12);
  DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

  group('BattleFaceClock', () {
    test('a battle opens on the creator', () {
      final c = BattleFaceClock();
      expect(c.showingOpponent, isFalse);
      final t = c.timesSince(t0, at(3000));
      expect(t.creatorMs, 3000);
      expect(t.opponentMs, 0);
    });

    test('each flip moves the time to the other side', () {
      final c = BattleFaceClock()
        ..turn(opponent: true, at: at(1000))
        ..turn(opponent: false, at: at(4000))
        ..turn(opponent: true, at: at(5000));
      final t = c.timesSince(t0, at(7000));
      // creator 0-1s and 4-5s; answer 1-4s and 5-7s.
      expect(t.creatorMs, 2000);
      expect(t.opponentMs, 5000);
      expect(c.showingOpponent, isTrue);
    });

    test('the next view starts clean, on the side still showing', () {
      final c = BattleFaceClock()..turn(opponent: true, at: at(1000));
      c.timesSince(t0, at(2000));
      final next = c.timesSince(at(2000), at(5000));
      expect(next.creatorMs, 0, reason: 'the answer was still on screen');
      expect(next.opponentMs, 3000);
    });

    test('turning to the side already showing changes nothing', () {
      final c = BattleFaceClock()
        ..turn(opponent: false, at: at(1000))
        ..turn(opponent: true, at: at(2000))
        ..turn(opponent: true, at: at(3000));
      final t = c.timesSince(t0, at(4000));
      expect(t.creatorMs, 2000);
      expect(t.opponentMs, 2000);
    });

    test('details carry the names the server reads', () {
      final c = BattleFaceClock()..turn(opponent: true, at: at(2500));
      final view = c.viewDetails(responseId: '12', since: t0, now: at(6000));
      expect(view, {'responseId': '12', 'creatorMs': 2500, 'opponentMs': 3500});
      expect(c.sideDetails(responseId: '12'), {
        'side': 'opponent',
        'responseId': '12',
      });
    });
  });

  group('API calls send what the server reads', () {
    late List<http.Request> sent;
    late http.Response Function(http.Request) answer;

    setUp(() {
      sent = [];
      answer = (_) => http.Response('{}', 200);
      ApiService.useClient(
        MockClient((req) async {
          sent.add(req);
          return answer(req);
        }),
      );
    });
    tearDown(() => ApiService.useClient(http.Client()));

    test('a vote for the creator goes up as side: creator', () async {
      // The dialogs name the creator's side by the challenge's own id.
      final res = await ApiService.voteChallenge(
        challengeId: '7',
        responseId: '7',
        voterId: 'u',
      );
      expect(res.ok, isTrue);
      final body = json.decode(sent.single.body) as Map<String, dynamic>;
      expect(body['side'], 'creator');
      expect(
        body['responseId'],
        '',
        reason: 'the challenge id is not an answer and must not be sent as one',
      );
    });

    test('a vote for the answer names the answer and no side', () async {
      await ApiService.voteChallenge(
        challengeId: '7',
        responseId: '12',
        voterId: 'u',
      );
      final body = json.decode(sent.single.body) as Map<String, dynamic>;
      expect(body['responseId'], '12');
      expect(body.containsKey('side'), isFalse);
    });

    test('a refused vote says why', () async {
      answer = (_) =>
          http.Response("You can't vote in your own battle.\n", 403);
      final res = await ApiService.voteChallenge(
        challengeId: '7',
        responseId: '12',
        voterId: 'u',
      );
      expect(res.ok, isFalse);
      expect(res.message, "You can't vote in your own battle.");
    });

    test('liking an answer uses the answer endpoint', () async {
      answer = (_) => http.Response('{"liked": true, "likes": 3}', 200);
      final res = await ApiService.likeResponse(responseId: '12');
      expect(sent.single.url.path, '/api/v1/challenges/responses/like');
      expect(json.decode(sent.single.body), {'responseId': '12'});
      expect(res?['likes'], 3);
    });

    test('making a battle longer sends the days', () async {
      await ApiService.extendBattle(challengeId: '7', days: 14);
      expect(sent.single.url.path, '/api/v1/challenges/7/battle-length');
      expect(json.decode(sent.single.body), {'days': 14});
    });
  });

  group('the server\'s battle JSON', () {
    // Field names exactly as the Go structs tag them (battles.go,
    // battles_http.go). A mismatch here reads as zeroes, not as an error.
    test('standings', () {
      final s = BattleStandings.fromJson({
        'challengeId': '7',
        'status': 'active',
        'battleDays': 14,
        'acceptedAt': '2026-09-20T10:00:00Z',
        'endsAt': '2099-10-04T10:00:00Z',
        'resolved': false,
        'participants': [
          {
            'userId': '1',
            'username': 'maya',
            'role': 'creator',
            'responseId': '',
            'votes': 4.5,
            'rawVotes': 6,
            'removedVotes': 1,
            'likes': 9,
            'views': 30,
            'shares': 2,
            'rank': 1,
            'leading': true,
          },
          {
            'userId': '2',
            'username': 'leo',
            'role': 'responder',
            'responseId': '12',
            'votes': 3,
            'rawVotes': 3,
            'removedVotes': 0,
            'likes': 4,
            'views': 21,
            'shares': 1,
            'rank': 2,
            'leading': false,
          },
        ],
        'removed': {'voted without watching': 1},
      });
      expect(s.sides, hasLength(2));
      expect(s.creator?.votes, 4.5);
      expect(s.creator?.leading, isTrue);
      expect(s.sides[1].responseId, '12');
      expect(s.sides[1].views, 21);
      expect(s.removedTotal, 1);
      expect(s.battleDays, 14);
      expect(s.over, isFalse);
    });

    test('a profile tab', () {
      final p = BattlesPage.fromJson({
        'tab': 'won',
        'summary': {
          'rating': 1016,
          'league': 'Bronze',
          'wins': 1,
          'losses': 0,
          'draws': 0,
          'streak': 1,
          'streakOf': 'won',
          'counts': {'open': 2, 'live': 1, 'won': 1, 'lost': 0, 'draw': 0},
        },
        'battles': [
          {
            'challengeId': '7',
            'title': 'who dances better',
            'role': 'creator',
            'status': 'completed',
            'outcome': 'won',
            'myVotes': 5,
            'theirVotes': 2,
            'opponent': 'leo',
            'ratingChange': 16,
            'createdAt': '2026-09-01T10:00:00Z',
          },
        ],
      });
      expect(p.record.rating, 1016);
      expect(p.record.counts['open'], 2);
      expect(p.record.winRate, 1.0);
      expect(p.battles.single.ratingChange, 16);
      expect(p.battles.single.opponent, 'leo');
    });
  });

  group('the battle reel uses all of it', () {
    // Comment lines removed first, so a comment describing a call can never
    // stand in for the call.
    final code = File(
      'lib/widgets/smart_reels_feed.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

    String body(String signature) {
      final start = code.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature is gone');
      final end = code.indexOf('\n  }\n', start);
      return code.substring(start, end < 0 ? code.length : end);
    }

    test('every flip turns the clock', () {
      expect(
        body('void _commitSide('),
        contains('widget.item.faces.turn(opponent: show)'),
      );
    });

    test('a view says how long each side was watched', () {
      final flush = body('void _flushCurrentItemEvent(');
      expect(flush, contains('item.viewDetails('));
      expect(
        RegExp(r'trackView\([^;]*metadata: details').hasMatch(flush),
        isTrue,
      );
    });

    test('completions and shares say which side was showing', () {
      expect(
        RegExp(
          r'trackComplete\([^;]*metadata: item\.sideDetails',
        ).allMatches(code).length,
        2,
      );
      expect(
        RegExp(r'trackShare\([^;]*metadata: item\.sideDetails').hasMatch(code),
        isTrue,
      );
    });

    test('the heart likes the side on screen and shows its count', () {
      final like = body('void _onLike(');
      expect(like, contains('item.faces.showingOpponent'));
      expect(like, contains('_likeAnswer(item)'));
      expect(code, contains('ApiService.likeResponse('));
      expect(code, contains('item.heartOn ? Icons.favorite'));
      expect(code, contains('_compact(item.heartCount)'));
    });
  });
}
