import 'dart:async';

import 'package:flutter/material.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// What a finished reset hands back to the sign-in screen: the account's
/// username, to fill in. Not the new password: the person signs in with it
/// themselves.
class PasswordResetDone {
  const PasswordResetDone({required this.username});

  final String username;
}

/// The three steps of [ForgotPasswordScreen].
enum _Step { find, code, password }

/// "Forgot password?", in three steps:
///
///  1. Your username or email. A 6-digit code goes to the email address on
///     the account.
///  2. The code. The server checks it before anything else is asked.
///  3. A new password: only once the code is right.
///
/// Finishing hands a [PasswordResetDone] back. Nobody is signed in: the
/// sign-in screen asks for the new password, and the person signs in.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.login = ''});

  /// What was already typed on the sign-in screen, to start from.
  final String login;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _login = TextEditingController(text: widget.login);
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  final _password = TextEditingController();

  /// Which step is showing.
  _Step _step = _Step.find;

  /// The username or email the code was sent for. The second step uses this
  /// one, whatever is in the first step's box by then.
  String _sentFor = '';

  /// Where the code went (k•••n@gmail.com). Only known for a username.
  String? _sentTo;

  /// A code was already on its way when this one was asked for.
  bool _alreadySent = false;

  /// "Resend" was used, and a new code went out.
  bool _resent = false;

  bool _busy = false;
  bool _obscure = true;

  /// What went wrong, for the whole step.
  String? _error;

  /// What is wrong with the code, under the boxes.
  String? _codeError;

  /// What is wrong with the new password, under its box.
  String? _passwordError;

  /// Seconds until another code may be asked for.
  int _resendIn = 0;
  Timer? _tick;

  static const _unreachable = "Couldn't reach the server. It may be waking "
      'up — wait a few seconds and try again.';
  static const _serverFailed =
      'The server had a problem. Please try again in a moment.';

  @override
  void dispose() {
    _tick?.cancel();
    _login.dispose();
    _code.dispose();
    _codeFocus.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Counts down to when "Resend" works again.
  void _countDown(int seconds) {
    _tick?.cancel();
    setState(() => _resendIn = seconds > 0 ? seconds : 0);
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

  /// What to say for an answer that is not about the account.
  String _sayFor(ResetCodeAsk ask) {
    switch (ask.answer) {
      case ResetCodeAnswer.serverError:
        return _serverFailed;
      case ResetCodeAnswer.unreachable:
        return _unreachable;
      default:
        return ask.message ?? "Couldn't send a code. Please try again.";
    }
  }

  /// Step 1: send a code.
  Future<void> _sendCode() async {
    final login = _login.text.trim();
    if (login.isEmpty) {
      setState(() => _error = 'Enter your username or email.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final ask = await ApiService.askResetCode(login);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (ask.answer) {
      case ResetCodeAnswer.sent:
      case ResetCodeAnswer.tooSoon:
        // "Too soon" means a code went out under a minute ago, and that one
        // still works: on to entering it.
        setState(() {
          _step = _Step.code;
          _sentFor = login;
          _sentTo = ask.sentTo;
          _alreadySent = ask.answer == ResetCodeAnswer.tooSoon;
          _resent = false;
          _code.clear();
          _password.clear();
          _codeError = null;
          _passwordError = null;
        });
        _countDown(ask.resendIn);
      default:
        setState(() => _error = _sayFor(ask));
    }
  }

  /// Step 2: another code, for the same account.
  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
      _codeError = null;
    });
    final ask = await ApiService.askResetCode(_sentFor);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (ask.answer) {
      case ResetCodeAnswer.sent:
        setState(() {
          _resent = true;
          _alreadySent = false;
          _sentTo = ask.sentTo ?? _sentTo;
          _code.clear();
        });
        _countDown(ask.resendIn);
        _codeFocus.requestFocus();
      case ResetCodeAnswer.tooSoon:
        setState(() => _error = ask.message);
        _countDown(ask.resendIn);
      default:
        setState(() => _error = _sayFor(ask));
    }
  }

  /// Sign-up's rules, said before the server has to say them.
  static String? _passwordProblem(String p) {
    if (p.isEmpty) return 'Choose a new password.';
    if (p.length < 8) return 'Use at least 8 characters.';
    if (!p.contains(RegExp(r'[A-Za-z]')) || !p.contains(RegExp(r'[0-9]'))) {
      return 'Use at least one letter and one number.';
    }
    return null;
  }

  /// A code that is finished with: said under the boxes, which are emptied,
  /// and a new one can be asked for straight away.
  void _codeSpent(String? why) {
    _tick?.cancel();
    setState(() {
      _step = _Step.code;
      _codeError = why;
      _code.clear();
      _resendIn = 0;
    });
  }

  /// Step 2: is the code right? Only then is a new password asked for.
  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() {
        _codeError = 'Enter the 6-digit code from the email.';
        _error = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _codeError = null;
    });
    final check = await ApiService.verifyResetCode(_sentFor, code);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (check.answer) {
      case ResetCodeCheckAnswer.right:
      case ResetCodeCheckAnswer.notChecked:
        setState(() {
          _step = _Step.password;
          _password.clear();
          _passwordError = null;
        });
      case ResetCodeCheckAnswer.wrong:
        setState(() => _codeError = check.message);
      case ResetCodeCheckAnswer.expired:
        _codeSpent(check.message);
      case ResetCodeCheckAnswer.tooMany:
      case ResetCodeCheckAnswer.refused:
        setState(() => _error = check.message);
      case ResetCodeCheckAnswer.serverError:
        setState(() => _error = _serverFailed);
      case ResetCodeCheckAnswer.unreachable:
        setState(() => _error = _unreachable);
    }
  }

  /// Step 3: the new password, with the code that was checked.
  Future<void> _reset() async {
    final password = _password.text;
    final problem = _passwordProblem(password);
    if (problem != null) {
      setState(() {
        _passwordError = problem;
        _error = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _passwordError = null;
    });
    final result =
        await ApiService.resetPassword(_sentFor, _code.text.trim(), password);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.answer) {
      case PasswordResetAnswer.reset:
        _tick?.cancel();
        Navigator.of(context)
            .pop(PasswordResetDone(username: result.username ?? _sentFor));
      case PasswordResetAnswer.wrongCode:
        // The code stopped working after it was checked: back to it.
        setState(() {
          _step = _Step.code;
          _codeError = result.message;
        });
      case PasswordResetAnswer.expired:
        // It ran out while the password was chosen. Back to the code, with
        // a new one a tap away.
        _codeSpent(result.message);
      case PasswordResetAnswer.badPassword:
        setState(() => _passwordError = result.message);
      case PasswordResetAnswer.tooMany:
      case PasswordResetAnswer.refused:
        setState(() => _error = result.message);
      case PasswordResetAnswer.serverError:
        setState(() => _error = _serverFailed);
      case PasswordResetAnswer.unreachable:
        setState(() => _error = _unreachable);
    }
  }

  /// Back to step 1, to use another username or email.
  void _restart() {
    _tick?.cancel();
    setState(() {
      _step = _Step.find;
      _resendIn = 0;
      _error = null;
      _codeError = null;
      _passwordError = null;
      _code.clear();
      _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      // Back goes one step back: from the new password to the code (still
      // filled in), from the code to step 1, and only then out.
      canPop: _step == _Step.find,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _busy) return;
        if (_step == _Step.password) {
          setState(() {
            _step = _Step.code;
            _error = null;
            _passwordError = null;
          });
        } else {
          _restart();
        }
      },
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: const BackButton(key: ValueKey('forgot_back')),
        ),
        body: AuthBackdrop(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.space24,
                AppTheme.space16,
                AppTheme.space24,
                AppTheme.space32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: switch (_step) {
                      _Step.find => _findStep(scheme),
                      _Step.code => _codeStep(scheme),
                      _Step.password => _passwordStep(scheme),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _findStep(ColorScheme scheme) {
    return Column(
      key: const ValueKey('forgot_step_find'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHeader(
          step: 1,
          icon: Icons.lock_reset_rounded,
          title: 'Forgot password?',
          subtitle: Text(
            "Enter your username or email. We'll send a 6-digit code to the "
            'email address on your account.',
          ),
        ),
        const SizedBox(height: 28),
        TextField(
          key: const ValueKey('forgot_login'),
          controller: _login,
          enabled: !_busy,
          autofocus: widget.login.isEmpty,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.send,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          onSubmitted: (_) => _sendCode(),
          decoration: const InputDecoration(
            labelText: 'Username or email',
            prefixIcon: Icon(Icons.person_outline_rounded),
          ),
        ),
        const SizedBox(height: 20),
        AuthPrimaryButton(
          key: const ValueKey('forgot_send'),
          label: 'Send code',
          loading: _busy,
          onPressed: _sendCode,
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          AuthErrorBox(message: _error!),
        ],
        const SizedBox(height: 28),
        _HelpNote(
          icon: Icons.support_agent_rounded,
          text: "Can't get into that email any more? Write to "
              '${AppConstants.supportEmail} and tell us your username. '
              "We'll help you get back in.",
        ),
      ],
    );
  }

  Widget _codeStep(ColorScheme scheme) {
    final strong =
        TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface);
    final Widget where;
    if (_alreadySent) {
      where = const Text(
        'We sent a code to the email on this account a moment ago. It works '
        'for 15 minutes.',
      );
    } else if (_sentTo != null) {
      where = Text.rich(
        TextSpan(children: [
          TextSpan(text: _resent ? 'We sent a new code to ' : 'We sent it to '),
          TextSpan(text: _sentTo, style: strong),
          const TextSpan(text: '. It works for 15 minutes.'),
        ]),
        key: const ValueKey('forgot_sent_to'),
      );
    } else {
      // An email address: never confirmed nor denied, so "if".
      where = Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'If '),
          TextSpan(text: _sentFor, style: strong),
          TextSpan(
            text: _resent
                ? " belongs to an account, we've sent a new code to it. It "
                    'works for 15 minutes.'
                : " belongs to an account, we've sent a code to it. It works "
                    'for 15 minutes.',
          ),
        ]),
        key: const ValueKey('forgot_sent_to'),
      );
    }
    return Column(
      key: const ValueKey('forgot_step_code'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          step: 2,
          icon: Icons.mark_email_unread_rounded,
          title: 'Enter the code',
          subtitle: where,
        ),
        const SizedBox(height: 28),
        CodeBoxes(
          fieldKey: const ValueKey('forgot_code'),
          controller: _code,
          focus: _codeFocus,
          enabled: !_busy,
          error: _codeError != null,
          onChanged: (value) {
            if (_codeError != null) setState(() => _codeError = null);
            // All six typed: checked at once, as the sign-in code is.
            if (value.length == 6 && !_busy) _verify();
          },
        ),
        if (_codeError != null) ...[
          const SizedBox(height: 10),
          Text(
            _codeError!,
            key: const ValueKey('forgot_code_error'),
            style: const TextStyle(color: AppTheme.error, fontSize: 13.5),
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
              key: const ValueKey('forgot_resend'),
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
          key: const ValueKey('forgot_verify'),
          label: 'Verify code',
          loading: _busy,
          onPressed: _verify,
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          AuthErrorBox(message: _error!),
        ],
        const SizedBox(height: 10),
        TextButton(
          key: const ValueKey('forgot_restart'),
          onPressed: _busy ? null : _restart,
          child: const Text('Use a different username or email'),
        ),
      ],
    );
  }

  Widget _passwordStep(ColorScheme scheme) {
    return Column(
      key: const ValueKey('forgot_step_password'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHeader(
          step: 3,
          icon: Icons.password_rounded,
          title: 'Choose a new password',
          subtitle: Text(
            "Your code is right. Choose a new password, then you'll sign in "
            'with it.',
          ),
        ),
        const SizedBox(height: 28),
        TextField(
          key: const ValueKey('forgot_new_password'),
          controller: _password,
          enabled: !_busy,
          autofocus: true,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.newPassword],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _reset(),
          onChanged: (_) => setState(() => _passwordError = null),
          decoration: InputDecoration(
            labelText: 'New password',
            helperText: _passwordError == null
                ? 'At least 8 characters, with a letter and a number.'
                : null,
            errorText: _passwordError,
            errorMaxLines: 3,
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              tooltip: _obscure ? 'Show password' : 'Hide password',
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 12),
        PasswordStrengthMeter(password: _password.text),
        const SizedBox(height: 24),
        AuthPrimaryButton(
          key: const ValueKey('forgot_reset'),
          label: 'Reset password',
          loading: _busy,
          onPressed: _reset,
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          AuthErrorBox(message: _error!),
        ],
      ],
    );
  }
}

/// "Step 1 of 3" with three bars, an icon, a big title and a line under it.
class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.step,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  /// How many steps there are: [_Step]'s.
  static final _steps = _Step.values.length;

  final int step;
  final IconData icon;
  final String title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (var i = 1; i <= _steps; i++) ...[
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= step
                        ? AppTheme.primary
                        : muted.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (i < _steps) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Step $step of $_steps',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: muted,
          ),
        ),
        const SizedBox(height: 26),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: AppTheme.gradientCyber,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.35),
                blurRadius: 28,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
        const SizedBox(height: 22),
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            height: 1.15,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 10),
        DefaultTextStyle.merge(
          style: TextStyle(fontSize: 15, height: 1.45, color: muted),
          child: subtitle,
        ),
      ],
    );
  }
}

/// A quiet card with one helpful line.
class _HelpNote extends StatelessWidget {
  const _HelpNote({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
