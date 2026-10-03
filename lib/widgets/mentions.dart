import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/widgets/arena_ui.dart';

/// Mentioning people with an @, in comments and in chat, the way Instagram
/// does it:
///
///   * type @ and a few letters, and the people who match show above the
///     text box — the ones you follow first. Tap one and their name goes in.
///   * an @name in a comment or a message is drawn in bold colour, and
///     tapping it opens their profile.
///
/// The server tells whoever a COMMENT mentions (mentions.go). A message in
/// chat sends nothing extra: the one other person in it already hears
/// about every message — and they are the only one a chat suggests.

/// The same letters a username is made of (signup.go on the server): an @
/// after the start of the text or something that cannot be part of a name.
final RegExp _mention = RegExp(r'(^|[^A-Za-z0-9_.@])@([A-Za-z0-9_.]{3,20})');

/// What is being typed after an @ right before the cursor, and where its @
/// is — or null when the cursor is not in a mention.
({int at, String query})? activeMention(TextEditingValue value) {
  final cursor = value.selection.baseOffset;
  if (cursor < 0 || cursor > value.text.length) return null;
  final before = value.text.substring(0, cursor);
  final m = RegExp(
    r'(?:^|[^A-Za-z0-9_.@])@([A-Za-z0-9_.]{0,20})$',
  ).firstMatch(before);
  if (m == null) return null;
  final query = m.group(1)!;
  return (at: cursor - query.length - 1, query: query);
}

/// Puts @[username] in place of the mention being typed, with a space after
/// it, and the cursor after that.
void insertMention(TextEditingController controller, String username) {
  final value = controller.value;
  final active = activeMention(value);
  if (active == null) return;
  final cursor = value.selection.baseOffset;
  final after = value.text.substring(cursor);
  final insert = '@$username ';
  final text =
      value.text.substring(0, active.at) +
      insert +
      (after.startsWith(' ') ? after.substring(1) : after);
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: active.at + insert.length),
  );
}

/// The people [query] could mean: whose name starts with it, then whose
/// name contains it — the people you follow first. Never yourself.
///
/// From [among] when given — in a chat, the people in it — and otherwise
/// from everyone the app knows.
List<UserModel> mentionCandidates(
  DataProvider dp,
  String query, {
  int max = 5,
  List<UserModel>? among,
}) {
  final me = dp.user?.id ?? '';
  final q = query.toLowerCase();
  final following = dp.following.toSet();
  int rank(UserModel u) {
    final name = u.username.toLowerCase();
    var r = name.startsWith(q) ? 0 : 2;
    if (following.contains(u.id)) r -= 1;
    return r;
  }

  final list =
      (among ?? dp.allUsers).where((u) {
        if (u.id.isEmpty || u.id == me || u.username.isEmpty) return false;
        if (q.isEmpty) return true;
        return u.username.toLowerCase().contains(q) ||
            u.fullName.toLowerCase().contains(q);
      }).toList()..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.username.compareTo(b.username);
      });
  return list.take(max).toList();
}

/// The people who match the @name being typed in [controller], shown above
/// the text box. Nothing at all when no @name is being typed.
class MentionSuggestions extends StatefulWidget {
  final TextEditingController controller;

  /// For the comments sheet, which is dark whatever the phone's theme.
  final bool dark;

  /// Only these people, when given. A chat offers the person you are
  /// talking to, not everyone on the app: they are the only one who will
  /// read it.
  final List<UserModel>? people;

  const MentionSuggestions({
    super.key,
    required this.controller,
    this.dark = false,
    this.people,
  });

  @override
  State<MentionSuggestions> createState() => _MentionSuggestionsState();
}

class _MentionSuggestionsState extends State<MentionSuggestions> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant MentionSuggestions old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final active = activeMention(widget.controller.value);
    if (active == null) return const SizedBox.shrink();
    final dp = Provider.of<DataProvider>(context, listen: false);
    final people = mentionCandidates(dp, active.query, among: widget.people);
    if (people.isEmpty) return const SizedBox.shrink();
    final dark = widget.dark || Theme.of(context).brightness == Brightness.dark;
    final bg = widget.dark
        ? const Color(0xFF1C1C1E)
        : (dark ? AppTheme.surfaceDark : AppTheme.surfaceLight);
    final text = dark ? Colors.white : Colors.black;
    final muted = dark ? AppTheme.textMutedDark : AppTheme.textMutedLight;
    return Container(
      key: const ValueKey('mention_suggestions'),
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.08),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final u in people)
              InkWell(
                key: ValueKey('mention_pick_${u.username}'),
                onTap: () => insertMention(widget.controller, u.username),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      ArenaAvatar(name: u.username, size: 32),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              u.username,
                              style: TextStyle(
                                color: text,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (u.fullName.isNotEmpty)
                              Text(
                                u.fullName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: muted, fontSize: 12.5),
                              ),
                          ],
                        ),
                      ),
                      if (dp.following.contains(u.id))
                        Text(
                          'Following',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// [text] with every @name in bold [mentionColor]; tapping one opens that
/// person's profile.
class MentionText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color mentionColor;

  /// Underlined too: on a coloured bubble, where colour alone would not
  /// set a name apart.
  final bool underline;

  const MentionText(
    this.text, {
    super.key,
    required this.style,
    this.mentionColor = AppTheme.primary,
    this.underline = false,
  });

  @override
  State<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends State<MentionText> {
  final List<TapGestureRecognizer> _taps = [];

  @override
  void dispose() {
    _disposeTaps();
    super.dispose();
  }

  void _disposeTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  Future<void> _open(String username) async {
    final dp = Provider.of<DataProvider>(context, listen: false);
    final lower = username.toLowerCase();
    UserModel? user;
    for (final u in dp.allUsers) {
      if (u.username.toLowerCase() == lower) {
        user = u;
        break;
      }
    }
    user ??= await ApiService.getUserByUsername(username);
    if (!mounted) return;
    if (user == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text("@$username isn't on here"),
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

  @override
  Widget build(BuildContext context) {
    _disposeTaps();
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _mention.allMatches(widget.text)) {
      final lead = m.group(1)!;
      final name = m.group(2)!.replaceAll(RegExp(r'\.+$'), '');
      final start = m.start + lead.length;
      final end = start + 1 + name.length;
      if (start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, start)));
      }
      final tap = TapGestureRecognizer()..onTap = () => _open(name);
      _taps.add(tap);
      spans.add(
        TextSpan(
          text: widget.text.substring(start, end),
          style: TextStyle(
            color: widget.mentionColor,
            fontWeight: FontWeight.w700,
            decoration: widget.underline ? TextDecoration.underline : null,
            decorationColor: widget.mentionColor,
          ),
          recognizer: tap,
          semanticsLabel: '@$name, open their profile',
        ),
      );
      last = end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
