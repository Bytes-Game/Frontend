import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/screens/signup_screen.dart';
import 'package:myapp/screens/two_step_signin_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/social_auth.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// Signs in with [provider], all the way: the phone's own Google or Apple
/// sheet, then the server, then whatever comes next — the two-step code,
/// keeping an account that is waiting to be deleted, or finishing a new
/// account. Answers what to tell the person when it stops short, or null
/// (signed in, or they closed the sheet).
Future<String?> continueWith(
    BuildContext context, SocialProvider provider) async {
  final SocialCredential? credential;
  try {
    credential = await SocialAuth.instance.signIn(provider);
  } on SocialAuthFailure catch (e) {
    return e.message;
  } catch (e) {
    // Anything else: said, and in the log, rather than a button that spins
    // for ever.
    debugPrint('[signin] ${provider.label} sign-in failed: $e');
    return "Couldn't sign in with ${provider.label}. Please try again.";
  }
  if (credential == null || !context.mounted) return null;

  final auth = Provider.of<AuthProvider>(context, listen: false);
  var result = await auth.signInWith(context, provider, credential);
  if (!context.mounted) return null;
  if (result?.failure == AuthFailure.deletionPending) {
    result = await keepIfChosen(context, result!);
    if (!context.mounted) return null;
  }
  final why = result;
  if (why == null) {
    // Signed in: the app is underneath now, whichever page this was on.
    Navigator.of(context).popUntil((r) => r.isFirst);
    return null;
  }
  switch (why.failure) {
    case AuthFailure.twoFactorRequired when why.ticket != null:
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TwoStepSignInScreen(ticket: why.ticket!)));
      return null;
    case AuthFailure.needsSignup when why.extra != null:
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FinishSocialSignupScreen(
              start: SocialSignupStart.fromAnswer(provider, why.extra!))));
      return null;
    default:
      return signInProblem(why);
  }
}

/// "Continue with Google" and "Continue with Apple", for whichever this
/// build and phone offer (see SocialAuth.offers); nothing at all when
/// neither. Each runs [continueWith]; [onProblem] gets the words when one
/// stops short, and null when a new try starts.
class SocialSignInButtons extends StatefulWidget {
  const SocialSignInButtons({
    super.key,
    required this.onProblem,
    this.enabled = true,
    this.verb = 'Continue',
  });

  final ValueChanged<String?> onProblem;
  final bool enabled;

  /// "Continue with Google", or "Sign up with Google".
  final String verb;

  /// Whether any button would show.
  static bool get anyOffered =>
      SocialProvider.values.any(SocialAuth.instance.offers);

  @override
  State<SocialSignInButtons> createState() => _SocialSignInButtonsState();
}

class _SocialSignInButtonsState extends State<SocialSignInButtons> {
  SocialProvider? _busy;

  Future<void> _go(SocialProvider provider) async {
    widget.onProblem(null);
    setState(() => _busy = provider);
    final problem = await continueWith(context, provider);
    if (!mounted) return;
    setState(() => _busy = null);
    if (problem != null) widget.onProblem(problem);
  }

  @override
  Widget build(BuildContext context) {
    final offered =
        SocialProvider.values.where(SocialAuth.instance.offers).toList();
    if (offered.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in offered) ...[
          _ProviderButton(
            provider: p,
            label: '${widget.verb} with ${p.label}',
            busy: _busy == p,
            onPressed: widget.enabled && _busy == null ? () => _go(p) : null,
          ),
          if (p != offered.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// One provider's button, in the look its owner asks for: Google's on
/// white (or deep blue in dark mode) with its four-colour G, Apple's black
/// (white in dark mode) with its apple.
class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.provider,
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final SocialProvider provider;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final apple = provider == SocialProvider.apple;
    final Color fill = apple
        ? (dark ? Colors.white : Colors.black)
        : (dark ? const Color(0xCC0B1A2E) : Colors.white);
    final Color ink = apple
        ? (dark ? Colors.black : Colors.white)
        : (dark ? Colors.white : const Color(0xFF1F1F1F));
    final Color edge = apple
        ? fill
        : (dark ? const Color(0x3364D2FF) : const Color(0xFFDADCE0));
    return SizedBox(
      height: 52,
      child: OutlinedButton(
        key: ValueKey('social_${provider.id}'),
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: fill,
          foregroundColor: ink,
          disabledForegroundColor: ink.withValues(alpha: 0.5),
          side: BorderSide(color: edge, width: 1.2),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: ink),
              )
            else if (apple)
              Icon(Icons.apple, size: 24, color: ink)
            else
              const SizedBox(
                width: 20,
                height: 20,
                child: CustomPaint(painter: _GoogleG()),
              ),
            const SizedBox(width: 12),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
    );
  }
}

/// Google's four-colour G, drawn: a ring in red, yellow, green and blue,
/// and the blue bar.
class _GoogleG extends CustomPainter {
  const _GoogleG();

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final stroke = s * 0.2;
    final rect = Rect.fromCircle(
        center: Offset(s / 2, s / 2), radius: s / 2 - stroke / 2);
    Paint arc(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const deg = math.pi / 180;
    // Clockwise from the right, where the bar meets the ring.
    canvas.drawArc(rect, -40 * deg, -100 * deg, false,
        arc(const Color(0xFFEA4335))); // red, over the top
    canvas.drawArc(rect, -140 * deg, -85 * deg, false,
        arc(const Color(0xFFFBBC05))); // yellow, down the left
    canvas.drawArc(rect, 135 * deg, -95 * deg, false,
        arc(const Color(0xFF34A853))); // green, along the bottom
    canvas.drawArc(rect, 40 * deg, -40 * deg, false,
        arc(const Color(0xFF4285F4))); // blue, up the right
    canvas.drawRect(
      Rect.fromLTWH(s / 2, s / 2 - stroke / 2, s / 2 - stroke * 0.1, stroke),
      Paint()..color = const Color(0xFF4285F4),
    );
  }

  @override
  bool shouldRepaint(_GoogleG old) => false;
}
