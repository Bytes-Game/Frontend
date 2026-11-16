import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';

/// The name being looked up on the server right now, so a second tap while
/// the first is still waiting does not open the page twice.
String? _lookingUp;

/// Opens [username]'s profile, the way tapping a name or a picture does on
/// Instagram. Uses the account already in hand when there is one, and asks
/// the server otherwise; says so when there is no such account.
///
/// [onOpened] hears who is being opened, just before their page opens. A
/// video uses it to tell the feed that you went to look at who made it.
Future<void> openProfileByName(
  BuildContext context,
  String username, {
  void Function(UserModel user)? onOpened,
}) async {
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
  var gone = false;
  if (user == null) {
    if (_lookingUp == lower) return;
    _lookingUp = lower;
    try {
      final found = await ApiService.lookUpUser(username);
      user = found.user;
      gone = found.gone;
    } finally {
      _lookingUp = null;
    }
  }
  if (!context.mounted) return;
  if (user == null) {
    debugPrint(
      '[profile] could not open $username: '
      '${gone ? 'no such account' : 'the server did not answer'}',
    );
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          gone
              ? "$username's account isn't available."
              : "Couldn't open $username's profile. Check your connection.",
        ),
      ),
    );
    return;
  }
  onOpened?.call(user);
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ProfilePage(user: user!, isEmbedded: false),
    ),
  );
}

/// A person's picture or name. A tap opens their profile, the same as a
/// tap on an account in Search.
///
/// With [username] empty there is nobody to open: the child is shown as it
/// is, and a tap goes to whatever is underneath it.
class OpenProfileOnTap extends StatelessWidget {
  final String username;
  final Widget child;

  /// Told who is being opened, just before their page opens.
  final void Function(UserModel user)? onOpened;

  const OpenProfileOnTap({
    super.key,
    required this.username,
    required this.child,
    this.onOpened,
  });

  @override
  Widget build(BuildContext context) {
    if (username.isEmpty) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => openProfileByName(context, username, onOpened: onOpened),
      child: child,
    );
  }
}
