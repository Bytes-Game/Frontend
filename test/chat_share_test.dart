// Sharing a battle or a short into a chat.
//
// A shared video used to arrive as a line of text and the raw address of the
// video file. Now it is sent as a share, and the chat draws it as a video
// card, the way Instagram shows a shared reel; one tap plays it.
//
// These go through the real chat screen, the real share sheet and the real
// reel's Share button, with only the server faked, and check what is ON
// screen.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/challenge_model.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/chat_cache.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/chat_share_widgets.dart';
import 'package:myapp/widgets/smart_reels_feed.dart';

/// A battle as the server attaches it to a share.
Map<String, dynamic> battleJson() => {
  'id': '31',
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': 'https://cdn/c31.mp4',
  'thumbnailUrl': 'https://cdn/c31.jpg',
  'prefix': 'Who can',
  'subject': 'juggle five',
  'visibility': 'arena',
  'status': 'active',
  'responseCount': 1,
  'topResponseId': '71',
  'topResponseUsername': 'leo',
  'topResponseVideoUrl': 'https://cdn/r71.mp4',
  'topResponseThumbnailUrl': 'https://cdn/r71.jpg',
};

Map<String, dynamic> shortJson() => {
  'id': '32',
  'creatorId': '5',
  'creatorUsername': 'maya',
  'videoUrl': 'https://cdn/c32.mp4',
  'thumbnailUrl': 'https://cdn/c32.jpg',
  'prefix': 'Who can',
  'subject': 'dance on a bus',
  'visibility': 'arena',
  'status': 'open',
};

Map<String, dynamic> shareMessage({
  required String id,
  Map<String, dynamic>? video,
  String note = '',
  String from = 'u2',
}) => {
  'id': id,
  'senderId': from,
  'senderUsername': from == 'u2' ? 'maya' : 'me',
  'receiverId': from == 'u2' ? 'u1' : 'u2',
  'receiverUsername': from == 'u2' ? 'me' : 'maya',
  'message': note,
  'isRead': true,
  'status': 'read',
  'createdAt': '2026-10-03T10:00:00Z',
  'kind': 'share',
  'shared': {'challengeId': video?['id'] ?? '99', 'challenge': ?video},
};

late List<Map<String, dynamic>> history;
late List<Map<String, dynamic>> sends;

/// Receivers the server refuses a send to.
Set<String> refuseTo = {};

List<Map<String, dynamic>> conversations = [];

/// When set, the server holds the list of chats until this completes.
Completer<void>? holdChats;

void fakeServer() {
  history = [];
  sends = [];
  refuseTo = {};
  conversations = [];
  holdChats = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p == '/api/v1/chat/send') {
        final body = json.decode(req.body) as Map<String, dynamic>;
        sends.add(body);
        if (refuseTo.contains(body['receiverId'])) {
          return http.Response('down', 500);
        }
        return http.Response(json.encode({'id': '${sends.length}'}), 200);
      }
      if (p.contains('/chat/messages/')) {
        return http.Response(json.encode(history), 200);
      }
      if (p.contains('/chat/conversations/')) {
        final hold = holdChats;
        if (hold != null) await hold.future;
        return http.Response(json.encode(conversations), 200);
      }
      if (p.contains('/feed')) {
        return http.Response(json.encode({'items': [], 'hasMore': false}), 200);
      }
      return http.Response('{}', 200);
    }),
  );
}

UserModel user(String id, String name) => UserModel(
  id: id,
  username: name,
  wins: 0,
  losses: 0,
  followersCount: 0,
  followingCount: 0,
);

DataProvider signedIn() => DataProvider()
  ..setUser(user('u1', 'me'))
  ..setAllUsers([
    user('u1', 'me'),
    user('u2', 'maya'),
    user('u3', 'leo'),
    user('u4', 'nina'),
  ]);

late WebSocketService ws;

Future<void> openChat(WidgetTester t) async {
  final dp = signedIn();
  EventTracker.instance.dispose();
  ws = WebSocketService('', '');
  await t.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DataProvider>.value(value: dp),
        Provider<WebSocketService>.value(value: ws),
      ],
      child: const MaterialApp(
        home: ChatConversationPage(otherUserId: 'u2', otherUsername: 'maya'),
      ),
    ),
  );
  await settle(t);
}

Future<void> openSheet(
  WidgetTester t, {
  Map<String, dynamic>? video,
  String responseId = '',
}) async {
  final dp = signedIn();
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const ValueKey('open_share'),
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (_) => ShareSheet(
                    challenge: ChallengeModel.fromJson(video ?? battleJson()),
                    responseId: responseId,
                  ),
                ),
                child: const Text('share'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open_share')));
  await settle(t);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  // Long enough for a player opened from a card to finish closing.
  await t.pump(const Duration(seconds: 5));
  ReelDiagnostics.instance.debugReset();
  EventTracker.instance.dispose();
}

