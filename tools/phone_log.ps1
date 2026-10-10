# The run log: everything into F:\logs.txt, whole, as it happens.
#
# Shared by run_profile.ps1. Load it with
#
#   . (Join-Path $PSScriptRoot 'phone_log.ps1')
#
# ONE FILE, WHOLE, DIRECT. Asked for in so many words: "make it in logs.txt
# only, do not create any other file", then "i don't want any copy, just
# paste whole logs in logs.txt directly". So:
#
#   - the phone's log (adb logcat) is read here as adb writes it, and each
#     line goes straight into the log - no temp file, no second copy;
#   - what "flutter run" prints goes into the same log the same way;
#   - every line is kept: nothing is shrunk, counted instead of copied, or
#     left out.
#
# One writer takes both, a whole line at a time, so the phone's lines and
# flutter's sit in the order they happened and never cut into each other.
#
# At the end the log is read back to say what is in it: how many lines, the
# kinds of line that filled it, what the phone said went wrong, and the
# video editor's last steps. That is on screen only; it creates nothing.
#
# The work is done in C#: reading adb as it writes needs a thread of its
# own, and Windows PowerShell 5.1 takes minutes to read 800,000 lines one at
# a time, which looks like a hung script.
#
# Keep this file plain ASCII. Windows PowerShell 5.1 misreads UTF-8 files
# that have no byte-order mark. And keep the C# to C# 5 with nothing beyond
# mscorlib and System.dll (no Linq, no HashSet): Windows PowerShell compiles
# it with the old compiler that ships with Windows, and hands it only those
# two. A test checks both.

$PhoneLogSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

namespace BattleArena
{
    // The log file. One writer for everything, a whole line at a time, so
    // flutter's lines and the phone's never cut into each other. UTF-8,
    // and on disk as each line arrives: a run stopped with Ctrl+C, or a
    // window closed, still leaves everything up to that point.
    public sealed class RunLog : IDisposable
    {
        readonly object gate = new object();
        readonly StreamWriter w;

        public RunLog(string path, bool append)
        {
            w = new StreamWriter(path, append, new UTF8Encoding(true));
            w.AutoFlush = true;
        }

        public void WriteLine(string line)
        {
            lock (gate) { w.WriteLine(line); }
        }

        public void Dispose()
        {
            lock (gate) { w.Dispose(); }
        }
    }

    // adb logcat, read as it writes, every line straight into the log.
    // adb records the PHONE, not one app, so it keeps going through the
    // app being killed, restarted or reopened.
    public sealed class PhoneRecorder
    {
        Process adb;
        Thread reader;
        long lines;
        string failure;

        public long Lines { get { return Interlocked.Read(ref lines); } }

        // Why the recording stopped early, or null.
        public string Failure { get { return failure; } }

        public static PhoneRecorder Start(string adbPath, RunLog log)
        {
            var psi = new ProcessStartInfo(adbPath, "logcat -v time");
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.CreateNoWindow = true;
            psi.StandardOutputEncoding = new UTF8Encoding(false);
            var rec = new PhoneRecorder();
            rec.adb = Process.Start(psi);
            rec.reader = new Thread(delegate ()
            {
                try
                {
                    string line;
                    while ((line = rec.adb.StandardOutput.ReadLine()) != null)
                    {
                        // Some adb versions on Windows end lines with
                        // \r\r\n, which reads as a blank line after each.
                        if (line.Length == 0) continue;
                        log.WriteLine(line);
                        Interlocked.Increment(ref rec.lines);
                    }
                }
                catch (Exception e)
                {
                    rec.failure = e.Message;
                }
            });
            rec.reader.IsBackground = true;
            rec.reader.Start();
            return rec;
        }

        // Stops adb, then waits until the last of what it wrote is in the
        // log - stopping it does not mean its last lines have been read.
        public void Stop()
        {
            try
            {
                if (!adb.HasExited) adb.Kill();
            }
            catch (Exception e)
            {
                if (failure == null) failure = "could not stop adb: " + e.Message;
            }
            if (!reader.Join(10000) && failure == null)
                failure = "adb's last lines were still arriving after 10 seconds";
        }
    }

