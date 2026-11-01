import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/config/dates.dart';
import 'package:myapp/widgets/flex_logo.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';

/// The pieces the sign-in and sign-up screens share, so the two look like
/// one product: the soft glow behind them, the logo, the big button, the
/// strength bar under a new password, and the Terms and Privacy links.

/// A quiet blue glow at the top and a cyan one low on the right, over the
/// page's own background. In dark mode the page already glows blue from
/// the top (PageBackdrop), so only the cyan one is added.
class AuthBackdrop extends StatelessWidget {
  final Widget child;

  const AuthBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      // Fills the page, so the glows reach its foot however short the form.
      fit: StackFit.expand,
      children: [
        if (!dark)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -1.1),
                  radius: 1.1,
                  colors: [
                    AppTheme.primary.withValues(alpha: 0.14),
                    AppTheme.primary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(1.2, 1.1),
                radius: 0.9,
                colors: [
                  AppTheme.accentCyan.withValues(alpha: dark ? 0.14 : 0.10),
                  AppTheme.accentCyan.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// The logo, the app's name and one line under it.
class AuthBrand extends StatelessWidget {
  final String title;
  final String subtitle;

  const AuthBrand({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        const FlexLogo(size: 76),
        const SizedBox(height: 20),
        Text(
          AppConstants.appName,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 30,
            height: 1.1,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            height: 1.35,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The main button: full width, tall, with a spinner while it works.
class AuthPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppTheme.primary.withValues(alpha: 0.45),
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          textStyle: const TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              )
            : Text(label),
      ),
    );
  }
}

/// "or", with a thin line either side.
class AuthOrDivider extends StatelessWidget {
  const AuthOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Expanded(child: Divider(color: muted.withValues(alpha: 0.3))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('or', style: TextStyle(color: muted, fontSize: 13)),
        ),
        Expanded(child: Divider(color: muted.withValues(alpha: 0.3))),
      ],
    );
  }
}

/// An error under the form, in a soft red box.
class AuthErrorBox extends StatelessWidget {
  final String message;

