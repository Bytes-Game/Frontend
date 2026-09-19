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
// These are source checks. The script is PowerShell on Windows and cannot
// be run from here, but every property below is one that silently produces
// a BROKEN OR MISSING LOG rather than an error — which is the class of
// fault this whole file exists to stop.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('tools/run_profile.ps1').readAsStringSync();

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

    test('it writes in the SAME encoding the rest of the file uses', () {
      // THE ONE THAT BIT ON THE FIRST ATTEMPT. Tee-Object writes UTF-16 on
      // Windows PowerShell 5.1 and Add-Content defaults to ASCII. Mixing
      // them in one file produces a garbled log — a warning that is
      // already written at the top of this very script.
      // Real commands only. A first version of this matched the COMMENT
      // that explains the trap, and failed on correct code — a check that
      // cries wolf gets deleted, and then the trap is unguarded.
      final commands = src
          .split('\n')
          .map((l) => l.trim())
          .where((l) => !l.startsWith('#'))
          .where((l) => l.contains('Add-Content'));
      expect(commands, isNotEmpty);
      for (final line in commands) {
        expect(line, contains('-Encoding Unicode'),
            reason: 'an Add-Content without an encoding writes ASCII into '
                'a UTF-16 file: \$line');
      }
    });

    test('and does not send the lines through one at a time', () {
      // A phone log is hundreds of thousands of lines. One at a time
      // through the pipeline takes minutes, which reads as a hung script.
      // Real command, not the comment that explains it — the same way the
      // encoding check above had to be tightened. A source test that can
      // be satisfied by its own documentation checks nothing.
      final reading = src
          .split('\n')
          .map((l) => l.trim())
          .where((l) => !l.startsWith('#'))
          .where((l) => l.contains('Get-Content') && l.contains(r'$deviceLog'))
          .toList();
      expect(reading, isNotEmpty);
      expect(reading.any((l) => l.contains('-ReadCount')), isTrue,
          reason: 'the phone log is piped a line at a time, which on a '
              'file this size reads as a hung script: \$reading');
    });

    test('the separate copy is kept, not deleted', () {
      // If the append fails, the phone's log has to still exist on its own
      // rather than be lost inside a half-written merge.
      expect(src, isNot(contains(r'Remove-Item -LiteralPath $deviceLog')));
      expect(src, contains('also kept on its own'));
    });

    test('a failed fold says so loudly', () {
      // Silence here means sending a log missing exactly the part that was
      // added to stop logs going missing.
      expect(src, contains('COULD NOT FOLD THE PHONE LOG IN'));
      expect(src, contains('Send BOTH files'),
          reason: 'it fails and gives no way to recover the run');
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

    test('and looks in the phone log too', () {
      expect(src, contains(r'$searchIn += $deviceLog'),
          reason: 'the run is declared empty because the summary landed in '
              'the phone log rather than the flutter one');
    });
  });
}
