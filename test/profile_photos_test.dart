// Profile photos, profile tags, who liked open to everyone, and "What's
// this video about?".
//
// Each test that checks something is NOT shown also checks something that
// IS, so a screen broken into showing nothing cannot pass by having
// nothing to find. And each goes through the app's own wiring — the real
// ApiService calls against a pretend server — rather than calling the far
// end by hand.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/profile_tags.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/edit_profile_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/avatar_book.dart';
import 'package:myapp/services/chat_media.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/profile_photo_flow.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/feed_action_bar.dart';
import 'package:myapp/widgets/people_list_sheet.dart';
import 'package:myapp/widgets/video_about_row.dart';

import 'fake_gallery.dart';

const myPhoto = 'https://cdn/u/1/up1/photo.jpg';

UserModel person(
  String id,
  String name, {
  String avatarUrl = '',
  String tag = '',
}) => UserModel(
  id: id,
  username: name,
  wins: 3,
  losses: 1,
  followersCount: 12,
  followingCount: 4,
  league: 'Silver',
  rating: 1080,
  avatarUrl: avatarUrl,
  profileTag: tag,
);

Map<String, dynamic> userJson(UserModel u) => {
  'id': u.id,
  'username': u.username,
  'league': u.league,
  'rating': u.rating,
  if (u.avatarUrl.isNotEmpty) 'avatarUrl': u.avatarUrl,
  if (u.profileTag.isNotEmpty) 'profileTag': u.profileTag,
};

http.Response jsonBody(Object o, [int code = 200]) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  code,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Every request the app made: method, address, body.
late List<(String, String, String)> asked;

/// Accounts the server knows, by username.
late Map<String, UserModel> accounts;

/// Each account's photo as the server has it.
late Map<String, String> photosOnServer;

/// What /about answers, and with what status.
late int aboutCode;
late Map<String, dynamic> aboutReply;

bool presignFails = false;

/// When set, reading an account waits for it: the server is slow.
Completer<void>? accountGate;

List<(String, String, String)> sentTo(String method, String path) => [
  for (final a in asked)
    if (a.$1 == method && Uri.parse(a.$2).path == path) a,
];

void fakeServer() {
  asked = [];
  accounts = {};
  photosOnServer = {};
  aboutCode = 200;
  aboutReply = {};
  presignFails = false;
  accountGate = null;
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      asked.add((
        req.method,
        req.url.toString(),
        utf8.decode(req.bodyBytes, allowMalformed: true),
      ));
      if (p == '/api/v1/users/avatars') {
        final names = req.url.queryParameters['names']!.split(',');
        return jsonBody({
          'avatars': {
            for (final n in names)
              if (accounts.containsKey(n)) n: photosOnServer[n] ?? '',
          },
        });
      }
      if (p.endsWith('/media/presign')) {
        if (presignFails) return http.Response('down', 503);
        final items = (json.decode(req.body)['items'] as List).cast<Map>();
        return jsonBody({
          'uploadId': 'up1',
          'items': [
            for (final i in items)
              {
                ...i,
                'uploadUrl': 'https://storage/put/${i['kind']}',
                'publicUrl': myPhoto,
              },
          ],
        });
      }
      if (req.url.host == 'storage') return http.Response('', 200);
      if (p == '/api/v1/users/1' && req.method == 'PATCH') {
        final body = json.decode(req.body) as Map<String, dynamic>;
        return jsonBody({
          'updated': true,
          'user': {
            ...userJson(person('1', 'me')),
            if (body['avatarUrl'] != null) 'avatarUrl': body['avatarUrl'],
            if (body['profileTag'] != null) 'profileTag': body['profileTag'],
          },
        });
      }
      if (p == '/api/v1/challenges/5/people') {
        return jsonBody({
          'sides': [
            {
              'username': 'maya',
              'role': 'creator',
              'people': [
                {
                  'userId': '31',
                  'username': 'nina',
                  'avatarUrl': 'https://cdn/u/31/a/photo.jpg',
                },
                {'userId': '32', 'username': 'omar'},
              ],
            },
          ],
        });
      }
      if (p == '/api/v1/challenges/5/about') {
        return jsonBody(aboutReply, aboutCode);
      }
      // Renewing a saved login: the server is not reachable just now,
      // which leaves the login as it is.
      if (p.endsWith('/auth/refresh')) return http.Response('asleep', 503);
      final user = RegExp(r'^/api/v1/users/([^/]+)$').firstMatch(p);
      if (user != null && req.method == 'GET') {
        await accountGate?.future;
        final u = accounts[Uri.decodeComponent(user.group(1)!)];
        if (u != null) return jsonBody(userJson(u));
      }
      return http.Response('not here', 404);
    }),
  );
}

