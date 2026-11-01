import 'package:myapp/config/constants.dart';

/// The words of Flex's Terms of Service, Privacy Policy and Community
/// Guidelines, kept apart from the pages that show them (legal_pages.dart).
///
/// They say what the app and the server really do. When either changes how
/// it handles people's data, change the words here in the same commit, and
/// move [legalUpdated] to that day.

/// The day the documents last changed.
const legalUpdated = '1 November 2026';

/// A numbered part of a document: a heading and its paragraphs. A paragraph
/// that starts with "• " shows as a bullet point.
class LegalSection {
  const LegalSection(this.title, this.body);

  final String title;
  final List<String> body;
}

/// One whole document.
class LegalDocument {
  const LegalDocument({
    required this.title,
    required this.intro,
    required this.summary,
    required this.sections,
    required this.contact,
  });

  final String title;

  /// The opening paragraph, above everything.
  final String intro;

  /// "The short version": the main points in a few lines, at the top.
  final List<String> summary;

  final List<LegalSection> sections;

  /// Where to write about this document.
  final String contact;
}

const _name = AppConstants.appName;
const _support = AppConstants.supportEmail;
const _privacy = AppConstants.privacyEmail;

// ─────────────────────────────────────────────────────────────────────────
// TERMS OF SERVICE
// ─────────────────────────────────────────────────────────────────────────

