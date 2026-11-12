import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// "Ask your parent or guardian."
///
/// Shown to somebody younger than the age at which a parent must agree
/// where they are (18 in most places). They have no account yet. The
/// server has emailed their parent or guardian a link; the account is made
/// when the parent opens it and says yes, and nothing is kept if they say
/// no or do not answer in seven days.
///
/// From here the young person can check whether the parent has answered,
/// have the email sent again, send it to a different address, or cancel,
/// which deletes what they entered at once.
class ParentConsentScreen extends StatefulWidget {
  const ParentConsentScreen({
    super.key,
    required this.wait,
    required this.onCheck,
  });

  /// What the server said when it put the sign-up aside.
  final ParentWait wait;

  /// Signs in again the way the person signed up: with their username and
  /// password, or with Google or Apple. Null when it worked, which means
  /// the parent agreed; otherwise the answer, which says it is still
  /// waiting or what went wrong.
  final Future<AuthResult?> Function(BuildContext context) onCheck;

  @override
  State<ParentConsentScreen> createState() => _ParentConsentScreenState();
}

enum _Doing { nothing, checking, sending, cancelling }

class _ParentConsentScreenState extends State<ParentConsentScreen> {
  late ParentWait _wait = widget.wait;
  final _newAddress = TextEditingController();

  _Doing _doing = _Doing.nothing;

  /// Typing a different address for the parent.
  bool _changing = false;

  /// Good news: "Sent."
  String? _notice;

  /// Not bad news, not good news: "They haven't answered yet."
  String? _info;

  String? _error;

  /// Nothing more can be done from here: the sign-up ran out, or the
  /// ticket did. Only going back to sign in helps.
  bool _ended = false;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  bool get _busy => _doing != _Doing.nothing;

  @override
  void dispose() {
    _newAddress.dispose();
    super.dispose();
  }

  void _clearMessages() {
    _notice = null;
    _info = null;
    _error = null;
  }

  void _backToSignIn() => Navigator.of(context).popUntil((r) => r.isFirst);

