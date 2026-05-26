import'package:flutter/material.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/widgets/league_badge.dart';

/// Reusable list-tile for displaying a user wherever needed
/// (search results, followers list, following list, suggestions).
class UserTile extends StatelessWidget{
  final UserModel user;
  final bool isFollowing;
  final VoidCallback onFollowToggle;
  final VoidCallback? onTap;
  final bool showFollowButton;

  const UserTile({
    super.key,
    required this.user,
    required this.isFollowing,
    required this.onFollowToggle,
    this.onTap,
    this.showFollowButton = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        child: Text(
          user.username[0].toUpperCase(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: cs.onPrimaryContainer,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              user.username,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          LeagueBadge(league: user.league, small: true),
        ],
      ),
      subtitle: Text(
        'W:${user.wins}  L:${user.losses}  •  ${user.followersCount} followers',
      ),
      trailing: showFollowButton
          ? FilledButton.tonal(
              onPressed: onFollowToggle,
              style: FilledButton.styleFrom(
                backgroundColor: isFollowing
                    ? cs.surfaceContainerHighest
                    : cs.primaryContainer,
                foregroundColor: isFollowing
                    ? cs.onSurface.withValues(alpha: 0.7)
                    : cs.onPrimaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 36),
              ),
              child: Text(isFollowing ? 'Following' : 'Follow'),
            )
          : null,
    );
  }
}