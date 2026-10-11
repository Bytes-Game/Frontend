import 'package:myapp/config/constants.dart';

/// The links the app hands out when something is shared, and its QR codes
/// hold. Each opens a real page — a person, or one video — that the server
/// draws for anybody, signed in or not (public_pages.go).
///
/// They used to point at a website that did not exist (a profile) or at the
/// raw video file (a video): a tap on the first was an error page, and the
/// second was a bare file with nothing about who made it.
class ShareLinks {
  ShareLinks._();

  static String profile(String username) =>
      '${AppConstants.shareBaseUrl}/u/${Uri.encodeComponent(username)}';

  static String video(String challengeId) =>
      '${AppConstants.shareBaseUrl}/v/${Uri.encodeComponent(challengeId)}';
}
