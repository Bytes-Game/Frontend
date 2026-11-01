import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:myapp/config/app_theme.dart';
import 'package:myapp/config/constants.dart';
import 'package:myapp/pages/legal_texts.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/page_tracker.dart';
import 'package:myapp/widgets/flex_logo.dart';
import 'package:myapp/widgets/settings_kit.dart';

/// Support and about: the Help Center, Terms and policies (with the Terms
/// of Service, Privacy Policy and Community Guidelines), About, and Report
/// a problem.
///
/// Everything is in the app rather than fetched from a website: it costs
/// nothing to run, never fails on a bad connection, and changes with each
/// release. The documents' words are in legal_texts.dart.

/// Puts [text] on the clipboard and says so.
Future<void> _copy(BuildContext context, String text, String what) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(SnackBar(
    behavior: SnackBarBehavior.floating,
    content: Text('$what copied'),
  ));
}

void _push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

/// The open-source licences of everything the app is built from, on
/// Flutter's own licence page.
void showFlexLicences(BuildContext context) => showLicensePage(
      context: context,
      applicationName: AppConstants.appName,
      applicationVersion: AppConstants.appVersion,
      applicationIcon: const Padding(
        padding: EdgeInsets.all(12),
        child: FlexLogo(size: 56, glow: false),
      ),
    );

// ═════════════════════════════════════════════════════════════════════════
// THE DOCUMENTS
// ═════════════════════════════════════════════════════════════════════════

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
  Widget build(BuildContext context) => const _LegalReader(
        doc: termsOfService,
        icon: Icons.description_rounded,
      );
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
  Widget build(BuildContext context) => const _LegalReader(
        doc: privacyPolicy,
        icon: Icons.privacy_tip_rounded,
      );
}

class CommunityGuidelinesPage extends StatefulWidget {
  const CommunityGuidelinesPage({super.key});

  @override
  State<CommunityGuidelinesPage> createState() =>
      _CommunityGuidelinesPageState();
}

class _CommunityGuidelinesPageState extends State<CommunityGuidelinesPage>
    with PageTracker<CommunityGuidelinesPage> {
  @override
  String get pageName => 'community_guidelines_page';

  @override
  Widget build(BuildContext context) => const _LegalReader(
        doc: communityGuidelines,
        icon: Icons.diversity_3_rounded,
      );
}

/// A long document, laid out to be read: when it last changed, the short
/// version, a table of contents that jumps to each part, then the numbered
/// parts, and who to write to.
class _LegalReader extends StatefulWidget {
  const _LegalReader({required this.doc, required this.icon});

  final LegalDocument doc;
  final IconData icon;

  @override
  State<_LegalReader> createState() => _LegalReaderState();
}

class _LegalReaderState extends State<_LegalReader> {
  late final _sectionKeys =
      List.generate(widget.doc.sections.length, (_) => GlobalKey());
  final _top = GlobalKey();

