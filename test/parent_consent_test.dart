// A parent's consent for a young person, through the real screens and the
// real sign-in state, against a stand-in server. And the country the phone
// sends with every request.
//
// Every test checks for something that IS there (a page, a request, a
// message), not only for what is gone.

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
import 'package:myapp/screens/parent_consent_screen.dart';
import 'package:myapp/screens/signup_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/social_auth.dart';

/// What the stand-in server was sent, by address; and the headers of every
/// request.
late Map<String, List<Map<String, dynamic>>> sent;
late List<Map<String, String>> headersSeen;

/// What the server says the ages are where this phone is.
late Map<String, dynamic> rules;

/// The parent has agreed: the account exists, and signing in works.
late bool parentAgreed;

/// The parent said no.
late bool parentDeclined;

/// What the server answers the next "send the email again", if not "sent".
http.Response? parentEmailAnswer;

/// Google says this is somebody new: the account still needs a username
/// and a birthday.
late bool newWithGoogle;

int tickets = 0;

http.Response jsonAnswer(Map<String, dynamic> body, int status) =>
    http.Response(
      json.encode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, dynamic> waitingBody(String parent, {bool forSignIn = false}) {
  tickets++;
  final words = parentDeclined
      ? 'Your parent or guardian said no, so no account was made.'
      : 'Waiting for your parent or guardian to say yes. We emailed them '
            'at $parent.';
  return {
    'parentConsentPending': true,
    'parentEmail': parent,
    'ticket': 'ticket-$tickets',
    'message': words,
    if (parentDeclined) 'declined': true,
    if (forSignIn) 'error': words,
  };
}

const signedInBody = {
  'token': 'tok-teen',
  'user': {'id': '61', 'username': 'teen_k', 'followingList': <String>[]},
};

void fakeServer() {
  sent = {};
  headersSeen = [];
  rules = {
    'country': 'IN',
    'source': 'network',
    'minAge': 13,
    'parentConsentAge': 18,
  };
  parentAgreed = false;
  parentDeclined = false;
  parentEmailAnswer = null;
  newWithGoogle = false;
  tickets = 0;
  ApiService.clearAuth();
  ApiService.useClient(
    MockClient((req) async {
      final path = req.url.path;
      headersSeen.add(req.headers);
      if (req.body.isNotEmpty) {
        sent
            .putIfAbsent(path, () => [])
            .add(json.decode(req.body) as Map<String, dynamic>);
      }
      if (path.endsWith('/signup/rules')) return jsonAnswer(rules, 200);
      if (path.endsWith('/signup/available')) {
        return jsonAnswer({
          'valid': true,
          'available': true,
          'reason': '',
        }, 200);
      }
      if (path.endsWith('/signup/parent')) {
        final body = json.decode(req.body) as Map<String, dynamic>;
        if (body['cancel'] == true) return jsonAnswer({'cancelled': true}, 200);
        final again = parentEmailAnswer;
        if (again != null) return again;
        final to = body['parentEmail'] as String?;
        return jsonAnswer(
          waitingBody(to == null ? 'p•••@example.com' : 'm•••@example.com'),
          200,
        );
      }
      if (path.endsWith('/signup') || path.endsWith('/auth/social/signup')) {
        final body = json.decode(req.body) as Map<String, dynamic>;
        if (body['parentEmail'] != null) {
          return jsonAnswer(waitingBody('p•••@example.com'), 202);
        }
        return jsonAnswer({...signedInBody, 'allUsers': []}, 201);
      }
      if (path.endsWith('/auth/google') && newWithGoogle) {
        return jsonAnswer({
          'needsSignup': true,
          'signupTicket': 'signup-1',
          'email': 'teen.g@gmail.com',
          'fullName': 'Teen G',
          'suggestedUsername': 'teen_g',
        }, 200);
      }
      if (path.endsWith('/login') || path.endsWith('/auth/google')) {
        if (parentAgreed) return jsonAnswer(signedInBody, 200);
        return jsonAnswer(
          waitingBody('p•••@example.com', forSignIn: true),
          403,
        );
      }
      if (path.endsWith('/api/v1/users')) return http.Response('[]', 200);
      return http.Response('{}', 200);
    }),
  );
}

/// The app's front door, routed the way main.dart routes it.
Future<AuthProvider> openApp(WidgetTester t, {Widget? page}) async {
  FlutterSecureStorage.setMockInitialValues({});
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(430, 1700));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final auth = AuthProvider();
  await t.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => DataProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<AuthProvider>(
        builder: (_, a, _) => MaterialApp(
          home: a.isAuthenticated
              ? Text(
                  a.needsOnboarding ? 'welcome steps' : 'the app',
                  key: const ValueKey('signed_in'),
                )
              : (page ?? const LoginScreen()),
        ),
      ),
    ),
  );
  await settle(t);
  return auth;
}

