import 'package:flutter/material.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/pages/static_content_pages.dart';

/// The pieces the sign-in and sign-up screens share, so the two look like
/// one product: the soft glow behind them, the logo, the big button, the
/// strength bar under a new password, and the Terms and Privacy links.

/// A quiet blue glow at the top and a cyan one low on the right, over the
/// page's own background. Works in light and dark.
class AuthBackdrop extends StatelessWidget {
  final Widget child;

  const AuthBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -1.1),
                radius: 1.1,
                colors: [
                  AppTheme.primary.withValues(alpha: dark ? 0.28 : 0.14),
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
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            gradient: AppTheme.gradientCyber,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.45),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.bolt_rounded, size: 44, color: Colors.white),
        ),
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
