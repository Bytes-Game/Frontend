// The phone's own log, always, in the same file.
//
// ═══════════════════════════════════════════════════════════════════════
// WHY THIS IS NOT A FLAG ANY MORE
// ═══════════════════════════════════════════════════════════════════════
//
// "flutter run" only prints for as long as it stays attached to the app it
// launched. A run arrived with 297 lines in it, ending in the middle of the
// first video's decoder starting, followed by "Application finished." — the
// app stopped being followed about two seconds in, and everything done
// after that happened on a phone nothing was listening to. The session was
// lost, and nobody knew until the file was opened.
//
// adb logcat records the PHONE, not one app process, so it keeps going
// through the app being killed, restarted, or reopened from the home
// screen. That was added as an opt-in switch — and a switch nobody
// remembers to pass is the same as not having it.
//
// So it is on by default, and folded into the main log at the end, because
// being asked for two files is its own way of losing one.
//
// These are source checks: they cover how Windows PowerShell 5.1 behaves,
// which cannot run here. test/phone_log_tools_test.dart RUNS the scripts
// with PowerShell 7. Every property below is one that silently produces a
// BROKEN OR MISSING LOG rather than an error — which is the class of fault
// this whole file exists to stop.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The lines that are commands, not comments. A check that can be satisfied
/// by the comment explaining a trap checks nothing.
List<String> _commands(String src) => src
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .toList();

void main() {
  final src = File('tools/run_profile.ps1').readAsStringSync();
  final shared = File('tools/phone_log.ps1').readAsStringSync();

  group('the phone is recorded without being asked', () {
    test('the switch turns it OFF, it does not turn it on', () {
      expect(src, contains(r'[switch]$NoLogcat'),
          reason: 'back to opt-in, which means off for anyone who does not '
              'already know it exists');
      expect(src, isNot(contains(r'[switch]$Logcat')));
    });

    test('and the default is on', () {
      expect(src, contains(r'$wantLogcat = -not $NoLogcat'));
    });

    test('a phone with no adb says so rather than failing silently', () {
      expect(src, contains('adb was not found'),
          reason: 'the recording is skipped and the run looks normal, so '
              'the gap is only discovered afterwards');
    });
  });

  group('one file, every line, straight in', () {
    test('the last of what adb wrote is in before the log closes', () {
      // Stopping adb does not mean its last lines have been read. The
      // recorder waits for them, and only then is the log closed.
      final stop = src.indexOf(r'$phone.Stop()');
      final close = src.indexOf(r'$log.Dispose()');
      expect(stop, greaterThan(-1));
      expect(close, greaterThan(stop),
          reason: 'the log closes first, and the end of the run is lost');
      expect(r'$log.Dispose()'.allMatches(src), hasLength(1),
          reason: 'closed once, after the phone has stopped');
      expect(shared, contains('reader.Join('),
          reason: 'Stop waits for the reader to finish');
    });

    test('the whole file is written in UTF-8, by one writer', () {
      // On Windows PowerShell 5.1, Tee-Object writes UTF-16 (two bytes a
      // letter) and Add-Content writes ASCII. The first doubled the size
      // of a log that was already too big to send; mixing the two garbled
      // it. Any of these cmdlets touching the log brings one of those back.
      const cmdlets = ['Tee-Object', 'Add-Content', 'Out-File', 'Set-Content'];
      for (final line in [..._commands(src), ..._commands(shared)]) {
        for (final cmdlet in cmdlets) {
          expect(line, isNot(contains(cmdlet)),
              reason: '$cmdlet writes UTF-16 or ASCII on 5.1: $line');
        }
      }
      expect(shared,
          contains('new StreamWriter(path, append, new UTF8Encoding(true))'));
    });

    test("the phone's lines go straight into the log: no copy anywhere", () {
      // "i don't want any copy, just paste whole logs in logs.txt
      // directly". adb used to write a file of its own - beside the log,
      // then in the temp folder - that was folded in afterwards.
      expect(src, isNot(contains('RedirectStandardOutput')),
          reason: 'adb writing a file of its own');
      expect(src, isNot(contains(r'$deviceLog')));
      expect(
          _commands(src).where((l) =>
              l.contains(r'[BattleArena.PhoneRecorder]::Start($adb, $log)')),
          hasLength(1),
          reason: 'adb read as it writes, each line into the one log');
    });

    test('a recording that fails says so loudly', () {
      // Silence here means sending a log missing exactly the part that was
      // added to stop logs going missing.
      expect(src, contains('COULD NOT START THE PHONE RECORDING'));
      expect(src, contains('THE PHONE RECORDING STOPPED EARLY'));
      expect(src, contains('COULD NOT LOAD THE LOG TOOLS'));
    });
  });

  group('the "did this run capture anything" check', () {
    test('matches the summary as it is actually written', () {
      // It searched for the literal "[reel] starts=". Those two words
      // stopped being next to each other when the decoder reading was
      // added in front of them, so a 63,000-line log with sixteen
      // summaries in it was reported as having none.
      expect(src, contains(r"-Pattern 'starts=\d+'"));
      expect(src, isNot(contains(r"-SimpleMatch '[reel] starts='")));
    });

    test('and looks once the phone has stopped writing', () {
      // The summary often comes only from the phone, when flutter run
      // stopped following the app. Searched before adb's last lines are
      // in, the run is declared empty.
      final stop = src.indexOf(r'$phone.Stop()');
      final search = src.indexOf(r'Select-String -LiteralPath $searchIn');
      expect(stop, greaterThan(-1));
      expect(search, greaterThan(stop));
    });
  });
}
