import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// "Check your email": the last step of signing up with an email and a
/// password. Every box on the form was right, and the server emailed a
/// 6-digit code to the address. The account is made when the code comes
/// back: nobody can sign up with an email they cannot read.
///
/// Signed in, it closes everything above the app. Otherwise, when the
/// answer is for the sign-up form to deal with, this page closes with it:
/// somebody young enough to need a parent (the form opens the page that
/// waits for them), or something wrong with the form itself (a username
/// taken in the meantime), to be shown under its box.
class EmailCodeScreen extends StatefulWidget {
  const EmailCodeScreen({
    super.key,
    required this.details,
    required this.sentTo,
    this.resendIn = 60,
  });

  /// The sign-up, as the form sent it.
  final SignupDetails details;

  /// Where the code went, as the server said it.
  final String sentTo;

  /// Seconds before another code may be asked for.
  final int resendIn;

  @override
  State<EmailCodeScreen> createState() => _EmailCodeScreenState();
}

class _EmailCodeScreenState extends State<EmailCodeScreen> {
  final _code = TextEditingController();
  final _codeFocus = FocusNode();

  bool _busy = false;

  /// What is wrong with the code, under the boxes.
  String? _codeError;

  /// What went wrong otherwise.
  String? _error;

  /// A new code was sent from here.
  bool _resent = false;

  /// Seconds until another code may be asked for.
  int _resendIn = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _countDown(widget.resendIn);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  /// Counts down to when "Resend" works again.
  void _countDown(int seconds) {
    _tick?.cancel();
    _resendIn = seconds > 0 ? seconds : 0;
    if (mounted) setState(() {});
    if (_resendIn == 0) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendIn--);
      if (_resendIn <= 0) t.cancel();
    });
  }

  Future<void> _verify() async {
    if (_busy) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _codeError = 'Enter the 6-digit code from the email.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _codeError = null;
      _error = null;
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final navigator = Navigator.of(context);
    final result = await auth.signup(context, widget.details.withCode(code));
    if (!mounted) return;
    if (result == null) {
      // Signed in: the app underneath has switched to the welcome steps.
      navigator.popUntil((r) => r.isFirst);
      return;
    }
    // Young enough to need a parent: no account yet. The form goes on to
    // the page that waits for them, as it always has.
    if (result.failure == AuthFailure.parentConsentPending) {
      navigator.pop(result);
      return;
    }
    // About a box on the form: back to it, to be put right there.
    final field = result.field;
    if (result.failure == AuthFailure.rejected &&
        field != null &&
        field != 'emailCode') {
      navigator.pop(result);
      return;
    }
    setState(() {
      _busy = false;
      if (field == 'emailCode') {
        _codeError = result.message ?? "That code isn't right.";
        _code.clear();
        // Spent or expired: a new code is the only way on, at once.
        if (result.extra?['expired'] == true) _countDown(0);
      } else {
        _error = _problem(result);
      }
    });
    if (field == 'emailCode') _codeFocus.requestFocus();
  }

  Future<void> _resend() async {
    if (_busy || _resendIn > 0) return;
    setState(() {
      _busy = true;
      _codeError = null;
      _error = null;
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final navigator = Navigator.of(context);
    final result = await auth.signup(context, widget.details);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result?.failure == AuthFailure.emailCodeSent) {
      _code.clear();
      setState(() => _resent = true);
      _countDown(_secondsIn(result!.extra?['resendIn'], 60));
      _codeFocus.requestFocus();
      return;
    }
    final why = result ?? const AuthResult.failed(AuthFailure.unreachable);
    // Asked again too soon: the server says how long to wait.
    if (why.field == 'emailCode') {
      setState(() => _codeError = why.message);
      _countDown(_secondsIn(why.extra?['retryAfter'], 60));
      return;
    }
    // About a box on the form (this address has had all the codes it can
    // for now): back to it.
    if (why.failure == AuthFailure.rejected && why.field != null) {
      navigator.pop(why);
      return;
    }
    setState(() => _error = _problem(why));
  }

  static int _secondsIn(Object? said, int otherwise) =>
      said is num ? said.toInt() : otherwise;

  String _problem(AuthResult result) => switch (result.failure) {
    AuthFailure.unreachable =>
      "Couldn't reach the server. It may be "
          'waking up — wait a few seconds and try again.',
    AuthFailure.serverError =>
      'The server had a problem. Please try again in a moment.',
    _ => result.message ?? "Couldn't create the account. Please try again.",
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final strong = TextStyle(
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    );
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: const BackButton(key: ValueKey('email_code_back')),
      ),
      body: AuthBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space24,
              AppTheme.space16,
              AppTheme.space24,
              32,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  key: const ValueKey('email_code_screen'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AuthStepHeader(
                      icon: Icons.mark_email_unread_rounded,
                      title: 'Check your email',
                      subtitle: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: _resent
                                  ? 'We sent a new 6-digit code to '
                                  : 'We sent a 6-digit code to ',
                            ),
                            TextSpan(text: widget.sentTo, style: strong),
                            const TextSpan(
                              text:
                                  '. Enter it to finish making your '
                                  'account. It works for 15 minutes.',
                            ),
                          ],
                        ),
                        key: const ValueKey('email_code_sent_to'),
                      ),
                    ),
                    const SizedBox(height: 28),
                    CodeBoxes(
                      fieldKey: const ValueKey('email_code'),
                      controller: _code,
                      focus: _codeFocus,
                      enabled: !_busy,
                      error: _codeError != null,
                      onChanged: (value) {
                        if (_codeError != null) {
                          setState(() => _codeError = null);
                        }
                        // All six typed: checked at once.
                        if (value.length == 6 && !_busy) _verify();
                      },
                    ),
                    if (_codeError != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        _codeError!,
                        key: const ValueKey('email_code_error'),
                        style: const TextStyle(
                          color: AppTheme.error,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            "Didn't get it? Check your spam folder.",
                            style: TextStyle(
                              fontSize: 13.5,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('email_code_resend'),
                          onPressed: _resendIn > 0 || _busy ? null : _resend,
                          child: Text(
                            _resendIn > 0
                                ? 'Resend in ${_resendIn ~/ 60}:'
                                      '${(_resendIn % 60).toString().padLeft(2, '0')}'
                                : 'Resend code',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    AuthPrimaryButton(
                      key: const ValueKey('email_code_verify'),
                      label: 'Create account',
                      loading: _busy,
                      onPressed: _verify,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      AuthErrorBox(message: _error!),
                    ],
                    const SizedBox(height: 10),
                    TextButton(
                      key: const ValueKey('email_code_change'),
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Use a different email'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
