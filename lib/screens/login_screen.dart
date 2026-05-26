import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/auth_provider.dart';

/// Clean, professional login screen.
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
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final user = _usernameCtrl.text.trim();
    final pass = _passwordCtrl.text.trim();
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Please enter both username and password.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    final ok = await Provider.of<AuthProvider>(context, listen: false)
        .login(context, user, pass);

    if (!mounted) return;
    if (!ok) {
      setState(() {
        _isLoading = false;
        _error = 'Invalid credentials. Try player1 / pass1';
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
                    'Sign in to continue',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: AppTheme.space40),

                  // Username
                  TextField(
                    controller: _usernameCtrl,
                    enabled: !_isLoading,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      prefixIcon: Icon(Icons.person_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: AppTheme.space16),

                  // Password
                  TextField(
                    controller: _passwordCtrl,
                    enabled: !_isLoading,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _login(),
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

                  // Sign in button
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _isLoading ? null : _login,
                      child: _isLoading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Sign In'),
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

                  const SizedBox(height: AppTheme.space32),

                  // Demo hint
                  Center(
                    child: Text(
                      'Demo: player1 / pass1',
                      style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant
                            .withValues(alpha: 0.7),
                        fontSize: 12,
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
