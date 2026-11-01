// "Forgot password?", through the real sign-in screen, the real reset screen
// and the real sign-in state, against a stand-in server that answers the
// way the real one does (password_reset.go on the server).
//
// Every test checks for something that IS there (a screen, a request, a
// message), not only for what is gone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

/// What the stand-in server was sent, by address.
late Map<String, List<Map<String, dynamic>>> sent;

/// The account's password, as the server knows it. A reset changes it.
late String password;

/// What the server answers "send a code", when a test wants something other
/// than "sent".
http.Response? forgotAnswer;

/// What the server answers the code and new password, in order. Empty: the
/// code is right and the password is changed.
late List<http.Response> resetAnswers;

/// The server cannot be reached at all.
bool offline = false;

const theCode = '483920';

/// A JSON answer, labelled the way the server labels it (writeJSON). The
/// label matters: it is what makes the app read "m•••a" as text rather than
/// as bytes.
http.Response jsonAnswer(Object body, int status) => http.Response(
    json.encode(body), status,
    headers: {'content-type': 'application/json'});

void fakeServer() {
  sent = {};
  password = 'sunset42';
  forgotAnswer = null;
  resetAnswers = [];
  offline = false;
  ApiService.useClient(MockClient((req) async {
    if (offline) throw http.ClientException('no connection');
    final path = req.url.path;
    Map<String, dynamic> body = const {};
    if (req.body.isNotEmpty) {
      body = json.decode(req.body) as Map<String, dynamic>;
      sent.putIfAbsent(path, () => []).add(body);
    }
    if (path.endsWith('/password/forgot')) {
      if (forgotAnswer != null) return forgotAnswer!;
      final login = '${body['login']}';
      return jsonAnswer(
          {
            'sent': true,
            // Only a username is told where the code went.
            if (!login.contains('@')) 'to': 'm•••a@example.com',
            'resendIn': 60,
          },
          200);
    }
    if (path.endsWith('/password/reset')) {
      if (resetAnswers.isNotEmpty) return resetAnswers.removeAt(0);
      if (body['code'] != theCode) {
        return jsonAnswer(
            {'field': 'code', 'error': "That code isn't right."},
            400);
      }
      password = '${body['newPassword']}';
      return jsonAnswer({'reset': true, 'username': 'maya'},
          200);
    }
    if (path.endsWith('/login')) {
      if (body['password'] != password) {
        return http.Response('Invalid username or password', 401);
      }
      return jsonAnswer(
          {
            'token': 'tok-login',
            'user': {
              'id': '7',
              'username': 'maya',
              'followingList': <String>[],
            },
          },
          200);
    }
    if (path.endsWith('/api/v1/users')) return http.Response('[]', 200);
    return http.Response('{}', 200);
  }));
}

/// The app's front door, routed the way main.dart routes it.
Future<AuthProvider> openApp(WidgetTester t) async {
  FlutterSecureStorage.setMockInitialValues({});
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(430, 1400));
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
            ? const Text('the app', key: ValueKey('signed_in'))
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

/// The words on the resend button, and whether it can be pressed.
(String, bool) resendButton(WidgetTester t) {
  final button = t.widget<TextButton>(byKey('forgot_resend'));
  return ((button.child as Text).data!, button.onPressed != null);
}

/// From the sign-in screen, with [login] typed in, to the code step.
Future<void> askForCode(WidgetTester t, String login) async {
  await t.enterText(byKey('login_username'), login);
  await tapKey(t, 'login_forgot');
  expect(byKey('forgot_step_find'), findsOneWidget);
  await tapKey(t, 'forgot_send');
}

