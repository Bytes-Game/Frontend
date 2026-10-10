// The redesigned Search, Profile and shared parts.
//
// Every test here looks for something that IS on screen as well as for what
// was taken away, so a screen broken into showing nothing cannot pass by
// having nothing to find.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/challenge_metadata_page.dart';
import 'package:myapp/pages/create_page.dart';
import 'package:myapp/pages/edit_profile_page.dart';
import 'package:myapp/pages/notifications_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/search_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/device_gallery.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/explore_grid_cache.dart';
import 'package:myapp/services/reel_diagnostics.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/create_burst.dart';
import 'package:myapp/widgets/user_tile.dart';

import 'fake_gallery.dart';

UserModel person(String id, String name, {String bio = ''}) => UserModel(
  id: id,
  username: name,
  wins: 3,
  losses: 1,
  followersCount: 12,
  followingCount: 4,
  league: 'Silver',
  rating: 1080,
  bio: bio,
);

Map<String, dynamic> challenge(int id, int responses) => {
  'id': '$id',
  'creatorId': '9',
  'creatorUsername': 'leo',
  'videoUrl': 'https://x/$id.mp4',
  'prefix': 'Who can',
  'subject': 'dance better',
  'status': responses > 0 ? 'active' : 'open',
  'views': 1200,
  'createdAt': '2026-09-20T10:00:00Z',
  'responseCount': responses,
};

http.Response jsonBody(Object o) => http.Response.bytes(
  utf8.encode(json.encode(o)),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Whom the app asked the server to follow, in order.
late List<String> followed;

void fakeServer() {
  followed = [];
  ApiService.useClient(
    MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/follow')) {
        followed.add(
          (json.decode(req.body) as Map<String, dynamic>)['followingId']
              as String,
        );
        return jsonBody({'ok': true});
      }
      if (p.contains('/feed/explore')) {
        return jsonBody({
          'items': [
            for (var i = 1; i <= 6; i++)
              {'type': 'challenge', 'challenge': challenge(i, i % 2)},
          ],
        });
      }
      if (p.endsWith('/search/recent')) {
        return jsonBody({
          'recent': ['dance'],
        });
      }
      if (p.endsWith('/search/trending')) {
        return jsonBody({
          'trending': ['freestyle'],
        });
      }
      if (p.endsWith('/search')) {
        return jsonBody({
          'accounts': [
            {
              'id': '5',
              'username': 'maya',
              'fullName': 'Maya Singh',
              'league': 'Gold',
              'wins': 12,
              'losses': 4,
              'visibility': 'public',
            },
            {
              'id': '6',
              'username': 'leo_private',
              'league': 'Silver',
              'visibility': 'friends',
            },
          ],
          'battles': [challenge(1, 1)],
          'shorts': [challenge(2, 0)],
        });
      }
      if (p.endsWith('/followers')) {
        return jsonBody([
          {'id': '5', 'username': 'maya', 'fullName': 'Maya Singh'},
          {'id': '6', 'username': 'leo', 'fullName': ''},
        ]);
      }
      if (p.endsWith('/battles')) {
        return jsonBody({
          'summary': {
            'rating': 1080,
            'league': 'Silver',
            'wins': 3,
            'losses': 1,
            'counts': {'open': 1, 'live': 2, 'won': 3, 'lost': 1},
          },
          'battles': [],
        });
      }
      if (p.contains('/challenges')) return jsonBody([]);
      return jsonBody({});
    }),
  );
}

/// A phone-sized screen. The window itself, not only the drawing surface,
/// so the app's idea of the screen size (MediaQuery) matches it too.
void phone(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 120));
  }
}

