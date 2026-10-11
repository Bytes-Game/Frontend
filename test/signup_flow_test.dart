// Sign-up and sign-in, through the real screens and the real sign-in state,
// against a stand-in server.
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

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/change_password_page.dart';
import 'package:myapp/pages/settings_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/screens/signup_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/session_store.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// What the stand-in server was sent, by address.
late Map<String, List<Map<String, dynamic>>> sent;

/// What the server answers a sign-up: null for "made it".
http.Response? signupAnswer;

/// The usernames the server says are taken or reserved, and why.
const Map<String, String> notFree = {
  'taken_one': 'That username is taken.',
  'admin': 'That name is reserved. Please pick another.',
};

void fakeServer() {
  sent = {};
  signupAnswer = null;
  ApiService.useClient(MockClient((req) async {
    final path = req.url.path;
    if (req.body.isNotEmpty) {
      sent.putIfAbsent(path, () => []).add(
          json.decode(req.body) as Map<String, dynamic>);
    }
    if (path.endsWith('/signup/available')) {
      final name = req.url.queryParameters['username'] ?? '';
      final why = notFree[name];
      return http.Response(
          json.encode({
            'valid': name != 'admin',
            'available': why == null,
            'reason': why ?? '',
          }),
          200);
    }
    if (path.endsWith('/signup')) {
      final body = json.decode(req.body) as Map<String, dynamic>;
      return signupAnswer ??
          http.Response(
              json.encode({
                'token': 'tok-new',
                'user': {
                  'id': '50',
                  'username': body['username'],
                  'fullName': body['fullName'],
                  'followingList': <String>[],
                },
                'allUsers': [],
              }),
              201);
    }
    if (path.endsWith('/login')) {
      final body = json.decode(req.body) as Map<String, dynamic>;
      if (body['password'] != 'sunset42') {
        return http.Response('Invalid username or password', 401);
      }
      return http.Response(
          json.encode({
            'token': 'tok-login',
            'user': {'id': '7', 'username': 'maya', 'followingList': <String>[]},
          }),
          200);
    }
    if (path.endsWith('/auth/password')) {
      final body = json.decode(req.body) as Map<String, dynamic>;
      if (body['currentPassword'] != 'sunset42') {
        return http.Response(
            json.encode({
              'field': 'currentPassword',
              'error': "That isn't your current password.",
            }),
            403);
      }
      return http.Response(json.encode({'token': 'tok-fresh'}), 200);
    }
    if (path.endsWith('/api/v1/users')) return http.Response('[]', 200);
    return http.Response('{}', 200);
  }));
}

/// The app's front door, routed the way main.dart routes it.
Future<AuthProvider> openApp(WidgetTester t,
    {UserModel? signedIn, Widget? page, Map<String, String>? stored}) async {
  FlutterSecureStorage.setMockInitialValues(stored ?? {});
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(430, 1400));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final auth = AuthProvider();
  final dp = DataProvider();
  if (signedIn != null) dp.setUser(signedIn);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: auth),
      ChangeNotifierProvider.value(value: dp),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: Consumer<AuthProvider>(
      builder: (_, a, _) => MaterialApp(
        home: page != null
            ? _Opens(page)
            : (a.isAuthenticated
                ? Text(a.needsOnboarding ? 'welcome steps' : 'the app',
                    key: const ValueKey('signed_in'))
                : const LoginScreen()),
      ),
    ),
  ));
  await settle(t);
  return auth;
}

/// Signing in starts the app's activity reporter, which keeps a timer; a
/// test that signed in stops it before it ends, as the app does on sign-out.
void stopReporter() => EventTracker.instance.dispose();

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

/// Fills in every box with good answers (the username is [name]).
Future<void> fillSignup(WidgetTester t, {String name = 'maya_k'}) async {
  await t.enterText(find.byKey(const ValueKey('signup_full_name')), 'Maya K');
  await t.enterText(find.byKey(const ValueKey('signup_username')), name);
  await t.pump(const Duration(milliseconds: 500)); // the live check
  await settle(t);
  await t.enterText(find.byKey(const ValueKey('signup_email')), 'Maya@Example.com');
  await tapKey(t, 'signup_birthday');
  // The calendar offers nothing younger than 13.
  expect(t.widget<DatePickerDialog>(find.byType(DatePickerDialog)).lastDate,
      thirteenYearsAgo(DateTime.now()));
  await t.tap(find.text('OK'));
  await settle(t);
  await t.enterText(find.byKey(const ValueKey('signup_password')), 'Sunset42!');
  await settle(t);
  await tapKey(t, 'signup_terms');
}

