import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/profile_tags.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/services/profile_photo_flow.dart';
import 'package:myapp/widgets/arena_ui.dart';
import 'package:myapp/widgets/league_badge.dart';

/// Form for editing the signed-in user's profile.
///
/// The photo changes on its own, the moment it is chosen, as on Instagram
/// (see ProfilePhotoFlow). Everything else waits for Save.
///
/// Wired end-to-end to `PATCH /api/v1/users/{id}` — the Save button
/// pushes the dirty fields (fullName, bio, visibility, tag) to the backend,
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
  late String _tag;
  bool _dirty = false;
  bool _saving = false;

  /// A new photo is being framed, uploaded or saved.
  bool _photoBusy = false;

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
    _tag = user?.profileTag ?? '';
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
            : 'public') ||
        _tag != (user?.profileTag ?? '');
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
      profileTag: _tag != user.profileTag ? _tag : null,
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

  /// Take a photo, choose one, or remove the one there is.
  Future<void> _editPhoto() async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final me = dp.user;
    if (me == null || _photoBusy) return;
    EventTracker.instance.trackTap(
      target: 'edit_profile_photo',
      pageName: pageName,
    );
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('profile_photo_camera'),
              leading: const Icon(Icons.photo_camera_rounded, color: kAccent),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              key: const ValueKey('profile_photo_gallery'),
              leading: const Icon(Icons.photo_library_rounded, color: kAccent),
              title: const Text('Choose from your photos'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            if (me.avatarUrl.isNotEmpty)
              ListTile(
                key: const ValueKey('profile_photo_remove'),
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: Colors.red,
                ),
                title: const Text(
                  'Remove current picture',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _photoBusy = true);
    final change = choice == 'remove'
        ? await ProfilePhotoFlow.remove(me)
        : await ProfilePhotoFlow.change(context, me, camera: choice == 'camera');
    if (!mounted) return;
    setState(() => _photoBusy = false);
    final updated = change.user;
    if (updated != null) {
      // Keeps the form's unsaved edits: only the photo is taken from it.
      dp.setUser(me.copyWith(avatarUrl: updated.avatarUrl));
      _toast(updated.avatarUrl.isEmpty
          ? 'Profile photo removed'
          : 'Profile photo updated');
    } else if (change.problem.isNotEmpty) {
      _toast(change.problem);
    }
  }

  /// What the profile is about: one word from [profileTags], or none.
  Future<void> _pickTag() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'What is your profile about?',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              const Text(
                'Shown under your name, so people know what to expect.',
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in profileTags)
                    ChoiceChip(
                      key: ValueKey('tag_$t'),
                      label: Text(t),
                      selected: t == _tag,
                      onSelected: (_) => Navigator.pop(ctx, t),
                    ),
                  ChoiceChip(
                    key: const ValueKey('tag_none'),
                    label: const Text('No tag'),
                    selected: _tag.isEmpty,
                    onSelected: (_) => Navigator.pop(ctx, ''),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _tag = picked);
    _recomputeDirty();
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
            // Your picture: your photo, or your initial. Tap it, or "Edit
            // picture", to take one, choose one, or remove it.
            Center(
              child: GestureDetector(
                key: const ValueKey('edit_photo_avatar'),
                onTap: _editPhoto,
                child: Stack(
                  children: [
                    ArenaAvatar(name: user?.username ?? '', size: 96),
                    if (_photoBusy)
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black45,
                          ),
                          child: Center(
                            child: CircularProgressIndicator(
                              key: ValueKey('edit_photo_busy'),
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: kAccent,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.photo_camera_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: TextButton(
                key: const ValueKey('edit_photo'),
                onPressed: _photoBusy ? null : _editPhoto,
                child: const Text('Edit picture'),
              ),
            ),
            const SizedBox(height: AppTheme.space8),

            // Your username, shown but not editable. It used to have a
            // Change button that only said "coming soon" in developer
            // words; usernames cannot be changed, so it says that plainly.
            ListTile(
              key: const ValueKey('edit_username'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Username'),
              subtitle: Text(
                '@${user?.username ?? ''}',
                style: tt.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              trailing: Text(
                "Can't be changed",
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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

            // One word for what the profile is about, shown under the name.
            ListTile(
              key: const ValueKey('edit_profile_tag'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Profile tag'),
              subtitle: Text(
                _tag.isEmpty ? 'Say what your profile is about' : _tag,
                style: tt.bodyMedium?.copyWith(
                  color: _tag.isEmpty ? cs.onSurfaceVariant : kAccent,
                  fontWeight: _tag.isEmpty ? null : FontWeight.w600,
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: _pickTag,
            ),
            const SizedBox(height: AppTheme.space8),

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