Widget app(Widget home, {UserModel? me, List<String> following = const []}) {
  final dp = DataProvider()
    ..setUser(me ?? person('1', 'me'))
    ..setFollowing([...following]);
  EventTracker.instance.dispose();
  return ChangeNotifierProvider<DataProvider>.value(
    value: dp,
    child: MaterialApp(home: home),
  );
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    ReelDiagnostics.instance.debugReset();
    // Search keeps its grid between visits; each test starts without one.
    ExploreGridCache.instance.clear();
    fakeServer();
  });
  tearDown(() => ApiService.useClient(http.Client()));

  group('Search', () {
    testWidgets('opens straight onto videos; suggestions only while the bar '
        'is tapped, and Cancel goes back', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);

      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Search people, battles, shorts'), findsOneWidget);
      // Videos, and nothing above them.
      expect(find.text('Who can dance better'), findsWidgets);
      expect(find.text('Recent'), findsNothing);
      expect(find.text('Trending'), findsNothing);
      expect(find.text('Cancel'), findsNothing);

      // Tap into the bar: what you searched before, and nothing trending.
      await t.tap(find.byType(TextField));
      await settle(t);
      expect(find.text('Recent'), findsOneWidget);
      expect(find.text('dance'), findsOneWidget);
      expect(find.text('Trending'), findsNothing);
      expect(find.text('freestyle'), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);

      // Cancel: back to the videos.
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(find.text('Recent'), findsNothing);
      expect(find.text('Who can dance better'), findsWidgets);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('people are slim rows: name, league, a lock when private, '
        'and a Follow button that follows', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);

      await t.enterText(find.byType(TextField), 'may');
      await settle(t);

      expect(find.text('Top'), findsOneWidget);
      expect(find.text('Maya Singh'), findsOneWidget);
      expect(find.text('@maya · Gold'), findsOneWidget);
      // Leo's account is private; Maya's is not.
      expect(find.text('leo_private'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      // No boxes round people any more: no card holds the row.
      expect(
        find.ancestor(
          of: find.text('Maya Singh'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).borderRadius != null,
          ),
        ),
        findsNothing,
      );

      // Follow follows, and the button says so.
      expect(find.text('Follow'), findsNWidgets(2));
      await t.tap(find.text('Follow').first);
      await settle(t);
      expect(find.text('Following'), findsOneWidget);
      expect(followed, ['5']);

      await t.tap(find.byTooltip('Clear'));
      await settle(t);
      expect(find.text('Top'), findsNothing);

      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('the search bar\'s words sit centred, even under the app\'s '
        'big text-box padding', (t) async {
      final ctrl = TextEditingController();
      await t.pumpWidget(
        MaterialApp(
          // The app's own setting: 20 at the side, 16 above and below.
          theme: ThemeData(
            inputDecorationTheme: const InputDecorationTheme(
              filled: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 16,
              ),
            ),
          ),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ArenaSearchField(controller: ctrl, hint: 'Search chats'),
            ),
          ),
        ),
      );
      final field = t.getRect(find.byType(ArenaSearchField));
      final hint = t.getRect(find.text('Search chats'));
      expect(
        (hint.center.dy - field.center.dy).abs(),
        lessThan(2.5),
        reason: 'the words sit above or below the middle of the bar',
      );
      // Magnifier at 10 + 20 wide, then 6: the words start 36 in, not 56.
      expect(
        hint.left - field.left,
        closeTo(36, 3),
        reason: 'the theme\'s 20 pixels are pushing the words right',
      );
    });

    testWidgets('leaving the page opens no video on the way out', (t) async {
      await t.pumpWidget(app(const SearchPage()));
      await settle(t);
      // The grid is on screen and has had its turn at opening previews.
      expect(find.text('Who can dance better'), findsWidgets);
      final before = ReelDiagnostics.instance.debugPreviewOpened;

      // Closing the page closes every tile. None of them may hand the
      // preview to a neighbour that is itself about to close — and none may
      // rebuild while the framework is tearing them down, which a debug
      // build reports as an error and fails this test.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));

      expect(ReelDiagnostics.instance.debugPreviewOpened, before);
    });
  });

  group('Profile', () {
    testWidgets('your own: edit, share and settings are icons in the bar, '
        'and the old row of buttons is gone', (t) async {
      final me = person('1', 'me', bio: 'dancer');
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(app(ProfilePage(user: me, isEmbedded: false), me: me));
      await settle(t);

      expect(find.byTooltip('Edit profile'), findsOneWidget);
      expect(find.byTooltip('Share profile'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(find.text('Edit Profile'), findsNothing);
      expect(find.text('Share'), findsNothing);
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
      // What is left under the arena: stats and the bio.
      expect(find.text('Followers'), findsOneWidget);
      expect(find.text('dancer'), findsOneWidget);

      await t.tap(find.byTooltip('Edit profile'));
      await settle(t);
      expect(find.byType(EditProfilePage), findsOneWidget);
      // No buttons that only say "coming soon": the username says plainly
      // it can't be changed, and the picture really changes (see
      // profile_photos_test.dart).
      expect(find.byKey(const ValueKey('edit_username')), findsOneWidget);
      expect(find.text("Can't be changed"), findsOneWidget);
      expect(find.text('Change'), findsNothing);
      expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
      expect(find.byKey(const ValueKey('edit_photo')), findsOneWidget);
    });

    testWidgets('someone else\'s: follow, plus message and battle as icons', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        app(ProfilePage(user: person('5', 'maya'), isEmbedded: false)),
      );
      await settle(t);

      expect(find.text('Follow'), findsOneWidget);
      expect(find.byTooltip('Message'), findsOneWidget);
      expect(find.byTooltip('Challenge to a battle'), findsOneWidget);
      expect(find.byTooltip('Share profile'), findsOneWidget);
      expect(find.byTooltip('More'), findsOneWidget);
      // Not yours to edit.
      expect(find.byTooltip('Edit profile'), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
    });
  });

  group('Profile, continued', () {
    testWidgets('a private account you do not follow shows a lock, not its '
        'battles', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final private = UserModel(
        id: '6',
        username: 'leo_private',
        wins: 1,
        losses: 0,
        followersCount: 3,
        followingCount: 2,
        visibility: 'friends',
      );
      await t.pumpWidget(app(ProfilePage(user: private, isEmbedded: false)));
      await settle(t);

      expect(find.text('This account is private'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      // Still there: who they are, and the way to follow them.
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Followers'), findsOneWidget);
      // Not there: their tabs.
      expect(find.text('Shorts'), findsNothing);
    });

    testWidgets('the same account, once you follow it, shows its tabs', (
      t,
    ) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final private = UserModel(
        id: '6',
        username: 'leo_private',
        wins: 1,
        losses: 0,
        followersCount: 3,
        followingCount: 2,
        visibility: 'friends',
      );
      await t.pumpWidget(
        app(
          ProfilePage(user: private, isEmbedded: false),
          following: const ['6'],
        ),
      );
      await settle(t);

      expect(find.text('This account is private'), findsNothing);
      expect(find.text('Shorts'), findsOneWidget);
    });

    testWidgets('your own profile with no bio: "Add bio" beside the name '
        'opens the editor', (t) async {
      await t.binding.setSurfaceSize(const Size(400, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final me = person('1', 'me');
      await t.pumpWidget(app(ProfilePage(user: me, isEmbedded: false), me: me));
      await settle(t);

      // Up in the header, level with the name — not somewhere below.
      final name = t.getRect(find.text('me').first);
      final addBio = t.getRect(
        find
            .ancestor(
              of: find.text('Add bio'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(addBio.top - name.bottom, lessThan(60));
      expect(addBio.left, closeTo(name.left, 2));

      await t.tap(find.text('Add bio'));
      await settle(t);
      expect(find.byType(EditProfilePage), findsOneWidget);
    });
  });

  group('Create pop-out', () {
    Future<(CreateBurstHandle, List<CreateChoice>)> open(
      WidgetTester t, {
      bool fromHold = false,
      Offset anchor = const Offset(200, 560),
      Size? screen,
    }) async {
      if (screen != null) phone(t, screen);
      final picked = <CreateChoice>[];
      late CreateBurstHandle handle;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => handle = CreateBurst.show(
                    context,
                    anchor: anchor,
                    fromHold: fromHold,
                    onChoose: picked.add,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      return (handle, picked);
    }

    testWidgets('Record and Upload rise out of the +; tapping one picks it', (
      t,
    ) async {
      final (_, picked) = await open(t);
      expect(find.text('Record'), findsOneWidget);
      expect(find.text('Upload'), findsOneWidget);
      // Upload is up and to the right of the +, Record up and to the left.
      expect(t.getCenter(find.text('Upload')).dx, greaterThan(200));
      expect(t.getCenter(find.text('Record')).dx, lessThan(200));
      expect(t.getCenter(find.text('Record')).dy, lessThan(560));

      await t.tap(find.text('Upload'));
      await t.pumpAndSettle();
      expect(picked, [CreateChoice.upload]);
      expect(find.text('Record'), findsNothing, reason: 'it closes');
    });

    testWidgets('hold, slide onto Record, let go: picked in one movement', (
      t,
    ) async {
      final (handle, picked) = await open(t, fromHold: true);
      expect(find.text('Slide to choose'), findsOneWidget);
      final record = t.getCenter(find.byIcon(Icons.videocam_rounded));
      handle.pointerMoved(record);
      await t.pump();
      handle.pointerReleased(record);
      await t.pumpAndSettle();
      expect(picked, [CreateChoice.record]);
    });

    testWidgets('letting go on nothing keeps it open; the background closes '
        'it with no pick', (t) async {
      final (handle, picked) = await open(t, fromHold: true);
      handle.pointerReleased(const Offset(200, 300));
      await t.pumpAndSettle();
      expect(find.text('Record'), findsOneWidget, reason: 'still open');

      await t.tapAt(const Offset(30, 60));
      await t.pumpAndSettle();
      expect(find.text('Record'), findsNothing);
      expect(picked, isEmpty);
    });

    // Every choice, whole, inside a phone-width screen, and not on top of
    // each other.
    void bothOnScreen(WidgetTester t, double width) {
      final record = t.getRect(find.byIcon(Icons.videocam_rounded));
      final upload = t.getRect(find.byIcon(Icons.video_library_rounded));
      final photo = find.byIcon(Icons.image_rounded);
      final all = [
        record,
        upload,
        if (photo.evaluate().isNotEmpty) t.getRect(photo),
      ];
      for (final r in all) {
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(width));
        expect(r.top, greaterThanOrEqualTo(0));
      }
      for (var i = 0; i < all.length; i++) {
        for (var j = i + 1; j < all.length; j++) {
          expect(
            (all[i].center - all[j].center).distance,
            greaterThan(66),
            reason: 'the circles are 66 across; closer and they overlap',
          );
        }
      }
    }

    testWidgets('from a button at the right edge it swings left, so Upload '
        'is not pushed off the screen', (t) async {
      final (handle, picked) = await open(
        t,
        anchor: const Offset(352, 420),
        screen: const Size(390, 844),
      );
      bothOnScreen(t, 390);
      // Still steerable where it now is.
      final upload = t.getCenter(find.byIcon(Icons.video_library_rounded));
      handle.pointerMoved(upload);
      await t.pump();
      handle.pointerReleased(upload);
      await t.pumpAndSettle();
      expect(picked, [CreateChoice.upload]);
    });

    testWidgets('from a button near the top it opens downwards', (t) async {
      await open(
        t,
        anchor: const Offset(195, 110),
        screen: const Size(390, 844),
      );
      bothOnScreen(t, 390);
      expect(t.getCenter(find.text('Record')).dy, greaterThan(110));
      expect(t.getCenter(find.text('Upload')).dy, greaterThan(110));
      // Mirrored, so Record is still the one on the left.
      expect(
        t.getCenter(find.text('Record')).dx,
        lessThan(t.getCenter(find.text('Upload')).dx),
      );
      expect(
        t.getCenter(find.text('Create a challenge')).dy,
        greaterThan(t.getCenter(find.text('Record')).dy),
        reason: 'the line saying what to do goes below, on the open side',
      );
    });

    testWidgets('a profile\'s Battle button opens the same create page as '
        'the +: the phone\'s photos and videos, and the camera', (t) async {
      DeviceGallery.instance = FakeGallery()..access = GalleryAccess.denied;
      addTearDown(() => DeviceGallery.instance = PhoneGallery());
      phone(t, const Size(390, 900));
      await t.pumpWidget(
        app(ProfilePage(user: person('5', 'maya'), isEmbedded: false)),
      );
      await settle(t);

      await t.tap(find.byTooltip('Challenge to a battle'));
      await settle(t);

      expect(find.byType(CreatePage), findsOneWidget);
      expect(find.byKey(const ValueKey('create_camera')), findsOneWidget);
      // No menu of choices any more.
      expect(find.text('Start a battle'), findsNothing);
      expect(find.text('Upload'), findsNothing);

      await t.tap(find.byKey(const ValueKey('create_close')));
      await settle(t);
      expect(find.byType(CreatePage), findsNothing);
      expect(find.byTooltip('Challenge to a battle'), findsOneWidget);
    });

    test('the + button and Battle both open the create page, and the old '
        'chooser page is gone', () {
      String code(String path) => File(path)
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        code('lib/pages/profile_page.dart'),
        contains("CreateFlow.open(context, from: 'profile_battle')"),
      );
      final shell = code('lib/screens/main_shell.dart');
      expect(
        shell,
        contains("CreateFlow.open(context, from: 'create_button')"),
      );
      expect(shell, isNot(contains('CreateBurst')));
      expect(File('lib/pages/create_challenge_page.dart').existsSync(), false);
    });
  });

  group('Challenge details', () {
    // No one signed in, so the page does not start uploading the clip in
    // the background; nothing here is about the upload.
    late DataProvider detailsDp;
    Future<void> openDetails(WidgetTester t) async {
      phone(t, const Size(400, 1600));
      detailsDp = DataProvider();
      await t.pumpWidget(
        ChangeNotifierProvider<DataProvider>.value(
          value: detailsDp,
          child: const MaterialApp(
            home: ChallengeMetadataPage(processedSourcePath: '/tmp/clip.mp4'),
          ),
        ),
      );
      await settle(t);
    }

    Finder onCard(String text) => find.descendant(
      of: find.byType(TiltCard),
      matching: find.text(text),
    );

    testWidgets('the card at the top writes the challenge as you type it', (
      t,
    ) async {
      await openDetails(t);
      expect(onCard('YOUR CHALLENGE'), findsOneWidget);
      expect(onCard('Who is better at'), findsOneWidget);
      expect(onCard('your subject?'), findsOneWidget);

      await t.enterText(find.byType(TextFormField).at(1), 'dancing');
      await settle(t);
      expect(onCard('dancing?'), findsOneWidget);
      expect(onCard('your subject?'), findsNothing);
    });

    testWidgets('one tap on a common opening puts it in the field and on the '
        'card', (t) async {
      await openDetails(t);
      expect(onCard('Who is the best at'), findsNothing);
      await t.ensureVisible(find.text('Who is the best at'));
      await settle(t);
      await t.tap(find.text('Who is the best at'));
      await settle(t);
      expect(onCard('Who is the best at'), findsOneWidget);
      expect(
        t.widget<TextFormField>(find.byType(TextFormField).first).controller!
            .text,
        'Who is the best at',
      );
    });

    testWidgets('who can see it and how long it runs are big taps, and the '
        'card follows them', (t) async {
      await openDetails(t);
      expect(onCard('Public'), findsOneWidget);
      expect(onCard('7-day battle'), findsOneWidget);

      await t.tap(find.text('Only friends'));
      await t.tap(find.text('14'));
      await settle(t);
      expect(onCard('Only friends'), findsOneWidget);
      expect(onCard('14-day battle'), findsOneWidget);
      expect(onCard('7-day battle'), findsNothing);
    });

    testWidgets('Only friends: all of them, or some chosen by name', (
      t,
    ) async {
      await openDetails(t);
      // Signed in only now: signed in from the start, the page begins
      // sending the video, which a test has no way to finish.
      detailsDp.setUser(person('1', 'me'));
      EventTracker.instance.dispose();
      expect(find.text('All friends'), findsNothing,
          reason: 'only once Only friends is picked');
      await t.tap(find.text('Only friends'));
      await settle(t);
      expect(find.text('All friends'), findsOneWidget);
      expect(find.text('Choose friends'), findsOneWidget);

      await t.ensureVisible(find.byKey(const ValueKey('friends_choose')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('friends_choose')));
      await settle(t);
      // Your followers, to tick.
      expect(find.byKey(const ValueKey('friend_5')), findsOneWidget);
      expect(find.byKey(const ValueKey('friend_6')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('friend_5')));
      await settle(t);
      expect(find.text('Done · 1 friend'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('friends_done')));
      await settle(t);

      expect(find.text('Only @maya'), findsOneWidget);
      expect(onCard('1 friend'), findsOneWidget);
      expect(
        find.textContaining('Only these friends see it'),
        findsOneWidget,
      );

      // Back to all of them.
      await t.tap(find.byKey(const ValueKey('friends_all')));
      await settle(t);
      expect(find.text('Only @maya'), findsNothing);
      expect(onCard('Only friends'), findsOneWidget);
    });

    test('the chosen friends reach the server on both ways of posting', () {
      final code = File('lib/services/upload_job_manager.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      // A video prepared while typing, a video sent at Post, and a photo.
      expect(
        RegExp(r'createChallenge\([^;]*visibleTo: meta\.visibleTo,')
            .allMatches(code)
            .length,
        3,
      );
      final page = File('lib/pages/challenge_metadata_page.dart')
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(page, contains("visibleTo: _visibility == 'friends'"));
    });

    testWidgets('Post is pinned to the bottom, whatever is scrolled', (
      t,
    ) async {
      await openDetails(t);
      final post = t.getRect(find.text('Post Challenge'));
      expect(post.bottom, greaterThan(1600 - 80));
      await t.drag(find.byType(ListView).first, const Offset(0, -600));
      await settle(t);
      expect(t.getRect(find.text('Post Challenge')), post);
    });
  });

  group('shared parts', () {
    testWidgets('a person row shows their league and record, and Follow '
        'does something', (t) async {
      var toggled = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserTile(
              user: person('5', 'maya'),
              isFollowing: false,
              onFollowToggle: () => toggled++,
            ),
          ),
        ),
      );
      expect(find.text('maya'), findsOneWidget);
      expect(find.text('Silver'), findsOneWidget);
      expect(find.text('3W · 1L'), findsOneWidget);
      await t.tap(find.text('Follow'));
      expect(toggled, 1);
    });

    testWidgets('the look is quiet: the main button is one solid accent', (
      t,
    ) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PrimaryButton(label: 'Follow', onPressed: () {}),
            ),
          ),
        ),
      );
      final box = t.widget<Container>(
        find
            .ancestor(of: find.text('Follow'), matching: find.byType(Container))
            .first,
      );
      final deco = box.decoration! as BoxDecoration;
      expect(deco.color, kAccent);
      expect(deco.gradient, isNull, reason: 'no rainbow gradients');
      expect(deco.boxShadow, isNull, reason: 'no glow');
      expect(kAccent, const Color(0xFF0A84FF), reason: "Apple's blue");
    });

    testWidgets('an empty notifications page says what will appear', (t) async {
      await t.pumpWidget(app(const NotificationsPage()));
      await settle(t);
      expect(find.text('Nothing yet'), findsOneWidget);
      expect(find.textContaining('challenges you'), findsOneWidget);
    });
  });
}