void stopReporter() => EventTracker.instance.dispose();

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder byKey(String key) => find.byKey(ValueKey(key));

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(byKey(key));
  await t.tap(byKey(key));
  await settle(t);
}

/// Picks a birthday in the calendar. An adult's is what it opens on. A
/// young person's is the 15th of the month after: the calendar opens 18
/// years back, on the first of this month, so the month after it is
/// always less than 18 years ago.
Future<void> pickBirthday(WidgetTester t, {required bool young}) async {
  await tapKey(t, 'signup_birthday');
  if (young) {
    await t.tap(find.byTooltip('Next month'));
    await settle(t);
    await t.tap(find.text('15').last);
    await settle(t);
  }
  await t.tap(find.text('OK'));
  await settle(t);
}

/// Fills in the sign-up page: every box but a parent's email.
Future<void> fillSignup(WidgetTester t, {required bool young}) async {
  await t.enterText(byKey('signup_full_name'), 'Teen K');
  await t.enterText(byKey('signup_username'), 'teen_k');
  await t.pump(const Duration(milliseconds: 500)); // the live check
  await settle(t);
  await t.enterText(byKey('signup_email'), 'Teen@Example.com');
  await pickBirthday(t, young: young);
  await t.enterText(byKey('signup_password'), 'Sunset42!');
  await settle(t);
  await tapKey(t, 'signup_terms');
}

bool enabled(WidgetTester t, String key) {
  final button = find.descendant(
    of: byKey(key),
    matching: find.byType(FilledButton),
  );
  return t.widget<FilledButton>(button).onPressed != null;
}

/// The phone's Google sheet, stood in for.
class FakeSheets implements SocialAuth {
  int asked = 0;

  @override
  bool offers(SocialProvider provider) => provider == SocialProvider.google;

  @override
  Future<SocialCredential?> signIn(SocialProvider provider) async {
    asked++;
    return const SocialCredential(idToken: 'google-says-teen');
  }
}

