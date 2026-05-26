import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/event_tracker.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/user_tile.dart';
import 'package:myapp/pages/profile_page.dart';

/// Shows who follows a given user.
///
/// Fetches all users from the backend and filters to those whose
/// `followingList` contains the target user's ID.
class FollowersPage extends StatefulWidget {
  final String username;
  const FollowersPage({super.key, required this.username});

  @override
  State<FollowersPage> createState() => _FollowersPageState();
}

class _FollowersPageState extends State<FollowersPage>
    with PageTracker<FollowersPage> {
  List<UserModel> _followers = [];
  bool _loading = true;

  @override
  String get pageName => 'followers_page';

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
        _followers = 
             all.where((u) => u.followingList.contains(target.id)).toList();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context){
    final dp = Provider.of<DataProvider>(context);
    return Scaffold(
      appBar: AppBar(title: Text('${widget.username}\'s Followers')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _followers.isEmpty
              ? const Center(child: Text('No followers yet'))
              : ListView.builder(
                  itemCount: _followers.length,
                  itemBuilder: (_, i) {
                    final u = _followers[i];
                    return UserTile(
                      user: u,
                      isFollowing: dp.following.contains(u.id),
                      onFollowToggle: () {
                        final becameFollowing = !dp.following.contains(u.id);
                        EventTracker.instance.trackFollowToggle(
                          targetUserId: u.id,
                          becameFollowing: becameFollowing,
                          fromPage: 'followers_page',
                        );
                        if (becameFollowing) {
                          dp.followUser(u);
                        } else {
                          dp.unfollowUser(u);
                        }
                      },
                      onTap: () {
                        EventTracker.instance.trackTap(
                          target: 'followers_user_tile',
                          pageName: 'followers_page',
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
                      showFollowButton: u.id != dp.user?. id,
                    );
                  },
                ),
    );
  }
}