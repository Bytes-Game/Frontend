import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/league_badge.dart';

/// Form for editing the signed-in user's profile.
///
/// Wired end-to-end to `PATCH /api/v1/users/{id}` — the Save button
/// pushes the dirty fields (fullName, bio, visibility) to the backend,
/// merges the returned user into [DataProvider], and pops the page
/// with a success toast. Username is locked behind a "request change"
/// affordance because username collisions are a hosting-uniqueness
/// problem we don't want to introduce here without the rename audit
/// log on the backend side.
class EditProfilePage extends StatefulWidget {
  const EditProfilePage({super.key});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage>
    with PageTracker<EditProfilePage> {
  late final TextEditingController _fullName;
  late final TextEditingController _bio;
  late String _visibility;
  bool _dirty = false;
  bool _saving = false;

  @override
  String get pageName => 'edit_profile_page';

  @override
  void initState() {
    super.initState();
    final user =
        Provider.of<DataProvider>(context, listen: false).user;
    _fullName = TextEditingController(text: user?.fullName ?? '');
    _bio = TextEditingController(text: user?.bio ?? '');
    _visibility = user?.visibility.isNotEmpty == true
        ? user!.visibility
        : 'public';
    for (final c in [_fullName, _bio]) {
      c.addListener(_recomputeDirty);
    }
  }

  @override
  void dispose() {
    _fullName.dispose();
    _bio.dispose();
    super.dispose();
  }

  void _recomputeDirty() {
    final user =
        Provider.of<DataProvider>(context, listen: false).user;
    final dirty = _fullName.text != (user?.fullName ?? '') ||
        _bio.text != (user?.bio ?? '') ||
        _visibility != (user?.visibility.isNotEmpty == true
            ? user!.visibility
            : 'public');
    if (dirty != _dirty) setState(() => _dirty = dirty);
  }

  Future<void> _onSave() async {
    final user =
        Provider.of<DataProvider>(context, listen: false).user;
    if (user == null) return;

    // Client-side validation. Keep in lock-step with the backend
    // validator (fullName ≤ 100, bio ≤ 500) so a bad input gets a
    // friendly error here rather than a 400 from the server.
    final fullName = _fullName.text.trim();
    final bio = _bio.text.trim();
    if (fullName.length > 100) {
      _toast('Full name is too long (max 100 chars).');
      return;
    }
    if (bio.length > 500) {
      _toast('Bio is too long (max 500 chars).');
      return;
    }

    EventTracker.instance.trackTap(
      target: 'edit_profile_save',
      pageName: pageName,
    );
    setState(() => _saving = true);
    final result = await ApiService.updateUserProfile(
      userId: user.id,
      fullName: fullName != user.fullName ? fullName : null,
      bio: bio != user.bio ? bio : null,
      visibility: _visibility != user.visibility ? _visibility : null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.success) {
      // Surface the server's actual error text so users see
      // "Username taken" / "Bio too long" / etc. instead of a generic
      // "Could not save." Trimmed to one line so it fits in the
      // floating snackbar without truncation in the middle of words.
      final msg = (result.error ?? '').trim();
      _toast(msg.isEmpty ? 'Could not save. Try again.' : msg);
      return;
    }
    // Merge the server-truth user into DataProvider when the response
    // included a fresh one. The backend returns `{"updated": false}`
    // for no-op requests (no dirty fields after server-side validation)
    // — also a successful save, just nothing to merge locally.
    if (result.user != null) {
      Provider.of<DataProvider>(context, listen: false).setUser(result.user!);
    }
    // CRITICAL: clear the dirty flag BEFORE popping. PopScope has
    // canPop = !_dirty, so a programmatic pop while dirty=true gets
    // intercepted and shows the "Discard changes?" dialog — which
    // looked to the user like "Save didn't work" because the page
    // didn't close. The save succeeded, the controllers still hold
    // the just-saved values, so from the user's perspective there
    // are no unsaved changes anymore — flipping _dirty here matches
    // that mental model.
    setState(() => _dirty = false);
    _toast('Profile updated');
    Navigator.of(context).pop(true);
  }

  Future<bool> _confirmDiscardIfDirty() async {
    if (!_dirty) return true;
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
          'You have unsaved changes. Leaving will lose them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<DataProvider>(context).user;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscardIfDirty()) {
          if (context.mounted) Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit Profile'),
          actions: [
            TextButton(
              onPressed: (_dirty && !_saving) ? _onSave : null,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space20,
            vertical: AppTheme.space16,
          ),
          children: [
            // Avatar block. Image uploads are gated on the presigned
            // image-upload endpoint we explicitly deferred — surface
            // the affordance but tell the user clearly it's pending.
            Center(
              child: Stack(
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: cs.surfaceContainerHighest,
                    child: Text(
                      (user?.username.isNotEmpty == true)
                          ? user!.username[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        fontSize: 36,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: cs.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => _toast(
                          'Avatar upload is pending the image-upload '
                          'endpoint — we skipped it to keep storage free.',
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(
                            Icons.camera_alt_outlined,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.space16),

            // Username readback. Editable username is gated on the
            // backend uniqueness-check + rename audit log; we surface
            // it as read-only here so the form is honest about what
            // it can persist.
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Username'),
              subtitle: Text(
                '@${user?.username ?? ''}',
                style: tt.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              trailing: TextButton(
                onPressed: () => _toast(
                  'Username changes are coming soon — needs the '
                  'backend uniqueness-check + audit endpoint.',
                ),
                child: const Text('Change'),
              ),
            ),

            // League badge row — read-only because league is derived
            // from wins/losses, not user-editable.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  if (user != null) LeagueBadge(league: user.league),
                  const SizedBox(width: AppTheme.space8),
                  Expanded(
                    child: Text(
                      'League is set by your battle record.',
                      style: tt.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: AppTheme.space32),

            _field(
              label: 'Full name',
              helper: 'Shown on your profile.',
              controller: _fullName,
              maxLength: 100,
              inputFormatters: [
                LengthLimitingTextInputFormatter(100),
              ],
            ),
            _field(
              label: 'Bio',
              helper: 'Up to 500 characters.',
              controller: _bio,
              maxLength: 500,
              maxLines: 4,
            ),

            // Visibility selector. Drives the server-side gate that
            // determines whether non-followers can see this user's
            // content + profile detail.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account visibility',
                    style: tt.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'public',
                        label: Text('Public'),
                        icon: Icon(Icons.public),
                      ),
                      ButtonSegment(
                        value: 'friends',
                        label: Text('Friends only'),
                        icon: Icon(Icons.lock_outline),
                      ),
                    ],
                    selected: {_visibility},
                    onSelectionChanged: (set) {
                      if (set.isEmpty) return;
                      setState(() => _visibility = set.first);
                      _recomputeDirty();
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _visibility == 'friends'
                        ? 'Only your followers can see your full profile and posts.'
                        : 'Anyone on devf can see your profile and posts.',
                    style: tt.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required String label,
    required String helper,
    required TextEditingController controller,
    int? maxLength,
    int maxLines = 1,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.space16),
      child: TextField(
        controller: controller,
        maxLength: maxLength,
        maxLines: maxLines,
        inputFormatters: inputFormatters,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
