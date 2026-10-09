// The run log, made small enough to open and to send - checked by RUNNING
// the scripts, not by reading them.
//
// WHY. A run recorded 817,837 lines from the phone. tools\run_profile
// copied every one into F:\logs.txt, two bytes a letter, and printed "Full
// log saved" without looking. The file came to a couple of hundred
// megabytes: too big to open comfortably, far too big to attach. The person
// running it opened it, found nothing they could use, and said "logs not
// saved". The run had the freeze in it; nobody could get at it.
//
// Now the phone's repeats are counted instead of copied, the file is
// UTF-8, and what is reported as saved is read back from the disk.
//
// These run the real scripts with PowerShell 7 (pwsh), which every GitHub
// runner has. Windows PowerShell 5.1 - what the scripts meet on the
// developer's PC - cannot run here, so the one way it differs that matters
// (it compiles the C# with the old C# 5 compiler) is checked by compiling
// under C# 5 rules. Without pwsh these skip locally and FAIL on CI: a check
// that quietly stops running looks exactly like one that passes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _app = 27066;
const _appAgain = 28100; // the app, after it was killed and opened again
const _system = 1800;
const _surface = 4321;

/// One line the way `adb logcat -v time` writes it.
String _line(int ms, String level, String tag, int pid, String msg) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = 23, m = 10 + ms ~/ 60000, s = ms ~/ 1000 % 60, f = ms % 1000;
  return '10-09 ${two(h)}:${two(m)}:${two(s)}.${f.toString().padLeft(3, '0')} '
      '$level/${tag.padRight(8)}(${pid.toString().padLeft(5)}): $msg';
}

/// A phone log with the shapes the real one has: one part of Android
/// repeating itself thousands of times, the app's own decoder chatter, the
/// app's messages (some not plain ASCII), an app not responding, the app
/// dying and coming back, and lines in no logcat shape at all.
List<String> _phoneLog() {
  final out = <String>['--------- beginning of main'];
  var ms = 0;
  var flutter = 0;
  for (var i = 0; i < 3000; i++) {
    ms += 7;
    out.add(
      _line(
        ms,
        'W',
        'BLASTBufferQueue',
        _surface,
        "[SurfaceView#${i % 9}] Can't acquire next buffer. Already acquired max frames ${i % 5}",
      ),
    );
    if (i % 10 == 0) {
      out.add(
        _line(
          ms,
          'D',
          'CCodec',
          _app,
          '[c2.mtk.avc.decoder#${i % 700}] elapsed n=${i % 9}',
        ),
      );
    }
    if (i % 120 == 0) {
      out.add(_line(ms, 'I', 'Other', 900, 'same thing again ${i % 7}'));
    }
    // Another app crashing over and over: more than the 20 a repeat from
    // elsewhere keeps, so only "crashes are always kept" keeps them all.
    if (i % 100 == 0) {
      out.add(
        _line(ms, 'E', 'AndroidRuntime', 5000 + i, 'FATAL EXCEPTION: main'),
      );
    }
    if (i % 60 == 0 && flutter < 40) {
      flutter++;
      out.add(
        _line(
          ms,
          'I',
          'flutter',
          _app,
          '[reel] feed forYou page $flutter: café ✓ starts=$flutter',
        ),
      );
    }
  }
  ms += 10;
  out.addAll([
    _line(ms, 'I', 'flutter', _app, '[editor] leaving the editor'),
    _line(
      ms + 1,
      'I',
      'flutter',
      _app,
      '[editor] closing: letting go of the video and the song',
    ),
    _line(
      ms + 2,
      'I',
      'flutter',
      _app,
      '[editor] closing: the editor let go after 1ms',
    ),
    _line(
      ms + 9000,
      'E',
      'ActivityManager',
      _system,
      'ANR in com.example.devf (com.example.devf/.MainActivity)',
    ),
    _line(ms + 9000, 'E', 'ActivityManager', _system, 'PID: $_app'),
    _line(
      ms + 9000,
      'E',
      'ActivityManager',
      _system,
      'Reason: Input dispatching timed out (Waiting to send key event)',
    ),
    _line(
      ms + 9500,
      'F',
      'libc',
      _app,
      'Fatal signal 6 (SIGABRT), code -1 in tid $_app (1.ui)',
    ),
    '--------- beginning of crash',
    _line(
      ms + 9600,
      'I',
      'ActivityManager',
      _system,
      'Process com.example.devf (pid $_app) has died: fg  TOP',
    ),
    _line(ms + 12000, 'I', 'flutter', _appAgain, '[reel] opened again'),
  ]);
  return out;
}

