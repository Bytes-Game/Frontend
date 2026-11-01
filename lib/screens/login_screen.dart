import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/screens/forgot_password_screen.dart';
import 'package:myapp/screens/signup_screen.dart';
import 'package:myapp/screens/social_sign_in.dart';
import 'package:myapp/screens/two_step_signin_screen.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// Sign in, with your username or your email. "Create new account" opens
/// the sign-up page, which has every box a new account needs.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    // Sent here by "Create a new account" in Settings: straight on to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = Provider.of<AuthProvider>(context, listen: false);
      if (auth.takeOpenSignup()) _openSignup();
    });
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _openSignup() {
    setState(() => _error = null);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
  }

  Future<void> _submit() async {
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() =>
          _error = 'Enter your username or email, and your password.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = Provider.of<AuthProvider>(context, listen: false);
    var failure = await auth.login(context, user, pass);

    // The account asked to be deleted and is waiting out its 30 days. Ask:
    // only the person's own tap keeps it.
    if (mounted && failure?.failure == AuthFailure.deletionPending) {
      // ignore: use_build_context_synchronously
      failure = await keepIfChosen(context, failure!,
          // ignore: use_build_context_synchronously
          withoutTicket: () => auth.login(context, user, pass,
              keepAccount: true));
    }
    if (!mounted) return;

    // Two-step verification is on: the code is next, on its own screen,
    // which signs in when it is right.
    final ticket = failure?.ticket;
    if (failure?.failure == AuthFailure.twoFactorRequired && ticket != null) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TwoStepSignInScreen(ticket: ticket)));
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final why = failure;
    if (why != null) {
      setState(() {
        _isLoading = false;
        _error = signInProblem(why);
      });
    }
  }

  /// "Forgot password?": a code by email, then a new password. Coming back
  /// with one signs in with it, the ordinary way, so everything signing in
  /// checks (an account waiting to be deleted, say) is still checked.
  Future<void> _forgotPassword() async {
    setState(() => _error = null);
    final done = await Navigator.of(context).push<PasswordResetDone>(
      MaterialPageRoute(
        builder: (_) =>
            ForgotPasswordScreen(login: _usernameCtrl.text.trim()),
      ),
    );
    if (!mounted || done == null) return;
    _usernameCtrl.text = done.username;
    _passwordCtrl.text = done.password;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        key: ValueKey('password_reset_done'),
        content: Text('Password changed. Signing you in…'),
      ),
    );
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: AuthBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space24,
                vertical: AppTheme.space32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AuthBrand(
                        title: 'Welcome back',
                        subtitle: 'Sign in to keep battling.',
                      ),
                      const SizedBox(height: 36),
                      TextField(
                        key: const ValueKey('login_username'),
                        controller: _usernameCtrl,
                        enabled: !_isLoading,
                        autocorrect: false,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Username or email',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('login_password'),
                        controller: _passwordCtrl,
                        enabled: !_isLoading,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            tooltip:
                                _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: scheme.onSurfaceVariant,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const ValueKey('login_forgot'),
                          onPressed: _isLoading ? null : _forgotPassword,
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      AuthPrimaryButton(
                        key: const ValueKey('login_submit'),
                        label: 'Sign in',
                        loading: _isLoading,
                        onPressed: _submit,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        AuthErrorBox(message: _error!),
                      ],
                      const SizedBox(height: 26),
                      const AuthOrDivider(),
                      const SizedBox(height: 26),
                      if (SocialSignInButtons.anyOffered) ...[
                        SocialSignInButtons(
                          enabled: !_isLoading,
                          onProblem: (why) => setState(() => _error = why),
                        ),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        height: 54,
                        child: OutlinedButton.icon(
                          key: const ValueKey('login_create_account'),
                          onPressed: _isLoading ? null : _openSignup,
                          icon: const Icon(Icons.person_add_alt_1_rounded),
                          label: const Text('Create new account'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primary,
                            side: BorderSide(
                              color: AppTheme.primary.withValues(alpha: 0.6),
                              width: 1.4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusLg),
                            ),
                            textStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      const AuthLegalLinks(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
