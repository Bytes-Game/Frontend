import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// TOTP-based two-factor setup flow.
///
/// Three states:
///   * [State.idle]       — not enrolled. Big primary CTA to start.
///   * [State.enrolling]  — server returned a secret + recovery codes.
///                          Show the otpauth URI (as a text payload
///                          the user pastes into their authenticator
///                          app — we don't ship a QR widget yet) and
///                          the recovery codes for save-to-clipboard.
///                          User types in a 6-digit code to verify.
///   * [State.active]     — 2FA is on. Show a "disable" CTA that
///                          re-prompts for a code.
///
/// Why no QR code widget yet: every QR package on pub.dev adds 100KB+
/// of native code and we want to keep app size + storage tight (per
/// the user's "no money / limited storage" constraint). The otpauth
/// URI works fine as a manual-entry string — every authenticator
/// app accepts pasting the URI directly, and we show the bare secret
/// + issuer prominently for the manual-add flow.
class TwoFactorSetupPage extends StatefulWidget {
  const TwoFactorSetupPage({super.key});

  @override
  State<TwoFactorSetupPage> createState() => _TwoFactorSetupPageState();
}

enum _Phase { idle, enrolling, active }

class _TwoFactorSetupPageState extends State<TwoFactorSetupPage>
    with PageTracker<TwoFactorSetupPage> {
  @override
  String get pageName => 'two_factor_setup_page';

  _Phase _phase = _Phase.idle;
  bool _busy = false;

  // Enrollment payload (only present in _Phase.enrolling).
  String _secret = '';
  String _otpauthUri = '';
  List<String> _recoveryCodes = const [];

  final TextEditingController _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    final u = Provider.of<DataProvider>(context, listen: false).user;
    _phase = u?.twoFactorEnabled == true ? _Phase.active : _Phase.idle;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  String? get _uid =>
      Provider.of<DataProvider>(context, listen: false).user?.id;

  Future<void> _enroll() async {
    final uid = _uid;
    if (uid == null) return;
    EventTracker.instance.trackTap(
      target: 'totp_enroll_start',
      pageName: pageName,
    );
    setState(() => _busy = true);
    final res = await ApiService.enrollTOTP(uid);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res == null) {
      _toast('Could not start enrollment. Try again.');
      return;
    }
    setState(() {
      _phase = _Phase.enrolling;
      _secret = (res['secret'] as String?) ?? '';
      _otpauthUri = (res['otpauthUri'] as String?) ?? '';
      _recoveryCodes =
          ((res['recoveryCodes'] as List?)?.cast<String>()) ?? const [];
    });
  }

  Future<void> _verify() async {
    final uid = _uid;
    if (uid == null) return;
    final code = _code.text.trim();
    if (code.length != 6) {
      _toast('Enter the 6-digit code from your authenticator app.');
      return;
    }
    EventTracker.instance.trackTap(
      target: 'totp_verify',
      pageName: pageName,
    );
    setState(() => _busy = true);
    final ok = await ApiService.verifyTOTP(userId: uid, code: code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _toast('Code didn\'t match. Try again.');
      return;
    }
    // Refresh the local user so the "2FA on" badge appears across
    // settings without a re-login. We don't have a profile-refresh
    // endpoint distinct from /profile, so just hand-mutate the flag
    // via copyWith for now — the next /profile fetch confirms.
    final dp = Provider.of<DataProvider>(context, listen: false);
    final u = dp.user;
    if (u != null) {
      dp.setUser(u.copyWith(twoFactorEnabled: true));
    }
    setState(() => _phase = _Phase.active);
    _toast('Two-step verification turned on.');
  }

  Future<void> _disable() async {
    final uid = _uid;
    if (uid == null) return;
    final code = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Turn off two-step verification'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter a current 6-digit code from your authenticator '
                '(or a recovery code) to confirm.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Code',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Turn off'),
            ),
          ],
        );
      },
    );
    if (code == null || code.isEmpty) return;
    setState(() => _busy = true);
    final ok = await ApiService.disableTOTP(userId: uid, code: code);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      _toast('Code didn\'t match. 2FA stays on.');
      return;
    }
    final dp = Provider.of<DataProvider>(context, listen: false);
    final u = dp.user;
    if (u != null) {
      dp.setUser(u.copyWith(twoFactorEnabled: false));
    }
    setState(() => _phase = _Phase.idle);
    _toast('Two-step verification turned off.');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _toast('$label copied');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Two-step verification')),
      body: SafeArea(
        child: _busy && _phase == _Phase.idle
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AppTheme.space20),
                child: switch (_phase) {
                  _Phase.idle => _idleView(),
                  _Phase.enrolling => _enrollingView(),
                  _Phase.active => _activeView(),
                },
              ),
      ),
    );
  }

  // ── Phase: idle ─────────────────────────────────────────────────────

  Widget _idleView() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.shield_outlined, size: 64, color: cs.primary),
        const SizedBox(height: 16),
        Text(
          'Add an extra layer of security',
          style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Two-step verification asks for a 6-digit code from an '
          'authenticator app every time you sign in. Use Google '
          'Authenticator, 1Password, Authy, or any compatible app.',
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _enroll,
          icon: const Icon(Icons.shield),
          label: const Text('Turn on'),
        ),
      ],
    );
  }

  // ── Phase: enrolling ───────────────────────────────────────────────

  Widget _enrollingView() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Step 1 — add devf to your authenticator',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          'Open your authenticator app and either paste the link '
          'below or manually enter the secret.',
          style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        _copyableField(
          label: 'otpauth link',
          value: _otpauthUri,
          icon: Icons.link,
        ),
        const SizedBox(height: 8),
        _copyableField(
          label: 'Manual entry secret',
          value: _secret,
          icon: Icons.key,
        ),

        const SizedBox(height: 24),
        Text(
          'Step 2 — save your recovery codes',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'These are the ONLY way back into your account if you lose '
          'your authenticator. Each can be used once. We won\'t show '
          'them again.',
          style: tt.bodySmall?.copyWith(color: cs.error),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 6,
                children: [
                  for (final c in _recoveryCodes)
                    SelectableText(
                      c,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        letterSpacing: 1.2,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _copy(
                  _recoveryCodes.join('\n'),
                  'Recovery codes',
                ),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy all'),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),
        Text(
          'Step 3 — enter the 6-digit code',
          style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Code from app',
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Verify and turn on'),
        ),
      ],
    );
  }

  // ── Phase: active ──────────────────────────────────────────────────

  Widget _activeView() {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
          ),
          child: Row(
            children: [
              const Icon(Icons.check_circle, color: Colors.green, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Two-step verification is on for your account.',
                  style: tt.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700, color: cs.onSurface),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          onPressed: _busy ? null : _disable,
          icon: const Icon(Icons.shield_outlined),
          label: const Text('Turn off'),
        ),
      ],
    );
  }

  Widget _copyableField({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  value,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                  maxLines: 1,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(value, label),
          ),
        ],
      ),
    );
  }
}