/// Signing in starts the app's activity reporter, which keeps a timer, and
/// the "signing you in" note keeps another. A test that signed in lets both
/// finish, as the app would.
Future<void> finishSigningIn(WidgetTester t) async {
  await t.pump(const Duration(seconds: 5));
  EventTracker.instance.dispose();
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('by username: a code by email, a new password, and signed in '
      'with it', (t) async {
    final auth = await openApp(t);
    await askForCode(t, 'maya');

    // What was typed on the sign-in screen is what was sent.
    expect(sent['/password/forgot']!.single, {'login': 'maya'});

    // Step 2 says where the code went, so only its owner knows it.
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(find.textContaining('m•••a@example.com', findRichText: true),
        findsOneWidget);
    expect(resendButton(t), ('Resend in 1:00', false));

    // The six boxes show the code as it is typed.
    await t.enterText(byKey('forgot_code'), theCode);
    await t.pump();
    for (final digit in theCode.split('')) {
      expect(find.text(digit), findsOneWidget);
    }
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');

    expect(sent['/password/reset']!.single, {
      'login': 'maya',
      'code': theCode,
      'newPassword': 'Moonrise77',
    });
    // Signed in with the new password, through the ordinary sign-in.
    expect(sent['/login']!.single['username'], 'maya');
    expect(sent['/login']!.single['password'], 'Moonrise77');
    expect(auth.isAuthenticated, isTrue);
    expect(find.text('the app'), findsOneWidget);
    await finishSigningIn(t);
  });

  testWidgets('by email: never confirmed nor denied, and signed in with the '
      "account's username", (t) async {
    final auth = await openApp(t);
    await askForCode(t, 'maya@example.com');

    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(
        find.textContaining('If maya@example.com belongs to an account',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('•••', findRichText: true), findsNothing);

    await t.enterText(byKey('forgot_code'), theCode);
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');

    expect(sent['/password/reset']!.single['login'], 'maya@example.com');
    expect(sent['/login']!.single['username'], 'maya',
        reason: 'the server says which account the code was for');
    expect(auth.isAuthenticated, isTrue);
    await finishSigningIn(t);
  });

  testWidgets('no such username, and no email on the account: each said in '
      'plain words', (t) async {
    await openApp(t);
    forgotAnswer = jsonAnswer(
        
            {'field': 'login', 'error': 'No account has that username.'},
        404);
    await askForCode(t, 'nobody_here');
    expect(byKey('forgot_step_find'), findsOneWidget);
    expect(find.text('No account has that username.'), findsOneWidget);

    forgotAnswer = jsonAnswer(
        {
          'field': 'login',
          'error': "This account has no email address, so we can't send it a "
              'code. Email support@devf.app from your email address and tell '
              'us your username.',
          'noEmail': true,
        },
        409);
    await tapKey(t, 'forgot_send');
    expect(byKey('forgot_step_find'), findsOneWidget);
    expect(find.textContaining('has no email address'), findsOneWidget);
  });

  testWidgets('email not working on the server, or no server at all: said '
      'as such, with where to get help', (t) async {
    await openApp(t);
    forgotAnswer = jsonAnswer(
        {
          'error': "Resetting a password by email isn't working right now. "
              "Email support@devf.app and we'll help you get back in.",
          'unavailable': true,
        },
        503);
    await askForCode(t, 'maya');
    expect(byKey('forgot_step_find'), findsOneWidget);
    expect(find.textContaining("isn't working right now"), findsOneWidget);

    offline = true;
    await tapKey(t, 'forgot_send');
    expect(find.textContaining("Couldn't reach the server"), findsOneWidget);

    // The help line is there on the first step whatever happens.
    expect(find.textContaining(AppConstants.supportEmail), findsWidgets);
  });

  testWidgets('a wrong code, then a spent one: each said, and a new code can '
      'be asked for at once', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');

    await t.enterText(byKey('forgot_code'), '111111');
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        "That code isn't right.");
    expect(password, 'sunset42');

    resetAnswers.add(jsonAnswer(
        {
          'field': 'code',
          'error': 'Too many wrong codes. Ask for a new one.',
          'expired': true,
        },
        400));
    await t.enterText(byKey('forgot_code'), '222222');
    await tapKey(t, 'forgot_reset');
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        'Too many wrong codes. Ask for a new one.');
    // The spent code is cleared, and Resend works without waiting.
    expect(t.widget<TextField>(byKey('forgot_code')).controller!.text, '');
    expect(resendButton(t), ('Resend code', true));

    await tapKey(t, 'forgot_resend');
    expect(sent['/password/forgot']!.length, 2);
    expect(sent['/password/forgot']!.last, {'login': 'maya'});
    expect(find.textContaining('We sent a new code to', findRichText: true),
        findsOneWidget);
    expect(resendButton(t), ('Resend in 1:00', false));
  });

  testWidgets('a weak password is caught before anything is sent; the '
      "server's own refusal lands under the password box", (t) async {
    await openApp(t);
    await askForCode(t, 'maya');

    await t.enterText(byKey('forgot_code'), theCode);
    await t.enterText(byKey('forgot_new_password'), 'short1');
    await tapKey(t, 'forgot_reset');
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(sent['/password/reset'], isNull);

    // Half a code is caught too.
    await t.enterText(byKey('forgot_code'), '483');
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        'Enter the 6-digit code from the email.');
    expect(sent['/password/reset'], isNull);

    resetAnswers.add(jsonAnswer(
        {
          'field': 'newPassword',
          'error': "Don't put your username in your password.",
        },
        400));
    await t.enterText(byKey('forgot_code'), theCode);
    await t.enterText(byKey('forgot_new_password'), 'maya12345');
    await tapKey(t, 'forgot_reset');
    // Under the password box itself, not somewhere on the page.
    expect(
        t.widget<TextField>(byKey('forgot_new_password')).decoration!.errorText,
        "Don't put your username in your password.");
    // Still on step 2 with the code kept: fix the password and go again.
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(t.widget<TextField>(byKey('forgot_code')).controller!.text,
        theCode);
  });

  testWidgets('Resend waits out its minute, then sends a new code',
      (t) async {
    await openApp(t);
    await askForCode(t, 'maya');
    expect(resendButton(t), ('Resend in 1:00', false));

    await t.pump(const Duration(seconds: 18));
    expect(resendButton(t), ('Resend in 0:42', false));

    await t.pump(const Duration(seconds: 43));
    expect(resendButton(t), ('Resend code', true));

    await tapKey(t, 'forgot_resend');
    expect(sent['/password/forgot']!.length, 2);
    expect(resendButton(t), ('Resend in 1:00', false));
  });

  testWidgets('a code sent under a minute ago still works: straight on to '
      'entering it', (t) async {
    await openApp(t);
    forgotAnswer = jsonAnswer(
        {
          'error': 'A code was just sent. You can ask for another in a minute.',
          'retryAfter': 42,
        },
        429);
    await askForCode(t, 'maya');
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(find.textContaining('a moment ago'), findsOneWidget);
    expect(resendButton(t), ('Resend in 0:42', false));
  });

  testWidgets('Back on the code step goes to the first step, then out',
      (t) async {
    await openApp(t);
    await askForCode(t, 'maya');
    expect(byKey('forgot_step_code'), findsOneWidget);

    await tapKey(t, 'forgot_back');
    expect(byKey('forgot_step_find'), findsOneWidget);
    expect(t.widget<TextField>(byKey('forgot_login')).controller!.text,
        'maya');

    await tapKey(t, 'forgot_back');
    expect(byKey('login_submit'), findsOneWidget);
    expect(byKey('forgot_step_find'), findsNothing);
  });

  group('the answers, read the way the server gives them', () {
    test('a general "too many" is told apart from "a code was just sent"',
        () async {
      forgotAnswer = http.Response(
          '{"error":"rate limited","action":"password_reset"}', 429);
      final ask = await ApiService.askResetCode('maya');
      expect(ask.answer, ResetCodeAnswer.tooMany);
      expect(ask.message, contains('Wait a while'));
    });

    test('an answer that is not the expected shape is not taken for "sent"',
        () async {
      forgotAnswer = http.Response('{}', 200);
      expect((await ApiService.askResetCode('maya')).answer,
          ResetCodeAnswer.serverError);
      forgotAnswer = http.Response('<html>proxy</html>', 502);
      expect((await ApiService.askResetCode('maya')).answer,
          ResetCodeAnswer.serverError);
      resetAnswers.add(http.Response('{}', 200));
      expect((await ApiService.resetPassword('maya', theCode, 'Moon77ab'))
          .answer, PasswordResetAnswer.serverError);
    });

    test('each "no" from the server is read as what it is', () async {
      forgotAnswer = jsonAnswer(
          {'field': 'login', 'error': 'No account has that username.'}, 404);
      expect((await ApiService.askResetCode('x')).answer,
          ResetCodeAnswer.noAccount);
      forgotAnswer = jsonAnswer(
          {'field': 'login', 'error': 'No email.', 'noEmail': true}, 409);
      expect((await ApiService.askResetCode('x')).answer,
          ResetCodeAnswer.noEmail);
      forgotAnswer = jsonAnswer(
          {'error': 'Email support.', 'unavailable': true}, 503);
      final off = await ApiService.askResetCode('x');
      expect(off.answer, ResetCodeAnswer.unavailable);
      expect(off.message, 'Email support.');
      // A 503 that is not the server saying "email is off" is just a failure.
      forgotAnswer = http.Response('Service Unavailable', 503);
      expect((await ApiService.askResetCode('x')).answer,
          ResetCodeAnswer.serverError);

      resetAnswers.addAll([
        jsonAnswer({'field': 'code', 'error': 'Expired.', 'expired': true},
            400),
        jsonAnswer({'field': 'newPassword', 'error': 'Too short.'}, 400),
        http.Response('{"error":"rate limited"}', 429),
      ]);
      expect((await ApiService.resetPassword('x', theCode, 'p')).answer,
          PasswordResetAnswer.expired);
      final weak = await ApiService.resetPassword('x', theCode, 'p');
      expect(weak.answer, PasswordResetAnswer.badPassword);
      expect(weak.message, 'Too short.');
      expect((await ApiService.resetPassword('x', theCode, 'p')).answer,
          PasswordResetAnswer.tooMany);
    });

    test('no connection is "unreachable", never "wrong"', () async {
      offline = true;
      expect((await ApiService.askResetCode('maya')).answer,
          ResetCodeAnswer.unreachable);
      expect((await ApiService.resetPassword('maya', theCode, 'Moon77ab'))
          .answer, PasswordResetAnswer.unreachable);
    });
  });
}
