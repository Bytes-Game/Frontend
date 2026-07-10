import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';

/// Clean, professional auth screen — sign-in and create-account in one
/// surface with a mode toggle (the IG/TikTok pattern; a separate signup
/// route just adds a navigation hop to the highest-dropoff screen in
/// any app).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

enum _Availability { unknown, checking, available, taken, invalid }

class _LoginScreenState extends State<LoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;
  String? _error;
  bool _obscure = true;

  // Signup mode + live username availability.
  bool _signupMode = false;
  _Availability _availability = _Availability.unknown;
  Timer? _availDebounce;
  static final _usernameRe = RegExp(r'^[a-z0-9_.]{3,20}$');

  @override
  void dispose() {
    _availDebounce?.cancel();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onUsernameChanged(String value) {
    if (!_signupMode) return;
    _availDebounce?.cancel();
    final name = value.trim().toLowerCase();
    if (name.isEmpty) {
      setState(() => _availability = _Availability.unknown);
      return;
    }
    if (!_usernameRe.hasMatch(name)) {
      setState(() => _availability = _Availability.invalid);
      return;
    }
    setState(() => _availability = _Availability.checking);
    _availDebounce = Timer(const Duration(milliseconds: 500), () async {
      final available = await ApiService.isUsernameAvailable(name);
      if (!mounted || _usernameCtrl.text.trim().toLowerCase() != name) return;
      setState(() => _availability =
          available ? _Availability.available : _Availability.taken);
    });
  }

  Future<void> _submit() async {
    final user = _usernameCtrl.text.trim().toLowerCase();
    final pass = _passwordCtrl.text.trim();
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please enter both username and password.');
      return;
    }
    if (_signupMode) {
      if (!_usernameRe.hasMatch(user)) {
        setState(() =>
            _error = 'Username must be 3-20 chars: a-z, 0-9, _ or .');
        return;
      }
      if (pass.length < 6) {
        setState(() => _error = 'Password must be at least 6 characters.');
        return;
      }
      if (_availability == _Availability.taken) {
        setState(() => _error = 'That username is taken.');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final ok = _signupMode
        ? await auth.signup(context, user, pass)
        : await auth.login(context, user, pass);

    if (!mounted) return;
    if (!ok) {
      setState(() {
        _isLoading = false;
        _error = _signupMode
            ? 'Signup failed — username may be taken.'
            : 'Invalid username or password.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.space24,
              vertical: AppTheme.space32,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                      ),
                      child: const Icon(
                        Icons.sports_esports_rounded,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.space24),

                  // Title
                  Text(
                    'Battle Arena',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: AppTheme.space8),
                  Text(
                    _signupMode
                        ? 'Create your account'
                        : 'Sign in to continue',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppTheme.space40),

                  // Username (live availability check in signup mode)
                  TextField(
                    controller: _usernameCtrl,
                    enabled: !_isLoading,
                    textInputAction: TextInputAction.next,
                    onChanged: _onUsernameChanged,
                    decoration: InputDecoration(
                      labelText: 'Username',
                      prefixIcon: const Icon(Icons.person_outline_rounded),
                      helperText: _signupMode &&
                              _availability == _Availability.invalid
                          ? '3-20 chars: a-z, 0-9, _ or .'
                          : null,
                      suffixIcon: !_signupMode
                          ? null
                          : switch (_availability) {
                              _Availability.checking => const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                              _Availability.available => const Icon(
                                  Icons.check_circle_outline,
                                  color: Colors.green),
                              _Availability.taken => const Icon(
                                  Icons.cancel_outlined,
                                  color: AppTheme.error),
                              _ => null,
                            },
                    ),
                  ),
                  const SizedBox(height: AppTheme.space16),

                  // Password
                  TextField(
                    controller: _passwordCtrl,
                    enabled: !_isLoading,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.space24),

                  // Submit button
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Text(_signupMode ? 'Create Account' : 'Sign In'),
                    ),
                  ),

                  // Error
                  if (_error != null) ...[
                    const SizedBox(height: AppTheme.space16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.space16,
                        vertical: AppTheme.space12,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withValues(alpha: 0.1),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMd),
                        border: Border.all(
                          color: AppTheme.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: AppTheme.error,
                            size: 18,
                          ),
                          const SizedBox(width: AppTheme.space8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: AppTheme.error,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: AppTheme.space24),

                  // Mode toggle
                  Center(
                    child: TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => setState(() {
                                _signupMode = !_signupMode;
                                _error = null;
                                _availability = _Availability.unknown;
                              }),
                      child: Text(
                        _signupMode
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
