import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/league_badge.dart';

/// Shows everyone the signed-in user has blocked, with an inline
/// "Unblock" button per row. Loads from
/// `GET /api/v1/users/{id}/blocks` and reconciles optimistically on
/// unblock so the row disappears instantly.
class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key});

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage>
    with PageTracker<BlockedUsersPage> {
  @override
  String get pageName => 'blocked_users_page';

  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = Provider.of<DataProvider>(context, listen: false).user?.id;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }
    final items = await ApiService.getBlockedUsers(uid);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _unblock(String id) async {
    final uid = Provider.of<DataProvider>(context, listen: false).user?.id;
    if (uid == null) return;
    // Optimistic: drop the row immediately so the tap feels instant.
    final before = List<Map<String, dynamic>>.from(_items);
    setState(() => _items.removeWhere((u) => u['id'] == id));
    final ok = await ApiService.unblockUser(blockerId: uid, blockedId: id);
    if (!mounted) return;
    if (!ok) {
      setState(() => _items = before);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not unblock. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Blocked accounts')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? _empty(cs)
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => const Divider(height: 0),
                  itemBuilder: (_, i) {
                    final u = _items[i];
                    final username = (u['username'] as String?) ?? '';
                    final fullName = (u['fullName'] as String?) ?? '';
                    final league = (u['league'] as String?) ?? '';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.surfaceContainerHighest,
                        child: Text(
                          username.isNotEmpty
                              ? username[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Row(
                        children: [
                          Flexible(child: Text('@$username')),
                          if (league.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            LeagueBadge(league: league, small: true),
                          ],
                        ],
                      ),
                      subtitle: fullName.isEmpty
                          ? null
                          : Text(fullName,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: OutlinedButton(
                        onPressed: () =>
                            _unblock((u['id'] as String?) ?? ''),
                        child: const Text('Unblock'),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _empty(ColorScheme cs) {
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, size: 72, color: cs.onSurfaceVariant),
            const SizedBox(height: AppTheme.space16),
            Text(
              'You haven\'t blocked anyone',
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppTheme.space8),
            Text(
              'Use the … menu on a profile to block someone whose '
              'content you don\'t want to see.',
              textAlign: TextAlign.center,
              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
