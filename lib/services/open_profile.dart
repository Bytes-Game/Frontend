import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

/// Opens [username]'s profile, the way tapping a name or a picture does on
/// Instagram. Uses the account already in hand when there is one, and asks
/// the server otherwise; says so when there is no such account.
Future<void> openProfileByName(BuildContext context, String username) async {
  if (username.isEmpty) return;
  final dp = Provider.of<DataProvider>(context, listen: false);
  final lower = username.toLowerCase();
  UserModel? user;
  if (dp.user?.username.toLowerCase() == lower) user = dp.user;
  if (user == null) {
    for (final u in dp.allUsers) {
      if (u.username.toLowerCase() == lower) {
        user = u;
        break;
      }
    }
  }
  user ??= await ApiService.getUserByUsername(username);
  if (!context.mounted) return;
  if (user == null) {
    debugPrint('[profile] no account called $username to open');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't open $username's profile."),
      ),
    );
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProfilePage(user: user!, isEmbedded: false),
    ),
  );
}
