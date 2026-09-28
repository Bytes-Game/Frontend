import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// Pick which friends can see a challenge.
///
/// "Friends" here are the people who follow you: they are who an "Only
/// friends" challenge is shown to, and who hears about it when you post
/// one. Choosing some of them narrows both to just those people.
///
/// Returns the chosen people, or null if the sheet was closed without
/// pressing Done.
Future<List<UserModel>?> pickFriends(
  BuildContext context, {
  required String userId,
  List<UserModel> chosen = const [],
}) {
  return showModalBottomSheet<List<UserModel>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: FriendPickerSheet(userId: userId, chosen: chosen),
    ),
  );
}

class FriendPickerSheet extends StatefulWidget {
  final String userId;
  final List<UserModel> chosen;

  const FriendPickerSheet({
    super.key,
    required this.userId,
    this.chosen = const [],
  });

  @override
  State<FriendPickerSheet> createState() => _FriendPickerSheetState();
}

class _FriendPickerSheetState extends State<FriendPickerSheet> {
  List<UserModel>? _friends;
  late final Map<String, UserModel> _picked = {
    for (final u in widget.chosen) u.id: u,
  };
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // A page at a time (the server hands out 100 at most), up to 1,000.
    final all = <UserModel>[];
    for (var page = 1; page <= 10; page++) {
      final got = await ApiService.getFollowers(
        widget.userId,
        page: page,
        limit: 100,
      );
      all.addAll(got);
      if (got.length < 100) break;
    }
    if (!mounted) return;
    setState(() => _friends = all);
  }

  List<UserModel> get _shown {
    final q = _search.text.trim().toLowerCase();
    final all = _friends ?? const <UserModel>[];
    if (q.isEmpty) return all;
    return [
      for (final u in all)
        if (u.username.toLowerCase().contains(q) ||
            u.fullName.toLowerCase().contains(q))
          u,
    ];
  }

  void _toggle(UserModel u) => setState(() {
    if (_picked.remove(u.id) == null) _picked[u.id] = u;
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final friends = _friends;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Choose friends',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Only they will see it, and only they get told you '
                      'posted it.',
                      style: TextStyle(fontSize: 13, color: quietText(context)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: TextField(
            key: const ValueKey('friend_search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search friends',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: quietFill(context),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: friends == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : friends.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'Nobody follows you yet. When people do, you can choose '
                    'them here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: quietText(context)),
                  ),
                )
              : ListView.builder(
                  itemCount: _shown.length,
                  itemBuilder: (_, i) {
                    final u = _shown[i];
                    final on = _picked.containsKey(u.id);
                    return ListTile(
                      key: ValueKey('friend_${u.id}'),
                      onTap: () => _toggle(u),
                      leading: ArenaAvatar(name: u.username, size: 40),
                      title: Text(
                        u.fullName.isNotEmpty ? u.fullName : u.username,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('@${u.username}'),
                      trailing: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: on ? cs.primary : Colors.transparent,
                          border: Border.all(
                            color: on ? cs.primary : quietText(context),
                            width: 2,
                          ),
                        ),
                        child: on
                            ? const Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                key: const ValueKey('friends_done'),
                onPressed: () =>
                    Navigator.of(context).pop(_picked.values.toList()),
                child: Text(
                  _picked.isEmpty
                      ? 'All friends'
                      : 'Done · ${_picked.length} '
                            '${_picked.length == 1 ? 'friend' : 'friends'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
