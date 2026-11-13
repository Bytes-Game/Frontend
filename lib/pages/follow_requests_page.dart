import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// The people asking to follow you.
///
/// Only a private account is asked: a public one is followed at once.
/// Each person waits here until you say yes or no. A yes makes them a
/// follower, who can see your videos and battles. A no is not announced.
class FollowRequestsPage extends StatefulWidget {
  const FollowRequestsPage({super.key});

  @override
  State<FollowRequestsPage> createState() => _FollowRequestsPageState();
}

class _FollowRequestsPageState extends State<FollowRequestsPage>
    with PageTracker<FollowRequestsPage> {
  @override
  String get pageName => 'follow_requests_page';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() =>
      Provider.of<DataProvider>(context, listen: false).loadFollowRequests();

  Future<void> _openProfile(UserModel asker) async {
    final user = await ApiService.getUserByUsername(asker.username);
    if (!mounted || user == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProfilePage(user: user, isEmbedded: false),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final waiting = Provider.of<DataProvider>(context).followRequests;
    return Scaffold(
      appBar: AppBar(title: const Text('Follow requests'), centerTitle: true),
      body: RefreshIndicator(
        onRefresh: _load,
        child: waiting.isEmpty
            ? ListView(
                children: const [
                  SizedBox(height: 80),
                  ArenaEmptyState(
                    key: ValueKey('follow_requests_none'),
                    icon: Icons.person_add_alt_1_rounded,
                    title: 'No requests',
                    subtitle:
                        'When your account is private, people who want to '
                        'follow you ask first. They wait here for your '
                        'answer.',
                  ),
                ],
              )
            : ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                itemCount: waiting.length,
                itemBuilder: (_, i) {
                  final asker = waiting[i];
                  return InkWell(
                    key: ValueKey('follow_request_${asker.id}'),
                    onTap: () => _openProfile(asker),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ArenaAvatar(name: asker.username, size: 48),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  asker.username,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (asker.fullName.isNotEmpty)
                                  Text(
                                    asker.fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      color: quietText(context),
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                FollowRequestButtons(asker: asker),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// Accept and Decline for one person asking to follow you.
///
/// Under the name rather than beside it: two buttons beside the text leave
/// no room for the text on a narrow phone, or with large type.
class FollowRequestButtons extends StatefulWidget {
  final UserModel asker;

  const FollowRequestButtons({super.key, required this.asker});

  @override
  State<FollowRequestButtons> createState() => _FollowRequestButtonsState();
}

class _FollowRequestButtonsState extends State<FollowRequestButtons> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    if (_busy) return;
    setState(() => _busy = true);
    final dp = Provider.of<DataProvider>(context, listen: false);
    // Found now: the row is gone by the time the server has answered, and
    // with it this widget's place on the screen.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = widget.asker.username;
    final ok = await dp.answerFollowRequest(widget.asker, accept: accept);
    if (mounted) setState(() => _busy = false);
    messenger?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          !ok
              ? "Couldn't answer @$name's request. Try again."
              : accept
              ? '@$name can now see your videos and battles.'
              : "@$name's request was declined.",
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
    );
    const label = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        SizedBox(
          height: 34,
          child: FilledButton(
            key: ValueKey('request_accept_${widget.asker.id}'),
            onPressed: _busy ? null : () => _answer(true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: shape,
            ),
            child: const Text('Accept', style: label),
          ),
        ),
        SizedBox(
          height: 34,
          child: OutlinedButton(
            key: ValueKey('request_decline_${widget.asker.id}'),
            onPressed: _busy ? null : () => _answer(false),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: shape,
            ),
            child: const Text('Decline', style: label),
          ),
        ),
      ],
    );
  }
}
