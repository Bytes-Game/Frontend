import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which won battles have already had their moment on this phone.
///
/// The win moment (WinMoment) plays once per battle. Kept in memory alone
/// it would play again every time the app was opened afresh and the person
/// looked at an old win. So the list is written down, and read back the
/// first time it is needed.
///
/// Best effort, like everything kept on the phone: if it cannot be read or
/// written, the list lives in memory for this run, and nothing breaks.
class CelebratedWins {
  CelebratedWins._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _key = 'celebrated_wins_v1';

  /// How many are remembered. The oldest go first.
  static const int kept = 200;

  /// Oldest first. Null until read.
  static List<String>? _ids;
  static Future<void>? _reading;

  /// Marks the battle [battleId] as celebrated. True when it had not been:
  /// the moment should play now. False every time after.
  static Future<bool> firstTime(String battleId) async {
    if (battleId.isEmpty) return false;
    await (_reading ??= _read());
    final ids = _ids ??= [];
    if (ids.contains(battleId)) return false;
    ids.add(battleId);
    if (ids.length > kept) ids.removeRange(0, ids.length - kept);
    try {
      await _storage.write(key: _key, value: json.encode(ids));
    } catch (e) {
      debugPrint(
        '[win] could not write down that battle $battleId was '
        'celebrated; it may play again after the app is closed: $e',
      );
    }
    return true;
  }

  static Future<void> _read() async {
    try {
      final raw = await _storage.read(key: _key);
      final list = raw == null ? const [] : json.decode(raw);
      _ids = [
        if (list is List)
          for (final id in list)
            if (id is String && id.isNotEmpty) id,
      ];
    } catch (e) {
      debugPrint(
        '[win] could not read which wins were celebrated; '
        'starting from none: $e',
      );
      _ids = [];
    }
  }

  /// Forgets what is in memory, as closing the app does. With [stored],
  /// what is written down too. For tests.
  @visibleForTesting
  static Future<void> resetForTest({bool stored = false}) async {
    _ids = null;
    _reading = null;
    if (!stored) return;
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Nothing written down to forget.
    }
  }
}
