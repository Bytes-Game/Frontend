import 'package:flutter/material.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/widgets/arena_ui.dart';
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
    final league = LeagueBadge.solidColor(user.league);

    return Pressable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ArenaAvatar(name: user.username, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      InfoChip(
                        label: user.league,
                        icon: Icons.shield_rounded,
                        color: league,
                      ),
                      InfoChip(
                        label: '${user.wins}W · ${user.losses}L',
                        icon: Icons.emoji_events_outlined,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (showFollowButton) ...[
              const SizedBox(width: 8),
              isFollowing
                  ? Pressable(
                      onTap: onFollowToggle,
                      child: Container(
                        height: 34,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: quietFill(context),
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusSm + 2),
                        ),
                        child: Text(
                          'Following',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    )
                  : PrimaryButton(
                      label: 'Follow',
                      height: 34,
                      onPressed: onFollowToggle,
                    ),
            ],
          ],
        ),
      ),
    );
  }
}