  const AuthErrorBox({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('auth_error'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: AppTheme.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.error, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// How strong a new password is, 0 to 4. The server's minimum — 8
/// characters with a letter and a number — is 2; under it is at most 1.
int passwordScore(String password) {
  if (password.isEmpty) return 0;
  final hasLetter = password.contains(RegExp(r'[A-Za-z]'));
  final hasDigit = password.contains(RegExp(r'[0-9]'));
  if (password.length < 8 || !hasLetter || !hasDigit) return 1;
  var score = 2;
  final mixedCase = password.contains(RegExp(r'[a-z]')) &&
      password.contains(RegExp(r'[A-Z]'));
  final symbol = password.contains(RegExp(r'[^A-Za-z0-9]'));
  if (mixedCase || symbol) score++;
  if (password.length >= 12 && (mixedCase || symbol)) score++;
  return score;
}

/// The words for each [passwordScore].
const passwordScoreWords = ['', 'Too weak', 'Okay', 'Good', 'Strong'];

/// Four bars that fill and change colour as a new password gets stronger,
/// with a word for how strong it is.
class PasswordStrengthMeter extends StatelessWidget {
  final String password;

  const PasswordStrengthMeter({super.key, required this.password});

  static const _colors = [
    Colors.transparent,
    AppTheme.error,
    AppTheme.warning,
    AppTheme.primary,
    AppTheme.success,
  ];

  @override
  Widget build(BuildContext context) {
    final score = passwordScore(password);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      key: const ValueKey('password_strength'),
      children: [
        for (var i = 1; i <= 4; i++) ...[
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: 4,
              decoration: BoxDecoration(
                color: i <= score
                    ? _colors[score]
                    : muted.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (i < 4) const SizedBox(width: 6),
        ],
        const SizedBox(width: 10),
        SizedBox(
          width: 62,
          child: Text(
            passwordScoreWords[score],
            key: const ValueKey('password_strength_word'),
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: score == 0 ? muted : _colors[score],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Terms of Service · Privacy Policy", both tappable.
class AuthLegalLinks extends StatelessWidget {
  const AuthLegalLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    void open(Widget page) => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => page));
    final style = TextStyle(fontSize: 12.5, color: muted);
    final compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      minimumSize: const Size(0, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    // Wraps rather than overflows, on a narrow phone or with large text.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          key: const ValueKey('auth_terms'),
          style: compact,
          onPressed: () => open(const TermsOfServicePage()),
          child: Text('Terms of Service', style: style),
        ),
        Text('·', style: style),
        TextButton(
          key: const ValueKey('auth_privacy'),
          style: compact,
          onPressed: () => open(const PrivacyPolicyPage()),
          child: Text('Privacy Policy', style: style),
        ),
      ],
    );
  }
}

/// Six boxes for the code. One real text box lies over them, unseen: it
/// takes the typing, a paste, and the phone's own "fill in the code", and
/// the boxes show what it holds.
class CodeBoxes extends StatelessWidget {
  const CodeBoxes({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.error,
    required this.onChanged,
  });

  /// The key of the text box itself, for tests to type into.
  final Key fieldKey;
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
              key: fieldKey,
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

/// "Keep your account?" for an account waiting to be deleted, asked after
/// every check of a sign-in has passed (the password or Google/Apple, and
/// the two-step code). True when the person chooses to keep it.
Future<bool?> askToKeepAccount(BuildContext context, DateTime? deleteOn) {
  final when =
      deleteOn == null ? 'soon' : 'on ${dateInWords(deleteOn.toLocal())}';
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('keep_account_dialog'),
      title: const Text('Keep your account?'),
      content: Text(
        'You asked for this account to be deleted. It will be deleted for '
        'good $when.\n\n'
        'Keep it to sign in and get everything back: your profile, posts, '
        'followers and messages. Battles that were going on when you left '
        'stay cancelled.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const ValueKey('keep_account'),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Keep my account'),
        ),
      ],
    ),
  );
}

/// The top of a sign-in step: an icon on the app's blue, a big title and a
/// line under it.
class AuthStepHeader extends StatelessWidget {
  const AuthStepHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final Widget subtitle;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

/// What to tell somebody whose sign-in stopped short, in plain words. An
/// unreachable server is never reported as a wrong password: that sends
/// people off resetting a password that was fine, which is what happened
/// when the server was waking up.
String signInProblem(AuthResult result) {
  switch (result.failure ?? AuthFailure.unreachable) {
    case AuthFailure.rejected:
      return result.message != null && result.field == null
          ? result.message!
          : "That username, email or password isn't right.";
    case AuthFailure.unreachable:
      return "Couldn't reach the server. It may be waking up — "
          'wait a few seconds and try again.';
    case AuthFailure.serverError:
      return 'The server had a problem. Your details are probably fine — '
          'please try again in a moment.';
    case AuthFailure.deletionPending:
      return 'This account is waiting to be deleted. Sign in again and '
          'choose "Keep my account" to stop that.';
    case AuthFailure.twoFactorRequired:
      return 'Enter the code from your authenticator app to sign in.';
    case AuthFailure.needsSignup:
      return 'Finish making your account to sign in.';
    case AuthFailure.unavailable:
      return result.message ?? "That way of signing in isn't set up yet.";
    case AuthFailure.expired:
      return result.message ?? 'That took too long. Please start again.';
  }
}

/// For a sign-in that answered [AuthFailure.deletionPending]: asks "Keep
/// your account?", and keeps it when the person chooses to. The answer's
/// ticket keeps it without anything typed again; [withoutTicket] is for an
/// older server that sent none. Not kept: the same answer stands.
Future<AuthResult?> keepIfChosen(BuildContext context, AuthResult waiting,
    {Future<AuthResult?> Function()? withoutTicket}) async {
  final keep = await askToKeepAccount(context, waiting.deleteOn);
  if (keep != true || !context.mounted) return waiting;
  final ticket = waiting.ticket;
  if (ticket != null) {
    return Provider.of<AuthProvider>(context, listen: false)
        .loginWithCode(context, ticket, '', keepAccount: true);
  }
  return withoutTicket == null ? waiting : withoutTicket();
}
