import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// Change your password: the current one, then a new one twice. Every other
/// phone signed in to the account is signed out; this one stays in.
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage>
    with PageTracker<ChangePasswordPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  final Map<String, String> _serverSays = {};
  String? _error;

  @override
  String get pageName => 'change_password_page';

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  String? get _nextProblem {
    final p = _next.text;
    if (p.isEmpty) return null;
    if (p.length < 8) return 'Use at least 8 characters.';
    if (!p.contains(RegExp(r'[A-Za-z]')) || !p.contains(RegExp(r'[0-9]'))) {
      return 'Use at least one letter and one number.';
    }
    if (p == _current.text) return "Choose a password you haven't been using.";
    return null;
  }

  String? get _againProblem {
    if (_again.text.isEmpty) return null;
    return _again.text == _next.text ? null : "The two new passwords don't match.";
  }

  bool get _ready =>
      _current.text.isNotEmpty &&
      _next.text.isNotEmpty &&
      _nextProblem == null &&
      _again.text == _next.text;

  Future<void> _save() async {
    if (!_ready || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _serverSays.clear();
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final result = await ApiService.changePassword(_current.text, _next.text);
    if (!mounted) return;
    if (result.ok) {
      final token = result.data!['token'] as String?;
      if (token != null && token.isNotEmpty) {
        await auth.keepFreshSignIn(token);
      }
      EventTracker.instance
          .trackTap(target: 'password_changed', pageName: pageName);
      messenger.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Password changed. Any other phone signed in to your '
            'account has been signed out.'),
      ));
      navigator.pop();
      return;
    }
    setState(() {
      _busy = false;
      if (result.field != null && result.message != null) {
        _serverSays[result.field!] = result.message!;
      } else {
        _error = result.message ??
            switch (result.failure) {
              AuthFailure.unreachable => "Couldn't reach the server. Check "
                  'your connection and try again.',
              _ => "Couldn't change your password. Please try again.",
            };
      }
    });
  }

  Widget _eye() => IconButton(
        tooltip: _obscure ? 'Show passwords' : 'Hide passwords',
        icon: Icon(
            _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
        onPressed: () => setState(() => _obscure = !_obscure),
      );

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text(
              'Choose a strong password you don\'t use anywhere else. '
              'Changing it signs out every other phone signed in to your '
              'account.',
              style: TextStyle(color: muted, fontSize: 14.5, height: 1.4),
            ),
            const SizedBox(height: 22),
            TextField(
              key: const ValueKey('password_current'),
              controller: _current,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.password],
              textInputAction: TextInputAction.next,
              onChanged: (_) =>
                  setState(() => _serverSays.remove('currentPassword')),
              decoration: InputDecoration(
                labelText: 'Current password',
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                errorText: _serverSays['currentPassword'],
                suffixIcon: _eye(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('password_new'),
              controller: _next,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() => _serverSays.remove('newPassword')),
              decoration: InputDecoration(
                labelText: 'New password',
                prefixIcon: const Icon(Icons.lock_reset_rounded),
                helperText: 'At least 8 characters, with a letter and a number.',
                errorText: _serverSays['newPassword'] ?? _nextProblem,
                errorMaxLines: 2,
              ),
            ),
            const SizedBox(height: 10),
            PasswordStrengthMeter(password: _next.text),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('password_again'),
              controller: _again,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: 'New password again',
                prefixIcon: const Icon(Icons.done_all_rounded),
                errorText: _againProblem,
              ),
            ),
            const SizedBox(height: 24),
            AuthPrimaryButton(
              key: const ValueKey('password_save'),
              label: 'Change password',
              loading: _busy,
              onPressed: _ready ? _save : null,
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              AuthErrorBox(message: _error!),
            ],
          ],
        ),
      ),
    );
  }
}