  void _jumpTo(GlobalKey key) {
    final at = key.currentContext;
    if (at == null) return;
    Scrollable.ensureVisible(
      at,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
      alignment: 0.02,
    );
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final cs = Theme.of(context).colorScheme;
    final muted = settingsMuted(context);
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: Text(doc.title),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        key: const ValueKey('legal_doc'),
        padding: const EdgeInsets.fromLTRB(
            AppTheme.space16, AppTheme.space8, AppTheme.space16, 48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The heading: what it is and when it changed.
                Row(
                  key: _top,
                  children: [
                    _GradientTile(icon: widget.icon, size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${AppConstants.appName} ${doc.title}',
                            style: const TextStyle(
                              fontSize: 22,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 6),
                          _Pill(
                            key: const ValueKey('legal_updated'),
                            text: 'Last updated $legalUpdated',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  doc.intro,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.55,
                    color: cs.onSurface.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: 18),

                // The short version.
                Container(
                  key: const ValueKey('legal_summary'),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  decoration: settingsCard(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _CardHeading(
                        icon: Icons.bolt_rounded,
                        text: 'The short version',
                      ),
                      const SizedBox(height: 10),
                      for (final line in doc.summary)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Padding(
                                padding: EdgeInsets.only(top: 1),
                                child: Icon(Icons.check_circle_rounded,
                                    size: 18, color: AppTheme.primary),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  line,
                                  style: const TextStyle(
                                      fontSize: 14.5, height: 1.4),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Contents.
                Container(
                  padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                  decoration: settingsCard(context),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: _CardHeading(
                          icon: Icons.format_list_numbered_rounded,
                          text: 'Contents',
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (var i = 0; i < doc.sections.length; i++)
                        InkWell(
                          key: ValueKey('legal_toc_$i'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: () => _jumpTo(_sectionKeys[i]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 9),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 28,
                                  child: Text(
                                    '${i + 1}.',
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.primary,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    doc.sections[i].title,
                                    style: const TextStyle(fontSize: 14.5),
                                  ),
                                ),
                                Icon(Icons.chevron_right_rounded,
                                    size: 20, color: muted),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),

                // The parts.
                for (var i = 0; i < doc.sections.length; i++)
                  _LegalPart(
                    key: _sectionKeys[i],
                    number: i + 1,
                    section: doc.sections[i],
                  ),

                // Who to write to.
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: settingsCard(context),
                  child: Row(
                    children: [
                      const _GradientTile(
                          icon: Icons.mail_rounded, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Questions?',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              doc.contact,
                              style: const TextStyle(
                                fontSize: 14,
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('legal_contact'),
                        tooltip: 'Copy email address',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () =>
                            _copy(context, doc.contact, 'Email address'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: TextButton.icon(
                    key: const ValueKey('legal_back_to_top'),
                    onPressed: () => _jumpTo(_top),
                    icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    label: const Text('Back to top'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One numbered part of a document.
class _LegalPart extends StatelessWidget {
  const _LegalPart({super.key, required this.number, required this.section});

  final int number;
  final LegalSection section;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = TextStyle(
      fontSize: 15,
      height: 1.55,
      color: cs.onSurface.withValues(alpha: 0.88),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            key: ValueKey('legal_part_$number'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$number',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    section.title,
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final p in section.body)
            if (p.startsWith('• '))
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(top: 9, right: 12),
                      decoration: const BoxDecoration(
                        color: AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(child: Text(p.substring(2), style: body)),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(p, style: body),
              ),
        ],
      ),
    );
  }
}

/// Terms and policies: every document in one place, the way TikTok lists
/// them.
class TermsAndPoliciesPage extends StatefulWidget {
  const TermsAndPoliciesPage({super.key});

  @override
  State<TermsAndPoliciesPage> createState() => _TermsAndPoliciesPageState();
}

class _TermsAndPoliciesPageState extends State<TermsAndPoliciesPage>
    with PageTracker<TermsAndPoliciesPage> {
  @override
  String get pageName => 'terms_and_policies_page';

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Terms and policies'),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const _Hero(
            icon: Icons.gavel_rounded,
            title: 'The rules, in plain words',
            text: 'How ${AppConstants.appName} works, how we look after '
                'your information, and how to keep it a good place for '
                'everyone.',
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                key: const ValueKey('policies_guidelines'),
                icon: Icons.diversity_3_rounded,
                color: AppTheme.primary,
                title: 'Community Guidelines',
                subtitle: 'What is and is not allowed',
                onTap: () => _push(context, const CommunityGuidelinesPage()),
              ),
              SettingsTile(
                key: const ValueKey('policies_terms'),
                icon: Icons.description_rounded,
                color: AppTheme.primary,
                title: 'Terms of Service',
                subtitle: 'The agreement for using ${AppConstants.appName}',
                onTap: () => _push(context, const TermsOfServicePage()),
              ),
              SettingsTile(
                key: const ValueKey('policies_privacy'),
                icon: Icons.privacy_tip_rounded,
                color: AppTheme.primary,
                title: 'Privacy Policy',
                subtitle: 'What we collect, and your choices',
                onTap: () => _push(context, const PrivacyPolicyPage()),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                key: const ValueKey('policies_licences'),
                icon: Icons.code_rounded,
                color: AppTheme.primary,
                title: 'Open-source licences',
                subtitle: 'The software ${AppConstants.appName} is built with',
                onTap: () => showFlexLicences(context),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Last updated $legalUpdated',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: muted),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// HELP CENTER
// ═════════════════════════════════════════════════════════════════════════

/// One answer in the Help Center.
class HelpArticle {
  const HelpArticle(this.question, this.answer);

  final String question;

  /// Paragraphs. One that starts with "• " shows as a bullet point.
  final List<String> answer;

  bool matches(List<String> words) {
    final text = '$question ${answer.join(' ')}'.toLowerCase();
    return words.every(text.contains);
  }
}

/// A group of answers.
class HelpTopic {
  const HelpTopic(this.id, this.title, this.icon, this.articles);

  final String id;
  final String title;
  final IconData icon;
  final List<HelpArticle> articles;
}

const _support = AppConstants.supportEmail;
const _app = AppConstants.appName;

/// Everything the Help Center answers. Each answer says what the app really
/// does: when a screen changes, change its answer here.
const helpTopics = [
  HelpTopic('account', 'Account and sign-in', Icons.person_rounded, [
    HelpArticle('I forgot my password', [
      'On the sign-in screen, tap Forgot password?. Enter your username or '
          'email, and we will email a 6-digit code to the address on your '
          'account.',
      'Enter the code and choose a new password. The code works for 15 '
          'minutes. After the change, every phone signed in to your account '
          'is signed out, and you are signed in with the new password.',
      'No email? Check your spam folder, then tap Resend after a minute. '
          'If your account has no email address, or you cannot get into it '
          'any more, write to $_support and tell us your username.',
    ]),
    HelpArticle('How do I change my username?', [
      'Profile → Edit profile → Username → Change. You can change it once '
          'every 30 days.',
      'Your old username becomes free for anyone to take, and links to '
          'your profile with it stop working. Any other phone signed in to '
          'your account is signed out.',
    ]),
    HelpArticle('How do I turn on two-step verification?', [
      'Settings → Two-step verification. You need an authenticator app, '
          'such as Google Authenticator, Authy or 1Password. Add $_app to it, '
          'save the recovery codes it shows you somewhere safe, and enter '
          'the 6-digit code the app shows.',
      'From then on, signing in asks for a code from the app as well as '
          'your password (or Google, or Apple). Each code works once.',
      'Lost your phone? Sign in with one of your recovery codes instead: '
          'tap "Use a recovery code instead" on the code screen. Each works '
          'once.',
    ]),
    HelpArticle('Can I sign in with Google or Apple?', [
      'Yes: on the sign-in or sign-up screen, tap Continue with Google, or '
          'Continue with Apple. The first time, choose a username and add '
          'your birthday to finish making your account.',
      'If you already made an account with a password using the same '
          'email, sign in with your password instead. Accounts are never '
          'joined on the email alone, to keep them safe.',
      'Signed up with Google or Apple and want a password too? On the '
          'sign-in screen, tap Forgot password? and use your email: the code '
          'lets you set one.',
    ]),
    HelpArticle('How do I change my password?', [
      'Settings → Change password. Enter your current password, then the '
          'new one twice.',
      'Every other phone signed in to your account is signed out. This '
          'one stays signed in.',
    ]),
    HelpArticle('How do I delete my account?', [
      'Settings → Delete account, then type your username to confirm.',
      'Your account is hidden from everyone straight away and signed out on '
          'every phone. Battles you are in end with no result. After 30 '
          'days it is deleted for good, with everything in it.',
      'Changed your mind? Sign in within the 30 days and choose Keep my '
          'account. Everything comes back.',
    ]),
    HelpArticle('Can I have more than one account?', [
      'Yes, each with its own email address. Go to Settings → Create a new '
          'account. You are logged out of this one first, and can sign back '
          'in to it any time.',
      'Using one of your accounts to vote for, or battle, another of yours '
          'breaks our rules.',
    ]),
  ]),
  HelpTopic('battles', 'Battles and leagues', Icons.emoji_events_rounded, [
    HelpArticle('How do battles work?', [
      'Anyone can post a challenge: a short video and a prompt. Others '
          'accept it by posting their own answer.',
      'Once there is an answer, viewers in the For You feed swipe between '
          'the two videos, then tap the trophy to vote for their pick.',
    ]),
    HelpArticle("What's a league?", [
      'Everybody starts on 1,000 points in Bronze. Every league is 1,000 '
          'points: Silver starts at 2,000, Gold at 3,000, Platinum at '
          '4,000, Diamond at 5,000 and Ace at 6,000. Your league moves with '
          'your points, up and down.',
      'Each league up is harder: a win is worth less and a loss costs '
          'more. In Bronze a win is +40 and a loss -10; in Ace a win is +15 '
          'and a loss -35. A draw is half of each.',
    ]),
    HelpArticle('Who can I battle?', [
      'Players close to your points, so battles stay fair. How close '
          'depends on your league: within 50 points in Bronze, 40 in '
          'Silver, 30 in Gold, 20 in Platinum, 10 in Diamond and 5 in Ace. '
          'When two leagues meet, the higher one\'s rule counts.',
      'As you get close to the next league, players in it come within '
          'reach. Friends (people you follow who follow you back) can '
          'battle you at any level.',
      'When you cannot answer a challenge, its Accept button is switched '
          'off and tells you why.',
    ]),
    HelpArticle("What if a video doesn't match its challenge?", [
      'On the video, tap More (⋯) and choose "Doesn\'t match the '
          'challenge". If our check or enough viewers agree, its owner '
          'loses rating points. The video stays up.',
      'If you are in that battle yourself and our check finds the video '
          'does match, the report costs you points, so report only what '
          'truly does not fit.',
    ]),
  ]),
  HelpTopic('posting', 'Posting videos', Icons.videocam_rounded, [
    HelpArticle('How long can my video be?', [
      'Up to 3 minutes. A longer video can be trimmed before you post it.',
    ]),
    HelpArticle('How do I add music?', [
      'In the editor, tap Music and pick a song from the free library. '
          'Every song there is free for anyone to use. When its licence '
          'asks for the artist to be credited, $_app adds the credit to '
          'your post.',
    ]),
    HelpArticle('Where are my posts saved on my phone?', [
      'With Settings → Save your posts to your phone switched on, a copy '
          'of what you make or edit goes to your phone\'s gallery, in a '
          '$_app album.',
    ]),
    HelpArticle('How do I delete a post?', [
      'Open the post, tap More (⋯) and choose Delete post. It is removed, '
          'with its answers and votes.',
    ]),
  ]),
  HelpTopic('privacy', 'Privacy and safety', Icons.shield_rounded, [
    HelpArticle('How do I make my account private?', [
      'Settings → Privacy → Private account. Only your followers can see '
          'your videos and battles. Anyone can still see your name and '
          'picture.',
    ]),
    HelpArticle('Who can message and call me?', [
      'Settings → Privacy → Messages and calls: Everyone, or Only people '
          'you follow. People you follow can always reach you.',
      'A private account takes messages and calls only from people it '
          'follows.',
    ]),
    HelpArticle('How do I block someone?', [
      'Open their profile, tap More (⋯) and choose Block. They cannot see '
          'your profile or message you.',
      'Settings → Privacy → Blocked accounts lists everyone you have '
          'blocked, and you can unblock them there.',
    ]),
    HelpArticle('How do I report something?', [
      '• A video that does not fit its challenge: on the video, tap More '
          '(⋯) → "Doesn\'t match the challenge".',
      '• Someone bothering you: block them from their profile.',
      '• Anything else that breaks our Community Guidelines, or someone '
          'pretending to be you: Settings → Report a problem, or write to '
          '$_support.',
    ]),
    HelpArticle("How do I hide when I'm online?", [
      'Settings → Privacy → Show when you\'re active. Switch it off and '
          'nobody sees when you are online or when you were last here.',
    ]),
    HelpArticle('How do I clear my watch history?', [
      'Settings → Watch history → Clear all. The videos you have watched '
          'stop shaping your For You feed.',
    ]),
  ]),
  HelpTopic('notifications', 'Messages and notifications',
      Icons.notifications_rounded, [
    HelpArticle('How do I choose my notifications?', [
      'Settings → Notifications. Switch each kind on or off: messages, '
          'battles, and news from $_app.',
    ]),
    HelpArticle('What is Pause at night?', [
      'Settings → Notifications → Pause at night. From 10 PM to 8 AM, '
          'battle and app notifications wait until morning. They are not '
          'lost: they arrive at 8 AM.',
      'Messages and calls always reach you, even at night.',
    ]),
    HelpArticle("I'm not getting notifications", [
      'Check that notifications for $_app are allowed in your phone\'s '
          'settings, and that the kind you want is switched on in Settings '
          '→ Notifications.',
      'If Pause at night is on, battle and app notifications wait until '
          '8 AM.',
    ]),
  ]),
  HelpTopic('problems', 'Fixing problems', Icons.build_rounded, [
    HelpArticle("Videos won't load, or keep stopping", [
      'Check your connection: videos start fastest on Wi-Fi. If the app has '
          'not been used for a while, the server can take a few seconds to '
          'wake up. Pull down on the feed to refresh.',
    ]),
    HelpArticle('The app takes up a lot of space', [
      'Settings → Free up space shows what $_app keeps on your phone, such '
          'as saved videos, leftover copies and your recent posts, and lets '
          'you clear them.',
    ]),
    HelpArticle('The app uses a lot of battery', [
      'Playing video takes power. $_app pauses every video you are not '
          'watching, but long sessions on mobile data still use noticeable '
          'battery. Wi-Fi helps a lot.',
    ]),
    HelpArticle('How do I report a bug?', [
      'Settings → Report a problem. Choose what it is about, tell us what '
          'happened, and send. It helps to say which screen you were on.',
    ]),
  ]),
];

/// The questions people ask most, shown first.
const _popular = [
  ('account', 0),
  ('battles', 0),
  ('account', 1),
  ('privacy', 0),
];

HelpTopic _topic(String id) => helpTopics.firstWhere((t) => t.id == id);

class HelpCenterPage extends StatefulWidget {
  const HelpCenterPage({super.key});

  @override
  State<HelpCenterPage> createState() => _HelpCenterPageState();
}

class _HelpCenterPageState extends State<HelpCenterPage>
    with PageTracker<HelpCenterPage> {
  @override
  String get pageName => 'help_center_page';

  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _words => _search.text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final words = _words;
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Help Center'),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            _HelpSearch(
              controller: _search,
              onChanged: (_) => setState(() {}),
            ),
            if (words.isEmpty) ...[
              _SectionLabel('Popular questions'),
              SettingsGroup(
                children: [
                  for (final (id, i) in _popular)
                    _ArticleRow(
                      topic: _topic(id),
                      article: _topic(id).articles[i],
                    ),
                ],
              ),
              _SectionLabel('Browse topics'),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.space16, vertical: 4),
                child: GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.45,
                  children: [
                    for (final t in helpTopics) _TopicCard(topic: t),
                  ],
                ),
              ),
            ] else
              ..._results(words),
            const SizedBox(height: 12),
            const _StillNeedHelp(),
          ],
        ),
      ),
    );
  }

  List<Widget> _results(List<String> words) {
    final found = [
      for (final t in helpTopics)
        for (final a in t.articles)
          if (a.matches(words)) (t, a),
    ];
    if (found.isEmpty) {
      return [
        Padding(
          key: const ValueKey('help_no_results'),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
          child: Column(
            children: [
              Icon(Icons.search_off_rounded,
                  size: 44, color: settingsMuted(context)),
              const SizedBox(height: 10),
              Text(
                'No answers for "${_search.text.trim()}"',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Try other words, or tell us what you need below.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: settingsMuted(context)),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      _SectionLabel(
          '${found.length} ${found.length == 1 ? 'answer' : 'answers'}'),
      SettingsGroup(
        children: [
          for (final (t, a) in found)
            _ArticleRow(topic: t, article: a, showTopic: true),
        ],
      ),
    ];
  }
}

/// The blue banner with the search box.
class _HelpSearch extends StatelessWidget {
  const _HelpSearch({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, AppTheme.space8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: FlexMark.tileColors,
            stops: [0, 0.5, 1],
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primary.withValues(alpha: 0.26),
              blurRadius: 28,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'How can we help?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Search for an answer, or pick a topic below.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('help_search'),
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Color(0xFF111114), fontSize: 15.5),
              cursorColor: AppTheme.primary,
              decoration: InputDecoration(
                hintText: 'Search help',
                hintStyle: const TextStyle(color: Color(0xFF8E8E93)),
                prefixIcon:
                    const Icon(Icons.search_rounded, color: Color(0xFF8E8E93)),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('help_search_clear'),
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded,
                            color: Color(0xFF8E8E93)),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A topic on the Help Center's grid.
class _TopicCard extends StatelessWidget {
  const _TopicCard({required this.topic});

  final HelpTopic topic;

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return DecoratedBox(
      decoration: settingsCard(context),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('help_topic_${topic.id}'),
          onTap: () => _push(context, _HelpTopicPage(topic: topic)),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsIcon(topic.icon, AppTheme.primary),
                const Spacer(),
                Text(
                  topic.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14.5,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${topic.articles.length} answers',
                  style: TextStyle(fontSize: 12.5, color: muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A question that opens its answer.
class _ArticleRow extends StatelessWidget {
  const _ArticleRow({
    required this.topic,
    required this.article,
    this.showTopic = false,
  });

  final HelpTopic topic;
  final HelpArticle article;
  final bool showTopic;

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      key: ValueKey('help_article_${article.question}'),
      icon: Icons.help_rounded,
      color: AppTheme.primary,
      title: article.question,
      subtitle: showTopic ? topic.title : null,
      onTap: () =>
          _push(context, _HelpArticlePage(topic: topic, article: article)),
    );
  }
}

/// Every answer in one topic.
class _HelpTopicPage extends StatelessWidget {
  const _HelpTopicPage({required this.topic});

  final HelpTopic topic;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: Text(topic.title),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        key: ValueKey('help_topic_page_${topic.id}'),
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsGroup(
            children: [
              for (final a in topic.articles)
                _ArticleRow(topic: topic, article: a),
            ],
          ),
          const SizedBox(height: 8),
          const _StillNeedHelp(),
        ],
      ),
    );
  }
}

/// One answer, with the others in its topic under it.
class _HelpArticlePage extends StatelessWidget {
  const _HelpArticlePage({required this.topic, required this.article});

  final HelpTopic topic;
  final HelpArticle article;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final body = TextStyle(
      fontSize: 15.5,
      height: 1.55,
      color: cs.onSurface.withValues(alpha: 0.9),
    );
    final others = topic.articles.where((a) => a != article).toList();
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: Text(topic.title),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        key: const ValueKey('help_article_page'),
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppTheme.space16, AppTheme.space8, AppTheme.space16, 8),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: settingsCard(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Pill(text: topic.title),
                  const SizedBox(height: 12),
                  Text(
                    article.question,
                    style: const TextStyle(
                      fontSize: 22,
                      height: 1.2,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 14),
                  for (final p in article.answer)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: p.startsWith('• ')
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  margin:
                                      const EdgeInsets.only(top: 9, right: 12),
                                  decoration: const BoxDecoration(
                                    color: AppTheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                Expanded(
                                    child: Text(p.substring(2), style: body)),
                              ],
                            )
                          : Text(p, style: body),
                    ),
                ],
              ),
            ),
          ),
          if (others.isNotEmpty) ...[
            _SectionLabel('More about ${topic.title.toLowerCase()}'),
            SettingsGroup(
              children: [
                for (final a in others) _ArticleRow(topic: topic, article: a),
              ],
            ),
          ],
          const SizedBox(height: 8),
          const _StillNeedHelp(),
        ],
      ),
    );
  }
}

/// "Still need help?": report a problem, or write to us.
class _StillNeedHelp extends StatelessWidget {
  const _StillNeedHelp();

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, 0),
      child: Container(
        key: const ValueKey('help_contact'),
        padding: const EdgeInsets.all(16),
        decoration: settingsCard(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                _GradientTile(icon: Icons.support_agent_rounded, size: 40),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Still need help?',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Tell us what happened and we will look into it. We read every '
              'message.',
              style: TextStyle(fontSize: 13.5, height: 1.4, color: muted),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('help_report'),
                    onPressed: () => _push(context, const BugReportPage()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.flag_rounded, size: 18),
                    label: const Text('Report a problem'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('help_email'),
                    onPressed: () => _copy(context, _support, 'Email address'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.primary,
                      minimumSize: const Size.fromHeight(46),
                      side: BorderSide(
                          color: AppTheme.primary.withValues(alpha: 0.6)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.mail_rounded, size: 18),
                    label: const Text('Email us'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                _support,
                style: TextStyle(fontSize: 12.5, color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// ABOUT
// ═════════════════════════════════════════════════════════════════════════

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> with PageTracker<AboutPage> {
  @override
  String get pageName => 'about_page';

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('About ${AppConstants.appName}'),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SizedBox(height: 18),
          const Center(child: FlexLogo(size: 96)),
          const SizedBox(height: 18),
          const Text(
            AppConstants.appName,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Short video battles',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: muted),
          ),
          const SizedBox(height: 10),
          const Center(
            child: _Pill(
              key: ValueKey('about_version'),
              text: 'Version ${AppConstants.appVersion}',
            ),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.space16, vertical: AppTheme.space8),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: settingsCard(context),
              child: Text(
                '${AppConstants.appName} is where you show what you can do. '
                'Post a challenge, answer someone else\'s, and let people '
                'vote for the better video. Win battles to climb from Bronze '
                'to Ace.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.88),
                ),
              ),
            ),
          ),
          SettingsGroup(
            children: [
              SettingsTile(
                key: const ValueKey('about_policies'),
                icon: Icons.gavel_rounded,
                color: AppTheme.primary,
                title: 'Terms and policies',
                onTap: () => _push(context, const TermsAndPoliciesPage()),
              ),
              SettingsTile(
                key: const ValueKey('about_help'),
                icon: Icons.support_agent_rounded,
                color: AppTheme.primary,
                title: 'Help Center',
                onTap: () => _push(context, const HelpCenterPage()),
              ),
              SettingsTile(
                key: const ValueKey('about_licences'),
                icon: Icons.code_rounded,
                color: AppTheme.primary,
                title: 'Open-source licences',
                onTap: () => showFlexLicences(context),
              ),
              SettingsTile(
                key: const ValueKey('about_contact'),
                icon: Icons.mail_rounded,
                color: AppTheme.primary,
                title: 'Contact us',
                value: 'Copy',
                subtitle: _support,
                onTap: () => _copy(context, _support, 'Email address'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            '© ${DateTime.now().year} ${AppConstants.appName}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: muted),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// REPORT A PROBLEM
// ═════════════════════════════════════════════════════════════════════════

/// What a problem report can be about. The first part of each is what
/// reaches the reports, so they can be sorted by it.
const bugTopics = [
  ('playback', 'Videos and playback', Icons.play_circle_rounded),
  ('battles', 'Battles and votes', Icons.emoji_events_rounded),
  ('posting', 'Posting', Icons.videocam_rounded),
  ('account', 'Account and sign-in', Icons.person_rounded),
  ('messages', 'Messages and calls', Icons.chat_bubble_rounded),
  ('notifications', 'Notifications', Icons.notifications_rounded),
  ('other', 'Something else', Icons.more_horiz_rounded),
];

/// Report a problem: what it is about, what happened, and which screen.
/// It goes into the app's event stream with the app's version, so reports
/// can be sorted and followed up.
class BugReportPage extends StatefulWidget {
  const BugReportPage({super.key});

  @override
  State<BugReportPage> createState() => _BugReportPageState();
}

class _BugReportPageState extends State<BugReportPage>
    with PageTracker<BugReportPage> {
  @override
  String get pageName => 'bug_report_page';

  final _desc = TextEditingController();
  final _screen = TextEditingController();
  String? _topic;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _desc.dispose();
    _screen.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final user = Provider.of<DataProvider>(context, listen: false).user;
    final desc = _desc.text.trim();
    if (_topic == null) {
      setState(() => _error = 'Choose what the problem is about.');
      return;
    }
    if (desc.isEmpty) {
      setState(() => _error = 'Tell us what happened.');
      return;
    }
    if (user == null) {
      setState(() => _error = 'Sign in to send a report.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    final screen = _screen.text.trim();
    final ok = await ApiService.reportBug(
      userId: user.id,
      description: desc,
      surface: _topic!,
      extra: {
        'appVersion': AppConstants.appVersion,
        if (screen.isNotEmpty) 'screen': screen,
      },
    );
    if (!mounted) return;
    setState(() => _submitting = false);
    if (!ok) {
      setState(() => _error =
          "Couldn't send your report. Check your connection and try again.");
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('Thanks. We got your report.'),
    ));
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final muted = settingsMuted(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    InputDecoration field(String label, {String? hint}) => InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: dark ? const Color(0x990B1A2E) : Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
                color: dark ? const Color(0x2664D2FF) : const Color(0xFFE5EAF2)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
                color: dark ? const Color(0x2664D2FF) : const Color(0xFFE5EAF2)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppTheme.primary, width: 1.6),
          ),
        );
    return Scaffold(
      backgroundColor: settingsBackground(context),
      appBar: AppBar(
        title: const Text('Report a problem'),
        backgroundColor: settingsBarColor(context),
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.space16, AppTheme.space8, AppTheme.space16, 40),
        children: [
          const _Hero(
            icon: Icons.flag_rounded,
            title: 'Something not working?',
            text: 'Tell us what went wrong. We read every report, and it '
                'helps us fix things for everyone.',
            padded: false,
          ),
          const SizedBox(height: 18),
          Text(
            "WHAT'S IT ABOUT?",
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
              color: muted,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (id, label, icon) in bugTopics)
                ChoiceChip(
                  key: ValueKey('bug_topic_$id'),
                  avatar: Icon(icon,
                      size: 18,
                      color: _topic == id ? Colors.white : AppTheme.primary),
                  label: Text(label),
                  selected: _topic == id,
                  showCheckmark: false,
                  selectedColor: AppTheme.primary,
                  backgroundColor:
                      dark ? const Color(0x990B1A2E) : Colors.white,
                  side: BorderSide(
                    color: _topic == id
                        ? AppTheme.primary
                        : (dark
                            ? const Color(0x2664D2FF)
                            : const Color(0xFFE5EAF2)),
                  ),
                  labelStyle: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: _topic == id ? Colors.white : null,
                  ),
                  onSelected: _submitting
                      ? null
                      : (_) => setState(() {
                            _topic = id;
                            _error = null;
                          }),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('bug_description'),
            controller: _desc,
            enabled: !_submitting,
            minLines: 5,
            maxLines: 10,
            maxLength: 1000,
            inputFormatters: [LengthLimitingTextInputFormatter(1000)],
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: field('What happened?',
                hint: 'What you did, what you expected, and what happened '
                    'instead'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('bug_screen'),
            controller: _screen,
            enabled: !_submitting,
            decoration: field('Which screen? (optional)',
                hint: 'For example: the feed, editing your profile'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(
              _error!,
              key: const ValueKey('bug_error'),
              style: const TextStyle(color: AppTheme.error, fontSize: 13.5),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              key: const ValueKey('bug_send'),
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                textStyle:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              icon: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Colors.white),
                    )
                  : const Icon(Icons.send_rounded, size: 20),
              label: const Text('Send report'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your report includes your username and the app version '
            '(${AppConstants.appVersion}), so we can look into it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, height: 1.35, color: muted),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// SMALL SHARED PIECES
// ═════════════════════════════════════════════════════════════════════════

/// An icon on a blue tile, like the app's own icon.
class _GradientTile extends StatelessWidget {
  const _GradientTile({required this.icon, this.size = 44});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3DA5FF), Color(0xFF0050D0)],
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.28),
            blurRadius: 14,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: size * 0.52),
    );
  }
}

/// A small rounded label.
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

/// A card's small heading: a blue icon and a few words.
class _CardHeading extends StatelessWidget {
  const _CardHeading({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.primary),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

/// A heading between groups.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 2),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: settingsMuted(context),
        ),
      ),
    );
  }
}

/// The card at the top of a support page: an icon, a title and a line.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.icon,
    required this.title,
    required this.text,
    this.padded = true,
  });

  final IconData icon;
  final String title;
  final String text;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: settingsCard(context),
      child: Row(
        children: [
          _GradientTile(icon: icon, size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: settingsMuted(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!padded) return card;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.space16, AppTheme.space8, AppTheme.space16, AppTheme.space8),
      child: card,
    );
  }
}
