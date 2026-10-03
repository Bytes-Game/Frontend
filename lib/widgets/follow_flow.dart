import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

/// Every Follow button in the app goes through here.
///
/// Following someone you have blocked used to just work: blocking ended the
/// follow, and the next tap on Follow put it back. The server now refuses a
/// follow across a block, and this turns its answer into something to do:
///
///   * you blocked them — a sheet says so and offers "Unblock and follow";
///   * they can't be followed by you — a short note, never saying why;
///   * anything else — the button flips back, as it always did.
///
/// Answers whether they are now followed.
Future<bool> followFromScreen(BuildContext context, UserModel target) async {
  final dp = Provider.of<DataProvider>(context, listen: false);
  final outcome = await dp.follow(target);
  if (!context.mounted) return outcome == FollowOutcome.followed;
  switch (outcome) {
    case FollowOutcome.followed:
      return true;
    case FollowOutcome.youBlocked:
      return _offerUnblock(context, dp, target);
    case FollowOutcome.unavailable:
      _say(context, "You can't follow this account.");
      return false;
    case FollowOutcome.failed:
      return false;
  }
}

Future<bool> _offerUnblock(
  BuildContext context,
  DataProvider dp,
  UserModel target,
) async {
  final unblock = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => BlockedFollowSheet(username: target.username),
  );
  if (unblock != true || !context.mounted) return false;
  final me = dp.user;
  if (me == null) return false;
  final ok = await ApiService.unblockUser(
    blockerId: me.id,
    blockedId: target.id,
  );
  if (!context.mounted) return false;
  if (!ok) {
    _say(context, "Couldn't unblock @${target.username}. Try again.");
    return false;
  }
  final outcome = await dp.follow(target);
  if (!context.mounted) return outcome == FollowOutcome.followed;
  _say(
    context,
    outcome == FollowOutcome.followed
        ? 'Unblocked and following @${target.username}'
        : "Unblocked @${target.username}, but couldn't follow. Try again.",
  );
  return outcome == FollowOutcome.followed;
}

void _say(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
  );
}

/// "You've blocked @name" — what Follow shows for someone you blocked, with
/// the way out: unblock them, and the follow goes through.
class BlockedFollowSheet extends StatelessWidget {
  final String username;

  const BlockedFollowSheet({super.key, required this.username});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? AppTheme.surfaceDark : AppTheme.surfaceLight;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    final text = dark ? Colors.white : Colors.black;
    return SafeArea(
      top: false,
      child: Container(
        key: const ValueKey('blocked_follow_sheet'),
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(AppTheme.radiusXxl),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(height: 20),
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.block_rounded,
                color: AppTheme.error,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "You've blocked @$username",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: text,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'To follow @$username, unblock them first. They will be '
              'able to see your profile and message you again.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 14.5, height: 1.35),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                key: const ValueKey('blocked_follow_unblock'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text(
                  'Unblock and follow',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: TextButton(
                key: const ValueKey('blocked_follow_cancel'),
                style: TextButton.styleFrom(foregroundColor: text),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now', style: TextStyle(fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
