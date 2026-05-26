import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:myapp/config/app_theme.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';

/// Several read-only "policy + support" surfaces share the same
/// shape: a scrollable Markdown-ish body inside an AppBar Scaffold.
/// Bundling them in one file keeps small static pages out of their
/// own files each. The content is shipped in-app rather than fetched
/// from a CMS — that costs zero infrastructure, never breaks on a
/// network failure, and updates ride the regular Flutter release
/// train.

/// Terms of Service. Lightweight, app-author authored. Keep this in
/// sync with the version we publish elsewhere (web/landing) so a
/// user's "I read the ToS" claim is verifiable against a single
/// source of truth.
class TermsOfServicePage extends StatefulWidget {
  const TermsOfServicePage({super.key});

  @override
  State<TermsOfServicePage> createState() => _TermsOfServicePageState();
}

class _TermsOfServicePageState extends State<TermsOfServicePage>
    with PageTracker<TermsOfServicePage> {
  @override
  String get pageName => 'terms_of_service_page';

  @override
  Widget build(BuildContext context) {
    return _StaticDocScaffold(
      title: 'Terms of Service',
      lastUpdated: 'May 2026',
      sections: const [
        _DocSection('Welcome',
            'By using devf you agree to these terms. If you do not '
                'agree, please stop using the app.'),
        _DocSection('Your account',
            'You\'re responsible for the security of your account, '
                'the content you post, and the behavior you exhibit '
                'on the platform.'),
        _DocSection('Content rules',
            'Don\'t post content that is illegal, harassing, sexually '
                'explicit, violent, or violates someone else\'s '
                'rights. We may remove anything that breaks these '
                'rules and suspend accounts for repeat offenses.'),
        _DocSection('Your rights to your content',
            'You keep ownership of what you post. By posting it, you '
                'grant devf a license to host, display, and distribute '
                'it within the app and its public surfaces.'),
        _DocSection('Termination',
            'You can delete your account at any time. We may suspend '
                'or terminate accounts that break these terms or '
                'present a safety risk.'),
        _DocSection('Disclaimer',
            'The app is provided "as is" without warranties of any '
                'kind. We work hard to keep it reliable but downtime '
                'and bugs do happen.'),
        _DocSection('Changes',
            'We may update these terms. Material changes will be '
                'surfaced in-app before they take effect.'),
        _DocSection('Contact',
            'Questions about these terms can be sent to '
                'support@devf.app.'),
      ],
    );
  }
}

class PrivacyPolicyPage extends StatefulWidget {
  const PrivacyPolicyPage({super.key});

  @override
  State<PrivacyPolicyPage> createState() => _PrivacyPolicyPageState();
}

class _PrivacyPolicyPageState extends State<PrivacyPolicyPage>
    with PageTracker<PrivacyPolicyPage> {
  @override
  String get pageName => 'privacy_policy_page';

  @override
  Widget build(BuildContext context) {
    return _StaticDocScaffold(
      title: 'Privacy Policy',
      lastUpdated: 'May 2026',
      sections: const [
        _DocSection('What we collect',
            'Account info (username, full name, optional bio), '
                'content you post (videos, comments, likes, votes), '
                'and usage telemetry (which reels you watch, how long, '
                'tap events). We do NOT collect your phone number or '
                'email at sign-up today.'),
        _DocSection('Why we collect it',
            'Telemetry powers the recommendation engine that picks '
                'reels for your For You feed. Content + engagement '
                'feed your social graph and the battle/voting system. '
                'Account info keeps your profile visible to others.'),
        _DocSection('Who we share with',
            'No one for advertising — we don\'t sell or share your '
                'data for ads. We use cloud infrastructure providers '
                '(Render for hosting, Cloudflare R2 for video storage) '
                'who only see what they need to deliver the service.'),
        _DocSection('Your controls',
            'You can: edit your profile, delete posts (cascades through '
                'all responses/votes), clear watch history, block users, '
                'and turn on two-step verification. Account deletion is '
                'planned.'),
        _DocSection('Retention',
            'Watch events older than 30 days are aggregated into your '
                'user profile and the raw rows are eligible for deletion. '
                'Content stays until you delete it.'),
        _DocSection('Contact',
            'Privacy questions: privacy@devf.app.'),
      ],
    );
  }
}

class HelpCenterPage extends StatefulWidget {
  const HelpCenterPage({super.key});