final card = find.byKey(const ValueKey('shared_video_card'));
final sheet = find.byKey(const ValueKey('share_sheet'));
Finder person(String id) => find.byKey(ValueKey('share_person_$id'));

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  group('in the chat', () {
    testWidgets('a shared battle is a video card, not a link', (t) async {
      history = [shareMessage(id: '1', video: battleJson())];
      await openChat(t);
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('Who can juggle five')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('@maya vs @leo')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Battle')),
        findsOneWidget,
      );
      expect(
        find.textContaining('https://'),
        findsNothing,
        reason: 'no raw link anywhere',
      );
      await close(t);
    });

    testWidgets('a shared short says so, and a note sits under it', (t) async {
      history = [
        shareMessage(id: '1', video: shortJson(), note: 'look at this'),
      ];
      await openChat(t);
      expect(
        find.descendant(of: card, matching: find.text('Short')),
        findsOneWidget,
      );
      expect(find.text('look at this'), findsOneWidget);
      await close(t);
    });

    testWidgets('a video they cannot see any more says it is unavailable', (
      t,
    ) async {
      history = [shareMessage(id: '1')];
      await openChat(t);
      expect(card, findsNothing);
      expect(
        find.byKey(const ValueKey('shared_video_unavailable')),
        findsOneWidget,
      );
      expect(find.text('Video unavailable'), findsOneWidget);
      await close(t);
    });

    testWidgets('tapping the card plays the video', (t) async {
      // No picture: the player would go and fetch it, and a test cannot.
      history = [
        shareMessage(id: '1', video: {...shortJson(), 'thumbnailUrl': ''}),
      ];
      await openChat(t);
      await t.tap(card);
      await settle(t);
      expect(find.byType(SmartReelsFeed), findsOneWidget);
      await close(t);
    });

    testWidgets('one shared live arrives as a card too', (t) async {
      await openChat(t);
      expect(card, findsNothing);
      ws.debugReceive({
        'type': 'chat',
        'messageId': '9',
        'senderId': 'u2',
        'senderUsername': 'maya',
        'receiverId': 'u1',
        'receiverUsername': 'me',
        'message': '',
        'timestamp': '2026-10-03T10:01:00Z',
        'kind': 'share',
        'shared': {'challengeId': '31', 'challenge': battleJson()},
      });
      await settle(t);
      expect(card, findsOneWidget);
      await close(t);
    });
  });

  group('the share sheet', () {
    testWidgets('sends the video, not a link, to the one picked', (t) async {
      await openSheet(t, responseId: '71');
      expect(sheet, findsOneWidget);
      expect(person('u1'), findsNothing, reason: 'not yourself');
      await t.tap(person('u3'));
      await t.pump();
      await t.enterText(find.byKey(const ValueKey('share_note')), 'you!');
      await t.tap(find.byKey(const ValueKey('share_send')));
      await settle(t);
      expect(sends, hasLength(1));
      expect(sends.single['kind'], 'share');
      expect(sends.single['receiverId'], 'u3');
      expect(sends.single['challengeId'], '31');
      expect(sends.single['responseId'], '71');
      expect(sends.single['message'], 'you!');
      expect(
        '${sends.single}',
        isNot(contains('https://')),
        reason: 'no link in what is sent',
      );
      expect(sheet, findsNothing, reason: 'done: the sheet closes');
      expect(find.text('Sent to @leo'), findsOneWidget);
      await close(t);
    });

    testWidgets('several at once, one message each', (t) async {
      await openSheet(t);
      await t.tap(person('u3'));
      await t.tap(person('u4'));
      await t.pump();
      expect(find.text('Send separately (2)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('share_send')));
      await settle(t);
      expect({for (final s in sends) s['receiverId']}, {'u3', 'u4'});
      expect(find.text('Sent to 2 people'), findsOneWidget);
      await close(t);
    });

    testWidgets('a send that fails stays picked, to try again', (t) async {
      refuseTo = {'u4'};
      await openSheet(t);
      await t.tap(person('u3'));
      await t.tap(person('u4'));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('share_send')));
      await settle(t);
      expect(sheet, findsOneWidget, reason: 'not done: it stays open');
      expect(find.text("Couldn't send to @nina. Try again."), findsOneWidget);
      expect(find.text('Send'), findsOneWidget, reason: 'nina alone picked');
      await close(t);
    });

    testWidgets('the people you chat with are in order at once, from the '
        'chats the app already has', (t) async {
      ChatCache.instance.keepChats('u1', [
        {'userId': 'u4', 'username': 'nina'},
      ]);
      holdChats = Completer<void>();
      await openSheet(t);
      final ninaX = t.getTopLeft(person('u4')).dx;
      final mayaX = t.getTopLeft(person('u2')).dx;
      expect(ninaX, lessThan(mayaX),
          reason: 'nina first before the server has answered');
      holdChats!.complete();
      await settle(t);
      await close(t);
    });

    testWidgets('the people you chat with come first, and search finds the '
        'rest', (t) async {
      conversations = [
        {'userId': 'u4', 'username': 'nina'},
      ];
      await openSheet(t);
      final ninaX = t.getTopLeft(person('u4')).dx;
      final mayaX = t.getTopLeft(person('u2')).dx;
      expect(ninaX, lessThan(mayaX), reason: 'nina, a recent chat, first');

      await t.enterText(find.byType(TextField).first, 'le');
      await t.pump();
      expect(person('u3'), findsOneWidget);
      expect(person('u2'), findsNothing);
      await close(t);
    });
  });
}
