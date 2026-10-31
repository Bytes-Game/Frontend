import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/auth_widgets.dart';

/// Create an account: name, username, email, birthday, password, and the
/// terms. Every box says what is wrong with it as you go, and the server's
/// answer lands under the box it is about.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

enum _Name { empty, checking, free, taken, bad }

/// The latest birthday that is 13 years ago [today]: the calendar offers
/// nothing after it.
DateTime thirteenYearsAgo(DateTime today) {
  final y = today.year - 13;
  // 29 February, thirteen years on, is 28 February.
  final d = today.month == 2 && today.day == 29 ? 28 : today.day;
  return DateTime(y, today.month, d);
}

class _SignupScreenState extends State<SignupScreen> {
  final _fullName = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  DateTime? _birthday;
  bool _agreed = false;
  bool _obscure = true;
  bool _busy = false;

  _Name _name = _Name.empty;
  String? _nameWhy;
  Timer? _nameCheck;

  /// What the server said about one box, by its name: username, email,
  /// password, birthDate, fullName, terms. Cleared when that box changes.
  final Map<String, String> _serverSays = {};
  String? _error;

  static final _usernameRe = RegExp(r'^[a-z0-9_.]{3,20}$');
  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _nameCheck?.cancel();
    _fullName.dispose();
    _username.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// What is wrong with the username as typed, before asking the server.
  static String? usernameProblem(String name) {
    if (name.isEmpty) return null;
    if (!_usernameRe.hasMatch(name)) {
      return 'Use 3 to 20 characters: letters, numbers, _ and . only.';
    }
    if (name.startsWith('.') || name.endsWith('.') || name.contains('..')) {
      return "Can't start or end with a dot, or have two dots in a row.";
    }
    if (!name.contains(RegExp(r'[a-z]'))) {
      return 'Needs at least one letter.';
    }
    return null;
  }

  void _onUsername(String raw) {
    _serverSays.remove('username');
    _nameCheck?.cancel();
    final name = raw.trim().toLowerCase();
    final problem = usernameProblem(name);
    if (name.isEmpty) {
      setState(() => _name = _Name.empty);
      return;
    }
    if (problem != null) {
      setState(() {
        _name = _Name.bad;
        _nameWhy = problem;
      });
      return;
    }
    setState(() => _name = _Name.checking);
    _nameCheck = Timer(const Duration(milliseconds: 450), () async {
      final answer = await ApiService.checkUsername(name);
      if (!mounted || _username.text.trim().toLowerCase() != name) return;
      setState(() {
        if (answer.available) {
          _name = _Name.free;
        } else {
          _name = answer.valid ? _Name.taken : _Name.bad;
          _nameWhy = answer.reason;
        }
      });
    });
  }

  String? get _emailProblem {
    final e = _email.text.trim();
    if (e.isEmpty || _emailRe.hasMatch(e)) return null;
    return "That doesn't look like an email address.";
  }

  String? get _passwordProblem {
    final p = _password.text;
    if (p.isEmpty) return null;
    if (p.length < 8) return 'Use at least 8 characters.';
    if (!p.contains(RegExp(r'[A-Za-z]')) || !p.contains(RegExp(r'[0-9]'))) {
      return 'Use at least one letter and one number.';
    }
    final name = _username.text.trim().toLowerCase();
    if (name.length >= 3 && p.toLowerCase().contains(name)) {
      return "Don't put your username in your password.";
    }
    return null;
  }

  bool get _ready =>
      _name == _Name.free &&
      _email.text.trim().isNotEmpty &&
      _emailProblem == null &&
      _password.text.isNotEmpty &&
      _passwordProblem == null &&
      _birthday != null &&
      _agreed;

