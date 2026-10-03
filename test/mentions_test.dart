// Mentioning people with an @, in comments and in chat.
//
// Type @ and a few letters: the people who match show above the text box,
// the ones you follow first — in a chat, only the person you are talking
// to. Tap one and their name goes in. An @name in a
// comment or a message is drawn in colour, and tapping it opens their
// profile. (The server tells whoever a comment mentions — mentions.go.)
//
// These go through the real comments sheet and the real chat screen, with
// only the server faked, and tap what is on screen.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/websocket_service.dart';
import 'package:myapp/widgets/feed_action_bar.dart';
import 'package:myapp/widgets/mentions.dart';

UserModel user(String id, String name, {String fullName = ''}) => UserModel(
  id: id,
  username: name,
  fullName: fullName,
  wins: 0,
  losses: 0,
  followersCount: 0,
  followingCount: 0,
);

DataProvider signedIn({List<String> following = const []}) => DataProvider()
  ..setUser(user('u1', 'me'))
  ..setAllUsers([
    user('u1', 'me'),
    user('u2', 'maya', fullName: 'Maya Singh'),
    user('u3', 'mark'),
    user('u4', 'nina'),
    user('u5', 'leo'),
  ])
  ..setFollowing(List<String>.from(following));

late List<Map<String, dynamic>> commentsPosted;
late List<Map<String, dynamic>> messagesSent;
late List<Map<String, dynamic>> serverComments;
late List<Map<String, dynamic>> history;

void fakeServer() {
  commentsPosted = [];
  messagesSent = [];
  serverComments = [];
  history = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/challenges/comments')) {
        final body = json.decode(req.body) as Map<String, dynamic>;
        commentsPosted.add(body);
        return http.Response(
          json.encode({
            'id': '9',
            'text': body['text'],
            'authorUsername': 'me',
          }),
          200,
        );
      }
      if (p.contains('/comments')) {
        return http.Response(json.encode(serverComments), 200);
      }
      if (p == '/api/v1/chat/send') {
        messagesSent.add(json.decode(req.body) as Map<String, dynamic>);
        return http.Response(json.encode({'id': '77'}), 200);
      }
      if (p.contains('/chat/messages/')) {
        return http.Response(json.encode(history), 200);
      }
      if (p.contains('/battles')) {
        return http.Response(
          json.encode({'summary': {}, 'tab': 'live', 'battles': []}),
          200,
        );
      }
      if (p.endsWith('/challenges')) return http.Response('[]', 200);
      return http.Response('{}', 200);
    }),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> openComments(
  WidgetTester t, {
  List<String> following = const [],
}) async {
  final dp = signedIn(following: following);
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    ChangeNotifierProvider<DataProvider>.value(
      value: dp,
      child: const MaterialApp(
        home: Scaffold(body: ChallengeCommentSheet(challengeId: '31')),
      ),
    ),
  );
  await settle(t);
}

late WebSocketService ws;

Future<void> openChat(
  WidgetTester t, {
  String otherId = 'u2',
  String otherName = 'maya',
}) async {
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
      child: MaterialApp(
        home: ChatConversationPage(
          otherUserId: otherId,
          otherUsername: otherName,
        ),
      ),
    ),
  );
  await settle(t);
}

Future<void> close(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 1));
  EventTracker.instance.dispose();
}

final suggestions = find.byKey(const ValueKey('mention_suggestions'));
Finder pick(String name) => find.byKey(ValueKey('mention_pick_$name'));