  @override
  State<HelpCenterPage> createState() => _HelpCenterPageState();
}

class _HelpCenterPageState extends State<HelpCenterPage>
    with PageTracker<HelpCenterPage> {
  @override
  String get pageName => 'help_center_page';

  @override
  Widget build(BuildContext context) {
    return _StaticDocScaffold(
      title: 'Help Center',
      lastUpdated: '',
      sections: const [
        _DocSection('How do challenges work?',
            'Anyone can post a challenge — a short video and a prompt. '
                'Other users accept the challenge by posting a response '
                'video. Once there\'s a response, viewers in the For You '
                'feed can swipe left/right between the original and the '
                'response, then tap the trophy to vote for their pick.'),
        _DocSection('What\'s a league?',
            'Your league (Bronze through Diamond) reflects your battle '
                'record. Win battles to climb, lose to drop. The league '
                'badge shows next to your username everywhere.'),
        _DocSection('Why can\'t I edit my username?',
            'Username changes are rolling out — they need a uniqueness '
                'check + audit log on the backend before we open them up. '
                'You can update your full name and bio today.'),
        _DocSection('How do I report inappropriate content?',
            'Tap the share icon → Report on any post. The report goes '
                'into the moderation queue.'),
        _DocSection('How do I turn on 2FA?',
            'Profile → Settings → Two-step verification. You\'ll need '
                'an authenticator app like Google Authenticator, Authy, '
                'or 1Password.'),
        _DocSection('Why does the app drain battery on long sessions?',
            'Reels are video playback; we cap player pool size and '
                'aggressively pause off-screen video, but extended '
                'sessions over LTE will use noticeable power. Wi-Fi '
                'helps a lot.'),
        _DocSection('Still stuck?',
            'Tap "Report a problem" in Settings to send us a note.'),
      ],
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _StaticDocScaffold(
      title: 'About devf',
      lastUpdated: '',
      sections: const [
        _DocSection('What is devf?',
            'A TikTok-style battle arena where users challenge each '
                'other with creative videos and the community votes for '
                'the winner.'),
        _DocSection('Version',
            'devf 1.0.0 (May 2026)'),
        _DocSection('Open-source acknowledgements',
            'Built with Flutter, video_player, video_compress, gorilla/mux, '
                'PostgreSQL, Redis, and Meilisearch.'),
      ],
    );
  }
}

/// Bug report / feedback form. Posts an event into the existing
/// events stream — no new endpoint or storage. Analytics rolls
/// these up by surface for triage.
class BugReportPage extends StatefulWidget {
  const BugReportPage({super.key});

  @override
  State<BugReportPage> createState() => _BugReportPageState();
}

class _BugReportPageState extends State<BugReportPage>
    with PageTracker<BugReportPage> {
  @override
  String get pageName => 'bug_report_page';

  final TextEditingController _desc = TextEditingController();
  final TextEditingController _surface = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _desc.dispose();
    _surface.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    if (user == null) return;
    final desc = _desc.text.trim();
    if (desc.isEmpty) {
      _toast('Please describe the problem.');
      return;
    }
    setState(() => _submitting = true);
    final ok = await ApiService.reportBug(
      userId: user.id,
      description: desc,
      surface: _surface.text.trim(),
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (!ok) {
      _toast('Could not send. Try again.');
      return;
    }
    _toast('Thanks — we received your report.');
    Navigator.of(context).pop(true);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Report a problem')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.space20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'What happened?',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _surface,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Which screen? (optional)',
                  helperText: 'e.g. "home reels", "edit profile"',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _desc,
                minLines: 4,
                maxLines: 10,
                maxLength: 1000,
                inputFormatters: [LengthLimitingTextInputFormatter(1000)],
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Describe the problem',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: const Text('Send'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────
// Private — the reusable doc scaffold + a section model
// ────────────────────────────────────────────────────────────────────

class _StaticDocScaffold extends StatelessWidget {
  final String title;
  final String lastUpdated;
  final List<_DocSection> sections;

  const _StaticDocScaffold({
    required this.title,
    required this.lastUpdated,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppTheme.space20),
          children: [
            if (lastUpdated.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  'Last updated: $lastUpdated',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            for (final s in sections) ...[
              Text(
                s.heading,
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(s.body, style: tt.bodyMedium),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocSection {
  final String heading;
  final String body;
  const _DocSection(this.heading, this.body);
}