    public sealed class PhoneLogKind
    {
        public string Key;
        public long Count;
    }

    public sealed class PhoneLogResult
    {
        public long Lines;
        public long PhoneLines;
        public long AppLines;
        public int AppProcesses;
        public string[] TopKinds;
        public string[] Problems;
        public string[] EditorSteps;
    }

    public static class PhoneLog
    {
        const int KeyLength = 100;
        const int MaxProblems = 40;
        const int EditorStepsKept = 25;

        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        // "10-09 23:38:43.171 I/flutter (27066): message" - logcat -v time.
        static bool Parse(string line, out char level, out string tag,
            out int pid, out string msg, out int ms)
        {
            level = ' '; tag = null; pid = -1; msg = null; ms = -1;
            if (line.Length < 23) return false;
            if (line[2] != '-' || line[5] != ' ' || line[8] != ':' ||
                line[11] != ':' || line[14] != '.' || line[18] != ' ' ||
                line[20] != '/') return false;
            int close = line.IndexOf("): ", 21, StringComparison.Ordinal);
            if (close < 0)
            {
                if (!line.EndsWith("):", StringComparison.Ordinal)) return false;
                close = line.Length - 2;
            }
            int open = line.LastIndexOf('(', close);
            if (open <= 21) return false;
            if (!int.TryParse(line.Substring(open + 1, close - open - 1).Trim(),
                NumberStyles.Integer, Inv, out pid)) return false;
            int h, m, s, f;
            if (!int.TryParse(line.Substring(6, 2), NumberStyles.None, Inv, out h) ||
                !int.TryParse(line.Substring(9, 2), NumberStyles.None, Inv, out m) ||
                !int.TryParse(line.Substring(12, 2), NumberStyles.None, Inv, out s) ||
                !int.TryParse(line.Substring(15, 3), NumberStyles.None, Inv, out f))
                return false;
            ms = ((h * 60 + m) * 60 + s) * 1000 + f;
            level = line[19];
            tag = line.Substring(21, open - 21).TrimEnd();
            msg = close + 3 <= line.Length ? line.Substring(close + 3) : "";
            return true;
        }

        static bool IsHexish(char c)
        {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                (c >= 'A' && c <= 'F') || c == 'x' || c == 'X';
        }

        // The line with every number shown as #, so repeats that differ only
        // in a count, an id or an address are one kind.
        static string KindOf(char level, string tag, string msg)
        {
            var sb = new StringBuilder(KeyLength + 32);
            sb.Append(level).Append('/').Append(tag).Append(": ");
            int start = sb.Length;
            int i = 0;
            while (i < msg.Length)
            {
                if (sb.Length - start >= KeyLength) { sb.Append("..."); break; }
                char c = msg[i];
                if (IsHexish(c))
                {
                    int j = i;
                    bool digit = false;
                    while (j < msg.Length && IsHexish(msg[j]))
                    {
                        if (msg[j] >= '0' && msg[j] <= '9') digit = true;
                        j++;
                    }
                    if (digit) sb.Append('#'); else sb.Append(msg, i, j - i);
                    i = j;
                }
                else
                {
                    sb.Append(c);
                    i++;
                }
            }
            return sb.ToString();
        }

        static string Cap(string s, int n)
        {
            return s.Length <= n ? s : s.Substring(0, n) + "...";
        }

        public static long CountLines(string path)
        {
            long n = 0;
            using (var r = new StreamReader(path, true))
            {
                while (r.ReadLine() != null) n++;
            }
            return n;
        }