const termsOfService = LegalDocument(
  title: 'Terms of Service',
  intro: 'These terms are the agreement between you and $_name ("$_name", '
      '"we", "us") for using the $_name app, its website pages and its '
      'services (together, the "Service"). Please read them. By creating an '
      'account or using the Service, you agree to them.',
  summary: [
    'You must be at least 13 to use $_name.',
    'You own what you post. You let us show it on $_name so the Service '
        'can work.',
    'Play fair: no fake accounts, no bought votes, likes or followers.',
    'Follow our Community Guidelines. We may remove content or accounts '
        'that break them.',
    'You can delete your account at any time. It is gone for good after '
        '30 days.',
  ],
  contact: _support,
  sections: [
    LegalSection('Who can use $_name', [
      'You must be at least 13 years old to create an account. If you are '
          'under the age of adulthood where you live, you need a parent or '
          'guardian to agree to these terms with you.',
      'You must give your real date of birth and an email address you use. '
          'We use your date of birth only to check your age, and we never '
          'show it or your email to anyone.',
      'You cannot use $_name if you have been banned from it before, or if '
          'the law where you live does not allow it.',
    ]),
    LegalSection('Your account', [
      'One account per person per email address. Your username is public, '
          'and you can change it once every 30 days. When you change it, '
          'your old one becomes free for anyone to take.',
      'You can sign in with your username or email and a password, or with '
          'Google or Apple. Keep your password to yourself, use a strong one '
          'that you do not use anywhere else, and turn on two-step '
          'verification in Settings.',
      'You are responsible for what happens on your account. If you think '
          'someone else has got into it, change your password straight '
          'away (this signs out every other phone) and tell us at '
          '$_support.',
      'If you forget your password, you can reset it with a code we email '
          'to the address on your account.',
    ]),
    LegalSection('Battles, votes and leagues', [
      '$_name is built around battles. Anyone can post a challenge, and '
          'others answer it with their own video. Viewers vote for the one '
          'they think is better.',
      'Wins, losses and draws move your rating points, which place you in '
          'a league. The rules for points, leagues and who you can battle '
          'are in the Help Center, and we may adjust them to keep battles '
          'fair.',
      'A video that has nothing to do with its challenge can be reported. '
          'If our check or enough viewers agree, its owner loses rating '
          'points.',
      'Rating points, leagues and votes have no money value. They cannot be '
          'bought, sold, traded or exchanged for anything.',
    ]),
    LegalSection('Play fair', [
      'Do not try to win by anything other than your videos. In '
          'particular, do not:',
      '• make fake or extra accounts, or use someone else\'s;',
      '• buy, sell, swap or ask for votes, likes, views, shares or '
          'followers;',
      '• use bots, scripts or automated tools on $_name;',
      '• report videos falsely to make someone lose points.',
      'Votes and engagement that look bought or automated do not count, '
          'and accounts that do this lose rating points or are suspended.',
    ]),
    LegalSection('Your content', [
      'You keep ownership of everything you post: videos, photos, captions, '
          'comments and messages.',
      'When you post, you give $_name a worldwide, non-exclusive, '
          'royalty-free licence to host, store, copy, show and share that '
          'content, and to make versions of it that play well on different '
          'phones and connections. We use this licence only to run, '
          'improve and promote the Service. It ends when you delete the '
          'content, except where someone has already shared it, where we '
          'must keep it by law, or for copies that take a short time to '
          'clear from backups.',
      'Public content can be seen by anyone, inside the app and on '
          '$_name\'s web pages for shared profiles and videos. A private '
          'account\'s videos are shown only to its followers.',
      'You must have the rights to everything you post. Do not post '
          'other people\'s work, music or images unless you are allowed '
          'to.',
    ]),
    LegalSection('Music in the app', [
      'Songs in $_name\'s music library come from artists who let anyone '
          'use them for free, under licences such as Creative Commons. '
          'When a licence asks for the artist to be credited, $_name adds '
          'the credit to your post. Do not remove it.',
    ]),
    LegalSection('Rules for content and behaviour', [
      'Everything on $_name must follow our Community Guidelines, which are '
          'part of these terms. In short: no illegal content, no '
          'harassment or hate, nothing sexual involving anyone, no '
          'dangerous challenges, and respect for other people\'s privacy '
          'and rights.',
      'We may remove content, limit features, or suspend or end accounts '
          'that break these terms or the Guidelines, or that put people at '
          'risk. Where we can, we tell you why.',
    ]),
    LegalSection('Using the Service properly', [
      'Do not interfere with how $_name works. That means no hacking, no '
          'getting around limits or security, no collecting other people\'s '
          'data, no copying the Service, and no overloading it.',
      'We limit how often some things can be done (signing in, asking for '
          'codes, changing a username) to keep accounts safe.',
    ]),
    LegalSection('Deleting your account', [
      'You can delete your account at any time in Settings. It is hidden '
          'from everyone straight away and signed out on every phone. '
          'Battles you are in at that moment end with no result.',
      'For 30 days, signing in again lets you keep it, with everything '
          'back. After 30 days it is deleted for good: your profile, posts, '
          'battles, comments, likes, votes and followers.',
      'We may suspend or end an account that seriously or repeatedly '
          'breaks these terms, or when the law requires it.',
    ]),
    LegalSection('Changes to $_name and to these terms', [
      'We keep improving $_name, so features may change, and some may be '
          'removed.',
      'We may update these terms. If a change matters, we will tell you in '
          'the app before it takes effect. If you keep using $_name after '
          'that, the new terms apply.',
    ]),
    LegalSection('Disclaimers', [
      'We work hard to keep $_name running well, but it is provided "as '
          'is". We cannot promise it will always be available, free of '
          'mistakes, or that content on it is accurate. Content is the '
          'responsibility of the person who posted it, not of $_name.',
    ]),
    LegalSection('Limits on our responsibility', [
      'As far as the law allows, $_name is not responsible for indirect '
          'losses, lost data or lost profits that come from using the '
          'Service, or from content or behaviour of other people on it.',
      'Nothing in these terms takes away rights you have by law that '
          'cannot be taken away by an agreement.',
    ]),
    LegalSection('Contact', [
      'Questions about these terms: $_support.',
    ]),
  ],
);

// ─────────────────────────────────────────────────────────────────────────
// PRIVACY POLICY
// ─────────────────────────────────────────────────────────────────────────