  /// "They said yes": try to sign in. It works only once the parent has
  /// agreed.
  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _doing = _Doing.checking;
      _clearMessages();
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final result = await widget.onCheck(context);
    if (!mounted) return;
    if (result == null) {
      // Signed in, for the first time: the welcome steps, as for any new
      // account. The app is underneath now.
      auth.welcomeNewAccount();
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _doing = _Doing.nothing;
      switch (result.failure) {
        case AuthFailure.parentConsentPending:
          // Still waiting, or refused. Either way the answer carries a
          // fresh ticket.
          if (result.extra != null) {
            _wait = ParentWait.fromAnswer(result.extra!);
          }
          if (!_wait.declined) {
            _info =
                "They haven't answered yet. Ask them to look for an "
                'email from Flexete, in their spam folder too.';
          }
        case AuthFailure.rejected:
          // No sign-up and no account answers to these details any more:
          // the seven days ran out, or it was cancelled.
          _ended = true;
          _error =
              'This sign-up is no longer waiting. Sign up again to '
              'start over.';
        default:
          _error = signInProblem(result);
      }
    });
  }

  /// Sends the email again, or to [newAddress] instead.
  Future<void> _send({String? newAddress}) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _doing = _Doing.sending;
      _clearMessages();
    });
    final result = await ApiService.parentEmail(
      _wait.ticket,
      newAddress: newAddress,
    );
    if (!mounted) return;
    setState(() {
      _doing = _Doing.nothing;
      switch (result.answer) {
        case ParentEmailAnswer.sent:
          _wait = result.wait ?? _wait;
          _changing = false;
          _newAddress.clear();
          _notice = _wait.parentEmail.isEmpty
              ? 'Sent.'
              : 'Sent to ${_wait.parentEmail}.';
        case ParentEmailAnswer.refused:
          _error = result.message ?? "Couldn't send the email.";
        case ParentEmailAnswer.expired:
          _ended = true;
          _error =
              'That took too long. Go back and sign in again to '
              'carry on.';
        case ParentEmailAnswer.gone:
          _ended = true;
          _error =
              result.message ??
              'This sign-up is no longer waiting. Sign up again to start '
                  'over.';
        case ParentEmailAnswer.cancelled:
        case ParentEmailAnswer.failed:
          _error =
              result.message ??
              "Couldn't send the email right now. Try again in a little "
                  'while.';
      }
    });
  }

  void _sendToNewAddress() {
    final address = _newAddress.text.trim();
    if (!_emailRe.hasMatch(address)) {
      setState(() {
        _clearMessages();
        _error = "That doesn't look like an email address.";
      });
      return;
    }
    _send(newAddress: address);
  }

  /// Cancels the sign-up, once the person has said they mean it.
  Future<void> _cancel() async {
    if (_busy) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel your sign-up?'),
        content: const Text(
          'What you entered is deleted now, and the link we emailed your '
          'parent or guardian stops working. You can sign up again any '
          'time.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('parent_wait_cancel_no'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep waiting'),
          ),
          TextButton(
            key: const ValueKey('parent_wait_cancel_yes'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Cancel sign-up'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _doing = _Doing.cancelling;
      _clearMessages();
    });
    final result = await ApiService.parentEmail(_wait.ticket, cancel: true);
    if (!mounted) return;
    switch (result.answer) {
      // Deleted, or there was nothing left to delete.
      case ParentEmailAnswer.cancelled:
      case ParentEmailAnswer.gone:
        _backToSignIn();
      default:
        setState(() {
          _doing = _Doing.nothing;
          _ended = result.answer == ParentEmailAnswer.expired;
          _error = result.answer == ParentEmailAnswer.expired
              ? 'That took too long. Go back and sign in again, then '
                    'cancel.'
              : result.message ??
                    "Couldn't cancel right now. Try again in a little while.";
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final strong = TextStyle(
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    );
    final declined = _wait.declined;
    final address = _wait.parentEmail.isEmpty
        ? 'your parent or guardian'
        : _wait.parentEmail;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: BackButton(
          key: const ValueKey('parent_wait_back'),
          onPressed: _backToSignIn,
        ),
      ),
      body: AuthBackdrop(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  key: const ValueKey('parent_wait'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AuthStepHeader(
                      icon: declined
                          ? Icons.do_not_disturb_on_outlined
                          : Icons.family_restroom_rounded,
                      title: declined
                          ? 'Your parent or guardian said no'
                          : 'Ask your parent or guardian',
                      subtitle: declined
                          ? const Text(
                              'So no account was made. What you entered is '
                              'deleted within a day.',
                              key: ValueKey('parent_wait_declined'),
                            )
                          : Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(
                                    text:
                                        'You need their permission to '
                                        'join Flexete. We emailed ',
                                  ),
                                  TextSpan(text: address, style: strong),
                                  const TextSpan(text: '.'),
                                ],
                              ),
                              key: const ValueKey('parent_wait_sent_to'),
                            ),
                    ),
                    const SizedBox(height: 24),
                    if (!declined) ...[
                      const _Steps(
                        steps: [
                          'They open the email from Flexete.',
                          'They read what Flexete is and tap "I agree".',
                          'You come back here and sign in.',
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The link works for 7 days. Until they agree, you '
                        'have no account and nothing about you is shown to '
                        'anyone.',
                        style: TextStyle(
                          color: muted,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 22),
                    ],
                    if (_notice != null) ...[
                      AuthNoticeBox(message: _notice!),
                      const SizedBox(height: 14),
                    ],
                    if (_info != null) ...[
                      _InfoBox(message: _info!),
                      const SizedBox(height: 14),
                    ],
                    if (_error != null) ...[
                      AuthErrorBox(message: _error!),
                      const SizedBox(height: 14),
                    ],
                    if (declined || _ended)
                      AuthPrimaryButton(
                        key: const ValueKey('parent_wait_to_signin'),
                        label: 'Back to sign in',
                        onPressed: _backToSignIn,
                      )
                    else ...[
                      AuthPrimaryButton(
                        key: const ValueKey('parent_wait_check'),
                        label: 'They said yes — sign me in',
                        loading: _doing == _Doing.checking,
                        onPressed: _busy ? null : _check,
                      ),
                      const SizedBox(height: 10),
                      if (_changing) ...[
                        const SizedBox(height: 8),
                        TextField(
                          key: const ValueKey('parent_wait_new_email'),
                          controller: _newAddress,
                          enabled: !_busy,
                          autocorrect: false,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendToNewAddress(),
                          decoration: const InputDecoration(
                            labelText: "Parent or guardian's email",
                            helperText:
                                'Their own email, not yours. The '
                                'old link stops working.',
                            helperMaxLines: 2,
                            prefixIcon: Icon(Icons.mail_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey('parent_wait_change_no'),
                                onPressed: _busy
                                    ? null
                                    : () => setState(() {
                                        _changing = false;
                                        _clearMessages();
                                      }),
                                child: const Text('Never mind'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                key: const ValueKey('parent_wait_send_new'),
                                onPressed: _busy ? null : _sendToNewAddress,
                                child: _doing == _Doing.sending
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('Send'),
                              ),
                            ),
                          ],
                        ),
                      ] else
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              key: const ValueKey('parent_wait_resend'),
                              onPressed: _busy ? null : () => _send(),
                              child: Text(
                                _doing == _Doing.sending
                                    ? 'Sending…'
                                    : 'Send the email again',
                              ),
                            ),
                            TextButton(
                              key: const ValueKey('parent_wait_change'),
                              onPressed: _busy
                                  ? null
                                  : () => setState(() {
                                      _changing = true;
                                      _clearMessages();
                                    }),
                              child: const Text('Use a different email'),
                            ),
                          ],
                        ),
                      const SizedBox(height: 18),
                      Center(
                        child: TextButton(
                          key: const ValueKey('parent_wait_cancel'),
                          onPressed: _busy ? null : _cancel,
                          style: TextButton.styleFrom(foregroundColor: muted),
                          child: Text(
                            _doing == _Doing.cancelling
                                ? 'Cancelling…'
                                : 'Cancel my sign-up',
                          ),
                        ),
                      ),
                    ],
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

/// Numbered steps, one under the other.
class _Steps extends StatelessWidget {
  const _Steps({required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      steps[i],
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 15,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Neither good news nor bad: "They haven't answered yet."
class _InfoBox extends StatelessWidget {
  const _InfoBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('parent_wait_info'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.hourglass_top_rounded,
            color: AppTheme.primary,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onSurface, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}