        // The process "Start proc 26220:com.example.devf/u0a391 ..." says
        // was started for [appId] (or one of its own sub-processes,
        // "com.example.devf:remote"), or -1.
        static int StartedPid(string msg, string appId)
        {
            const string Start = "Start proc ";
            if (!msg.StartsWith(Start, StringComparison.Ordinal)) return -1;
            int colon = msg.IndexOf(':', Start.Length);
            if (colon < 0) return -1;
            int pid;
            if (!int.TryParse(msg.Substring(Start.Length, colon - Start.Length),
                NumberStyles.None, Inv, out pid)) return -1;
            int end = colon + 1 + appId.Length;
            if (end > msg.Length ||
                string.CompareOrdinal(msg, colon + 1, appId, 0, appId.Length) != 0)
                return -1;
            if (end < msg.Length && msg[end] != '/' && msg[end] != ':' && msg[end] != ' ')
                return -1;
            return pid;
        }

        static StreamReader Open(string path)
        {
            return new StreamReader(path, new UTF8Encoding(false), true);
        }

        // Reads the log back and says what is in it. Changes nothing.
        public static PhoneLogResult Scan(string path, string appId, int top)
        {
            // Pass 1: which processes are the app's (more than one means it
            // was restarted). By name: Android logs "Start proc 26220:
            // com.example.devf/..." when it starts one, and the app's own
            // system lines carry the last 15 letters of its name as their
            // tag. Not by the tag "flutter" alone: every Flutter app prints
            // that, and a run counted Google Pay as this app restarting.
            // That is the fallback, for a log where the name never shows.
            string appTag = appId == null ? "" :
                appId.Length > 15 ? appId.Substring(appId.Length - 15) : appId;
            var named = new Dictionary<int, bool>();
            var flutterPids = new Dictionary<int, bool>();
            using (var r = Open(path))
            {
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    char lv; string tag; int pid; string msg; int ms;
                    if (!Parse(line, out lv, out tag, out pid, out msg, out ms)) continue;
                    if (tag == "flutter") flutterPids[pid] = true;
                    if (appTag.Length == 0) continue;
                    if (tag == appTag) named[pid] = true;
                    int started = StartedPid(msg, appId);
                    if (started >= 0) named[started] = true;
                }
            }
            var appPids = named.Count > 0 ? named : flutterPids;

