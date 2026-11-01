// The steps of signing in after the first: the two-step code, and signing
// in or up with Google or Apple. Through the real screens and the real
// sign-in state, against a stand-in server that answers the way the real
// one does (two_step_signin.go and social_signin.go on the server), and a
// stand-in for the phone's own Google and Apple sheets.
//
// Every test checks for something that IS there (a screen, a request, a
// sign-in), not only for what is gone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/social_auth.dart';

/// What the stand-in server was sent, by address.
late Map<String, List<Map<String, dynamic>>> sent;

/// What the server answers, by address, in order; when a list runs out,
/// the last answer repeats.
late Map<String, List<http.Response>> answers;

http.Response jsonAnswer(Object body, int status) => http.Response(
    json.encode(body), status,
    headers: {'content-type': 'application/json'});

final signedIn = jsonAnswer({
  'token': 'tok-in',
  'user': {'id': '7', 'username': 'maya', 'followingList': <String>[]},
}, 200);

final newAccount = jsonAnswer({
  'token': 'tok-new',
  'user': {'id': '8', 'username': 'maya_g', 'followingList': <String>[]},
}, 201);

void fakeServer() {
  sent = {};
  answers = {};
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (req.body.isNotEmpty) {
      sent.putIfAbsent(path, () => []).add(
          json.decode(req.body) as Map<String, dynamic>);
    }
    if (path.endsWith('/signup/available')) {
      return jsonAnswer({'valid': true, 'available': true, 'reason': ''}, 200);
    }
    for (final e in answers.entries) {
      if (path.endsWith(e.key)) {
        return e.value.length > 1 ? e.value.removeAt(0) : e.value.first;
      }
    }
    if (path.endsWith('/api/v1/users')) return http.Response('[]', 200);
    return http.Response('{}', 200);
  }));
}

/// The phone's Google and Apple sheets, stood in for.
class FakeSocialAuth implements SocialAuth {
  Set<SocialProvider> offered = {SocialProvider.google, SocialProvider.apple};

  /// What the sheet gives back; null is the person closing it.
  SocialCredential? credential =
      const SocialCredential(idToken: 'google-says-maya', fullName: 'Maya G');
  Object? failure;
  final asked = <SocialProvider>[];

  @override
  bool offers(SocialProvider provider) => offered.contains(provider);

  @override
  Future<SocialCredential?> signIn(SocialProvider provider) async {
    asked.add(provider);
    if (failure != null) throw failure!;
    return credential;
  }
}

late FakeSocialAuth sheets;

/// The app's front door, routed the way main.dart routes it.
Future<AuthProvider> openApp(WidgetTester t) async {
  FlutterSecureStorage.setMockInitialValues({});
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(430, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final auth = AuthProvider();
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider(create: (_) => DataProvider()),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: Consumer<AuthProvider>(
      builder: (_, a, _) => MaterialApp(
        home: a.isAuthenticated
            ? Text(a.needsOnboarding ? 'welcome steps' : 'the app',
                key: const ValueKey('signed_in'))
            : const LoginScreen(),
      ),
    ),
  ));
  await settle(t);
  return auth;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await settle(t);
}

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Signing in starts the app's activity reporter, which keeps a timer; a
/// test that signed in stops it, as signing out does.
void stopReporter() => EventTracker.instance.dispose();

Future<void> signInWithPassword(WidgetTester t) async {
  await t.enterText(byKey('login_username'), 'maya');
  await t.enterText(byKey('login_password'), 'sunset42');
  await tapKey(t, 'login_submit');
}