bool createEnabled(WidgetTester t) {
  final button = find.descendant(
    of: find.byKey(const ValueKey('signup_submit')),
    matching: find.byType(FilledButton),
  );
  return t.widget<FilledButton>(button).onPressed != null;
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('sign-in has "Create new account", and it opens sign-up with '
      'every box', (t) async {
    await openApp(t);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.byKey(const ValueKey('login_username')), findsOneWidget);
    expect(find.text('Username or email'), findsOneWidget);

    await tapKey(t, 'login_create_account');
    expect(find.byType(SignupScreen), findsOneWidget);
    for (final key in [
      'signup_full_name',
      'signup_username',
      'signup_email',
      'signup_birthday',
      'signup_password',
      'signup_terms',
      'signup_submit',
      'signup_to_signin',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(createEnabled(t), isFalse, reason: 'nothing is filled in yet');

    // And back to sign-in from it.
    await tapKey(t, 'signup_to_signin');
    expect(find.byType(SignupScreen), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('a whole sign-up: every detail goes to the server, and you '
      'land signed in on the welcome steps', (t) async {
    final auth = await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t);
    expect(find.byKey(const ValueKey('username_free')), findsOneWidget);
    expect(createEnabled(t), isTrue);

    await tapKey(t, 'signup_submit');
    await settle(t);

    final body = sent['/signup']!.single;
    expect(body['username'], 'maya_k');
    expect(body['fullName'], 'Maya K');
    expect(body['email'], 'maya@example.com');
    expect(body['acceptTerms'], true);
    expect(body['password'], 'Sunset42!');
    final born = DateTime.parse(body['birthDate'] as String);
    expect(thirteenYearsAgo(DateTime.now()).isBefore(born),
        isFalse,
        reason: 'the calendar only offers birthdays 13 or more years ago');

    expect(auth.isAuthenticated, isTrue);
    expect(find.byType(SignupScreen), findsNothing,
        reason: 'the sign-up page closes once you are in');
    expect(find.text('welcome steps'), findsOneWidget);
    expect(ApiService.authToken, 'tok-new');
    stopReporter();
  });

  testWidgets('the server\'s "no" lands under the box it is about',
      (t) async {
    signupAnswer = http.Response(
        json.encode({
          'field': 'email',
          'error': 'An account already uses this email. Try signing in.',
        }),
        409);
    final auth = await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t);
    await tapKey(t, 'signup_submit');

    expect(auth.isAuthenticated, isFalse);
    expect(find.text('An account already uses this email. Try signing in.'),
        findsOneWidget);
    expect(find.byKey(const ValueKey('auth_error')), findsNothing,
        reason: 'it is about one box, so it is said there');
    // Changing that box clears it.
    await t.enterText(find.byKey(const ValueKey('signup_email')), 'other@example.com');
    await settle(t);
    expect(find.text('An account already uses this email. Try signing in.'),
        findsNothing);
  });

  testWidgets('a taken or reserved username says why, and Create stays off',
      (t) async {
    await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t, name: 'taken_one');
    expect(find.text('That username is taken.'), findsOneWidget);
    expect(find.byKey(const ValueKey('username_not_free')), findsOneWidget);
    expect(createEnabled(t), isFalse);

    await t.enterText(find.byKey(const ValueKey('signup_username')), 'admin');
    await t.pump(const Duration(milliseconds: 500));
    await settle(t);
    expect(find.text('That name is reserved. Please pick another.'), findsOneWidget);
    expect(createEnabled(t), isFalse);

    // And a free one turns it on.
    await t.enterText(find.byKey(const ValueKey('signup_username')), 'maya_k');
    await t.pump(const Duration(milliseconds: 500));
    await settle(t);
    expect(createEnabled(t), isTrue);
  });

  testWidgets('Create stays off until the terms are agreed, and a weak '
      'password is named as one', (t) async {
    await openApp(t);
    await tapKey(t, 'login_create_account');
    await fillSignup(t);
    expect(createEnabled(t), isTrue);
    await tapKey(t, 'signup_terms'); // untick
    expect(createEnabled(t), isFalse);
    await tapKey(t, 'signup_terms');
    await t.enterText(find.byKey(const ValueKey('signup_password')), 'short1');
    await settle(t);
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(createEnabled(t), isFalse);
    expect(t.widget<Text>(find.byKey(const ValueKey('password_strength_word'))).data,
        'Too weak');
  });

  testWidgets('sign in with an email, and a wrong password says so plainly',
      (t) async {
    final auth = await openApp(t);
    await t.enterText(find.byKey(const ValueKey('login_username')), 'maya@example.com');
    await t.enterText(find.byKey(const ValueKey('login_password')), 'nope-1234');
    await tapKey(t, 'login_submit');
    expect(find.text("That username, email or password isn't right."), findsOneWidget);
    expect(auth.isAuthenticated, isFalse);

    await t.enterText(find.byKey(const ValueKey('login_password')), 'sunset42');
    await tapKey(t, 'login_submit');
    expect(sent['/login']!.last['username'], 'maya@example.com');
    expect(auth.isAuthenticated, isTrue);
    expect(find.text('the app'), findsOneWidget);
    stopReporter();
  });

  testWidgets('"Forgot password?" says how to get back in', (t) async {
    await openApp(t);
    await tapKey(t, 'login_forgot');
    expect(find.byKey(const ValueKey('forgot_password_sheet')), findsOneWidget);
    expect(find.textContaining('support@devf.app'), findsOneWidget);
  });

  testWidgets('Settings → Create a new account signs you out and opens '
      'sign-up', (t) async {
    final me = UserModel(
      id: '7',
      username: 'maya',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
    );
    final auth = AuthProvider();
    FlutterSecureStorage.setMockInitialValues({});
    EventTracker.instance.dispose();
    await t.binding.setSurfaceSize(const Size(430, 1600));
    addTearDown(() => t.binding.setSurfaceSize(null));
    // Signed in for real first, so signing out has something to undo.
    final dp = DataProvider()..setUser(me);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: dp),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: Consumer<AuthProvider>(
        builder: (ctx, a, _) => MaterialApp(
          home: a.isAuthenticated
              ? SettingsPage(
                  onEditProfile: () {},
                  onShareProfile: () {},
                  onSaved: () {},
                  onLiked: () {},
                )
              : const LoginScreen(),
        ),
      ),
    ));
    await settle(t);
    // Sign in through the real path so the app is in the signed-in state.
    await t.enterText(find.byKey(const ValueKey('login_username')), 'maya');
    await t.enterText(find.byKey(const ValueKey('login_password')), 'sunset42');
    await tapKey(t, 'login_submit');
    expect(find.byType(SettingsPage), findsOneWidget);

    await tapKey(t, 'settings_new_account');
    expect(find.text('Create a new account?'), findsOneWidget);
    await tapKey(t, 'new_account_confirm');
    await settle(t);

    expect(auth.isAuthenticated, isFalse);
    expect(find.byType(SignupScreen), findsOneWidget,
        reason: 'straight on to sign-up, not left on sign-in');
    stopReporter();
  });

  testWidgets('change password: the current one is checked, and this phone '
      'keeps a fresh sign-in', (t) async {
    final auth = await openApp(t, page: const ChangePasswordPage(), stored: {
      'session_v1': json.encode({
        'token': 'tok-old',
        'user': {'id': '7', 'username': 'maya', 'followingList': <String>[]},
        'issuedAt': DateTime.now().toUtc().toIso8601String(),
      }),
    });
    expect(find.text('Change password'), findsWidgets);

    await t.enterText(find.byKey(const ValueKey('password_current')), 'wrong-123');
    await t.enterText(find.byKey(const ValueKey('password_new')), 'Moonrise77');
    await t.enterText(find.byKey(const ValueKey('password_again')), 'Moonrise77');
    await settle(t);
    await tapKey(t, 'password_save');
    expect(find.text("That isn't your current password."), findsOneWidget);
    expect(ApiService.authToken, isNot('tok-fresh'));

    await t.enterText(find.byKey(const ValueKey('password_current')), 'sunset42');
    await settle(t);
    await tapKey(t, 'password_save');
    expect(sent['/api/v1/auth/password']!.last,
        {'currentPassword': 'sunset42', 'newPassword': 'Moonrise77'});
    expect(ApiService.authToken, 'tok-fresh');
    // Kept on the phone too, so it is still signed in after a restart.
    final kept = await SessionStore.loadFresh();
    expect(kept?.token, 'tok-fresh');
    expect(kept?.userJson['username'], 'maya');
    expect(find.textContaining('Password changed'), findsOneWidget);
    expect(find.byType(ChangePasswordPage), findsNothing,
        reason: 'back to Settings once it is done');
    expect(find.text('settings underneath'), findsOneWidget);
    expect(auth.isAuthenticated, isFalse,
        reason: 'unchanged: this test never signed in');
  });

  test('the strength bar: the server\'s minimum is "Okay", more is better',
      () {
    expect(passwordScore(''), 0);
    expect(passwordScore('short1'), 1);
    expect(passwordScore('abcdefgh'), 1);
    expect(passwordScore('sunset42'), 2);
    expect(passwordScore('Sunset42'), 3);
    expect(passwordScore('Sunset42 long one'), 4);
  });
}

/// A plain screen that opens [page] over itself, the way Settings opens a
/// page: so going back from it lands somewhere.
class _Opens extends StatefulWidget {
  final Widget page;
  const _Opens(this.page);

  @override
  State<_Opens> createState() => _OpensState();
}

class _OpensState extends State<_Opens> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => widget.page));
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('settings underneath')));
}
