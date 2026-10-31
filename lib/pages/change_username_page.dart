import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/dates.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/config/username_rules.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';

/// Change your username, the way TikTok allows it: once every 30 days.
///
/// Opens on what the server says: whether the name may change now. While it
/// may not, the page says from when, and there is nothing to type into.
/// Once it may, the new name is checked as it is typed (sign-up's check),
/// and saving asks first, since the next change is 30 days away.
///
/// After a change the server signs out every sign-in made before it — they
/// carry the old name — and hands this phone a fresh one, kept by
/// AuthProvider.keepRenamedAccount. The live connection follows the new
/// name by itself (WebSocketService.useUsername).
class ChangeUsernamePage extends StatefulWidget {
  const ChangeUsernamePage({super.key});

  @override
  State<ChangeUsernamePage> createState() => _ChangeUsernamePageState();
}

enum _Load { loading, failed, ready }

/// The name in the box: unchanged, not allowed, being checked, free, taken.
enum _Name { same, bad, checking, free, taken }

class _ChangeUsernamePageState extends State<ChangeUsernamePage>
    with PageTracker<ChangeUsernamePage> {
  final _box = TextEditingController();
  _Load _load = _Load.loading;

  /// When the name may change again; null when it may now.
  DateTime? _nextChangeAt;
  _Name _name = _Name.same;
  String? _why;
  String? _error;
  Timer? _check;
  bool _saving = false;

  @override
  String get pageName => 'change_username_page';

  @override
  void initState() {
    super.initState();
    _box.text = _current;
    // ignore: discarded_futures
    _fetch();
  }

  @override
  void dispose() {
    _check?.cancel();
    _box.dispose();
    super.dispose();
  }

  String get _current =>
      Provider.of<DataProvider>(context, listen: false).user?.username ?? '';

  bool get _locked =>
      _nextChangeAt != null && _nextChangeAt!.isAfter(DateTime.now());

  Future<void> _fetch() async {
    setState(() => _load = _Load.loading);
    final user = Provider.of<DataProvider>(context, listen: false).user;
    final status =
        user == null ? null : await ApiService.usernameStatus(user.id);
    if (!mounted) return;
    setState(() {
      if (status == null) {
        _load = _Load.failed;
        return;
      }
      _load = _Load.ready;
      _nextChangeAt = status.nextChangeAt;
    });
  }

  void _onChanged(String raw) {
    _check?.cancel();
    _error = null;
    final name = raw.trim().toLowerCase();
    if (name.isEmpty || name == _current.toLowerCase()) {
      setState(() {
        _name = _Name.same;
        _why = null;
      });
      return;
    }
    final problem = usernameProblem(name);
    if (problem != null) {
      setState(() {
        _name = _Name.bad;
        _why = problem;
      });
      return;
    }
    setState(() {
      _name = _Name.checking;
      _why = null;
    });
    _check = Timer(const Duration(milliseconds: 450), () async {
      final answer = await ApiService.checkUsername(name);
      if (!mounted || _box.text.trim().toLowerCase() != name) return;
      setState(() {
        if (answer.available) {
          _name = _Name.free;
          _why = null;
        } else {
          _name = answer.valid ? _Name.taken : _Name.bad;
          _why = answer.reason;
        }
      });
    });
  }

  Future<void> _save() async {
    final name = _box.text.trim().toLowerCase();
    if (_name != _Name.free || _saving) return;
    FocusScope.of(context).unfocus();
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('change_username_confirm'),
        title: Text('Change your username to @$name?'),
        content: const Text(
            "You won't be able to change it again for 30 days. Your old "
            'username will be free for anyone to take, and links to your '
            'profile with it will stop working.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('change_username_yes'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;

    final dp = Provider.of<DataProvider>(context, listen: false);
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final user = dp.user;
    if (user == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await ApiService.changeUsername(user.id, name);
    if (!mounted) return;
    if (result.changed) {
      await auth.keepRenamedAccount(dp, result.token!, result.user!);
      EventTracker.instance
          .trackTap(target: 'username_changed', pageName: pageName);
      messenger.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Your username is now @$name. Any other phone signed '
            'in to your account has been signed out.'),
      ));
      navigator.pop();
      return;
    }
    setState(() {
      _saving = false;
      if (!result.reachedServer) {
        _error = "Couldn't reach the server. Check your connection and try "
            'again.';
      } else if (result.tooSoon) {
        _nextChangeAt = result.nextChangeAt;
        _error = _nextChangeAt == null ? result.message : null;
      } else {
        _name = _Name.taken;
        _why = result.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = _load == _Load.ready && !_locked;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Username'),
        actions: [
          if (ready)
            TextButton(
              key: const ValueKey('change_username_save'),
              onPressed: _name == _Name.free && !_saving ? _save : null,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
        ],
      ),
      body: switch (_load) {
        _Load.loading => const Center(child: CircularProgressIndicator()),
        _Load.failed => _failed(context),
        _Load.ready => _locked ? _lockedView(context) : _form(context),
      },
    );
  }

  Widget _failed(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Couldn't load your username."),
            const SizedBox(height: AppTheme.space8),
            TextButton(
              key: const ValueKey('change_username_retry'),
              onPressed: _fetch,
              child: const Text('Try again'),
            ),
          ],
        ),
      );

  Widget _lockedView(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(AppTheme.space16),
      children: [
        Text('@$_current', style: tt.titleLarge),
        const SizedBox(height: AppTheme.space12),
        Text(
          'You can change your username once every 30 days. You can change '
          'it again on ${dateInWords(_nextChangeAt!.toLocal())}.',
          key: const ValueKey('change_username_locked'),
          style: tt.bodyMedium,
        ),
      ],
    );
  }

  Widget _form(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final name = _box.text.trim().toLowerCase();
    return ListView(
      padding: const EdgeInsets.all(AppTheme.space16),
      children: [
        TextField(
          key: const ValueKey('change_username_box'),
          controller: _box,
          enabled: !_saving,
          autofocus: true,
          autocorrect: false,
          onChanged: _onChanged,
          decoration: InputDecoration(
            labelText: 'Username',
            prefixText: '@',
            border: const OutlineInputBorder(),
            helperText: switch (_name) {
              _Name.checking => 'Checking…',
              _Name.free => '@$name is available',
              _ => 'Letters, numbers, _ and . — 3 to 20 characters.',
            },
            errorText: _name == _Name.bad || _name == _Name.taken
                ? (_why ?? 'That username is taken.')
                : null,
            suffixIcon: switch (_name) {
              _Name.checking => const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              _Name.free =>
                Icon(Icons.check_circle_rounded, color: cs.primary),
              _Name.bad || _Name.taken =>
                Icon(Icons.error_outline_rounded, color: cs.error),
              _Name.same => null,
            },
          ),
        ),
        const SizedBox(height: AppTheme.space16),
        Text(
          'You can change your username once every 30 days. Your old '
          'username becomes free for anyone to take, and links to your '
          'profile with it stop working.',
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppTheme.space12),
          Text(
            _error!,
            key: const ValueKey('change_username_error'),
            style: tt.bodyMedium?.copyWith(color: cs.error),
          ),
        ],
      ],
    );
  }
}