const privacyPolicy = LegalDocument(
  title: 'Privacy Policy',
  intro: 'This policy explains what information $_name collects when you '
      'use the app and its website pages, why, who it is shared with, and '
      'the choices you have. We collect only what the Service needs.',
  summary: [
    'We never sell your information, and we do not show ads.',
    'Your email and date of birth are private. Nobody else sees them.',
    'We use what you watch to pick videos for you. You can clear your '
        'watch history any time.',
    'Passwords and reset codes are stored scrambled, never as typed.',
    'Delete your account and everything in it is gone after 30 days.',
  ],
  contact: _privacy,
  sections: [
    LegalSection('Information you give us', [
      '• Account details: your username, your name if you add one, your '
          'email address, your date of birth and your password. Your '
          'password is stored scrambled, so not even we can read it.',
      '• Profile: your photo, bio and other details you choose to add.',
      '• Content: videos and photos you post, captions, tags, challenge '
          'answers, comments, likes, votes and saves.',
      '• Messages and calls: the messages you send, and the fact that a '
          'call happened, so a missed call can be shown. Calls themselves '
          'are not recorded.',
      '• Reports and feedback: what you tell us when you report a video or '
          'a problem.',
      '• Interests: the kinds of videos you pick when you join.',
      '• Google or Apple: if you sign in with one of them, the name and '
          'email address they share with us, and the id they give your '
          'account. We never see your Google or Apple password.',
    ]),
    LegalSection('Information collected as you use $_name', [
      '• Activity: which videos you watch and for how long, what you tap, '
          'like, share and vote for, and who you follow and block.',
      '• Device and connection: what kind of video your phone can play '
          'smoothly, the app version, and your IP address.',
      '• Notifications: a token from your phone that lets us send you '
          'notifications.',
      '• Crash reports: when the app crashes or something fails, a report '
          'of what went wrong, with your phone\'s model and system version, '
          'so we can fix it.',
      '• Camera, microphone and photos: used only when you record, call, or '
          'pick something to post. We receive only what you choose to post '
          'or send.',
      'We do not collect your phone number, your contacts or your '
          'location.',
    ]),
    LegalSection('How we use it', [
      '• To run $_name: your account, profile, posts, battles, votes, '
          'leagues, messages and calls.',
      '• To pick videos for you: your For You feed is chosen from what you '
          'and people like you watch and enjoy.',
      '• To keep $_name safe and fair: checking reports, spotting fake '
          'votes and spam, limiting sign-in attempts, and protecting '
          'accounts.',
      '• To talk to you: notifications you have switched on, and emails '
          'about your account, such as a password reset code.',
      '• To fix and improve the app: crash reports and usage numbers show '
          'us what breaks and what works.',
    ]),
    LegalSection('What other people can see', [
      'Your username, name, photo and bio are public. So are your videos '
          'and battles, unless your account is private: then only your '
          'followers see them.',
      'Public profiles and videos can also be opened from shared links on '
          '$_name\'s web pages.',
      'Your email address, date of birth, password, watch history and the '
          'accounts you have blocked are never shown to anyone.',
      'If your activity status is on, people you chat with can see when '
          'you are online. You can turn it off in Settings → Privacy.',
    ]),
    LegalSection('Who we share it with', [
      'We never sell your information and do not share it for advertising.',
      'We use a few trusted companies to run the Service. They act on our '
          'instructions and only get what they need:',
      '• Render, which hosts our servers and database;',
      '• Cloudflare, which stores and delivers videos and photos;',
      '• Google Firebase, to deliver notifications to your phone;',
      '• Sentry, to receive crash reports;',
      '• an email service, to send password reset codes;',
      '• Google or Apple, only if you choose to sign in with them.',
      'We may also share information when the law requires it, to protect '
          'someone\'s safety, or as part of a sale or merger of $_name, in '
          'which case this policy would continue to protect it.',
    ]),
    LegalSection('How long we keep it', [
      '• Detailed watch activity: about 30 days. After that it is folded '
          'into a summary of what you like, and the detail is deleted.',
      '• Your content: until you delete it, or delete your account.',
      '• Password reset codes: 15 minutes, or until used.',
      '• Your account: until you delete it. It is then hidden at once and '
          'deleted for good, with everything in it, after 30 days.',
      'Some records may be kept longer where the law requires it, or to '
          'deal with abuse.',
    ]),
    LegalSection('Your choices and rights', [
      'In the app you can: edit your profile; make your account private; '
          'choose who can message and call you; hide your activity status; '
          'block people; delete posts; clear your watch history; choose '
          'your notifications; change your password; turn on two-step '
          'verification; and delete your account.',
      'Depending on where you live, you may also have the right to see a '
          'copy of your information, correct it, have it deleted, take it '
          'with you, or object to how we use it. Write to $_privacy and we '
          'will answer. You can also complain to your local data '
          'protection authority.',
    ]),
    LegalSection('Keeping it safe', [
      'Connections to $_name are encrypted. Passwords and reset codes are '
          'stored scrambled, and changing your password signs out every '
          'other phone. Two-step verification adds a code from an '
          'authenticator app to signing in. We limit how often anyone can '
          'try to sign in or ask for a code. No system is perfect, but we '
          'work to protect your information.',
    ]),
    LegalSection('Children', [
      '$_name is not for children under 13, and we do not knowingly collect '
          'their information. If we learn that someone under 13 has an '
          'account, we delete it. If you think a child is using $_name, '
          'tell us at $_privacy.',
    ]),
    LegalSection('Information across borders', [
      'The companies that help run $_name may store and process '
          'information in other countries. When they do, we make sure it '
          'stays protected as this policy describes.',
    ]),
    LegalSection('Changes to this policy', [
      'If we change this policy in a way that matters, we will tell you in '
          'the app before the change takes effect.',
    ]),
    LegalSection('Contact', [
      'Privacy questions and requests: $_privacy.',
    ]),
  ],
);

