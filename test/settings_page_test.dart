// Settings and privacy: every row opens what it says, and the Privacy page
// saves each choice to the server the way the server reads it.
//
// Each test checks something that IS there — the page that opened, the
// request that was sent — not only what is gone.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:myapp/models/user_model.dart';
import 'package:myapp/pages/blocked_users_page.dart';
import 'package:myapp/pages/free_up_space_page.dart';
import 'package:myapp/pages/notification_settings_page.dart';
import 'package:myapp/pages/preferences_pages.dart';
import 'package:myapp/pages/privacy_page.dart';
import 'package:myapp/pages/profile_page.dart';
import 'package:myapp/pages/settings_page.dart';
import 'package:myapp/pages/static_content_pages.dart';
import 'package:myapp/pages/two_factor_setup_page.dart';
import 'package:myapp/pages/watch_history_page.dart';
import 'package:myapp/providers/auth_provider.dart';
import 'package:myapp/providers/data_provider.dart';
import 'package:myapp/providers/theme_provider.dart';
import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/event_tracker.dart';

/// Profile changes the app sent, and whether the server takes them.
List<Map<String, dynamic>> patches = [];
bool refuse = false;

/// Notification settings as the server keeps them, and the saves sent.
Map<String, dynamic>? serverPrefs;
List<Map<String, dynamic>> prefSaves = [];

void fakeServer() {
  patches = [];
  refuse = false;
  prefSaves = [];
  serverPrefs = {
    'userId': '1',
    'messages': true,
    'friendResponse': true,
    'endingSoon': true,
    'youWillLove': false,
    'inactiveWinback': true,
    'quietHoursStart': 22,
    'quietHoursEnd': 8,
    'maxPerDay': 4,
  };
  ApiService.useClient(MockClient((req) async {
    if (req.url.path.endsWith('/notifications/prefs')) {
      if (req.method == 'POST') {
        prefSaves.add(json.decode(req.body) as Map<String, dynamic>);
        return refuse
            ? http.Response('down', 500)
            : http.Response('{"status":"ok"}', 200);
      }
      final p = serverPrefs;
      return p == null
          ? http.Response('down', 503)
          : http.Response(json.encode(p), 200);
    }
    if (req.method == 'PATCH' && req.url.path.endsWith('/users/1')) {
      final body = json.decode(req.body) as Map<String, dynamic>;
      patches.add(body);
      if (refuse) return http.Response('down', 500);
      return http.Response('{"updated":true}', 200);
    }
    if (req.url.path.endsWith('/history')) {
      return http.Response('{"items":[],"hasMore":false}', 200);
    }
    if (req.url.path.endsWith('/blocks')) return http.Response('[]', 200);
    return http.Response('{}', 200);
  }));
}

UserModel me({String visibility = 'public', Map<String, dynamic>? settings}) =>
    UserModel(
      id: '1',
      username: 'maya',
      fullName: 'Maya K',
      wins: 0,
      losses: 0,
      followersCount: 0,
      followingCount: 0,
      visibility: visibility,
      settings: settings ?? const {'theme': 'dark'},
    );

