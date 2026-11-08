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

/// What the server answers "is this code right?", in order. Empty: right
/// when it is [theCode].
late List<http.Response> verifyAnswers;

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
  verifyAnswers = [];
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
    if (path.endsWith('/password/verify')) {
      if (verifyAnswers.isNotEmpty) return verifyAnswers.removeAt(0);
      if (body['code'] != theCode) {
        return jsonAnswer(
            {'field': 'code', 'error': "That code isn't right."}, 400);
      }
      return jsonAnswer({'valid': true}, 200);
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

/// Signing in starts the app's activity reporter, which keeps a timer. A
/// test that signed in lets it finish, as the app would.
Future<void> finishSigningIn(WidgetTester t) async {
  await t.pump(const Duration(seconds: 5));
  EventTracker.instance.dispose();
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  testWidgets('by username: a code by email, checked first, then a new '
      'password, and back to sign in with it', (t) async {
    final auth = await openApp(t);
    await askForCode(t, 'maya');

    // What was typed on the sign-in screen is what was sent.
    expect(sent['/password/forgot']!.single, {'login': 'maya'});

    // Step 2 says where the code went, so only its owner knows it.
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(find.text('Step 2 of 3'), findsOneWidget);
    expect(find.textContaining('m•••a@example.com', findRichText: true),
        findsOneWidget);
    expect(resendButton(t), ('Resend in 1:00', false));
    // No box for a new password until the code is checked.
    expect(byKey('forgot_new_password'), findsNothing);

    // The six boxes show the code as it is typed, and the sixth digit
    // checks it.
    await t.enterText(byKey('forgot_code'), theCode);
    await t.pump();
    for (final digit in theCode.split('')) {
      expect(find.text(digit), findsOneWidget);
    }
    await settle(t);
    expect(sent['/password/verify']!.single,
        {'login': 'maya', 'code': theCode});
    expect(sent['/password/reset'], isNull,
        reason: 'checking the code changes nothing');

    // Step 3: only now, a new password.
    expect(byKey('forgot_step_password'), findsOneWidget);
    expect(find.text('Step 3 of 3'), findsOneWidget);
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(sent['/password/reset']!.single, {
      'login': 'maya',
      'code': theCode,
      'newPassword': 'Moonrise77',
    });

    // Back on the sign-in screen: told so, the username filled in, the
    // password box empty and ready, and nobody signed in.
    expect(byKey('login_submit'), findsOneWidget);
    expect(find.text('Password changed. Sign in with your new password.'),
        findsOneWidget);
    expect(t.widget<TextField>(byKey('login_username')).controller!.text,
        'maya');
    final passwordBox = t.widget<TextField>(byKey('login_password'));
    expect(passwordBox.controller!.text, '');
    expect(passwordBox.focusNode!.hasFocus, isTrue);
    expect(sent['/login'], isNull);
    expect(auth.isAuthenticated, isFalse);

    // The old password no longer works, and saying so replaces the good
    // news.
    await t.enterText(byKey('login_password'), 'sunset42');
    await tapKey(t, 'login_submit');
    expect(auth.isAuthenticated, isFalse);
    expect(byKey('auth_error'), findsOneWidget);
    expect(byKey('auth_notice'), findsNothing);

    // The person signs in with the new one, themselves.
    await t.enterText(byKey('login_password'), 'Moonrise77');
    await tapKey(t, 'login_submit');
    expect(sent['/login']!.last['username'], 'maya');
    expect(sent['/login']!.last['password'], 'Moonrise77');
    expect(auth.isAuthenticated, isTrue);
    expect(find.text('the app'), findsOneWidget);
    await finishSigningIn(t);
  });

  testWidgets('by email: never confirmed nor denied, and the sign-in screen '
      "gets the account's username", (t) async {
    final auth = await openApp(t);
    await askForCode(t, 'maya@example.com');

    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(
        find.textContaining('If maya@example.com belongs to an account',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('•••', findRichText: true), findsNothing);

    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);
    expect(sent['/password/verify']!.single['login'], 'maya@example.com');
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');

    expect(sent['/password/reset']!.single['login'], 'maya@example.com');
    expect(t.widget<TextField>(byKey('login_username')).controller!.text,
        'maya',
        reason: 'the server says which account the code was for');
    expect(find.text('Password changed. Sign in with your new password.'),
        findsOneWidget);
    expect(sent['/login'], isNull);
    expect(auth.isAuthenticated, isFalse);
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
              'code. Email support@flexete.com from your email address and tell '
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
              "Email support@flexete.com and we'll help you get back in.",
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

  testWidgets('a wrong code is caught at the check, before any new '
      'password; a spent one can be replaced at once', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');

    await t.enterText(byKey('forgot_code'), '111111');
    await settle(t);
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        "That code isn't right.");
    // Still on the code: no box for a new password, and nothing changed.
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(byKey('forgot_new_password'), findsNothing);
    expect(sent['/password/reset'], isNull);
    expect(password, 'sunset42');

    // The button checks it too.
    await tapKey(t, 'forgot_verify');
    expect(sent['/password/verify']!.length, 2);
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        "That code isn't right.");

    verifyAnswers.add(jsonAnswer(
        {
          'field': 'code',
          'error': 'Too many wrong codes. Ask for a new one.',
          'expired': true,
        },
        400));
    await t.enterText(byKey('forgot_code'), '222222');
    await settle(t);
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

  testWidgets('half a code is caught before anything is sent', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');

    await t.enterText(byKey('forgot_code'), '483');
    await tapKey(t, 'forgot_verify');
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        'Enter the 6-digit code from the email.');
    expect(sent['/password/verify'], isNull);
    expect(byKey('forgot_step_code'), findsOneWidget);
  });

  testWidgets('a weak password is caught before anything is sent; the '
      "server's own refusal lands under the password box", (t) async {
    await openApp(t);
    await askForCode(t, 'maya');
    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);
    expect(byKey('forgot_step_password'), findsOneWidget);

    await t.enterText(byKey('forgot_new_password'), 'short1');
    await tapKey(t, 'forgot_reset');
    expect(find.text('Use at least 8 characters.'), findsOneWidget);
    expect(sent['/password/reset'], isNull);

    resetAnswers.add(jsonAnswer(
        {
          'field': 'newPassword',
          'error': "Don't put your username in your password.",
        },
        400));
    await t.enterText(byKey('forgot_new_password'), 'maya12345');
    await tapKey(t, 'forgot_reset');
    // Under the password box itself, not somewhere on the page.
    expect(
        t.widget<TextField>(byKey('forgot_new_password')).decoration!.errorText,
        "Don't put your username in your password.");
    // Still choosing a password, with the checked code kept: fix it and go
    // again.
    expect(byKey('forgot_step_password'), findsOneWidget);
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(sent['/password/reset']!.last,
        {'login': 'maya', 'code': theCode, 'newPassword': 'Moonrise77'});
    expect(byKey('login_submit'), findsOneWidget);
  });

  testWidgets('the code runs out while a password is chosen: back to the '
      'code, with a new one a tap away', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');
    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);

    resetAnswers.add(jsonAnswer(
        {
          'field': 'code',
          'error': 'That code has expired. Ask for a new one.',
          'expired': true,
        },
        400));
    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(t.widget<Text>(byKey('forgot_code_error')).data,
        'That code has expired. Ask for a new one.');
    expect(t.widget<TextField>(byKey('forgot_code')).controller!.text, '');
    expect(resendButton(t), ('Resend code', true));
    expect(byKey('login_submit'), findsNothing);
  });

  testWidgets('a server from before the check: on to the new password, and '
      'the reset checks the code', (t) async {
    verifyAnswers.add(http.Response('404 page not found', 404));
    await openApp(t);
    await askForCode(t, 'maya');
    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);
    expect(byKey('forgot_step_password'), findsOneWidget);

    await t.enterText(byKey('forgot_new_password'), 'Moonrise77');
    await tapKey(t, 'forgot_reset');
    expect(sent['/password/reset']!.single['code'], theCode);
    expect(find.text('Password changed. Sign in with your new password.'),
        findsOneWidget);
  });

  testWidgets('the server failing at the check: said as such, and the code '
      'stays to try again', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');

    verifyAnswers.add(http.Response('<html>proxy</html>', 502));
    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);
    expect(find.textContaining('The server had a problem'), findsOneWidget);
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(t.widget<TextField>(byKey('forgot_code')).controller!.text,
        theCode);

    offline = true;
    await tapKey(t, 'forgot_verify');
    expect(find.textContaining("Couldn't reach the server"), findsOneWidget);
    expect(byKey('forgot_step_code'), findsOneWidget);

    offline = false;
    await tapKey(t, 'forgot_verify');
    expect(byKey('forgot_step_password'), findsOneWidget);
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

  testWidgets('Back goes one step back: from the new password to the code, '
      'still filled in, to the first step, then out', (t) async {
    await openApp(t);
    await askForCode(t, 'maya');
    await t.enterText(byKey('forgot_code'), theCode);
    await settle(t);
    expect(byKey('forgot_step_password'), findsOneWidget);

    await tapKey(t, 'forgot_back');
    expect(byKey('forgot_step_code'), findsOneWidget);
    expect(t.widget<TextField>(byKey('forgot_code')).controller!.text,
        theCode);

    await tapKey(t, 'forgot_back');
    expect(byKey('forgot_step_find'), findsOneWidget);
    expect(t.widget<TextField>(byKey('forgot_login')).controller!.text,
        'maya');

    await tapKey(t, 'forgot_back');
    expect(byKey('login_submit'), findsOneWidget);
    expect(byKey('forgot_step_find'), findsNothing);
    // Leaving without a reset says nothing about a password.
    expect(byKey('auth_notice'), findsNothing);
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

    test('every answer to "is this code right?" is read as what it is',
        () async {
      verifyAnswers.addAll([
        jsonAnswer({'valid': true}, 200),
        jsonAnswer({'field': 'code', 'error': "That code isn't right."}, 400),
        jsonAnswer({'field': 'code', 'error': 'Expired.', 'expired': true},
            400),
        http.Response('{"error":"rate limited"}', 429),
        http.Response('404 page not found', 404),
        http.Response('{}', 200),
        http.Response('<html>proxy</html>', 502),
      ]);
      Future<ResetCodeCheckAnswer> next() async =>
          (await ApiService.verifyResetCode('maya', theCode)).answer;
      expect(await next(), ResetCodeCheckAnswer.right);
      final wrong = await ApiService.verifyResetCode('maya', '111111');
      expect(wrong.answer, ResetCodeCheckAnswer.wrong);
      expect(wrong.message, "That code isn't right.");
      expect(await next(), ResetCodeCheckAnswer.expired);
      expect(await next(), ResetCodeCheckAnswer.tooMany);
      expect(await next(), ResetCodeCheckAnswer.notChecked);
      expect(await next(), ResetCodeCheckAnswer.serverError,
          reason: 'a 200 without "valid" is not taken for right');
      expect(await next(), ResetCodeCheckAnswer.serverError);
      offline = true;
      expect(await next(), ResetCodeCheckAnswer.unreachable);
    });

    test('why no code was sent is in the log, with how long the server took',
        () async {
      final said = <String>[];
      final realPrint = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => said.add(m ?? '');
      addTearDown(() => debugPrint = realPrint);

      for (final reason in ['notSent', 'notSetUp', null]) {
        forgotAnswer = jsonAnswer({
          'error': 'Email support.',
          'unavailable': true,
          'reason': ?reason,
        }, 503);
        expect((await ApiService.askResetCode('maya')).answer,
            ResetCodeAnswer.unavailable);
      }
      final lines = said.where((l) => l.startsWith('[forgot]')).toList();
      expect(lines, hasLength(3), reason: said.join('\n'));
      expect(lines[0], contains('the server tried to email it'));
      expect(lines[1], contains('email is not set up on the server'));
      expect(lines[2], contains('the server says email is not working'));
      for (final line in lines) {
        expect(line, matches(RegExp(r'\(the server answered in \d+ ms\)$')));
      }
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
