import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// The two-step code at sign-in. Shown after the password (or Google, or
/// Apple) was right, for an account with two-step verification on: six
/// digits from the authenticator app, or one of the recovery codes saved
/// when it was turned on.
///
/// Signed in, it closes everything above the app. The server's [ticket]
/// says the first step is done; it lasts five minutes.
class TwoStepSignInScreen extends StatefulWidget {
  const TwoStepSignInScreen({super.key, required this.ticket});

  final String ticket;

  @override
  State<TwoStepSignInScreen> createState() => _TwoStepSignInScreenState();
}

class _TwoStepSignInScreenState extends State<TwoStepSignInScreen> {
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  final _recovery = TextEditingController();

  /// Typing a recovery code instead of the app's six digits.
  bool _useRecovery = false;
  bool _busy = false;

  /// What is wrong with the code, under it.
  String? _codeError;

  /// What went wrong otherwise.
  String? _error;

  /// The ticket ran out: only starting again helps.
  bool _expired = false;

  @override
  void dispose() {
    _code.dispose();
    _codeFocus.dispose();
    _recovery.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy || _expired) return;
    final code = (_useRecovery ? _recovery.text : _code.text).trim();
    if (!_useRecovery && code.length != 6) {
      setState(() =>
          _codeError = 'Enter the 6-digit code from your authenticator app.');
      return;
    }
    if (_useRecovery && code.isEmpty) {
      setState(() => _codeError = 'Enter one of your recovery codes.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _codeError = null;
      _error = null;
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    var result = await auth.loginWithCode(context, widget.ticket, code);
    if (!mounted) return;
    // Waiting to be deleted: asked only now, after the code.
    if (result?.failure == AuthFailure.deletionPending) {
      // ignore: use_build_context_synchronously
      result = await keepIfChosen(context, result!);
      if (!mounted) return;
    }
    final why = result;
    if (why == null) {
      // Signed in: the app is underneath now.
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _busy = false;
      if (why.failure == AuthFailure.rejected && why.field == 'code') {
        _codeError = why.message ?? "That code isn't right.";
        _code.clear();
      } else if (why.failure == AuthFailure.expired) {
        _expired = true;
        _error = why.message ?? 'That took too long. Sign in again.';
      } else {
        _error = signInProblem(why);
      }
    });
  }

  void _switchKind() {
    setState(() {
      _useRecovery = !_useRecovery;
      _codeError = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: const BackButton(key: ValueKey('two_step_back')),
      ),
      body: AuthBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.space24, AppTheme.space16, AppTheme.space24, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  key: const ValueKey('two_step_screen'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AuthStepHeader(
                      icon: Icons.verified_user_rounded,
                      title: 'Two-step verification',
                      subtitle: Text(
                        _useRecovery
                            ? 'Enter one of the recovery codes you saved when '
                                'you turned on two-step verification. Each '
                                'works once.'
                            : 'Open your authenticator app and enter the '
                                '6-digit code it shows for '
                                '${AppConstants.appName}.',
                      ),
                    ),
                    const SizedBox(height: 28),
                    if (_useRecovery)
                      TextField(
                        key: const ValueKey('two_step_recovery'),
                        controller: _recovery,
                        enabled: !_busy && !_expired,
                        autofocus: true,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _verify(),
                        onChanged: (_) {
                          if (_codeError != null) {
                            setState(() => _codeError = null);
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Recovery code',
                          hintText: 'xxxxx-xxxxx',
                          errorText: _codeError,
                          prefixIcon: const Icon(Icons.key_rounded),
                        ),
                      )
                    else ...[
                      CodeBoxes(
                        fieldKey: const ValueKey('two_step_code'),
                        controller: _code,
                        focus: _codeFocus,
                        enabled: !_busy && !_expired,
                        error: _codeError != null,
                        onChanged: (value) {
                          if (_codeError != null) {
                            setState(() => _codeError = null);
                          }
                          // Six digits in: on with it, as the app's own
                          // code screens do.
                          if (value.length == 6) _verify();
                        },
                      ),
                      if (_codeError != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _codeError!,
                          key: const ValueKey('two_step_code_error'),
                          style: const TextStyle(
                              color: AppTheme.error, fontSize: 13.5),
                        ),
                      ],
                    ],
                    const SizedBox(height: 24),
                    if (_expired)
                      AuthPrimaryButton(
                        key: const ValueKey('two_step_start_again'),
                        label: 'Back to sign in',
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    else
                      AuthPrimaryButton(
                        key: const ValueKey('two_step_verify'),
                        label: 'Verify',
                        loading: _busy,
                        onPressed: _verify,
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      AuthErrorBox(message: _error!),
                    ],
                    const SizedBox(height: 10),
                    TextButton(
                      key: const ValueKey('two_step_switch'),
                      onPressed: _busy || _expired ? null : _switchKind,
                      child: Text(_useRecovery
                          ? 'Use your authenticator app instead'
                          : 'Use a recovery code instead'),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Lost your authenticator app and your recovery codes? '
                      'Write to ${AppConstants.supportEmail} from the email '
                      'on your account.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: scheme.onSurfaceVariant,
                      ),
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
