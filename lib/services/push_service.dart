import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:myapp/pages/challenge_detail_page.dart';
import 'package:myapp/pages/chat_conversation_page.dart';
import 'package:myapp/services/api_service.dart';

/// Notifications on the phone itself — the ones that show outside the app.
///
/// A new message (or a missed call) is a push: the sender's name and what
/// they said, on the lock screen and in the phone's list, and a tap opens
/// the chat. Messages never go to the app's notifications page.
///
/// What this does:
///   * after sign-in, asks the phone for permission once, gets this phone's
///     address from Google's push service (Firebase) and gives it to our
///     server, which is what lets the server reach this phone at all;
///   * when that address changes, gives the new one;
///   * opens the right screen when a push is tapped — a chat, or the battle
///     a battle push is about — whether the app was open, in the
///     background, or closed;
///   * at sign-out, tells the server to stop sending to this phone.
///
/// A push that arrives while the app is open is left alone: the message is
/// already on screen, live.
///
/// Firebase has to be set up for any of this, with this app's four values
/// passed in at build time (see README "Phone notifications"). Without
/// them the app works as before with no phone notifications, and says so
/// once in its log.
class PushService {
  PushService._();
  static final instance = PushService._();

  /// The phone's push service. Swapped for a stand-in in tests.
  PushPlatform platform = FirebasePushPlatform();

  GlobalKey<NavigatorState>? _navigator;
  String? _token;
  bool _started = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// This phone's push address, once the server has it.
  String? get token => _token;

  /// After sign-in: permission, this phone's address to the server, and
  /// taps open the right screen. Safe to call more than once.
  Future<void> signedIn({required GlobalKey<NavigatorState> navigator}) async {
    _navigator = navigator;
    if (_started) return;
    _started = true;
    if (!await platform.start()) {
      debugPrint('[push] Firebase is not set up, so this phone gets no '
          'notifications outside the app (see README "Phone notifications")');
      return;
    }
    _subs.add(platform.opened.listen(open));
    // A push tapped while the app was closed is what started it.
    final launched = await platform.launchedFrom();
    if (launched != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => open(launched));
    }
    if (!await platform.askPermission()) {
      debugPrint('[push] notifications were not allowed on this phone; '
          'messages will only show inside the app');
      return;
    }
    await _register(await platform.token());
    _subs.add(platform.tokenRefresh.listen(_register));
  }

  Future<void> _register(String? token) async {
    if (token == null || token.isEmpty) {
      debugPrint('[push] the phone gave no push address; no notifications '
          'outside the app this time');
      return;
    }
    final ok = await ApiService.registerPushToken(
      userId: '',
      token: token,
      platform: 'fcm',
    );
    if (ok) {
      _token = token;
    } else {
      debugPrint('[push] the server did not take this phone\'s address; '
          'it will be tried again at the next start');
    }
  }

  /// Before sign-out: the server stops sending this person's messages to
  /// this phone. Must run while still signed in.
  Future<void> signingOut() async {
    final token = _token;
    _token = null;
    _started = false;
    _stopListening();
    if (token != null) await ApiService.unregisterPushToken(token);
  }

  /// A tapped push: open what it is about.
  void open(Map<String, dynamic> data) {
    final outbox = '${data['outboxId'] ?? ''}';
    if (outbox.isNotEmpty && outbox != '0') {
      // ignore: discarded_futures
      ApiService.trackNotificationClicked(outbox);
    }
    final nav = _navigator?.currentState;
    if (nav == null) return;
    final type = data['type'];
    final who = '${data['senderId'] ?? ''}';
    if ((type == 'chat' || type == 'missed_call') && who.isNotEmpty) {
      nav.push(MaterialPageRoute(
        builder: (_) => ChatConversationPage(
          otherUserId: who,
          otherUsername: '${data['senderUsername'] ?? ''}',
        ),
      ));
      return;
    }
    final challenge = RegExp(r'^devf://challenge/(\d+)')
        .firstMatch('${data['deeplink'] ?? ''}')
        ?.group(1);
    if (challenge != null) {
      nav.push(MaterialPageRoute(
        builder: (_) => ChallengeDetailPage(challengeId: challenge),
      ));
    }
  }

  /// Stops at once. Not waited on: nothing depends on the listeners having
  /// finished, and waiting on them is what kept sign-out from finishing.
  void _stopListening() {
    for (final s in _subs) {
      // ignore: discarded_futures
      s.cancel();
    }
    _subs.clear();
  }

  @visibleForTesting
  Future<void> debugReset() async {
    _stopListening();
    _started = false;
    _token = null;
    _navigator = null;
    platform = FirebasePushPlatform();
  }
}