            // Pass 2: what each line is.
            var res = new PhoneLogResult();
            res.AppProcesses = appPids.Count;
            var kinds = new Dictionary<string, PhoneLogKind>(StringComparer.Ordinal);
            // Each kind of problem once, with how many more like it, so a
            // crash repeated 30 times by some other app cannot push this
            // app's own "not responding" off the screen.
            var problems = new List<string>();
            var problemCounts = new List<int>();
            var problemAt = new Dictionary<string, int>(StringComparer.Ordinal);
            // The editor's steps from the phone's lines, which carry the
            // time; from flutter run's own copy only when there are none.
            var editor = new List<string>();
            var editorFromRun = new List<string>();
            int anrPid = -1, anrLeft = 0;
            using (var r = Open(path))
            {
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    res.Lines++;
                    char lv; string tag; int pid; string msg; int ms;
                    if (!Parse(line, out lv, out tag, out pid, out msg, out ms))
                    {
                        // The one line logcat writes in another shape:
                        // "--------- beginning of main" and the like.
                        if (line.StartsWith("--------- ", StringComparison.Ordinal))
                            res.PhoneLines++;
                        else if (line.IndexOf("[editor]", StringComparison.Ordinal) >= 0)
                        {
                            editorFromRun.Add(Cap(line, 200));
                            if (editorFromRun.Count > EditorStepsKept) editorFromRun.RemoveAt(0);
                        }
                        continue;
                    }
                    res.PhoneLines++;
                    bool isApp = appPids.ContainsKey(pid);
                    // This app's own messages: another Flutter app's are
                    // just more of the phone.
                    bool flutter = tag == "flutter" && isApp;
                    if (flutter)
                    {
                        res.AppLines++;
                        if (msg.IndexOf("[editor]", StringComparison.Ordinal) >= 0)
                        {
                            editor.Add(line.Substring(6, 12) + "  " + Cap(msg, 200));
                            if (editor.Count > EditorStepsKept) editor.RemoveAt(0);
                        }
                    }

                    bool problem = false;
                    if (msg.IndexOf("ANR in ", StringComparison.Ordinal) >= 0)
                    {
                        problem = true;
                        anrPid = pid;
                        anrLeft = 10;
                    }
                    else if (anrLeft > 0 && pid == anrPid)
                    {
                        anrLeft--;
                        if (msg.StartsWith("Reason:", StringComparison.Ordinal)) problem = true;
                    }
                    if (!problem)
                    {
                        problem =
                            msg.IndexOf("FATAL EXCEPTION", StringComparison.Ordinal) >= 0 ||
                            msg.IndexOf("Fatal signal", StringComparison.Ordinal) >= 0 ||
                            (flutter && msg.IndexOf("Unhandled Exception", StringComparison.Ordinal) >= 0) ||
                            (isApp && (lv == 'F' || lv == 'A')) ||
                            (appId != null && appId.Length > 0 &&
                                msg.IndexOf(appId, StringComparison.Ordinal) >= 0 &&
                                (msg.IndexOf("died", StringComparison.Ordinal) >= 0 ||
                                 msg.IndexOf("crash", StringComparison.OrdinalIgnoreCase) >= 0 ||
                                 msg.IndexOf("Force finishing", StringComparison.Ordinal) >= 0 ||
                                 msg.IndexOf("Killing", StringComparison.Ordinal) >= 0 ||
                                 msg.IndexOf("not responding", StringComparison.OrdinalIgnoreCase) >= 0));
                    }

                    string key = KindOf(lv, tag, msg);
                    if (problem)
                    {
                        int at;
                        if (problemAt.TryGetValue(key, out at)) problemCounts[at]++;
                        else if (problems.Count < MaxProblems)
                        {
                            problemAt[key] = problems.Count;
                            problems.Add(line.Substring(6, 12) + "  " + lv + "/" + tag + ": " + Cap(msg, 300));
                            problemCounts.Add(1);
                        }
                    }

                    PhoneLogKind k;
                    if (!kinds.TryGetValue(key, out k))
                    {
                        k = new PhoneLogKind();
                        k.Key = key;
                        kinds[key] = k;
                    }
                    k.Count++;
                }
            }

            var all = new List<PhoneLogKind>(kinds.Values);
            all.Sort(delegate (PhoneLogKind a, PhoneLogKind b)
            {
                int c = b.Count.CompareTo(a.Count);
                return c != 0 ? c : string.CompareOrdinal(a.Key, b.Key);
            });
            var topKinds = new List<string>();
            for (int t = 0; t < all.Count && t < top; t++)
                topKinds.Add(string.Format(Inv, "{0,10:N0}  {1}", all[t].Count, all[t].Key));
            res.TopKinds = topKinds.ToArray();
            for (int p = 0; p < problems.Count; p++)
                if (problemCounts[p] > 1)
                    problems[p] += string.Format(Inv, "  (and {0:N0} more like it)", problemCounts[p] - 1);
            res.Problems = problems.ToArray();
            res.EditorSteps = (editor.Count > 0 ? editor : editorFromRun).ToArray();
            return res;
        }
    }
}
'@

# Compiled once, at the start of a run.
#
# -IgnoreWarnings: Add-Type treats a compiler WARNING as an error. The old
# compiler on Windows does not warn about exactly the same things as the
# new one the tests compile with, so a warning only it gives would stop
# the tools loading on the PC alone. The tests compile without this, so the
# code itself stays free of warnings.
function Import-LogTools {
    if (-not ('BattleArena.PhoneLog' -as [type])) {
        Add-Type -TypeDefinition $PhoneLogSource -Language CSharp -IgnoreWarnings
    }
}