  Future<void> _pickBirthday() async {
    FocusScope.of(context).unfocus();
    final today = DateTime.now();
    final latest = thirteenYearsAgo(today);
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(latest.year - 5, latest.month, 1),
      firstDate: DateTime(1900),
      lastDate: latest,
      helpText: 'Your date of birth',
      initialEntryMode: DatePickerEntryMode.calendarOnly,
    );
    if (picked != null && mounted) {
      setState(() {
        _birthday = picked;
        _serverSays.remove('birthDate');
      });
    }
  }

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];

  static String birthdayWords(DateTime d) =>
      '${d.day} ${_months[d.month - 1]} ${d.year}';

  static String birthdayForServer(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (!_ready || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _serverSays.clear();
    });
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final navigator = Navigator.of(context);
    final result = await auth.signup(
      context,
      SignupDetails(
        username: _username.text.trim().toLowerCase(),
        password: _password.text,
        fullName: _fullName.text.trim(),
        email: _email.text.trim().toLowerCase(),
        birthDate: birthdayForServer(_birthday!),
        acceptTerms: _agreed,
      ),
    );
    if (!mounted) return;
    if (result == null) {
      // Signed in. The app underneath has already switched to the welcome
      // steps; this page is still on top of it.
      navigator.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _busy = false;
      final field = result.field;
      if (field != null && result.message != null) {
        _serverSays[field] = result.message!;
        if (field == 'username') _name = _Name.taken;
      } else {
        _error = result.message ?? _messageFor(result.failure ?? AuthFailure.unreachable);
      }
    });
  }

  String _messageFor(AuthFailure failure) => switch (failure) {
        // Sign-up never meets an account waiting to be deleted — its name
        // just reads as taken — so that reads as a refusal too.
        AuthFailure.rejected ||
        AuthFailure.deletionPending =>
          "Couldn't create the account. Check the "
              'details above and try again.',
        AuthFailure.unreachable => "Couldn't reach the server. It may be "
            'waking up — wait a few seconds and try again.',
        AuthFailure.serverError => 'The server had a problem. Please try '
            'again in a moment.',
      };

  Widget? _nameSuffix() => switch (_name) {
        _Name.checking => const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        _Name.free => const Icon(Icons.check_circle_rounded,
            color: AppTheme.success, key: ValueKey('username_free')),
        _Name.taken || _Name.bad => const Icon(Icons.cancel_rounded,
            color: AppTheme.error, key: ValueKey('username_not_free')),
        _Name.empty => null,
      };

  String? get _nameHelp => switch (_name) {
        _Name.free => '@${_username.text.trim().toLowerCase()} is yours '
            'if you want it',
        _ => null,
      };

  String? get _nameError =>
      _serverSays['username'] ??
      switch (_name) {
        _Name.taken => _nameWhy ?? 'That username is taken.',
        _Name.bad => _nameWhy,
        _ => null,
      };

  InputDecoration _box({
    required String label,
    required IconData icon,
    String? hint,
    String? helper,
    String? error,
    Widget? suffix,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: error == null ? helper : null,
      helperMaxLines: 2,
      errorText: error,
      errorMaxLines: 3,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          key: const ValueKey('signup_back'),
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          tooltip: 'Back to sign in',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: AuthBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const AuthBrand(
                        title: 'Create your account',
                        subtitle: 'Join the arena. Battle, vote, and climb '
                            'the leagues.',
                      ),
                      const SizedBox(height: 32),
                      TextField(
                        key: const ValueKey('signup_full_name'),
                        controller: _fullName,
                        enabled: !_busy,
                        textCapitalization: TextCapitalization.words,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        maxLength: 50,
                        onChanged: (_) => setState(
                            () => _serverSays.remove('fullName')),
                        decoration: _box(
                          label: 'Your name',
                          icon: Icons.badge_outlined,
                          helper: 'Optional. Shown on your profile.',
                          error: _serverSays['fullName'],
                        ).copyWith(counterText: ''),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('signup_username'),
                        controller: _username,
                        enabled: !_busy,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.newUsername],
                        onChanged: _onUsername,
                        decoration: _box(
                          label: 'Username',
                          icon: Icons.alternate_email_rounded,
                          helper: _nameHelp ??
                              'Letters, numbers, _ and . — this is how '
                                  'people find you.',
                          error: _nameError,
                          suffix: _nameSuffix(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('signup_email'),
                        controller: _email,
                        enabled: !_busy,
                        autocorrect: false,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        onChanged: (_) =>
                            setState(() => _serverSays.remove('email')),
                        decoration: _box(
                          label: 'Email',
                          icon: Icons.mail_outline_rounded,
                          helper: 'Private. Never shown to anyone.',
                          error: _serverSays['email'] ?? _emailProblem,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _BirthdayBox(
                        value: _birthday == null
                            ? null
                            : birthdayWords(_birthday!),
                        error: _serverSays['birthDate'],
                        enabled: !_busy,
                        onTap: _pickBirthday,
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('signup_password'),
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.newPassword],
                        onChanged: (_) =>
                            setState(() => _serverSays.remove('password')),
                        onSubmitted: (_) => _submit(),
                        decoration: _box(
                          label: 'Password',
                          icon: Icons.lock_outline_rounded,
                          helper: 'At least 8 characters, with a letter and '
                              'a number.',
                          error: _serverSays['password'] ?? _passwordProblem,
                          suffix: IconButton(
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            icon: Icon(_obscure
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      PasswordStrengthMeter(password: _password.text),
                      const SizedBox(height: 18),
                      _TermsLine(
                        agreed: _agreed,
                        error: _serverSays['terms'],
                        onChanged: _busy
                            ? null
                            : (v) => setState(() {
                                  _agreed = v;
                                  _serverSays.remove('terms');
                                }),
                      ),
                      const SizedBox(height: 18),
                      AuthPrimaryButton(
                        key: const ValueKey('signup_submit'),
                        label: 'Create account',
                        loading: _busy,
                        onPressed: _ready ? _submit : null,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        AuthErrorBox(message: _error!),
                      ],
                      const SizedBox(height: 18),
                      // Wraps rather than overflows, with large text.
                      Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('Already have an account?',
                              style: TextStyle(color: muted, fontSize: 14)),
                          TextButton(
                            key: const ValueKey('signup_to_signin'),
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).maybePop(),
                            child: const Text(
                              'Sign in',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
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

/// The birthday box: looks like the others, opens a calendar.
class _BirthdayBox extends StatelessWidget {
  final String? value;
  final String? error;
  final bool enabled;
  final VoidCallback onTap;

  const _BirthdayBox({
    required this.value,
    required this.error,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const ValueKey('signup_birthday'),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: 'Date of birth',
          prefixIcon: const Icon(Icons.cake_outlined),
          suffixIcon: const Icon(Icons.calendar_month_rounded),
          helperText: error == null
              ? "Private. You need to be 13 or older to join."
              : null,
          errorText: error,
          enabled: enabled,
        ),
        child: Text(value ?? '', style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

/// "I agree to the Terms of Service and Privacy Policy", with both links.
class _TermsLine extends StatefulWidget {
  final bool agreed;
  final String? error;
  final ValueChanged<bool>? onChanged;

  const _TermsLine({
    required this.agreed,
    required this.error,
    required this.onChanged,
  });

  @override
  State<_TermsLine> createState() => _TermsLineState();
}

class _TermsLineState extends State<_TermsLine> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => _open(const TermsOfServicePage());
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => _open(const PrivacyPolicyPage());

  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    const link = TextStyle(
      color: AppTheme.primary,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: Checkbox(
                key: const ValueKey('signup_terms'),
                value: widget.agreed,
                onChanged: widget.onChanged == null
                    ? null
                    : (v) => widget.onChanged!(v ?? false),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(color: muted, fontSize: 13.5, height: 1.4),
                    children: [
                      const TextSpan(text: 'I agree to the '),
                      TextSpan(
                          text: 'Terms of Service',
                          style: link,
                          recognizer: _terms),
                      const TextSpan(text: ' and the '),
                      TextSpan(
                          text: 'Privacy Policy',
                          style: link,
                          recognizer: _privacy),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        if (widget.error != null)
          Padding(
            padding: const EdgeInsets.only(left: 40, top: 4),
            child: Text(widget.error!,
                style: const TextStyle(color: AppTheme.error, fontSize: 12.5)),
          ),
      ],
    );
  }
}