void main() {
  setUp(() {
    fakeServer();
    sheets = FakeSocialAuth();
    SocialAuth.instance = sheets;
  });
  tearDown(() {
    ApiService.useClient(http.Client());
    SocialAuth.instance = PlatformSocialAuth();
  });

  group('the two-step code', () {
    setUp(() {
      answers['/login'] = [
        jsonAnswer({
          'twoFactorRequired': true,
          'ticket': 'ticket-1',
          'error': 'Enter the 6-digit code from your authenticator app.',
        }, 401),
      ];
    });

    testWidgets('the password alone opens the code screen; a wrong code is '
        'said under the boxes; the right one signs in', (t) async {
      final auth = await openApp(t);
      await signInWithPassword(t);
      expect(byKey('two_step_screen'), findsOneWidget);
      expect(auth.isAuthenticated, isFalse);

      answers['/login/2fa'] = [
        jsonAnswer({'field': 'code', 'error': "That code isn't right."}, 401),
        signedIn,
      ];
      await t.enterText(byKey('two_step_code'), '111111');
      await settle(t); // six digits: it checks without a tap
      expect(t.widget<Text>(byKey('two_step_code_error')).data,
          "That code isn't right.");
      expect(sent['/login/2fa']!.single, {'ticket': 'ticket-1', 'code': '111111'});

      await t.enterText(byKey('two_step_code'), '482913');
      await settle(t);
      expect(sent['/login/2fa']!.last['code'], '482913');
      expect(auth.isAuthenticated, isTrue);
      expect(find.text('the app'), findsOneWidget);
      expect(byKey('two_step_screen'), findsNothing, reason: 'closed');
      stopReporter();
    });

    testWidgets('a recovery code works too', (t) async {
      final auth = await openApp(t);
      await signInWithPassword(t);
      answers['/login/2fa'] = [signedIn];
      await tapKey(t, 'two_step_switch');
      await t.enterText(byKey('two_step_recovery'), 'ABCDE-FGHIJ');
      await tapKey(t, 'two_step_verify');
      expect(sent['/login/2fa']!.single, {'ticket': 'ticket-1', 'code': 'ABCDE-FGHIJ'});
      expect(auth.isAuthenticated, isTrue);
      stopReporter();
    });

    testWidgets('a ticket that ran out says so, and leads back to sign in',
        (t) async {
      await openApp(t);
      await signInWithPassword(t);
      answers['/login/2fa'] = [
        jsonAnswer({'error': 'That took too long. Sign in again.', 'expired': true}, 401),
      ];
      await t.enterText(byKey('two_step_code'), '482913');
      await settle(t);
      expect(find.text('That took too long. Sign in again.'), findsOneWidget);
      await tapKey(t, 'two_step_start_again');
      expect(byKey('login_submit'), findsOneWidget);
      expect(byKey('two_step_screen'), findsNothing);
    });

    testWidgets('an account waiting to be deleted is asked only after the '
        'code, and kept without the code typed again', (t) async {
      final auth = await openApp(t);
      await signInWithPassword(t);
      answers['/login/2fa'] = [
        jsonAnswer({
          'error': 'This account will be deleted on 30 November 2026. Keep it to sign in.',
          'deletionPending': true,
          'deleteOn': '2026-11-30T10:00:00Z',
          'ticket': 'ticket-verified',
        }, 409),
        signedIn,
      ];
      await t.enterText(byKey('two_step_code'), '482913');
      await settle(t);
      expect(byKey('keep_account_dialog'), findsOneWidget);
      expect(find.textContaining('30 November 2026'), findsOneWidget);
      await tapKey(t, 'keep_account');
      expect(sent['/login/2fa']!.last,
          {'ticket': 'ticket-verified', 'code': '', 'keepAccount': true});
      expect(auth.isAuthenticated, isTrue);
      stopReporter();
    });
  });

  group('which buttons a build shows', () {
    bool offers(TargetPlatform phone, SocialProvider p,
            {String web = '',
            String ios = '',
            bool appleOnIos = false,
            String service = ''}) =>
        PlatformSocialAuth.offersOn(phone, p,
            googleServerClientId: web,
            googleIosClientId: ios,
            appleOnIos: appleOnIos,
            appleServiceId: service);
    const android = TargetPlatform.android, iPhone = TargetPlatform.iOS;
    const google = SocialProvider.google, apple = SocialProvider.apple;

    test('without the settings, none: what every build has today', () {
      for (final phone in [android, iPhone]) {
        expect(offers(phone, google), isFalse);
        expect(offers(phone, apple), isFalse);
      }
      // This test run is such a build.
      expect(PlatformSocialAuth().offers(google), isFalse);
      expect(PlatformSocialAuth().offers(apple), isFalse);
    });

    test('Google: the server id on Android; the iPhone needs its own too', () {
      expect(offers(android, google, web: 'w'), isTrue);
      expect(offers(iPhone, google, web: 'w'), isFalse);
      expect(offers(iPhone, google, web: 'w', ios: 'i'), isTrue);
      expect(offers(android, google, ios: 'i'), isFalse);
    });

    test("Apple: the iPhone's own sheet when switched on; on Android, the "
        'Services ID', () {
      expect(offers(iPhone, apple, appleOnIos: true), isTrue);
      expect(offers(android, apple, appleOnIos: true), isFalse);
      expect(offers(android, apple, service: 's'), isTrue);
      expect(offers(iPhone, apple, service: 's'), isFalse);
    });
  });

  group('Google and Apple', () {
    testWidgets('the buttons show what this build offers, and nothing when '
        'it offers neither', (t) async {
      await openApp(t);
      expect(byKey('social_google'), findsOneWidget);
      expect(byKey('social_apple'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);

      // Only one of them: only its button.
      sheets.offered = {SocialProvider.google};
      await t.pumpWidget(const SizedBox()); // a fresh sign-in screen
      await openApp(t);
      expect(byKey('social_google'), findsOneWidget);
      expect(byKey('social_apple'), findsNothing);

      sheets.offered = {};
      await t.pumpWidget(const SizedBox());
      await openApp(t);
      expect(byKey('social_google'), findsNothing);
      expect(byKey('social_apple'), findsNothing);
      expect(byKey('login_create_account'), findsOneWidget);
    });

    testWidgets('somebody who has been here before is signed straight in',
        (t) async {
      final auth = await openApp(t);
      answers['/auth/google'] = [signedIn];
      await tapKey(t, 'social_google');
      expect(sheets.asked, [SocialProvider.google]);
      expect(sent['/auth/google']!.single, {'idToken': 'google-says-maya'},
          reason: "Google's token goes to the server, and no name: Google "
              'puts it in the token');
      expect(auth.isAuthenticated, isTrue);
      expect(find.text('the app'), findsOneWidget);
      stopReporter();
    });

    testWidgets('somebody new picks a username and a birthday, and the '
        'account is made and signed in', (t) async {
      final auth = await openApp(t);
      answers['/auth/google'] = [
        jsonAnswer({
          'needsSignup': true,
          'signupTicket': 'signup-1',
          'email': 'maya.g@gmail.com',
          'fullName': 'Maya G',
          'suggestedUsername': 'maya_g',
        }, 200),
      ];
      answers['/auth/social/signup'] = [newAccount];
      await tapKey(t, 'social_google');

      expect(byKey('finish_signup'), findsOneWidget);
      expect(find.textContaining('maya.g@gmail.com', findRichText: true),
          findsOneWidget);
      expect(t.widget<TextField>(byKey('finish_username')).controller!.text,
          'maya_g');
      expect(t.widget<TextField>(byKey('finish_full_name')).controller!.text,
          'Maya G');
      await t.pump(const Duration(milliseconds: 500)); // the live check
      await settle(t);
      expect(byKey('username_free'), findsOneWidget);

      await tapKey(t, 'signup_birthday');
      await t.tap(find.text('OK'));
      await settle(t);
      await tapKey(t, 'signup_terms');
      await tapKey(t, 'finish_submit');

      final body = sent['/auth/social/signup']!.single;
      expect(body['signupTicket'], 'signup-1');
      expect(body['username'], 'maya_g');
      expect(body['fullName'], 'Maya G');
      expect(body['acceptTerms'], isTrue);
      expect(body['birthDate'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      expect(auth.isAuthenticated, isTrue);
      expect(find.text('welcome steps'), findsOneWidget,
          reason: 'a new account goes on to the welcome steps');
      stopReporter();
    });

    testWidgets("Apple's name goes to the server, since Apple keeps it out "
        'of its token', (t) async {
      await openApp(t);
      sheets.credential =
          const SocialCredential(idToken: 'apple-says-maya', fullName: 'Maya A');
      answers['/auth/apple'] = [signedIn];
      await tapKey(t, 'social_apple');
      expect(sent['/auth/apple']!.single,
          {'idToken': 'apple-says-maya', 'fullName': 'Maya A'});
      stopReporter();
    });

    testWidgets('an email already on a password account is said plainly, and '
        'nothing is joined', (t) async {
      final auth = await openApp(t);
      answers['/auth/google'] = [
        jsonAnswer({
          'error': 'An account already uses this email. Sign in with your '
              'username or email and your password.',
          'emailTaken': true,
        }, 409),
      ];
      await tapKey(t, 'social_google');
      expect(find.textContaining('An account already uses this email'),
          findsOneWidget);
      expect(auth.isAuthenticated, isFalse);
      expect(byKey('finish_signup'), findsNothing);
    });

    testWidgets('closing the sheet sends nothing and says nothing; a sheet '
        'that fails says so', (t) async {
      await openApp(t);
      sheets.credential = null;
      await tapKey(t, 'social_google');
      expect(sheets.asked, [SocialProvider.google]);
      expect(sent['/auth/google'], isNull);
      expect(byKey('auth_error'), findsNothing);

      sheets.failure =
          const SocialAuthFailure("Couldn't sign in with Google. Please try again.");
      await tapKey(t, 'social_google');
      expect(find.text("Couldn't sign in with Google. Please try again."),
          findsOneWidget);

      // A failure nobody planned for (a plugin error): said all the same,
      // and the button works again instead of spinning.
      sheets.failure = Exception('the plugin broke');
      await tapKey(t, 'social_apple');
      expect(find.text("Couldn't sign in with Apple. Please try again."),
          findsOneWidget);
      expect(t.widget<OutlinedButton>(byKey('social_apple')).onPressed,
          isNotNull);
    });

    testWidgets('an account waiting to be deleted is asked, and kept without '
        'the sheet opened again', (t) async {
      final auth = await openApp(t);
      answers['/auth/google'] = [
        jsonAnswer({
          'error': 'This account will be deleted on 30 November 2026. Keep '
              'it to sign in.',
          'deletionPending': true,
          'deleteOn': '2026-11-30T10:00:00Z',
          'ticket': 'ticket-verified',
        }, 409),
      ];
      answers['/login/2fa'] = [signedIn];
      await tapKey(t, 'social_google');
      expect(byKey('keep_account_dialog'), findsOneWidget);
      expect(find.textContaining('30 November 2026'), findsOneWidget);
      await tapKey(t, 'keep_account');
      expect(sent['/login/2fa']!.single,
          {'ticket': 'ticket-verified', 'code': '', 'keepAccount': true});
      expect(sheets.asked, [SocialProvider.google], reason: 'opened once');
      expect(auth.isAuthenticated, isTrue);
      expect(find.text('the app'), findsOneWidget);
      stopReporter();
    });

    testWidgets('not set up on the server: said, with the other way in',
        (t) async {
      await openApp(t);
      answers['/auth/google'] = [
        jsonAnswer({
          'error': "Signing in with Google isn't set up yet. Sign in with your "
              'username or email.',
          'unavailable': true,
        }, 503),
      ];
      await tapKey(t, 'social_google');
      expect(find.textContaining("isn't set up yet"), findsOneWidget);
    });

    testWidgets('Google, then the two-step code, then signed in', (t) async {
      final auth = await openApp(t);
      answers['/auth/google'] = [
        jsonAnswer({'twoFactorRequired': true, 'ticket': 'ticket-g'}, 401),
      ];
      answers['/login/2fa'] = [signedIn];
      await tapKey(t, 'social_google');
      expect(byKey('two_step_screen'), findsOneWidget);
      await t.enterText(byKey('two_step_code'), '482913');
      await settle(t);
      expect(sent['/login/2fa']!.single['ticket'], 'ticket-g');
      expect(auth.isAuthenticated, isTrue);
      stopReporter();
    });

    testWidgets('from the sign-up page too, and the page closes once signed '
        'in', (t) async {
      final auth = await openApp(t);
      await tapKey(t, 'login_create_account');
      expect(find.text('Sign up with Google'), findsOneWidget);
      answers['/auth/google'] = [signedIn];
      await tapKey(t, 'social_google');
      expect(auth.isAuthenticated, isTrue);
      expect(find.text('the app'), findsOneWidget);
      expect(byKey('signup_submit'), findsNothing, reason: 'sign-up closed');
      stopReporter();
    });
  });
}
