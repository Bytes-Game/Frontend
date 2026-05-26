import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/user_tile.dart';
import 'package:myapp/pages/profile_page.dart';

/// Shows who a given user is following
///
/// Fetches all users and filters to those whose ID appears in the
/// target user's 'followinglist`.
class FollowingPage extends StatefulWidget{
  final String username;
  const FollowingPage({super.key, required this.username});

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage>
    with PageTracker<FollowingPage> {
  List<UserModel> _following = [];
  bool _loading = true;

  @override
  String get pageName => 'following_page';

  @override
  Map<String, dynamic> get pageParams => {'targetUsername': widget.username};

  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    final all = await ApiService.getAllUsers();
    final target = all.firstWhere(
      (u) => u.username == widget.username,
      orElse: () => all.first,
    );
    if (mounted) {
      setState(() {
        _following = 
            all.where((u) => target.followingList.contains(u.id)).toList();
        _loading = false;
      });
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final dp = Provider.of<DataProvider>(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.username} follows')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _following.isEmpty
              ? const Center(child: Text('Not following anyone yet'))
              : ListView.builder(
                  itemCount: _following.length,
                  itemBuilder: (_, i) {
                    final u = _following[i];
                    return UserTile(
                      user: u,
                      isFollowing: dp.following.contains(u.id),
                      onFollowToggle: () {
                        final becameFollowing = !dp.following.contains(u.id);
                        EventTracker.instance.trackFollowToggle(
                          targetUserId: u.id,
                          becameFollowing: becameFollowing,
                          fromPage: 'following_page',
                        );
                        if (becameFollowing) {
                          dp.followUser(u);
                        } else {
                          dp.unfollowUser(u);
                        }
                      },
                      onTap: () {
                        EventTracker.instance.trackTap(
                          target: 'following_user_tile',
                          pageName: 'following_page',
                          params: {'targetUserId': u.id, 'position': i},
                        );
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                ProfilePage(user: u, isEmbedded: false),
                          ),
                        );
                      },
                      showFollowButton: u.id != dp.user?.id,
                    );
                  },
                ),
    );
  }
}