/// The photo [name]'s picture shows, if any.
Finder photoOf(String name) => find.byKey(ValueKey('photo_$name'));

String photoUrl(WidgetTester t, String name) {
  final img = t.widget<Image>(photoOf(name));
  return ((img.image as ResizeImage).imageProvider as NetworkImage).url;
}

Widget app(Widget home, {UserModel? me, DataProvider? dp}) {
  final provider = dp ?? DataProvider();
  provider.setUser(me ?? person('1', 'me'));
  EventTracker.instance.dispose();
  return ChangeNotifierProvider<DataProvider>.value(
    value: provider,
    child: MaterialApp(home: home),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

/// Lets real file reads and writes finish between frames: the photo is
/// written to a file and read back for the upload.
Future<void> work(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 30),
        ));
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Runs out the toasts and the photo book's save, so nothing is left
/// ticking when the test ends. Saving your profile signs you in again
/// (DataProvider.setUser), which starts the event uploader's timer.
Future<void> finish(WidgetTester t) async {
  await t.pump(const Duration(seconds: 5));
  EventTracker.instance.dispose();
}

class _Photos implements PhotoSource {
  File? next;
  bool? askedCamera;
  @override
  Future<File?> pick({required bool camera}) async {
    askedCamera = camera;
    return next;
  }
}

