import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:myapp/config/constants.dart';

/// Signing in with Google or Apple, as far as the phone goes: the phone's
/// own "Continue with Google" or "Sign in with Apple" sheet, which ends with
/// a signed token saying who the person is. The server checks the token
/// (ApiService.signInWithProvider); nothing here is trusted on its own.
enum SocialProvider {
  google('google', 'Google'),
  apple('apple', 'Apple');

  const SocialProvider(this.id, this.label);

  /// How the server names it: /auth/google, /auth/apple.
  final String id;

  /// How people name it.
  final String label;
}

/// What the phone's sign-in sheet gave back.
class SocialCredential {
  const SocialCredential({required this.idToken, this.fullName});

  /// The signed "this is me" token, for the server to check.
  final String idToken;

  /// The person's name, when the sheet said it. Apple says it once, the
  /// first time, and never to the server, so it is passed on.
  final String? fullName;
}

/// The sheet opened but did not finish, for a reason worth telling.
class SocialAuthFailure implements Exception {
  const SocialAuthFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The phone's sign-in sheets. A test puts a stand-in in [instance].
abstract class SocialAuth {
  static SocialAuth instance = PlatformSocialAuth();

  /// Whether [provider] can be offered on this phone, with this build's
  /// settings (see AppConstants).
  bool offers(SocialProvider provider);

  /// Opens [provider]'s sheet. Null when the person closed it.
  Future<SocialCredential?> signIn(SocialProvider provider);
}

/// The real sheets: the google_sign_in and sign_in_with_apple plugins.
class PlatformSocialAuth implements SocialAuth {
  bool _googleReady = false;

  @override
  bool offers(SocialProvider provider) =>
      !kIsWeb &&
      offersOn(
        defaultTargetPlatform,
        provider,
        googleServerClientId: AppConstants.googleServerClientId,
        googleIosClientId: AppConstants.googleIosClientId,
        appleOnIos: AppConstants.appleSignInOnIos,
        appleServiceId: AppConstants.appleServiceId,
      );

  /// [offers], for any phone and any build settings (see the before-release
  /// list in CLAUDE.md for where each comes from).
  @visibleForTesting
  static bool offersOn(
    TargetPlatform platform,
    SocialProvider provider, {
    required String googleServerClientId,
    required String googleIosClientId,
    required bool appleOnIos,
    required String appleServiceId,
  }) {
    final android = platform == TargetPlatform.android;
    final iPhone = platform == TargetPlatform.iOS;
    switch (provider) {
      case SocialProvider.google:
        // The token must be made for the server's id (the "Web" one), and
        // the iPhone also needs its own.
        return googleServerClientId.isNotEmpty &&
            (android || (iPhone && googleIosClientId.isNotEmpty));
      case SocialProvider.apple:
        // The iPhone's own sheet; on Android, Apple's web page, which needs
        // the Services ID.
        return (iPhone && appleOnIos) ||
            (android && appleServiceId.isNotEmpty);
    }
  }

  @override
  Future<SocialCredential?> signIn(SocialProvider provider) =>
      switch (provider) {
        SocialProvider.google => _google(),
        SocialProvider.apple => _apple(),
      };

  Future<SocialCredential?> _google() async {
    final google = GoogleSignIn.instance;
    try {
      if (!_googleReady) {
        await google.initialize(
          clientId: defaultTargetPlatform == TargetPlatform.iOS
              ? AppConstants.googleIosClientId
              : null,
          serverClientId: AppConstants.googleServerClientId,
        );
        _googleReady = true;
      }
      final account = await google.authenticate(scopeHint: const ['email']);
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        debugPrint('[signin] Google signed in, but gave no token to check');
        throw const SocialAuthFailure(
            "Google didn't say who you are. Please try again.");
      }
      return SocialCredential(idToken: token, fullName: account.displayName);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return null;
      }
      debugPrint('[signin] Google sign-in did not finish: ${e.code} '
          '${e.description ?? ''}');
      throw const SocialAuthFailure(
          "Couldn't sign in with Google. Please try again.");
    } on SocialAuthFailure {
      rethrow;
    } catch (e) {
      // Anything else (a plugin error, a setting missing on the phone):
      // said, and in the log, rather than a button that spins for ever.
      debugPrint('[signin] Google sign-in failed: $e');
      throw const SocialAuthFailure(
          "Couldn't sign in with Google. Please try again.");
    }
  }

  Future<SocialCredential?> _apple() async {
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        // On Android, Apple's sign-in is a web page, which hands back to the
        // app through the server (AppleCallbackHandler on the server).
        webAuthenticationOptions: defaultTargetPlatform == TargetPlatform.android
            ? WebAuthenticationOptions(
                clientId: AppConstants.appleServiceId,
                redirectUri:
                    Uri.parse('${AppConstants.apiBaseUrl}/auth/apple/callback'),
              )
            : null,
      );
      final token = credential.identityToken;
      if (token == null || token.isEmpty) {
        debugPrint('[signin] Apple signed in, but gave no token to check');
        throw const SocialAuthFailure(
            "Apple didn't say who you are. Please try again.");
      }
      final name = [credential.givenName, credential.familyName]
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .join(' ');
      return SocialCredential(
          idToken: token, fullName: name.isEmpty ? null : name);
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      debugPrint('[signin] Apple sign-in did not finish: ${e.code} ${e.message}');
      throw const SocialAuthFailure(
          "Couldn't sign in with Apple. Please try again.");
    } on SignInWithAppleException catch (e) {
      debugPrint('[signin] Apple sign-in did not open: $e');
      throw const SocialAuthFailure(
          "Couldn't sign in with Apple. Please try again.");
    } on SocialAuthFailure {
      rethrow;
    } catch (e) {
      debugPrint('[signin] Apple sign-in failed: $e');
      throw const SocialAuthFailure(
          "Couldn't sign in with Apple. Please try again.");
    }
  }
}
