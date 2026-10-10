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

  group('folding the two logs together', () {
    test('it waits for adb to finish writing first', () {
      // adb writes through a buffer. Appending a file that is still being
      // written truncates it mid-line.
      final at = src.indexOf('Stop-Process -Id \$logcatProc.Id');
      final sleep = src.indexOf('Start-Sleep -Milliseconds');
      expect(at, greaterThan(-1));
      expect(sleep, greaterThan(at),
          reason: 'the append starts while adb is still flushing, so the '
              'last lines of the run are cut off');
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
      expect(
          _commands(src).where((l) =>
              l.contains('System.IO.StreamWriter') &&
              l.contains('UTF8Encoding')),
          isNotEmpty);
    });

    test('and does not send the phone log through PowerShell line by line',
        () {
      // A phone log is hundreds of thousands of lines - 817,837 in one run.
      // PowerShell 5.1 takes minutes over that, which reads as a hung
      // script. The C# in phone_log.ps1 does the reading.
      final piped = _commands(src)
          .where((l) => l.contains('Get-Content') && l.contains(r'$deviceLog'));
      expect(piped, isEmpty, reason: '$piped');
      expect(
          _commands(src)
              .where((l) => l.contains(r'Add-PhoneLog -PhoneLog $deviceLog')),
          hasLength(1),
          reason: 'the fold is the shared one, which shrinks the log');
    });

    test('the phone is recorded in the temp folder, not beside the log', () {
      // "Make it in logs.txt only, do not create any other file." This
      // used to keep a second copy next to the log, and the copy was the
      // reason a 200 MB log came with a 130 MB friend.
      final at = _commands(src)
          .where((l) => l.startsWith(r'$deviceLog = '))
          .toList();
      expect(at, hasLength(1));
      expect(at.single, contains('GetTempPath()'));
      expect(at.single, isNot(contains(r'$LogFile')));
      expect(
          _commands(src).where(
              (l) => l.startsWith(r'Remove-Item -LiteralPath $deviceLog')),
          hasLength(1),
          reason: 'deleted once its lines are in the log');
    });

    test('a failed shrink says so loudly, and still gets the lines in', () {
      // Silence here means sending a log missing exactly the part that was
      // added to stop logs going missing. test/phone_log_tools_test.dart
      // breaks the shrinking on purpose and checks the lines arrive whole.
      expect(src, contains('COULD NOT SHRINK THE PHONE LOG'));
      expect(
          _commands(src)
              .where((l) => l.startsWith('Add-PhoneLogWhole -PhoneLog')),
          hasLength(1));
      expect(src, contains('COULD NOT COPY IT IN WHOLE EITHER'),
          reason: 'and if that fails too, it says where the lines are');
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

    test('and looks once the phone log is in the file', () {
      // The summary often lands only in the phone's log, when flutter run
      // stopped following the app. Searched before the fold, the run is
      // declared empty.
      final fold = src.indexOf(r'Add-PhoneLog -PhoneLog $deviceLog');
      final search = src.indexOf(r"Select-String -LiteralPath $searchIn");
      expect(fold, greaterThan(-1));
      expect(search, greaterThan(fold));
    });
  });
}