# The app's id (com.example.devf), so the phone's lines about this app
# being killed or crashing can be picked out from every other app's.
function Get-AppId([string]$ProjectRoot) {
    foreach ($name in @('build.gradle.kts', 'build.gradle')) {
        $file = [System.IO.Path]::Combine($ProjectRoot, 'android', 'app', $name)
        if (Test-Path -LiteralPath $file) {
            foreach ($line in Get-Content -LiteralPath $file) {
                if ($line -match 'applicationId\s*=?\s*"([^"]+)"') { return $matches[1] }
            }
        }
    }
    return ''
}

function Format-Count($n) {
    return ([long]$n).ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Size([string]$Path) {
    $mb = (Get-Item -LiteralPath $Path).Length / 1MB
    return $mb.ToString('N1', [System.Globalization.CultureInfo]::InvariantCulture) + ' MB'
}

# Says what is actually on disk, read back from the disk - not what the
# script meant to write. "Full log saved" used to be printed whatever
# happened, and a run reported as saved was not one anybody could use.
function Show-SavedFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "$Path WAS NOT WRITTEN. Nothing from this run is in it." -ForegroundColor Red
        return
    }
    $bytes = (Get-Item -LiteralPath $Path).Length
    if ($bytes -eq 0) {
        Write-Host "$Path IS EMPTY. Nothing from this run is in it." -ForegroundColor Red
        return
    }
    $lines = ''
    try {
        Import-LogTools
        $lines = ', ' + (Format-Count ([BattleArena.PhoneLog]::CountLines($Path))) + ' lines'
    } catch {
        Write-Host "  (could not count its lines: $($_.Exception.Message))" -ForegroundColor Yellow
    }
    Write-Host "Saved $Path ($(Format-Size $Path)$lines)" -ForegroundColor Cyan
    if ($bytes -gt 25MB) {
        Write-Host "  That is big to attach. Right-click it, Send to > Compressed (zipped) folder," -ForegroundColor Yellow
        Write-Host "  and attach the zip instead." -ForegroundColor Yellow
    }
}

# What is in the log, worth seeing without opening the file. $Recorded is
# how many lines the phone recording took in (-1 when it did not run), so
# a file holding fewer than that says so instead of passing for complete.
function Show-PhoneLogFindings($Result, [long]$Recorded = -1) {
    $restarts = ''
    if ($Result.AppProcesses -gt 1) {
        $restarts = " - it ran $($Result.AppProcesses) times, so it was closed or killed and opened again"
    }
    Write-Host "  From the phone: $(Format-Count $Result.PhoneLines) lines, every one. The app's own: $(Format-Count $Result.AppLines)$restarts"
    if ($Recorded -ge 0 -and $Result.PhoneLines -lt $Recorded) {
        Write-Host "  BUT THE PHONE SENT $(Format-Count $Recorded) LINES. $(Format-Count ($Recorded - $Result.PhoneLines)) are missing from the file." -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "The most common lines from the phone:" -ForegroundColor Cyan
    foreach ($kind in @($Result.TopKinds | Select-Object -First 8)) {
        if ($kind.Length -gt 118) { $kind = $kind.Substring(0, 118) + '...' }
        Write-Host $kind
    }

    Write-Host ""
    if ($Result.Problems.Length -gt 0) {
        Write-Host "What the phone said went wrong:" -ForegroundColor Yellow
        foreach ($p in @($Result.Problems | Select-Object -First 15)) { Write-Host "  $p" }
        if ($Result.Problems.Length -gt 15) {
            Write-Host "  ...and more in the file."
        }
    } else {
        Write-Host "The phone reported no crash and no app not responding." -ForegroundColor Cyan
    }

    Write-Host ""
    if ($Result.EditorSteps.Length -gt 0) {
        Write-Host "The video editor's last steps:" -ForegroundColor Cyan
        foreach ($s in $Result.EditorSteps) { Write-Host "  $s" }
    } else {
        Write-Host "The video editor was not opened in this run." -ForegroundColor Cyan
    }
}