String? _pwsh() {
  final asked = Platform.environment['PWSH'];
  for (final exe in [?asked, 'pwsh']) {
    try {
      final r = Process.runSync(exe, [
        '-NoProfile',
        '-Command',
        r'$PSVersionTable.PSVersion.Major',
      ]);
      if (r.exitCode == 0) return exe;
    } catch (_) {
      // Not this one; try the next.
    }
  }
  return null;
}

void main() {
  final pwsh = _pwsh();
  final onCi =
      Platform.environment['CI'] == 'true' ||
      Platform.environment['GITHUB_ACTIONS'] == 'true';
  final skip = pwsh == null && !onCi
      ? 'PowerShell 7 (pwsh) is not installed here, or set PWSH to it'
      : null;

  Future<ProcessResult> run(List<String> args, {Map<String, String>? env}) {
    if (pwsh == null) {
      fail(
        'PowerShell 7 (pwsh) is missing on CI. These tests would stop '
        'running without anyone noticing; install it in the workflow.',
      );
    }
    return Process.run(
      pwsh,
      ['-NoProfile', ...args],
      environment: env,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('phone_log_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File writePhoneLog(List<String> lines) {
    // adb writes UTF-8 with no byte-order mark.
    final f = File('${dir.path}/logs.txt.device.txt');
    f.writeAsBytesSync(utf8.encode('${lines.join('\n')}\n'));
    return f;
  }

  /// Lines of [text] that are log lines, not the header, table or footer.
  List<String> logLines(String text) => const LineSplitter()
      .convert(text)
      .where((l) => l.startsWith('10-09 ') || l.startsWith('---------'))
      .toList();

  group('the C# that shrinks the log', () {
    test(
      'compiles under C# 5, the compiler Windows PowerShell 5.1 uses',
      () async {
        final r = await run([
          '-Command',
          r". ./tools/phone_log.ps1; "
              r"Add-Type -TypeDefinition $PhoneLogSource -CompilerOptions '-langversion:5'; "
              r"'compiled'",
        ]);
        expect(
          r.stdout,
          contains('compiled'),
          reason:
              'it uses C# newer than 5, so on the PC it fails to '
              'compile and the phone log is not folded in at all:\n'
              '${r.stdout}\n${r.stderr}',
        );
      },
      skip: skip,
    );

    test('uses nothing outside mscorlib, which is all 5.1 hands it', () {
      // Windows PowerShell's Add-Type does not reference System.Core, so
      // Linq and HashSet are not there. PowerShell 7 references everything,
      // so compiling here cannot catch it - this has to read the source.
      final src = File('tools/phone_log.ps1').readAsStringSync();
      final start = src.indexOf(r"$PhoneLogSource = @'");
      final end = src.indexOf("\n'@", start);
      expect(start, greaterThan(-1));
      expect(end, greaterThan(start));
      final code = src
          .substring(start, end)
          .split('\n')
          .where((l) => !l.trim().startsWith('//'))
          .join('\n');
      for (final missing in [
        'System.Linq',
        'HashSet',
        'Queue<',
        'Stack<',
        'LinkedList',
        'SortedSet',
        'SortedDictionary',
        'Concurrent',
      ]) {
        expect(
          code,
          isNot(contains(missing)),
          reason: '$missing is not in mscorlib on .NET Framework',
        );
      }
      // And it is the C# that does the reading: proves the check above is
      // looking at the right block.
      expect(code, contains('new StreamReader'));
    });
  });

  group('tools/shrink_phone_log', () {
    late List<String> input;
    late String small;
    late ProcessResult r;

    setUp(() async {
      if (skip != null) return;
      input = _phoneLog();
      final phone = writePhoneLog(input);
      final out = '${dir.path}/logs.small.txt';
      r = await run([
        '-File',
        'tools/shrink_phone_log.ps1',
        '-PhoneLog',
        phone.path,
        '-Out',
        out,
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final bytes = File(out).readAsBytesSync();
      expect(bytes.take(3), [
        0xEF,
        0xBB,
        0xBF,
      ], reason: 'UTF-8 with its mark, so Notepad and 5.1 read it right');
      small = utf8.decode(bytes.skip(3).toList());
    });

    test('keeps every line the app printed, in order', () {
      final app = input.where((l) => l.contains('I/flutter ')).toList();
      expect(app, hasLength(44));
      expect(
        logLines(small).where((l) => l.contains('I/flutter ')).toList(),
        app,
      );
      expect(
        small,
        contains('café ✓'),
        reason: 'not plain ASCII, and has to survive the trip',
      );
    }, skip: skip);

    test('keeps the first 20 of a repeat from elsewhere on the phone', () {
      final kept = logLines(
        small,
      ).where((l) => l.contains('W/BLASTBufferQueue('));
      expect(kept, hasLength(20));
      expect(
        logLines(small).where((l) => l.contains('I/Other ')),
        hasLength(20),
        reason: '25 of them, so 5 counted',
      );
    }, skip: skip);

    test("keeps the first 200 of a repeat from the app's own process", () {
      expect(
        logLines(small).where((l) => l.contains('D/CCodec ')),
        hasLength(200),
        reason: "300 decoder lines from the app's process, so 100 counted",
      );
    }, skip: skip);

    test('counts what it leaves out, by kind', () {
      expect(
        small,
        contains('3,000  W/BLASTBufferQueue: [SurfaceView##] '),
        reason: 'the table of what filled the log',
      );
      expect(small, contains('2,980 more  W/BLASTBufferQueue: '));
      expect(small, contains('100 more  D/CCodec: '));
      expect(small, contains('5 more  I/Other: '));
      expect(
        small,
        contains(
          'PHONE LOG (adb logcat): ${_comma(input.length)} lines from the phone.',
        ),
      );
    }, skip: skip);

    test('always keeps crashes, an app not responding, and odd lines', () {
      expect(
        logLines(small).where((l) => l.contains('FATAL EXCEPTION')),
        hasLength(30),
        reason: 'a crash repeated past the limit for repeats',
      );
      for (final keep in [
        'ANR in com.example.devf',
        'Reason: Input dispatching timed out',
        'Fatal signal 6',
        '--------- beginning of crash',
        'Process com.example.devf (pid $_app) has died',
      ]) {
        expect(
          logLines(small).where((l) => l.contains(keep)),
          hasLength(1),
          reason: keep,
        );
      }
    }, skip: skip);

    test('keeps lines in the order they happened', () {
      var at = 0;
      for (final l in logLines(small)) {
        at = input.indexOf(l, at);
        expect(at, greaterThan(-1), reason: 'out of order or changed: $l');
        at++;
      }
    }, skip: skip);

    test('says on screen what it found, without opening the file', () {
      final said = r.stdout as String;
      expect(said, contains('Saved ${dir.path}/logs.small.txt ('));
      expect(said, contains('Attach ${dir.path}/logs.small.txt'));
      expect(
        said,
        contains('it ran 2 times'),
        reason: 'the app died and came back under a new process',
      );

      // Inside their own parts of the report. With few kinds of line, the
      // same lines also make the "most common" list, and a check on the
      // whole screen passed with the not-responding detection switched off.
      final problems = _section(said, 'What the phone said went wrong:');
      expect(problems, contains('ANR in com.example.devf'));
      expect(problems, contains('Reason: Input dispatching timed out'));
      expect(
        problems,
        contains('FATAL EXCEPTION: main  (and 29 more like it)'),
        reason:
            'one line for a crash repeated 30 times, so it cannot push '
            "this app's own lines below off the screen",
      );
      expect(
        problems,
        contains('Process com.example.devf (pid $_app) has died'),
        reason: "picked out by the app's id, read from the Android build",
      );
      expect(
        problems,
        isNot(contains('[reel]')),
        reason: 'only problems, not every line the app printed',
      );

      final editor = _section(said, "The video editor's last steps:");
      expect(editor.split('\n'), [
        '  23:10:21.010  [editor] leaving the editor',
        '  23:10:21.011  [editor] closing: letting go of the video and the song',
        '  23:10:21.012  [editor] closing: the editor let go after 1ms',
      ]);
    }, skip: skip);
  });

  group('tools/run_profile', () {
    // A stand-in flutter and adb, so the whole script runs: the build, the
    // phone's recording, the fold, and the report.
    late Directory bin;
    late List<String> input;

    setUp(() {
      input = _phoneLog();
      bin = Directory('${dir.path}/bin')..createSync();
      final phone = File('${dir.path}/phone.txt')
        ..writeAsBytesSync(utf8.encode('${input.join('\n')}\n'));
      File('${bin.path}/flutter').writeAsStringSync(
        '#!/bin/sh\n'
        'echo "Launching lib/main.dart in profile mode..."\n'
        'echo "a warning on stderr" 1>&2\n'
        'echo "Built app-profile.apk (82.5MB) ✓"\n'
        'echo "I/flutter (27066): [reel] decoders{c2=15} starts=3 proxy=1"\n'
        // Long enough for the phone's whole log to be on disk first.
        'sleep 2\n'
        'echo "Application finished."\n',
      );
      File('${bin.path}/adb').writeAsStringSync(
        '#!/bin/sh\n'
        'if [ "\$2" = "-c" ]; then exit 0; fi\n'
        'cat "${phone.path}"\n'
        'exec sleep 60\n',
      );
      for (final exe in ['flutter', 'adb']) {
        Process.runSync('chmod', ['+x', '${bin.path}/$exe']);
      }
    });

    Future<ProcessResult> runProfile(List<String> extra) => run(
      [
        '-File',
        'tools/run_profile.ps1',
        '-LogFile',
        '${dir.path}/logs.txt',
        ...extra,
      ],
      env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
    );

    final unix = Platform.isWindows ? 'the stand-ins are shell scripts' : null;

    test(
      'one UTF-8 file: the run, then the phone shrunk',
      () async {
        final r = await runProfile([]);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        final bytes = File('${dir.path}/logs.txt').readAsBytesSync();
        expect(bytes.take(3), [
          0xEF,
          0xBB,
          0xBF,
        ], reason: 'Tee-Object on 5.1 wrote UTF-16, twice the size');
        final log = utf8.decode(bytes.skip(3).toList());
        expect(log, contains('flutter run --profile'));
        expect(log, contains('Built app-profile.apk (82.5MB) ✓'));
        expect(log, contains('a warning on stderr'));
        expect(log, contains('Application finished.'));
        expect(
          log,
          contains(
            'PHONE LOG (adb logcat): ${_comma(input.length)} lines from the phone.',
          ),
        );
        expect(log, contains('2,980 more  W/BLASTBufferQueue: '));
        expect(
          log.indexOf('Application finished.'),
          lessThan(log.indexOf('PHONE LOG (adb logcat)')),
          reason: 'the phone is folded in after the run, not into it',
        );
        expect(
          logLines(log).where((l) => l.contains('W/BLASTBufferQueue(')),
          hasLength(20),
        );

        // The phone's own copy is left whole.
        final phone = File(
          '${dir.path}/logs.txt.device.txt',
        ).readAsStringSync();
        expect(
          const LineSplitter()
              .convert(phone)
              .where((l) => l.isNotEmpty)
              .toList(),
          input,
        );
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'the report is read back from the disk',
      () async {
        final r = await runProfile([]);
        final said = r.stdout as String;
        final lines = const LineSplitter()
            .convert(File('${dir.path}/logs.txt').readAsStringSync())
            .length;
        expect(said, contains('Saved ${dir.path}/logs.txt ('));
        expect(
          said,
          contains(', ${_comma(lines)} lines)'),
          reason: 'the size and lines it reports are the real ones',
        );
        expect(
          said,
          isNot(contains('Full log saved')),
          reason: 'the old message, printed whether or not anything was',
        );
        expect(
          said,
          contains('Phone log (${_comma(input.length)} lines) folded'),
        );
        expect(said, contains('What the phone said went wrong:'));
        expect(said, contains("The video editor's last steps:"));
        expect(said, contains('Cache stats from this run:'));
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '-Append moves an old UTF-16 log aside instead of mixing them',
      () async {
        final old = File('${dir.path}/logs.txt');
        old.writeAsBytesSync([
          0xFF,
          0xFE,
          ...'old run\r\n'.codeUnits.expand((c) => [c, 0]),
        ]);
        final r = await runProfile(['-Append']);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(File('${dir.path}/logs.txt.old.txt').readAsBytesSync().take(2), [
          0xFF,
          0xFE,
        ]);
        final bytes = old.readAsBytesSync();
        expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
        expect(
          utf8.decode(bytes.skip(3).toList()),
          contains('Application finished.'),
        );
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

/// The lines under [heading] in the report, up to the next blank line.
String _section(String said, String heading) {
  final at = said.indexOf(heading);
  if (at < 0) return '';
  final body = said.substring(at + heading.length).replaceFirst('\n', '');
  final blank = body.indexOf('\n\n');
  return (blank < 0 ? body : body.substring(0, blank)).trimRight();
}

String _comma(int n) => n.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+$)'),
  (m) => '${m[1]},',
);