/// Source with the comment lines taken out, so a test that reads it finds
/// code and not the words explaining it.
String code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  late Directory dir;
  late _Photos photos;

  setUp(() {
    fakeServer();
    AvatarBook.instance.debugReset();
    dir = Directory.systemTemp.createTempSync('profile_photos');
    AvatarBook.directory = () async => dir;
    AvatarBook.now = DateTime.now;
    VideoAboutRow.debugForget();
    photos = _Photos();
    ChatMedia.instance.photos = photos;
  });

  tearDown(() {
    AvatarBook.instance.debugReset();
    AvatarBook.ask = ApiService.getAvatars;
    AvatarBook.now = DateTime.now;
    ApiService.useClient(http.Client());
    ChatMedia.instance.debugReset();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('Everybody\'s photo, everywhere', () {
    testWidgets('a picture shows the person\'s photo once the app knows it, '
        'and their initial until then', (t) async {
      await t.pumpWidget(
        const MaterialApp(home: Center(child: ArenaAvatar(name: 'maya'))),
      );
      expect(photoOf('maya'), findsNothing);
      expect(find.text('M'), findsOneWidget);

      AvatarBook.instance.learn('maya', 'https://cdn/u/7/a/photo.jpg');
      await t.pump();
      expect(photoOf('maya'), findsOneWidget);
      expect(photoUrl(t, 'maya'), 'https://cdn/u/7/a/photo.jpg');

      // Taken away: the initial again.
      AvatarBook.instance.learn('maya', '');
      await t.pump();
      expect(photoOf('maya'), findsNothing);
      expect(find.text('M'), findsOneWidget);
    });

    testWidgets('once started, the app asks the server for every face on '
        'screen in ONE question, and shows the answers', (t) async {
      accounts = {
        for (final n in ['maya', 'leo', 'sam']) n: person('0', n),
      };
      photosOnServer = {
        'maya': 'https://cdn/u/7/a/photo.jpg',
        'leo': 'https://cdn/u/8/a/photo.jpg',
      };
      await t.runAsync(AvatarBook.instance.start);
      await t.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [
              ArenaAvatar(name: 'maya'),
              ArenaAvatar(name: 'leo'),
              ArenaAvatar(name: 'sam'),
              ArenaAvatar(name: 'maya'),
            ],
          ),
        ),
      );
      await t.pump(AvatarBook.gather);
      await t.pump();
      await t.pump();
      final questions = sentTo('GET', '/api/v1/users/avatars');
      expect(questions, hasLength(1));
      final names = Uri.parse(questions.single.$2)
          .queryParameters['names']!
          .split(',');
      expect(names.toSet(), {'maya', 'leo', 'sam'});
      expect(photoOf('maya'), findsNWidgets(2));
      expect(photoOf('leo'), findsOneWidget);
      expect(photoOf('sam'), findsNothing, reason: 'sam has no photo');

      // Asked again later: the answers are fresh, nothing more goes.
      await t.pumpWidget(
        const MaterialApp(home: ArenaAvatar(name: 'leo')),
      );
      await t.pump(AvatarBook.gather);
      expect(sentTo('GET', '/api/v1/users/avatars'), hasLength(1));
      expect(photoOf('leo'), findsOneWidget);
      await finish(t);
    });

    test('nothing is asked before the app starts the book', () async {
      var questions = 0;
      AvatarBook.ask = (names) async {
        questions++;
        return {for (final n in names) n: ''};
      };
      AvatarBook.instance.photoOf('maya');
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, 0);
      await AvatarBook.instance.start();
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, 1, reason: 'what was wanted before goes once started');
    });

    test('a server that does not answer is asked again a minute later, not '
        'on every redraw and not six hours later', () async {
      var clock = DateTime(2026, 10, 10, 12);
      AvatarBook.now = () => clock;
      final questions = <List<String>>[];
      Map<String, String>? reply;
      AvatarBook.ask = (names) async {
        questions.add(names);
        return reply;
      };
      await AvatarBook.instance.start();
      AvatarBook.instance.photoOf('maya');
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, hasLength(1));

      // Redrawn straight away: not asked again.
      AvatarBook.instance.photoOf('maya');
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, hasLength(1));

      // A minute on: asked again, and this time it answers.
      clock = clock.add(AvatarBook.retry + const Duration(seconds: 1));
      reply = {'maya': 'https://cdn/u/7/a/photo.jpg'};
      final photo = AvatarBook.instance.photoOf('maya');
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, hasLength(2));
      expect(photo.value, 'https://cdn/u/7/a/photo.jpg');

      // Six hours on, asked again: that is how a new photo reaches people.
      clock = clock.add(AvatarBook.fresh + const Duration(minutes: 1));
      reply = {'maya': 'https://cdn/u/7/b/photo.jpg'};
      AvatarBook.instance.photoOf('maya');
      await Future<void>.delayed(AvatarBook.gather * 3);
      expect(questions, hasLength(3));
      expect(photo.value, 'https://cdn/u/7/b/photo.jpg');
    });

    test('photos are kept on the phone, so the next app open shows them at '
        'once', () async {
      AvatarBook.ask = (names) async => null;
      await AvatarBook.instance.start();
      AvatarBook.instance.learn('maya', 'https://cdn/u/7/a/photo.jpg');
      await Future<void>.delayed(const Duration(milliseconds: 2400));
      expect(File('${dir.path}/avatar_book.json').existsSync(), isTrue);

      // A new app open.
      AvatarBook.instance.debugReset();
      expect(AvatarBook.instance.photoOf('maya').value, '');
      await AvatarBook.instance.start();
      expect(
        AvatarBook.instance.photoOf('maya').value,
        'https://cdn/u/7/a/photo.jpg',
      );
    });

    test('a profile read from the server, and your own, teach the book '
        'their photo', () async {
      accounts = {'leo': person('8', 'leo', avatarUrl: 'https://cdn/l.jpg')};
      await ApiService.getUserByUsername('leo');
      expect(AvatarBook.instance.photoOf('leo').value, 'https://cdn/l.jpg');

      DataProvider().setUser(person('1', 'me', avatarUrl: myPhoto));
      expect(AvatarBook.instance.photoOf('me').value, myPhoto);
    });

    test('your profile is brought up to date from the server, keeping what '
        'that answer does not say', () async {
      final dp = DataProvider()
        ..setUser(person('1', 'me').copyWith(twoFactorEnabled: true));
      EventTracker.instance.dispose();
      accounts = {'me': person('1', 'me', avatarUrl: myPhoto, tag: 'Gamer')};
      await dp.refreshUser();
      expect(sentTo('GET', '/api/v1/users/me'), hasLength(1));
      expect(dp.user!.avatarUrl, myPhoto);
      expect(dp.user!.profileTag, 'Gamer');
      expect(dp.user!.twoFactorEnabled, isTrue,
          reason: 'the account answer does not carry it');
      expect(AvatarBook.instance.photoOf('me').value, myPhoto);
    });

    testWidgets('opening the app on the login kept from days ago does not '
        'take away the photo the phone knows, and the server then brings the '
        'profile up to date', (t) async {
      String jwt() {
        String seg(Map<String, dynamic> m) =>
            base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
        final exp = DateTime.now().add(const Duration(days: 3));
        return '${seg({'alg': 'HS256'})}.'
            '${seg({'sub': '1', 'username': 'me', 'exp': exp.millisecondsSinceEpoch ~/ 1000})}'
            '.sig';
      }

      // Kept at sign-in, before the photo was chosen.
      FlutterSecureStorage.setMockInitialValues({
        'session_v1': json.encode({
          'token': jwt(),
          'user': {'id': '1', 'username': 'me', 'followingList': <String>[]},
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      });
      SessionStore.resetForTest();
      addTearDown(ApiService.clearAuth);
      // The photo chosen since, kept by the book.
      AvatarBook.instance.learn('me', myPhoto);
      accounts = {'me': person('1', 'me', avatarUrl: myPhoto, tag: 'Gamer')};
      accountGate = Completer<void>();

      final auth = AuthProvider();
      final dp = DataProvider();
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: dp),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => auth.restoreSession(context),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await work(t);
      expect(auth.isAuthenticated, isTrue);
      expect(dp.user!.avatarUrl, '', reason: 'the kept copy');
      expect(AvatarBook.instance.photoOf('me').value, myPhoto,
          reason: 'not taken away by the old copy');

      accountGate!.complete();
      await work(t);
      expect(dp.user!.avatarUrl, myPhoto);
      expect(dp.user!.profileTag, 'Gamer');
      await finish(t);
    });

    test('the app starts the book as it opens', () {
      expect(
        code('lib/main.dart'),
        contains('AvatarBook.instance.start()'),
      );
    });
  });

  group('Who liked: open to everyone, and a tap opens the person', () {
    testWidgets('the list shows each person\'s photo, and tapping one opens '
        'their profile', (t) async {
      accounts = {'nina': person('31', 'nina')};
      await t.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showPeople(context, '5', PeopleList.likes),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      expect(find.text('Liked by 2'), findsOneWidget);
      // nina's photo came with the list; omar has none.
      expect(photoOf('nina'), findsOneWidget);
      expect(photoUrl(t, 'nina'), 'https://cdn/u/31/a/photo.jpg');
      expect(photoOf('omar'), findsNothing);
      expect(find.text('omar'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('person_31')));
      await settle(t);
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(t.widget<ProfilePage>(find.byType(ProfilePage)).user.username,
          'nina');
      await finish(t);
    });

    testWidgets('a person with no account says so instead of doing nothing', (
      t,
    ) async {
      await t.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPeople(context, '5', PeopleList.likes),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('person_32')));
      await settle(t);
      expect(find.byType(ProfilePage), findsNothing);
      expect(find.text("Couldn't open omar's profile."), findsOneWidget);
      await finish(t);
    });
  });

  group('Changing your photo', () {
    late DataProvider dp;

    Future<void> openEdit(WidgetTester t, {UserModel? me}) async {
      dp = DataProvider();
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      const temp = MethodChannel('plugins.flutter.io/path_provider');
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        temp,
        (call) async => dir.path,
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          temp,
          null,
        ),
      );
      await t.pumpWidget(app(const EditProfilePage(), me: me, dp: dp));
      await settle(t);
    }

    final editorCrop = ProfilePhotoFlow.crop;
    setUp(() {
      photos.next = File('${dir.path}/picked.jpg')..writeAsBytesSync(tinyJpeg);
      // The real framing needs a picture decoder the tests do not have.
      ProfilePhotoFlow.crop = (context, photo) async => tinyJpeg;
    });
    tearDown(() => ProfilePhotoFlow.crop = editorCrop);

    testWidgets('choose one from your photos: framed, uploaded, saved, and '
        'it is your picture everywhere at once', (t) async {
      await openEdit(t);
      expect(photoOf('me'), findsNothing);
      await t.tap(find.byKey(const ValueKey('edit_photo')));
      await settle(t);
      expect(find.byKey(const ValueKey('profile_photo_camera')), findsOneWidget);
      // No photo yet: nothing to remove.
      expect(find.byKey(const ValueKey('profile_photo_remove')), findsNothing);
      await t.tap(find.byKey(const ValueKey('profile_photo_gallery')));
      await work(t);

      expect(photos.askedCamera, isFalse);
      expect(sentTo('POST', '/api/v1/media/presign'), hasLength(1));
      expect(
        asked.where((a) => Uri.parse(a.$2).host == 'storage'),
        hasLength(1),
        reason: 'the picture went to storage',
      );
      final saved = sentTo('PATCH', '/api/v1/users/1');
      expect(saved, hasLength(1));
      expect(json.decode(saved.single.$3)['avatarUrl'], myPhoto);
      expect(find.text('Profile photo updated'), findsOneWidget);
      expect(dp.user!.avatarUrl, myPhoto);
      // Every picture of you shows it — this page's included.
      expect(AvatarBook.instance.photoOf('me').value, myPhoto);
      expect(photoOf('me'), findsOneWidget);
      await finish(t);
    });

    testWidgets('take one with the camera', (t) async {
      await openEdit(t);
      await t.tap(find.byKey(const ValueKey('edit_photo_avatar')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('profile_photo_camera')));
      await work(t);
      expect(photos.askedCamera, isTrue);
      expect(dp.user!.avatarUrl, myPhoto);
      await finish(t);
    });

    testWidgets('remove it: the initial comes back', (t) async {
      await openEdit(t, me: person('1', 'me', avatarUrl: myPhoto));
      expect(photoOf('me'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('edit_photo')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('profile_photo_remove')));
      await settle(t);
      final saved = sentTo('PATCH', '/api/v1/users/1');
      expect(json.decode(saved.single.$3)['avatarUrl'], '');
      expect(find.text('Profile photo removed'), findsOneWidget);
      expect(dp.user!.avatarUrl, '');
      expect(photoOf('me'), findsNothing);
      expect(find.text('M'), findsOneWidget);
      await finish(t);
    });

    testWidgets('backing out of the framing changes nothing and sends '
        'nothing', (t) async {
      ProfilePhotoFlow.crop = (context, photo) async => null;
      await openEdit(t);
      await t.tap(find.byKey(const ValueKey('edit_photo')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('profile_photo_gallery')));
      await settle(t);
      expect(photos.askedCamera, isFalse, reason: 'it did ask for a photo');
      expect(sentTo('POST', '/api/v1/media/presign'), isEmpty);
      expect(sentTo('PATCH', '/api/v1/users/1'), isEmpty);
      expect(dp.user!.avatarUrl, '');
      await finish(t);
    });

    testWidgets('an upload that fails says so, and the photo stays as it '
        'was', (t) async {
      presignFails = true;
      await openEdit(t);
      await t.tap(find.byKey(const ValueKey('edit_photo')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('profile_photo_gallery')));
      await work(t);
      expect(
        find.text("Couldn't upload your photo. Check your connection and "
            'try again.'),
        findsOneWidget,
      );
      expect(sentTo('PATCH', '/api/v1/users/1'), isEmpty);
      expect(dp.user!.avatarUrl, '');
      await finish(t);
    });
  });

  group('Profile tag', () {
    testWidgets('pick one and Save: the server is told, and it shows on the '
        'profile', (t) async {
      final dp = DataProvider();
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app(const EditProfilePage(), dp: dp));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('edit_profile_tag')));
      await settle(t);
      expect(find.text('What is your profile about?'), findsOneWidget);
      expect(find.byKey(const ValueKey('tag_Influencer')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('tag_Motivator')));
      await settle(t);
      expect(find.text('Motivator'), findsOneWidget, reason: 'on the row');
      await t.tap(find.text('Save'));
      await settle(t);
      final saved = sentTo('PATCH', '/api/v1/users/1');
      expect(saved, hasLength(1));
      expect(json.decode(saved.single.$3)['profileTag'], 'Motivator');
      expect(dp.user!.profileTag, 'Motivator');
      await finish(t);
    });

    testWidgets('a profile with a tag shows it beside the name; one without '
        'shows none', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final leo = person('8', 'leo', tag: 'Comedian');
      await t.pumpWidget(app(ProfilePage(user: leo, isEmbedded: false)));
      await settle(t);
      expect(find.byKey(const ValueKey('profile_tag_pill')), findsOneWidget);
      expect(find.text('Comedian'), findsOneWidget);

      await t.pumpWidget(app(
        ProfilePage(user: person('9', 'sam'), isEmbedded: false),
      ));
      await settle(t);
      expect(find.byKey(const ValueKey('profile_tag_pill')), findsNothing);
      expect(find.text('sam'), findsWidgets);
      await finish(t);
    });

    test('the app offers the same tags the server accepts', () {
      final server = File('../gobackend/profile_photo.go');
      if (!server.existsSync()) {
        markTestSkipped('the server is not checked out next to the app');
        return;
      }
      final src = server.readAsStringSync();
      final list = RegExp(r'profileTags = \[\]string\{([^}]*)\}', dotAll: true)
          .firstMatch(src)!
          .group(1)!;
      final tags = RegExp(r'"([^"]+)"')
          .allMatches(list)
          .map((m) => m.group(1))
          .toList();
      expect(profileTags, tags);
    });
  });

  group("What's this video about?", () {
    Future<void> openCaption(
      WidgetTester t, {
      String responseId = '',
    }) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: CommentSheetCaption(
              username: 'maya',
              caption: 'Who can juggle five balls?',
              challengeId: '5',
              responseId: responseId,
              responder: 'leo',
            ),
          ),
        ),
      );
    }

    testWidgets('a tap asks, and it says what happens in the video, written '
        'by AI and maybe wrong', (t) async {
      aboutReply = {
        'about': 'Someone juggles five balls on a beach.',
        'topics': ['juggling'],
        'from': 'said',
        'looked': true,
      };
      await openCaption(t);
      expect(find.text("What's this video about?"), findsOneWidget);
      expect(find.byKey(const ValueKey('video_about_text')), findsNothing);
      expect(sentTo('GET', '/api/v1/challenges/5/about'), isEmpty,
          reason: 'nothing is asked until somebody wants to know');

      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      final q = sentTo('GET', '/api/v1/challenges/5/about');
      expect(q, hasLength(1));
      expect(Uri.parse(q.single.$2).queryParameters, isEmpty);
      expect(find.text('Someone juggles five balls on a beach.'),
          findsOneWidget);
      expect(find.textContaining('Written by AI'), findsOneWidget);
      expect(find.textContaining('can be wrong'), findsOneWidget);

      // Closed and opened again: no second question.
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      expect(sentTo('GET', '/api/v1/challenges/5/about'), hasLength(1));
      expect(find.byKey(const ValueKey('video_about_text')), findsOneWidget);
    });

    testWidgets('on the answer in a battle it asks about THAT video, and '
        'says whose', (t) async {
      aboutReply = {'about': 'A man juggles knives.', 'looked': true,
        'from': 'shown'};
      await openCaption(t, responseId: '77');
      expect(find.text("What's leo's answer about?"), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      final q = sentTo('GET', '/api/v1/challenges/5/about');
      expect(Uri.parse(q.single.$2).queryParameters['response'], '77');
      expect(find.text('A man juggles knives.'), findsOneWidget);
      expect(find.textContaining('what happens in the video'), findsOneWidget);
    });

    testWidgets('a video not looked at yet says so, rather than that there '
        'is nothing to say', (t) async {
      aboutReply = {'about': '', 'topics': [], 'looked': false};
      await openCaption(t);
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      expect(find.text('This video is still being looked at.'),
          findsOneWidget);
      expect(find.text('Nothing to say about this one.'), findsNothing);
    });

    testWidgets('no sentence but topics: shows the topics', (t) async {
      aboutReply = {'about': '', 'topics': ['cooking', 'pasta'],
        'looked': true};
      await openCaption(t);
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      expect(find.text('Looks like: cooking, pasta.'), findsOneWidget);
    });

    testWidgets('a failed read says so and can be tried again', (t) async {
      aboutCode = 500;
      await openCaption(t);
      await t.tap(find.byKey(const ValueKey('video_about_ask')));
      await settle(t);
      expect(find.text("Couldn't load that. Tap to try again."),
          findsOneWidget);

      aboutCode = 200;
      aboutReply = {'about': 'Someone juggles.', 'looked': true,
        'from': 'said'};
      await t.tap(find.byKey(const ValueKey('video_about_retry')));
      await settle(t);
      expect(find.text('Someone juggles.'), findsOneWidget);
      expect(sentTo('GET', '/api/v1/challenges/5/about'), hasLength(2));
    });

    testWidgets('a caption with no video to ask about offers nothing', (
      t,
    ) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CommentSheetCaption(username: 'maya', caption: 'Hello'),
          ),
        ),
      );
      expect(find.text('Hello'), findsOneWidget);
      expect(find.byKey(const ValueKey('video_about_ask')), findsNothing);
    });
  });
}