// ─────────────────────────────────────────────────────────────────────────
// COMMUNITY GUIDELINES
// ─────────────────────────────────────────────────────────────────────────

const communityGuidelines = LegalDocument(
  title: 'Community Guidelines',
  intro: '$_name is a place to show what you can do and to take on '
      'challenges, safely and fairly. These guidelines apply to everyone '
      'and everything on $_name: videos, photos, captions, comments, '
      'messages and profiles.',
  summary: [
    'Be creative, be competitive, be kind.',
    'Never post a challenge that could hurt someone.',
    'No harassment, hate, or sexual content.',
    'Win with your videos, not with fake votes.',
    'Report what breaks these rules. We review it.',
  ],
  contact: _support,
  sections: [
    LegalSection('Safe challenges', [
      'Challenges are the heart of $_name, so they must never put anyone at '
          'risk. Do not post or encourage challenges that could cause '
          'injury, such as stunts that risk serious harm, misuse of '
          'medicine or substances, holding your breath, fire, or dangerous '
          'driving.',
      'If a challenge looks dangerous, do not answer it. Report it.',
    ]),
    LegalSection('Respect for people', [
      'No bullying or harassment: no threats, insults, humiliation, or '
          'piling on someone.',
      'No hate: nothing that attacks people for their race, ethnicity, '
          'nationality, religion, caste, sexual orientation, sex, gender, '
          'gender identity, disability or serious illness.',
      'Disagree and compete as hard as you like, but never make it '
          'personal.',
    ]),
    LegalSection('Safety and wellbeing', [
      'No violent extremism, threats of violence, or content that praises '
          'violence.',
      'No content that encourages suicide, self-harm or eating disorders. '
          'If you or someone you know is struggling, please reach out to a '
          'local helpline or emergency service.',
      'No graphic violence or gore.',
    ]),
    LegalSection('Young people', [
      'Accounts are for people 13 and over. Anything that sexualises, '
          'endangers or exploits young people is never allowed, is removed, '
          'and is reported to the authorities.',
    ]),
    LegalSection('Nudity and sexual content', [
      'No nudity, sexual activity or sexually explicit content, and no '
          'content offering or asking for sexual services.',
    ]),
    LegalSection('Fair play and honesty', [
      'Win with your videos. No fake accounts, bought or swapped votes, '
          'likes or followers, bots, or false reports.',
      'Answer a challenge with a video that matches it. A video that has '
          'nothing to do with its challenge costs its owner rating points.',
      'Do not pretend to be another person or organisation, and do not '
          'spread false information that could cause harm.',
      'No spam or scams.',
    ]),
    LegalSection('Privacy', [
      'Do not share other people\'s private information, such as their '
          'address, phone number, documents or private messages, and do '
          'not film people in private places without their consent.',
    ]),
    LegalSection('Illegal and regulated things', [
      'No content that sells or promotes illegal drugs, weapons, or other '
          'illegal goods and services, or that shows crimes being '
          'committed.',
    ]),
    LegalSection('Other people\'s work', [
      'Post only what you made, or have permission to use. Use the free '
          'songs in $_name\'s music library rather than music you do not '
          'have the rights to.',
    ]),
    LegalSection('What happens when rules are broken', [
      'Depending on how serious it is, we may remove the content, take '
          'rating points, limit features, or suspend or ban the account. '
          'Serious harm can lead to a ban the first time.',
      'If you think we got it wrong, write to $_support and we will look '
          'again.',
    ]),
    LegalSection('Reporting', [
      'On a video, tap More (⋯) and choose "Doesn\'t match the challenge". '
          'To stop someone reaching you, block them from their profile.',
      'For anything else that breaks these rules, use Settings → Report a '
          'problem, or write to $_support.',
    ]),
  ],
);
