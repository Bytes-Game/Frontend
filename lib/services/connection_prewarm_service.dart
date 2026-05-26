import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Pre-warms the DNS + TLS connection to the video-storage origin (and
/// optionally the API origin) at app launch, so the first reel the user
/// taps doesn't have to pay the cold-connection tax.
///
/// What this saves, in concrete terms:
///   * DNS lookup for the R2 / CDN hostname — 50-150ms cold, ~0 once
///     cached by the OS resolver.
///   * TLS handshake (cert exchange + key exchange) — 2-3 round trips,
///     which on cellular is 200-600ms before the first byte of any
///     video can flow.
///
/// Once the OS-level connection pool has a hot socket to the origin,
/// every subsequent video URL the player opens reuses that socket
/// (HTTP/1.1 keep-alive or HTTP/2 multiplexing) — no fresh handshake.
///
/// We deliberately keep this fire-and-forget: failures here are not
/// user-visible (worst case the first reel pays the cold cost it would
/// have paid anyway). We DO log so a misconfigured origin is visible in
/// debug builds without surfacing as a crash.
class ConnectionPrewarmService {
  ConnectionPrewarmService._();
  static final ConnectionPrewarmService instance = ConnectionPrewarmService._();

  /// Hostnames to prewarm. Populate from env / build config at startup
  /// — these are the origins whose first request you want to be fast.
  ///
  /// Default list covers the two origins every user touches in the
  /// first 2 seconds of an authenticated session:
  ///   * The backend API (catalog, feed, auth).
  ///   * The R2 public origin (every video + thumbnail).
  ///
  /// Add a CDN custom-domain hostname here once it's wired (e.g.
  /// media.devf.com) — the R2 default hostname becomes a fallback.
  static const List<String> _defaultOrigins = [
    'https://gobackend-9nd8.onrender.com',
    // R2 public origins — both shapes (pub-<account>.r2.dev AND any
    // custom domain) should be added by the caller via [start]. The
    // empty default is intentional: hard-coding an account-ID here
    // would be a secret-in-repo smell.
  ];

  bool _started = false;

  /// Idempotent. Call once from main() after MediaKit.ensureInitialized.
  /// Pass additional origins (R2 hostname, CDN custom domain) on top of
  /// the built-in API origin.
  Future<void> start({List<String> extraOrigins = const []}) async {
    if (_started) return;
    _started = true;

    final origins = <String>[..._defaultOrigins, ...extraOrigins]
        .where((o) => o.isNotEmpty)
        .toSet() // dedupe — caller may pass the same host the default list has
        .toList();

    // Fire all prewarms in parallel — they share no state and the only
    // resource they consume is one socket each, which the OS pool will
    // happily hold open for the keep-alive window (~30-60s on Android,
    // ~75s on iOS).
    await Future.wait(
      origins.map(_prewarmOne),
      eagerError: false, // one bad host shouldn't block the others
    );
  }

  Future<void> _prewarmOne(String origin) async {
    try {
      // HEAD is the minimum-body request shape. We don't care about the
      // response — we just want the OS to do the DNS lookup, TLS
      // handshake, and keep the resulting socket in its pool. Tight
      // timeout because if the host is down we shouldn't hang app boot.
      final client = http.Client();
      try {
        final req = http.Request('HEAD', Uri.parse(origin));
        await client.send(req).timeout(const Duration(seconds: 3));
      } finally {
        // Close releases our reference but the underlying socket pool
        // entry is kept warm by the platform until keep-alive expiry.
        client.close();
      }
    } catch (e) {
      // Log only in debug — a prewarm failure is a perf miss, not a
      // bug. Common causes: airplane mode at boot, DNS server unreachable
      // (captive portal), origin returning 5xx (still warms the connection).
      if (kDebugMode) debugPrint('prewarm failed for $origin: $e');
    }
  }
}