/// Taps the @name [text] inside a [MentionText], the way a finger does.
Future<void> tapMention(WidgetTester t, String text) async {
  await t.tapOnText(find.textRange.ofSubstring(text));
  await settle(t);
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  group('reading what is being typed', () {
    TextEditingValue at(String text, [int? cursor]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor ?? text.length),
    );

    test('an @name right before the cursor', () {
      expect(activeMention(at('hi @ma')), (at: 3, query: 'ma'));
      expect(activeMention(at('@')), (at: 0, query: ''));
      expect(activeMention(at('hi @ma and', 6)), (at: 3, query: 'ma'));
    });

    test('not an @ in an e-mail address, nor after a finished name', () {
      expect(activeMention(at('write to sam@ma')), isNull);
      expect(activeMention(at('hi @maya ')), isNull);
      expect(activeMention(at('no at all')), isNull);
    });

    test('picking puts the name in with a space after it', () {
      final c = TextEditingController.fromValue(at('great @ma'));
      insertMention(c, 'maya');
      expect(c.text, 'great @maya ');
      expect(c.selection.baseOffset, c.text.length);
    });

    test('people you follow come first, and never yourself', () {
      // maya before mark only because you follow her: alphabetically
      // mark would come first.
      final dp = signedIn(following: ['u2']);
      expect(mentionCandidates(dp, 'ma').map((u) => u.username), [
        'maya',
        'mark',
      ]);
      expect(mentionCandidates(dp, 'me'), isEmpty);
      expect(mentionCandidates(dp, 'singh').map((u) => u.username), [
        'maya',
      ], reason: 'found by their full name too');
    });
  });

  group('in a comment', () {
    testWidgets('typing @ and letters shows the people who match; tapping '
        'one puts their name in', (t) async {
      await openComments(t);
      expect(suggestions, findsNothing, reason: 'nothing until an @');
      await t.enterText(find.byType(TextField), 'great one @ni');
      await t.pump();
      expect(suggestions, findsOneWidget);
      expect(pick('nina'), findsOneWidget);
      expect(pick('maya'), findsNothing);
      await t.tap(pick('nina'));
      await t.pump();
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        'great one @nina ',
      );
      expect(suggestions, findsNothing, reason: 'gone once picked');

      await t.tap(find.byTooltip('Post'));
      await settle(t);
      expect(commentsPosted.single['text'], 'great one @nina');
      await close(t);
    });

    testWidgets('an @name in a comment opens their profile', (t) async {
      serverComments = [
        {
          'id': '1',
          'authorUsername': 'leo',
          'text': 'what do you think @maya?',
          'createdAt': '2026-10-03T10:00:00Z',
        },
      ];
      await openComments(t);
      expect(find.byType(ProfilePage), findsNothing);
      await tapMention(t, '@maya');
      expect(find.byType(ProfilePage), findsOneWidget);
      final page = t.widget<ProfilePage>(find.byType(ProfilePage));
      expect(page.user.username, 'maya');
      await close(t);
    });

    testWidgets('the words around a name do not open anything', (t) async {
      serverComments = [
        {
          'id': '1',
          'authorUsername': 'leo',
          'text': 'what do you think @maya?',
          'createdAt': '2026-10-03T10:00:00Z',
        },
      ];
      await openComments(t);
      await t.tapOnText(find.textRange.ofSubstring('what do you'));
      await settle(t);
      expect(find.byType(ProfilePage), findsNothing);
      await close(t);
    });
  });

  group('in chat', () {
    testWidgets('typing @ suggests the person you are talking to, and the '
        'name goes into the message', (t) async {
      await openChat(t);
      expect(suggestions, findsNothing);
      await t.enterText(find.byType(TextField), 'hey @');
      await t.pump();
      expect(suggestions, findsOneWidget);
      expect(pick('maya'), findsOneWidget);
      await t.tap(pick('maya'));
      // The send button turns in over a few frames.
      await settle(t);
      await t.tap(find.byTooltip('Send'));
      await settle(t);
      expect(messagesSent.single['message'], 'hey @maya');
      await close(t);
    });

    testWidgets('and nobody else: not everyone on the app', (t) async {
      await openChat(t);
      await t.enterText(find.byType(TextField), 'ask @');
      await t.pump();
      expect(pick('maya'), findsOneWidget,
          reason: 'the one person in this chat');
      for (final other in ['mark', 'nina', 'leo']) {
        expect(pick(other), findsNothing, reason: '$other is not in it');
      }
      // Letters that only match somebody else show nothing at all.
      await t.enterText(find.byType(TextField), 'ask @le');
      await t.pump();
      expect(suggestions, findsNothing);
      await close(t);
    });

    testWidgets('even one the app has not loaded yet', (t) async {
      await openChat(t, otherId: 'u9', otherName: 'zed');
      await t.enterText(find.byType(TextField), 'hi @');
      await t.pump();
      expect(pick('zed'), findsOneWidget);
      expect(pick('maya'), findsNothing);
      await close(t);
    });

    testWidgets('found by their full name too', (t) async {
      await openChat(t);
      await t.enterText(find.byType(TextField), 'ask @sin');
      await t.pump();
      expect(pick('maya'), findsOneWidget);
      await close(t);
    });

    testWidgets('an @name in a message opens their profile', (t) async {
      history = [
        {
          'id': '1',
          'senderId': 'u2',
          'senderUsername': 'maya',
          'receiverId': 'u1',
          'receiverUsername': 'me',
          'message': 'ask @nina about it',
          'isRead': true,
          'status': 'read',
          'createdAt': '2026-10-03T10:00:00Z',
          'kind': 'text',
        },
      ];
      await openChat(t);
      await tapMention(t, '@nina');
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(
        t.widget<ProfilePage>(find.byType(ProfilePage)).user.username,
        'nina',
      );
      await close(t);
    });
  });
}