Future<DataProvider> pump(WidgetTester t, Widget page, {UserModel? user}) async {
  final dp = DataProvider()..setUser(user ?? me());
  EventTracker.instance.dispose();
  await t.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: dp),
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
    ],
    child: MaterialApp(home: page),
  ));
  await t.pump();
  return dp;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(fakeServer);
  tearDown(() => ApiService.useClient(http.Client()));

  group('Settings', () {
    late List<String> asked;
    SettingsPage page() => SettingsPage(
          onEditProfile: () => asked.add('edit'),
          onShareProfile: () => asked.add('share'),
          onSaved: () => asked.add('saved'),
          onLiked: () => asked.add('liked'),
        );
    setUp(() => asked = []);

    final opens = <String, Type>{
      'settings_history': WatchHistoryPage,
      'settings_privacy': PrivacyPage,
      'settings_2fa': TwoFactorSetupPage,
      'settings_notifications': NotificationSettingsPage,
      'settings_appearance': AppearancePage,
      'settings_space': FreeUpSpacePage,
      'settings_help': HelpCenterPage,
      'settings_bug': BugReportPage,
      'settings_terms': TermsOfServicePage,
      'settings_policy': PrivacyPolicyPage,
      'settings_about': AboutPage,
    };
    for (final e in opens.entries) {
      testWidgets('${e.key} opens ${e.value}', (t) async {
        await pump(t, page());
        await t.ensureVisible(find.byKey(ValueKey(e.key)));
        await t.tap(find.byKey(ValueKey(e.key)));
        await settle(t);
        expect(find.byType(e.value), findsOneWidget);
      });
    }

    testWidgets('your card edits your profile; saved, liked and share go '
        'back to the profile', (t) async {
      await pump(t, page());
      expect(find.text('Maya K'), findsOneWidget);
      for (final k in [
        'settings_account',
        'settings_saved',
        'settings_liked',
        'settings_share',
      ]) {
        await t.ensureVisible(find.byKey(ValueKey(k)));
        await t.tap(find.byKey(ValueKey(k)));
        await t.pump();
      }
      expect(asked, ['edit', 'saved', 'liked', 'share']);
    });

    testWidgets('the rows that did nothing are gone', (t) async {
      await pump(t, page());
      expect(find.text('Login activity'), findsNothing);
      expect(find.text('Personal information'), findsNothing);
      expect(find.text('Language'), findsNothing);
      expect(find.textContaining('coming', findRichText: true), findsNothing);
      // And the ones that work are there.
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.text('Public'), findsOneWidget, reason: 'privacy summed up');
      expect(find.text('Dark'), findsOneWidget, reason: 'theme summed up');
    });

    testWidgets('log out asks first', (t) async {
      await pump(t, page());
      await t.ensureVisible(find.byKey(const ValueKey('settings_logout')));
      await t.tap(find.byKey(const ValueKey('settings_logout')));
      await settle(t);
      expect(find.text('Log out of @maya?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await settle(t);
      expect(find.byType(SettingsPage), findsOneWidget);
    });
  });

  group('Privacy', () {
    testWidgets('shows the current choices', (t) async {
      await pump(t, const PrivacyPage(),
          user: me(visibility: 'friends', settings: {
            'messages': 'following',
            'showActivity': false,
          }));
      Switch sw(String key) => t.widget<Switch>(find.descendant(
          of: find.byKey(ValueKey(key)), matching: find.byType(Switch)));
      expect(sw('privacy_private').value, isTrue);
      expect(sw('privacy_activity').value, isFalse);
      expect(
        t.widget<AnimatedOpacity>(find.descendant(
            of: find.byKey(const ValueKey('privacy_messages_following')),
            matching: find.byType(AnimatedOpacity))).opacity,
        1,
      );
    });

    testWidgets('private account: saved as the visibility the server reads',
        (t) async {
      final dp = await pump(t, const PrivacyPage());
      await t.tap(find.byKey(const ValueKey('privacy_private')));
      await settle(t);
      expect(patches.single['visibility'], 'friends');
      expect(dp.user!.visibility, 'friends');
      expect(find.textContaining('Only your followers'), findsOneWidget);
      // Saving refreshes the signed-in user, which restarts the app's
      // analytics timer; stop it so the test ends clean.
      EventTracker.instance.dispose();
    });

    testWidgets('messages from people you follow only: saved, other settings '
        'kept', (t) async {
      final dp = await pump(t, const PrivacyPage());
      await t.tap(find.byKey(const ValueKey('privacy_messages_following')));
      await settle(t);
      expect(patches.single['settings'], {'theme': 'dark', 'messages': 'following'});
      expect(dp.user!.settings['messages'], 'following');
      // Saving refreshes the signed-in user, which restarts the app's
      // analytics timer; stop it so the test ends clean.
      EventTracker.instance.dispose();
    });

    testWidgets('activity status off: saved', (t) async {
      final dp = await pump(t, const PrivacyPage());
      await t.tap(find.byKey(const ValueKey('privacy_activity')));
      await settle(t);
      expect(patches.single['settings']['showActivity'], false);
      expect(dp.user!.settings['showActivity'], false);
      expect(find.textContaining('Nobody sees'), findsOneWidget);
      // Saving refreshes the signed-in user, which restarts the app's
      // analytics timer; stop it so the test ends clean.
      EventTracker.instance.dispose();
    });

    testWidgets('the server says no: it flips back and says so', (t) async {
      final dp = await pump(t, const PrivacyPage());
      refuse = true;
      await t.tap(find.byKey(const ValueKey('privacy_activity')));
      await settle(t);
      final sw = t.widget<Switch>(find.descendant(
          of: find.byKey(const ValueKey('privacy_activity')),
          matching: find.byType(Switch)));
      expect(sw.value, isTrue);
      expect(find.text("Couldn't save that. Try again."), findsOneWidget);
      expect(dp.user!.settings['showActivity'], isNull);
    });

    testWidgets('blocked accounts opens the list', (t) async {
      await pump(t, const PrivacyPage());
      await t.tap(find.byKey(const ValueKey('privacy_blocked')));
      await settle(t);
      expect(find.byType(BlockedUsersPage), findsOneWidget);
    });
  });

  group('Notifications', () {
    bool on(WidgetTester t, String key) => t
        .widget<Switch>(find.descendant(
            of: find.byKey(ValueKey(key)), matching: find.byType(Switch)))
        .value;

    testWidgets("shows the server's settings, by the server's names",
        (t) async {
      await pump(t, const NotificationSettingsPage());
      await settle(t);
      expect(on(t, 'notif_messages'), isTrue);
      expect(on(t, 'notif_youWillLove'), isFalse);
      expect(on(t, 'notif_quiet'), isTrue);
      // The switches the server never had are gone.
      expect(find.text('Likes'), findsNothing);
      expect(find.text('Mentions'), findsNothing);
    });

    testWidgets('a flip saves only that switch', (t) async {
      await pump(t, const NotificationSettingsPage());
      await settle(t);
      await t.tap(find.byKey(const ValueKey('notif_endingSoon')));
      await settle(t);
      expect(prefSaves, [
        {'endingSoon': false},
      ]);
      expect(on(t, 'notif_endingSoon'), isFalse);
      await t.tap(find.byKey(const ValueKey('notif_messages')));
      await settle(t);
      expect(prefSaves.last, {'messages': false});
    });

    testWidgets('pause at night off clears the quiet hours', (t) async {
      await pump(t, const NotificationSettingsPage());
      await settle(t);
      await t.tap(find.byKey(const ValueKey('notif_quiet')));
      await settle(t);
      expect(prefSaves.single, {'quietHoursStart': 0, 'quietHoursEnd': 0});
      expect(on(t, 'notif_quiet'), isFalse);
      expect(find.text('Notifications arrive at any hour.'), findsOneWidget);
    });

    testWidgets('the server says no: it flips back and says so', (t) async {
      await pump(t, const NotificationSettingsPage());
      await settle(t);
      refuse = true;
      await t.tap(find.byKey(const ValueKey('notif_friendResponse')));
      await settle(t);
      expect(on(t, 'notif_friendResponse'), isTrue);
      expect(find.text("Couldn't save that. Try again."), findsOneWidget);
    });

    testWidgets("couldn't load: says so, with a retry", (t) async {
      serverPrefs = null;
      await pump(t, const NotificationSettingsPage());
      await settle(t);
      expect(find.text("Couldn't load your notification settings"),
          findsOneWidget);
      expect(find.byKey(const ValueKey('notif_messages')), findsNothing);
    });
  });

  group('From the profile', () {
    testWidgets('the settings button opens Settings; Saved comes back to the '
        'Saved tab', (t) async {
      final user = me();
      await pump(t, ProfilePage(user: user, isEmbedded: false), user: user);
      await settle(t);
      await t.tap(find.byTooltip('Settings'));
      await settle(t);
      expect(find.byType(SettingsPage), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('settings_saved')));
      await settle(t);
      expect(find.byType(SettingsPage), findsNothing);
      final tabs = t.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(tabs.index, 6, reason: 'on the Saved tab');
      EventTracker.instance.dispose();
    });
  });
}