/// The phone's push service, as PushService needs it.
abstract class PushPlatform {
  /// Gets ready. False when push is not set up on this build.
  Future<bool> start();

  /// Asks the person, once. False when they said no.
  Future<bool> askPermission();

  /// This phone's push address.
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// The push that was tapped to start the app, if one was.
  Future<Map<String, dynamic>?> launchedFrom();

  /// Pushes tapped while the app was in the background.
  Stream<Map<String, dynamic>> get opened;
}

/// Google's push service (Firebase Cloud Messaging), for Android and
/// iPhone.
class FirebasePushPlatform implements PushPlatform {
  // This app's Firebase project ("battle-38226"), built in so every build
  // gets phone notifications with no extra steps. These are not secrets:
  // every copy of the app carries them, the way every Android app carries
  // its google-services.json. The secret half (the service-account key)
  // lives only on the server.
  //
  // A different project can still be used for one build:
  // --dart-define-from-file=firebase_push.json (see README).
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY',
      defaultValue: 'AIzaSyBGU-hjM5x0rCzbsFbmVs7QmaV7wqN7R5M');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID',
      defaultValue: '1:966321160135:android:3b2f0cb1df4f13957463e2');
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID',
      defaultValue: '966321160135');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID',
      defaultValue: 'battle-38226');

  /// The values in use, for the check that they belong together.
  @visibleForTesting
  static ({String apiKey, String appId, String senderId, String projectId})
      get debugValues => (
            apiKey: _apiKey,
            appId: _appId,
            senderId: _senderId,
            projectId: _projectId,
          );

  /// Whether this build was given the Firebase values.
  static bool get configured =>
      _apiKey.isNotEmpty && _senderId.isNotEmpty && _projectId.isNotEmpty &&
      (_appId.isNotEmpty || _iosAppId.isNotEmpty);

  @override
  Future<bool> start() async {
    if (!configured || kIsWeb) return false;
    try {
      if (Firebase.apps.isEmpty) {
        final ios = defaultTargetPlatform == TargetPlatform.iOS;
        await Firebase.initializeApp(
          options: FirebaseOptions(
            apiKey: _apiKey,
            appId: ios && _iosAppId.isNotEmpty ? _iosAppId : _appId,
            messagingSenderId: _senderId,
            projectId: _projectId,
          ),
        );
      }
      return true;
    } catch (e) {
      debugPrint('[push] Firebase would not start: $e');
      return false;
    }
  }

  @override
  Future<bool> askPermission() async {
    try {
      final s = await FirebaseMessaging.instance.requestPermission();
      return s.authorizationStatus == AuthorizationStatus.authorized ||
          s.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e) {
      debugPrint('[push] could not ask for notification permission: $e');
      return false;
    }
  }

  @override
  Future<String?> token() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[push] could not get this phone\'s push address: $e');
      return null;
    }
  }

  @override
  Stream<String> get tokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Future<Map<String, dynamic>?> launchedFrom() async {
    try {
      return (await FirebaseMessaging.instance.getInitialMessage())?.data;
    } catch (e) {
      debugPrint('[push] could not read the push that opened the app: $e');
      return null;
    }
  }

  @override
  Stream<Map<String, dynamic>> get opened =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);
}