void main() {
  setUp(fakeServer);
  tearDown(() {
    ApiService.useClient(http.Client());
    ApiService.deviceCountryForTest = null;
    SocialAuth.instance = PlatformSocialAuth();
  });

  testWidgets('an adult is never asked for a parent, and none is sent', (
    t,
  ) async {
    final auth = await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t, young: false);

    expect(byKey('signup_parent_email'), findsNothing);
    expect(find.text('Create account'), findsOneWidget);
    expect(enabled(t, 'signup_submit'), isTrue);
    await tapKey(t, 'signup_submit');

    expect(sent['/signup']!.single.containsKey('parentEmail'), isFalse);
    expect(auth.isAuthenticated, isTrue);
    expect(find.text('welcome steps'), findsOneWidget);
    expect(find.byType(ParentConsentScreen), findsNothing);
    stopReporter();
  });

  testWidgets('somebody under 18 names a parent; no account is made; the '
      'app waits with them and signs in once the parent agrees', (t) async {
    final auth = await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t, young: true);

    // The box for a parent appears, and nothing goes until it is good.
    expect(byKey('signup_parent_email'), findsOneWidget);
    expect(find.textContaining("You're under 18"), findsOneWidget);
    expect(find.text('Ask my parent or guardian'), findsOneWidget);
    expect(
      enabled(t, 'signup_submit'),
      isFalse,
      reason: 'no parent has been named',
    );

    await t.enterText(byKey('signup_parent_email'), 'teen@example.com');
    await settle(t);
    expect(
      find.text("Use your parent's or guardian's own email, not yours."),
      findsOneWidget,
    );
    expect(enabled(t, 'signup_submit'), isFalse);

    await t.enterText(byKey('signup_parent_email'), 'not an address');
    await settle(t);
    expect(
      find.text("That doesn't look like an email address."),
      findsOneWidget,
    );
    expect(enabled(t, 'signup_submit'), isFalse);

    await t.enterText(byKey('signup_parent_email'), ' Parent@Example.com ');
    await settle(t);
    expect(enabled(t, 'signup_submit'), isTrue);
    await tapKey(t, 'signup_submit');

    // What went to the server, and what did not happen.
    final body = sent['/signup']!.single;
    expect(body['parentEmail'], 'parent@example.com');
    expect(body['username'], 'teen_k');
    expect(
      auth.isAuthenticated,
      isFalse,
      reason: 'no account exists until the parent agrees',
    );
    expect(ApiService.authToken, isNull);

    // The page that waits with them.
    expect(find.byType(ParentConsentScreen), findsOneWidget);
    expect(find.byType(SignupScreen), findsNothing);
    expect(find.text('Ask your parent or guardian'), findsOneWidget);
    expect(
      find.textContaining('p•••@example.com', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('7 days'), findsOneWidget);

    // "They said yes" before they did: still waiting, said kindly.
    await tapKey(t, 'parent_wait_check');
    final tried = sent['/login']!.single;
    expect(tried['username'], 'teen_k');
    expect(tried['password'], 'Sunset42!');
    expect(byKey('parent_wait_info'), findsOneWidget);
    expect(find.textContaining("haven't answered yet"), findsOneWidget);
    expect(auth.isAuthenticated, isFalse);

    // Send it again: with the newest ticket the server gave.
    await tapKey(t, 'parent_wait_resend');
    expect(sent['/signup/parent']!.last, {'ticket': 'ticket-2'});
    expect(find.text('Sent to p•••@example.com.'), findsOneWidget);

    // A different address.
    await tapKey(t, 'parent_wait_change');
    await t.enterText(byKey('parent_wait_new_email'), 'nope');
    await tapKey(t, 'parent_wait_send_new');
    expect(
      find.text("That doesn't look like an email address."),
      findsOneWidget,
    );
    expect(sent['/signup/parent']!.length, 1, reason: 'nothing was sent');
    await t.enterText(byKey('parent_wait_new_email'), 'mum@example.com');
    await tapKey(t, 'parent_wait_send_new');
    expect(sent['/signup/parent']!.last, {
      'ticket': 'ticket-3',
      'parentEmail': 'mum@example.com',
    });
    expect(find.text('Sent to m•••@example.com.'), findsOneWidget);
    expect(
      byKey('parent_wait_new_email'),
      findsNothing,
      reason: 'the box closes once it is sent',
    );

    // The parent agrees. Now it signs in, and on to the welcome steps.
    parentAgreed = true;
    await tapKey(t, 'parent_wait_check');
    expect(auth.isAuthenticated, isTrue);
    expect(ApiService.authToken, 'tok-teen');
    expect(find.byType(ParentConsentScreen), findsNothing);
    expect(
      find.text('welcome steps'),
      findsOneWidget,
      reason: 'a first sign-in gets the welcome steps',
    );
    stopReporter();
  });

  testWidgets('signing in while it waits opens the same page; a refusal '
      'by the server is said in its words', (t) async {
    final auth = await openApp(t);
    await t.enterText(byKey('login_username'), 'teen_k');
    await t.enterText(byKey('login_password'), 'Sunset42!');
    await tapKey(t, 'login_submit');

    expect(find.byType(ParentConsentScreen), findsOneWidget);
    expect(
      find.textContaining('p•••@example.com', findRichText: true),
      findsOneWidget,
    );
    expect(auth.isAuthenticated, isFalse);

    // Too soon for another email: the server's own words.
    parentEmailAnswer = jsonAnswer({
      'error': 'We emailed them a moment ago. Try again in a minute.',
      'retryAfter': 42,
    }, 429);
    await tapKey(t, 'parent_wait_resend');
    expect(
      find.text('We emailed them a moment ago. Try again in a minute.'),
      findsOneWidget,
    );
    expect(byKey('auth_notice'), findsNothing);

    // The ticket ran out: only signing in again helps, and the page says so.
    parentEmailAnswer = jsonAnswer({
      'error': 'That took too long. Sign in again to carry on.',
      'expired': true,
    }, 401);
    await tapKey(t, 'parent_wait_resend');
    expect(find.textContaining('sign in again'), findsOneWidget);
    expect(byKey('parent_wait_to_signin'), findsOneWidget);
    expect(byKey('parent_wait_check'), findsNothing);
    await tapKey(t, 'parent_wait_to_signin');
    expect(find.byType(ParentConsentScreen), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('a parent who said no: said plainly, with only the way back', (
    t,
  ) async {
    parentDeclined = true;
    await openApp(t);
    await t.enterText(byKey('login_username'), 'teen_k');
    await t.enterText(byKey('login_password'), 'Sunset42!');
    await tapKey(t, 'login_submit');

    expect(find.byType(ParentConsentScreen), findsOneWidget);
    expect(find.text('Your parent or guardian said no'), findsOneWidget);
    expect(byKey('parent_wait_declined'), findsOneWidget);
    expect(byKey('parent_wait_to_signin'), findsOneWidget);
    for (final gone in [
      'parent_wait_check',
      'parent_wait_resend',
      'parent_wait_change',
      'parent_wait_cancel',
    ]) {
      expect(byKey(gone), findsNothing, reason: gone);
    }
    await tapKey(t, 'parent_wait_to_signin');
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('cancelling asks first, then deletes the sign-up and goes '
      'back to sign in', (t) async {
    await openApp(t);
    await t.enterText(byKey('login_username'), 'teen_k');
    await t.enterText(byKey('login_password'), 'Sunset42!');
    await tapKey(t, 'login_submit');

    await tapKey(t, 'parent_wait_cancel');
    expect(find.text('Cancel your sign-up?'), findsOneWidget);
    await tapKey(t, 'parent_wait_cancel_no');
    expect(sent['/signup/parent'], isNull, reason: 'they chose to wait');
    expect(find.byType(ParentConsentScreen), findsOneWidget);

    await tapKey(t, 'parent_wait_cancel');
    await tapKey(t, 'parent_wait_cancel_yes');
    expect(sent['/signup/parent']!.single, {
      'ticket': 'ticket-1',
      'cancel': true,
    });
    expect(find.byType(ParentConsentScreen), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('the ages come from the server: where the law says 16, the '
      'calendar offers nothing younger and the page says 16', (t) async {
    rules = {
      'country': 'AU',
      'source': 'network',
      'minAge': 16,
      'parentConsentAge': 18,
    };
    await openApp(t);
    await tapKey(t, 'login_create_account');
    expect(find.textContaining('16 or older'), findsOneWidget);
    await tapKey(t, 'signup_birthday');
    expect(
      t.widget<DatePickerDialog>(find.byType(DatePickerDialog)).lastDate,
      yearsAgo(DateTime.now(), 16),
    );
    await t.tap(find.text('OK'));
    await settle(t);
  });

  testWidgets('with no answer about the ages, the usual ones: 13 to join, '
      'a parent under 18', (t) async {
    ApiService.useClient(
      MockClient((req) async {
        if (req.url.path.endsWith('/signup/rules')) {
          return http.Response('down', 502);
        }
        if (req.url.path.endsWith('/signup/available')) {
          return jsonAnswer({'valid': true, 'available': true}, 200);
        }
        return http.Response('{}', 200);
      }),
    );
    await openApp(t);
    await tapKey(t, 'login_create_account');
    expect(find.textContaining('13 or older'), findsOneWidget);
    await pickBirthday(t, young: true);
    expect(byKey('signup_parent_email'), findsOneWidget);
  });

  testWidgets('with Google: the parent is named on the last step, and the '
      'page that waits signs in with Google again', (t) async {
    final sheets = FakeSheets();
    SocialAuth.instance = sheets;
    newWithGoogle = true;
    final auth = await openApp(t);
    await tapKey(t, 'social_google');
    expect(byKey('finish_signup'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 500)); // the live check
    await settle(t);
    await pickBirthday(t, young: true);
    expect(byKey('signup_parent_email'), findsOneWidget);
    await tapKey(t, 'signup_terms');
    expect(enabled(t, 'finish_submit'), isFalse);

    // Their own Google address is not a parent's.
    await t.enterText(byKey('signup_parent_email'), 'Teen.G@gmail.com');
    await settle(t);
    expect(enabled(t, 'finish_submit'), isFalse);
    await t.enterText(byKey('signup_parent_email'), 'dad@example.com');
    await settle(t);
    await tapKey(t, 'finish_submit');

    final body = sent['/auth/social/signup']!.single;
    expect(body['parentEmail'], 'dad@example.com');
    expect(body['signupTicket'], 'signup-1');
    expect(find.byType(ParentConsentScreen), findsOneWidget);
    expect(byKey('finish_signup'), findsNothing);
    expect(auth.isAuthenticated, isFalse);

    // "They said yes": Google's sheet again, then the server.
    newWithGoogle = false;
    parentAgreed = true;
    await tapKey(t, 'parent_wait_check');
    expect(sheets.asked, 2, reason: 'once to start, once to check');
    expect(sent['/auth/google']!.last['idToken'], 'google-says-teen');
    expect(auth.isAuthenticated, isTrue);
    expect(find.text('welcome steps'), findsOneWidget);
    stopReporter();
  });

  testWidgets('Google while a sign-up waits opens the page that waits', (
    t,
  ) async {
    SocialAuth.instance = FakeSheets();
    final auth = await openApp(t);
    await tapKey(t, 'social_google');
    expect(find.byType(ParentConsentScreen), findsOneWidget);
    expect(
      find.textContaining('p•••@example.com', findRichText: true),
      findsOneWidget,
    );
    expect(auth.isAuthenticated, isFalse);
  });

  test('every request says which country the phone is set to, and only '
      'when that is a real country code', () async {
    ApiService.deviceCountryForTest = 'in';
    await ApiService.signupRules();
    expect(headersSeen.last['X-Device-Country'], 'IN');

    ApiService.deviceCountryForTest = 'India';
    await ApiService.signupRules();
    expect(headersSeen.last.containsKey('X-Device-Country'), isFalse);

    ApiService.deviceCountryForTest = '';
    await ApiService.signupRules();
    expect(headersSeen.last.containsKey('X-Device-Country'), isFalse);

    // Signed in or not, on any kind of request.
    ApiService.deviceCountryForTest = 'GB';
    ApiService.authToken = 'tok';
    addTearDown(ApiService.clearAuth);
    await ApiService.login('maya', 'sunset42');
    expect(headersSeen.last['X-Device-Country'], 'GB');
    expect(headersSeen.last['Authorization'], 'Bearer tok');
  });

  test('the ages: who needs a parent, to the day', () {
    const rules = SignupRules(minAge: 13, parentConsentAge: 18);
    final today = DateTime(2026, 11, 12);
    expect(
      rules.needsParent(DateTime(2008, 11, 13), today),
      isTrue,
      reason: '18 tomorrow',
    );
    expect(
      rules.needsParent(DateTime(2008, 11, 12), today),
      isFalse,
      reason: '18 today',
    );
    expect(SignupRules.ageOn(DateTime(2008, 2, 29), DateTime(2026, 2, 28)), 17);
    expect(SignupRules.ageOn(DateTime(2008, 2, 29), DateTime(2026, 3, 1)), 18);
  });
}
