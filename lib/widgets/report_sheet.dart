import 'package:flutter/material.dart';

import 'package:myapp/config/constants.dart';
import 'package:myapp/services/api_service.dart';

/// What is being reported.
enum ReportTarget {
  /// A post's own video (or photo).
  video('challenge', 'video'),

  /// An answer video in a battle.
  answer('response', 'video'),

  /// A comment.
  comment('comment', 'comment'),

  /// A whole account.
  account('user', 'account');

  const ReportTarget(this.wire, this.noun);

  /// What the server calls it.
  final String wire;

  /// What the person is told it is.
  final String noun;
}

/// The reasons offered, in the order shown: (code the server keeps, what
/// the person reads). The same list as the server's (moderation.go).
const reportReasons = <(String, String)>[
  ('sexual_content', 'Nudity or sexual content'),
  ('child_safety', 'A child may be at risk'),
  ('violence', 'Violence, threats or dangerous acts'),
  ('hate', 'Hate speech'),
  ('harassment', 'Bullying or harassment'),
  ('self_harm', 'Suicide or self-harm'),
  ('spam', 'Spam or scams'),
  ('impersonation', 'Pretending to be someone else'),
  ('ip', 'Uses my work without permission'),
  ('other', 'Something else'),
];

/// What the person is told after sending, by what came of it.
String reportOutcomeMessage(ReportOutcome o) => switch (o) {
  ReportOutcome.sent =>
    "Thanks for telling us. We'll review it. Nobody is told who reported it.",
  ReportOutcome.alreadySent => "You've already reported this. We'll review it.",
  ReportOutcome.gone => "This isn't here any more.",
  ReportOutcome.tooMany =>
    "You've sent several reports in a row. Try again in a few minutes.",
  ReportOutcome.failed =>
    "Couldn't send the report. Check your connection and try again.",
};

/// Report something as harmful: a video, an answer, a comment or an
/// account. Asks why, lets the person add a few words, sends it, and says
/// what came of it. Returns that, or null when they changed their mind.
///
/// Reports wait for a person to read them (the server's /admin/reports),
/// who can remove the thing or suspend the account. A report on a serious
/// reason also stops the reporter seeing that account's videos.
///
/// [whose] is the owner's username, for the title ("Report @maya").
Future<ReportOutcome?> reportHarm(
  BuildContext context, {
  required ReportTarget target,
  required String targetId,
  String whose = '',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await showModalBottomSheet<ReportOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        ReportSheet(target: target, targetId: targetId, whose: whose),
  );
  if (outcome != null) {
    messenger?.showSnackBar(
      SnackBar(content: Text(reportOutcomeMessage(outcome))),
    );
  }
  return outcome;
}

/// The sheet itself: a reason, then a few optional words and Send.
class ReportSheet extends StatefulWidget {
  final ReportTarget target;
  final String targetId;
  final String whose;

  const ReportSheet({
    super.key,
    required this.target,
    required this.targetId,
    this.whose = '',
  });

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  String? _reason;
  final _words = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  String get _title {
    if (widget.target == ReportTarget.account && widget.whose.isNotEmpty) {
      return 'Report @${widget.whose}';
    }
    if (widget.whose.isNotEmpty) {
      return "Report ${widget.whose}'s ${widget.target.noun}";
    }
    return 'Report this ${widget.target.noun}';
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    setState(() => _sending = true);
    final outcome = await ApiService.reportContent(
      targetType: widget.target.wire,
      targetId: widget.targetId,
      reason: reason,
      description: _words.text.trim(),
    );
    if (!mounted) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.65);
    final reason = _reason;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            key: const ValueKey('report_sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                reason == null
                    ? 'Why are you reporting it? Nobody is told who reported '
                          'it.'
                    : _labelOf(reason),
                style: TextStyle(color: muted, fontSize: 14),
              ),
              const SizedBox(height: 8),
              if (reason == null)
                for (final (code, label) in reportReasons)
                  ListTile(
                    key: ValueKey('report_reason_$code'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    trailing: Icon(Icons.chevron_right_rounded, color: muted),
                    onTap: () => setState(() => _reason = code),
                  )
              else ...[
                if (_urgentHelp(reason) case final help?)
                  Container(
                    key: const ValueKey('report_urgent_help'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      help,
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                TextField(
                  key: const ValueKey('report_words'),
                  controller: _words,
                  maxLength: 1000,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Anything we should know? (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      key: const ValueKey('report_back'),
                      onPressed: _sending
                          ? null
                          : () => setState(() => _reason = null),
                      child: const Text('Back'),
                    ),
                    const Spacer(),
                    FilledButton(
                      key: const ValueKey('report_send'),
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Send report'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Reports are read by a person. Anything that breaks the '
                  'Community Guidelines is removed, and the account may be '
                  'suspended. You can also write to ${AppConstants.supportEmail}.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _labelOf(String code) => reportReasons
      .firstWhere((r) => r.$1 == code, orElse: () => (code, code))
      .$2;

  /// Words for the reasons where somebody may be in danger right now: a
  /// report is read later, and help should not wait for it.
  static String? _urgentHelp(String code) => switch (code) {
    'child_safety' =>
      'If a child is in danger right now, call 112. You can also report '
          'child sexual abuse material at cybercrime.gov.in.',
    'self_harm' =>
      'If you or someone you know may be in danger right now, call 112. '
          'Tele-MANAS (14416) is free, any time, in many languages.',
    _ => null,
  };
}
