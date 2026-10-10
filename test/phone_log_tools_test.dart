// The run log: everything into F:\logs.txt, whole, straight from the phone
// - checked by RUNNING the scripts, not by reading them.
//
// WHY. A run recorded 817,837 lines from the phone and the old script said
// "Full log saved" without looking; what arrived could not be used. Then the
// ask, twice: "make it in logs.txt only, do not create any other file", and
// "i don't want any copy, just paste whole logs in logs.txt directly".
//
// So the phone's log goes into logs.txt line by line as adb writes it, next
// to what flutter prints - no temp file, no copy, nothing shrunk - and what
// is reported at the end is read back from the disk. Every test here checks
// the log's folder holds nothing but the log afterwards, and the temp
// folder nothing at all.
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
const _otherFlutterApp = 30339; // Google Pay, also built with Flutter
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
/// dying and coming back, another Flutter app printing its own "flutter"
/// lines, and lines in no logcat shape at all.
List<String> _phoneLog() {
  final out = <String>[
    '--------- beginning of main',
    _line(
      0,
      'I',
      'ActivityManager',
      _system,
      'Start proc $_app:com.example.devf/u0a391 for next-top-activity',
    ),
    _line(
      1,
      'I',
      'ActivityManager',
      _system,
      'Start proc $_otherFlutterApp:com.google.android.apps.nbu.paisa.user/'
          'u0a332 for service',
    ),
    _line(2, 'I', 'flutter', _otherFlutterApp, 'Impeller opt-out deprecated.'),
    _line(3, 'I', 'flutter', _otherFlutterApp, 'another app, not this one'),
  ];
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
    _line(
      ms + 11900,
      'I',
      'ActivityManager',
      _system,
      'Start proc $_appAgain:com.example.devf/u0a391 for next-top-activity',
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
  final unix = Platform.isWindows ? 'the stand-ins are shell scripts' : null;

  late Directory dir;
  // Where the log goes. Nothing but the log may be in it afterwards.
  late Directory out;
  // The temp folder the scripts see. Nothing may be in it afterwards.
  late Directory tmp;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('phone_log_');
    out = Directory('${dir.path}/out')..createSync();
    tmp = Directory('${dir.path}/tmp')..createSync();
  });
  tearDown(() => dir.deleteSync(recursive: true));

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
      environment: {'TMPDIR': tmp.path, ...?env},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  List<String> filesIn(Directory d) =>
      d.listSync().map((e) => e.path.split('/').last).toList()..sort();

  /// Lines of [text] that came from the phone.
  List<String> phoneLines(String text) => const LineSplitter()
      .convert(text)
      .where((l) => l.startsWith('10-09 ') || l.startsWith('---------'))
      .toList();

  String readUtf8(File f) {
    final bytes = f.readAsBytesSync();
    expect(bytes.take(3), [
      0xEF,
      0xBB,
      0xBF,
    ], reason: 'UTF-8 with its mark, so Notepad and 5.1 read it right');
    return utf8.decode(bytes.skip(3).toList());
  }

  group('the C# that records and reads the log', () {
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
              'it uses C# newer than 5, so on the PC it fails to compile '
              "and the phone's log is not recorded at all:\n"
              '${r.stdout}\n${r.stderr}',
        );
      },
      skip: skip,
    );

    test('uses nothing beyond mscorlib and System.dll, all 5.1 hands it', () {
      // Windows PowerShell's Add-Type references only those two, so Linq
      // and HashSet (System.Core) are not there. PowerShell 7 references
      // everything, so compiling here cannot catch it - this has to read
      // the source.
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
        'SortedSet',
        'Concurrent',
        'System.Threading.Tasks',
      ]) {
        expect(
          code,
          isNot(contains(missing)),
          reason: '$missing is not in what 5.1 references',
        );
      }
      // And it is the C# that does the work: proves the check above is
      // looking at the right block.
      expect(code, contains('Process.Start(psi)'));
      expect(code, contains('new StreamReader'));
    });

    test(
      'says so when the file holds fewer phone lines than were sent',
      () async {
        // The check for a log that looks complete and is not. Every other
        // test here expects it to stay quiet, so this one makes it speak.
        final r = await run([
          '-Command',
          r". ./tools/phone_log.ps1; "
              r"$r = [pscustomobject]@{ PhoneLines = 5; AppLines = 1; "
              r"AppProcesses = 1; TopKinds = @(); Problems = @(); "
              r"EditorSteps = @() }; "
              r"Show-PhoneLogFindings $r 7",
        ]);
        expect(r.stdout, contains('BUT THE PHONE SENT 7 LINES. 2 are missing'));
        final quiet = await run([
          '-Command',
          r". ./tools/phone_log.ps1; "
              r"$r = [pscustomobject]@{ PhoneLines = 7; AppLines = 1; "
              r"AppProcesses = 1; TopKinds = @(); Problems = @(); "
              r"EditorSteps = @() }; "
              r"Show-PhoneLogFindings $r 7",
        ]);
        expect(quiet.stdout, isNot(contains('missing')));
      },
      skip: skip,
    );
  });

  group('tools/run_profile', () {
    // A stand-in flutter and adb, so the whole script runs: the build, the
    // phone's recording, and the report.
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
        // Long enough for the phone's whole log to have arrived.
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

    Future<ProcessResult> runProfile(
      List<String> extra, {
      String tools = 'tools',
    }) => run(
      [
        '-File',
        '$tools/run_profile.ps1',
        '-LogFile',
        '${out.path}/logs.txt',
        ...extra,
      ],
      env: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
    );

    test(
      "every phone line goes straight into logs.txt, and nothing else is made",
      () async {
        final r = await runProfile([]);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(filesIn(out), ['logs.txt'], reason: 'no copy beside it');
        expect(filesIn(tmp), isEmpty, reason: 'no copy in the temp folder');
        final log = readUtf8(File('${out.path}/logs.txt'));
        expect(
          phoneLines(log),
          input,
          reason:
              'every line the phone sent, whole and in order: nothing '
              'shrunk, nothing left out, nothing cut into another line',
        );
        final lines = const LineSplitter().convert(log);
        for (final whole in [
          'flutter run --profile',
          'Launching lib/main.dart in profile mode...',
          'a warning on stderr',
          'Built app-profile.apk (82.5MB) ✓',
          'Application finished.',
        ]) {
          expect(lines, contains(whole), reason: 'a whole line of its own');
        }
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
            .convert(File('${out.path}/logs.txt').readAsStringSync())
            .length;
        expect(said, contains('Saved ${out.path}/logs.txt ('));
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
          contains(
            'Phone log: ${_comma(input.length)} lines, written straight',
          ),
        );
        expect(
          said,
          contains('From the phone: ${_comma(input.length)} lines, every one'),
        );
        expect(said, isNot(contains('missing')));
        expect(said, contains('Cache stats from this run:'));
        expect(
          said,
          contains("The app's own: 44 - it ran 2 times"),
          reason:
              'the app died and came back under a new process - and the '
              "other Flutter app's lines and process are not counted as "
              "this app's",
        );

        // Inside their own parts of the report: with few kinds of line, the
        // same lines also make the "most common" list, and a check on the
        // whole screen once passed with the not-responding detection off.
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
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'removes the copy an older version left beside the log',
      () async {
        File('${out.path}/logs.txt.device.txt').writeAsStringSync('old\n');
        final r = await runProfile([]);
        expect(r.stdout, contains('Removed ${out.path}/logs.txt.device.txt'));
        expect(filesIn(out), ['logs.txt']);
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      '-Append turns an old UTF-16 log into UTF-8 in place',
      () async {
        final old = File('${out.path}/logs.txt');
        old.writeAsBytesSync([
          0xFF,
          0xFE,
          ...'old run\r\n'.codeUnits.expand((c) => [c, 0]),
        ]);
        final r = await runProfile(['-Append']);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(filesIn(out), [
          'logs.txt',
        ], reason: 'not moved aside into a second file');
        final log = readUtf8(old);
        expect(log, startsWith('old run'));
        expect(phoneLines(log), input);
      },
      skip: skip ?? unix,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      "if the C# will not load, flutter's output is still saved, and it says so",
      () async {
        final tools = Directory('${dir.path}/proj/tools')
          ..createSync(recursive: true);
        for (final name in ['run_profile.ps1', 'phone_log.ps1']) {
          var src = File('tools/$name').readAsStringSync();
          if (name == 'phone_log.ps1') {
            const scan = 'public static PhoneLogResult Scan(';
            expect(src, contains(scan));
            src = src.replaceFirst(scan, 'this does not compile $scan');
          }
          File('${tools.path}/$name').writeAsStringSync(src);
        }
        final r = await runProfile([], tools: tools.path);
        expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
        expect(r.stdout, contains('COULD NOT LOAD THE LOG TOOLS'));
        expect(r.stdout, contains('The phone-side recording is off'));
        expect(filesIn(out), ['logs.txt']);
        final log = readUtf8(File('${out.path}/logs.txt'));
        expect(log, contains('Application finished.'));
        expect(phoneLines(log), isEmpty);
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
