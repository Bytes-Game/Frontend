import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// What a finished reset hands back to the sign-in screen: the account's
/// username and its new password, to sign in with the ordinary way.
class PasswordResetDone {
  const PasswordResetDone({required this.username, required this.password});

  final String username;
  final String password;
}

/// "Forgot password?", in two steps:
///
///  1. Your username or email. A 6-digit code goes to the email address on
///     the account.
///  2. The code, and a new password.
///
/// Finishing hands a [PasswordResetDone] back, and the sign-in screen signs
/// in with it. The server signs nobody in by itself, so everything that
/// signing in checks is still checked.
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

  /// False: the first step. True: the code and the new password.
  bool _codeSent = false;

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
          _codeSent = true;
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

  /// Step 2: the code and the new password.
  Future<void> _reset() async {
    final code = _code.text.trim();
    final password = _password.text;
    final codeProblem =
        code.length == 6 ? null : 'Enter the 6-digit code from the email.';
    final passwordProblem = _passwordProblem(password);
    if (codeProblem != null || passwordProblem != null) {
      setState(() {
        _codeError = codeProblem;
        _passwordError = passwordProblem;
        _error = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _codeError = null;
      _passwordError = null;
    });
    final result = await ApiService.resetPassword(_sentFor, code, password);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.answer) {
      case PasswordResetAnswer.reset:
        _tick?.cancel();
        Navigator.of(context).pop(PasswordResetDone(
          username: result.username ?? _sentFor,
          password: password,
        ));
      case PasswordResetAnswer.wrongCode:
        setState(() => _codeError = result.message);
      case PasswordResetAnswer.expired:
        // That code is finished with. A new one can be asked for straight
        // away.
        _tick?.cancel();
        setState(() {
          _codeError = result.message;
          _code.clear();
          _resendIn = 0;
        });
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
      _codeSent = false;
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
      // Back on step 2 goes to step 1, not out.
      canPop: !_codeSent,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _restart();
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
                    child: _codeSent ? _codeStep(scheme) : _findStep(scheme),
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
        _CodeBoxes(
          controller: _code,
          focus: _codeFocus,
          enabled: !_busy,
          error: _codeError != null,
          onChanged: (_) {
            if (_codeError != null) setState(() => _codeError = null);
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
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('forgot_new_password'),
          controller: _password,
          enabled: !_busy,
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
        const SizedBox(height: 10),
        TextButton(
          key: const ValueKey('forgot_restart'),
          onPressed: _busy ? null : _restart,
          child: const Text('Use a different username or email'),
        ),
      ],
    );
  }
}

/// "Step 1 of 2" with two bars, an icon, a big title and a line under it.
class _StepHeader extends StatelessWidget {
  const _StepHeader({
    required this.step,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

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
            for (var i = 1; i <= 2; i++) ...[
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
              if (i < 2) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Step $step of 2',
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
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 24,
                offset: const Offset(0, 8),
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

/// Six boxes for the code. One real text box lies over them, unseen: it
/// takes the typing, a paste, and the phone's own "fill in the code", and
/// the boxes show what it holds.
class _CodeBoxes extends StatelessWidget {
  const _CodeBoxes({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.error,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool enabled;
  final bool error;
  final ValueChanged<String> onChanged;

  static const _length = 6;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 60,
      child: Stack(
        children: [
          ListenableBuilder(
            listenable: Listenable.merge([controller, focus]),
            builder: (context, _) {
              final code = controller.text;
              return Row(
                children: [
                  for (var i = 0; i < _length; i++) ...[
                    Expanded(child: _box(i, code, scheme, dark)),
                    if (i < _length - 1) const SizedBox(width: 10),
                  ],
                ],
              );
            },
          ),
          Positioned.fill(
            child: TextField(
              key: const ValueKey('forgot_code'),
              controller: controller,
              focusNode: focus,
              enabled: enabled,
              autofocus: true,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(_length),
              ],
              onChanged: onChanged,
              showCursor: false,
              cursorColor: Colors.transparent,
              style: const TextStyle(color: Colors.transparent, fontSize: 1),
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                isCollapsed: true,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _box(int i, String code, ColorScheme scheme, bool dark) {
    final digit = i < code.length ? code[i] : '';
    final active = enabled &&
        focus.hasFocus &&
        (i == code.length || (code.length == _length && i == _length - 1));
    final Color edge = error
        ? AppTheme.error
        : active
            ? AppTheme.primary
            : digit.isNotEmpty
                ? AppTheme.primary.withValues(alpha: 0.5)
                : scheme.onSurfaceVariant.withValues(alpha: 0.25);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark
            ? Colors.white.withValues(alpha: 0.06)
            : AppTheme.surfaceLightHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: edge, width: active || error ? 2 : 1.2),
        boxShadow: active
            ? [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.25),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Text(
        digit,
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
