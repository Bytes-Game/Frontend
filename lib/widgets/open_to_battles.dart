import 'package:flutter/material.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/services/api_service.dart';

/// The owner's "Open to battles" switch, for a post that is already up.
///
/// On: anybody can answer it with their own video, and the two battle for
/// votes. Off: a normal post that nobody can answer. Closing a post that
/// already has an answer stops anyone else joining; the battle already
/// running carries on.
///
/// The same switch everywhere the owner meets their post: its page, the
/// reel's long-press menu, and their profile's long-press menu. It asks the
/// server, shows the answer, and says so when it could not change.
class OpenToBattlesTile extends StatefulWidget {
  final String challengeId;
  final bool open;

  /// After the server agreed, with what it now is.
  final ValueChanged<bool> onChanged;

  const OpenToBattlesTile({
    super.key,
    required this.challengeId,
    required this.open,
    required this.onChanged,
  });

  @override
  State<OpenToBattlesTile> createState() => _OpenToBattlesTileState();
}

class _OpenToBattlesTileState extends State<OpenToBattlesTile> {
  late bool _open = widget.open;
  bool _busy = false;

  @override
  void didUpdateWidget(OpenToBattlesTile old) {
    super.didUpdateWidget(old);
    if (!_busy && old.open != widget.open) _open = widget.open;
  }

  Future<void> _change(bool want) async {
    if (_busy) return;
    final was = _open;
    // Moves at once, the way a switch should; put back if the server says no.
    setState(() {
      _open = want;
      _busy = true;
    });
    final got = await ApiService.setOpenToBattles(widget.challengeId, want);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _open = got ?? was;
    });
    final say = ScaffoldMessenger.maybeOf(context);
    if (got == null) {
      say?.showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't change that. Check your connection and "
            'try again.'),
      ));
      return;
    }
    widget.onChanged(got);
    say?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(got
          ? 'Open to battles. Anyone can answer it now.'
          : 'Now a normal post. Nobody can answer it.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      key: ValueKey('battles_switch_${widget.challengeId}'),
      value: _open,
      onChanged: _busy ? null : _change,
      activeTrackColor: AppTheme.primary,
      secondary: Icon(
        _open ? Icons.bolt_rounded : Icons.do_not_disturb_on_outlined,
        color: _open ? AppTheme.primary : null,
      ),
      title: const Text('Open to battles'),
      subtitle: Text(
        _open
            ? 'Anyone can answer it with their own video'
            : 'A normal post. Nobody can answer it',
      ),
    );
  }
}
