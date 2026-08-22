import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:myapp/services/device_capabilities.dart';

/// Tells us when a video refuses to play on a real phone.
///
/// ## Why this exists
///
/// A video that fails to open is invisible to us today. The feed already
/// handles it gracefully — it swaps to the backup copy and carries on, which
/// is right for the person holding the phone — but it means the failure leaves
/// no trace anywhere we can see. If someone's phone cannot decode a video
/// another user uploaded, we find out never.
///
/// That gap matters most for exactly the phones we cannot test on. A cheap
/// phone can only decode so much at once, and how much is a property of the
/// chip rather than of memory. The backend now measures uploads and keeps
/// oversized video away from weaker devices, but that protection is only as
/// good as our knowledge of where the line actually is. This is how we find
/// out we drew it in the wrong place.
///
/// ## What it deliberately does not send
///
/// No user id, no account details, no watch history. What goes up is the shape
/// of the failure: the kind of video file, the phone's memory tier, and the
/// error the player gave. Enough to spot "every 2 GB phone fails on this kind
/// of file", which is the question, and nothing that identifies a person.
///
/// ## Why it counts itself
///
/// A feed of broken videos would otherwise fire this on every swipe. The free
/// Sentry tier allows about 5,000 events a month, so one bad batch of uploads
/// could spend the whole budget in an afternoon and leave us blind for the
/// rest of it. After [_maxReportsPerSession] the reporter goes quiet and says
/// so once, which keeps the signal and drops the flood.
class PlaybackReporter {
  PlaybackReporter._();
  static final PlaybackReporter instance = PlaybackReporter._();

  /// Ceiling per app run. Sized so a genuinely broken feed still tells us
  /// there is a problem — the first few reports carry that news — without any
  /// single session being able to spend a meaningful slice of the monthly
  /// allowance.
  static const int _maxReportsPerSession = 10;

  int _sent = 0;
  bool _announcedCap = false;

  /// The cap, for tests that need to assert it holds without hardcoding a
  /// number that would then have to be changed in two places.
  @visibleForTesting
  static int get maxReportsPerSessionForTest => _maxReportsPerSession;

  /// The two pure describers, exposed so what we send can be checked directly
  /// — the privacy rule (host yes, path no) is worth a test of its own.
  @visibleForTesting
  static String describeSourceForTest(String url) => _describeSource(url);

  @visibleForTesting
  static String describeHostForTest(String url) => _describeHost(url);

  /// How many reports this run has sent. Exposed for tests, which need to
  /// check the cap holds without reaching into Sentry.
  @visibleForTesting
  int get sentCount => _sent;

  /// Forget everything sent so far. Tests only — a real session's budget is
  /// meant to be spent once.
  @visibleForTesting
  void resetForTest() {
    _sent = 0;
    _announcedCap = false;
  }

  /// Report that a video would not play.
  ///
  /// [videoUrl] is used only to work out what KIND of file it was and which
  /// host served it. The full address is not sent — see [_describeSource].
  ///
  /// [error] is whatever the player said, which is usually the most useful
  /// part: a decoder that ran out of hardware says something quite different
  /// from a file that could not be downloaded.
  ///
  /// [recovered] says whether the app had a backup copy to fall back to. A
  /// failure the user never noticed is still worth knowing about, but it is a
  /// much smaller problem than one that left them looking at a black screen.
  void reportPlaybackFailure({
    required String videoUrl,
    String? error,
    bool recovered = false,
  }) {
    if (_sent >= _maxReportsPerSession) {
      if (!_announcedCap) {
        _announcedCap = true;
        debugPrint(
          'PlaybackReporter: $_maxReportsPerSession failures reported this '
          'session — staying quiet from here so one bad feed cannot spend the '
          'whole monthly error budget.',
        );
      }
      return;
    }
    _sent++;

    final caps = DeviceCapabilities.instance;
    // ignore: discarded_futures
    Sentry.captureMessage(
      'Video failed to play',
      level: recovered ? SentryLevel.warning : SentryLevel.error,
      withScope: (scope) {
        scope.setTag('playback.source', _describeSource(videoUrl));
        scope.setTag('playback.recovered', recovered.toString());
        // The two numbers that decide whether a phone can cope. Tagged rather
        // than buried in the body so failures can be grouped by device tier,
        // which is the whole question this is here to answer.
        scope.setTag('device.ramGb', caps.ramGb.toStringAsFixed(1));
        scope.setTag('device.maxVideoSide', caps.maxVideoLongSide.toString());
        scope.setContexts('playback', <String, dynamic>{
          'source': _describeSource(videoUrl),
          'host': _describeHost(videoUrl),
          'error': error ?? 'unknown',
          'recovered': recovered,
          'ramGb': caps.ramGb,
          'maxVideoSide': caps.maxVideoLongSide,
        });
      },
    );
  }

  /// "hls" or "mp4" — which playback path failed. The distinction matters:
  /// adaptive streaming and a plain file fail for different reasons and get
  /// fixed in different places.
  static String _describeSource(String url) {
    if (url.contains('.m3u8')) return 'hls';
    if (url.contains('127.0.0.1') || url.contains('localhost')) return 'proxy';
    return 'mp4';
  }

  /// Just the host, never the path.
  ///
  /// The host tells us which storage or CDN was involved, which is a real
  /// question when failures cluster. The path identifies a specific person's
  /// specific upload, which is not our business and is not needed to fix
  /// anything.
  static String _describeHost(String url) {
    final host = Uri.tryParse(url)?.host;
    return (host == null || host.isEmpty) ? 'unknown' : host;
  }
}
