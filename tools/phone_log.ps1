# The phone's log, made small enough to open and to send.
#
# Shared by run_profile.ps1 (at the end of every run) and
# shrink_phone_log.ps1 (for a phone log already on disk). Load it with
#
#   . (Join-Path $PSScriptRoot 'phone_log.ps1')
#
# WHY. A run once recorded 817,837 lines from the phone. The script folded
# every one of them into F:\logs.txt, in UTF-16 (two bytes a letter), which
# made a file of a couple of hundred megabytes. Notepad struggles to open
# that, and it is far too big to attach - so the person running it opened
# the file, found nothing they could use, and reported "logs not saved".
# The run had the answer in it; nobody could get at it.
#
# Most of a phone's log is the same few lines over and over: one part of
# Android repeating a warning many times a second. So this keeps:
#
#   - every line the app itself prints (tag "flutter"), always;
#   - every line about a crash or an app not responding, always;
#   - every line that is not in the usual logcat shape, always;
#   - from the app's own process, the first 200 lines of each kind;
#   - from the rest of the phone, the first 20 lines of each kind;
#
# in the order they happened. Everything past those limits is COUNTED, not
# thrown away: a table at the top says which kinds of line there were and
# how many, and a list at the end says how many of each were left out and
# when they ran. "3,000 decoder errors" is still in the file as a number.
#
# Two lines are the same kind when they match after the time, the process
# number, and every other number in them are taken out.
#
# The work is done in C#: Windows PowerShell 5.1 takes minutes to go
# through 800,000 lines one at a time, which looks like a hung script.
#
# Keep this file plain ASCII. Windows PowerShell 5.1 misreads UTF-8 files
# that have no byte-order mark. And keep the C# to C# 5 with nothing beyond
# mscorlib (no Linq, no HashSet, no Queue): Windows PowerShell compiles it
# with the old compiler that ships with Windows. A test checks both.

$PhoneLogSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace BattleArena
{
    public sealed class PhoneLogKind
    {
        public string Key;
        public long Count;
        public int KeptApp;
        public int KeptOther;
        public long Cut;
        public int CutFirstMs = -1;
        public int CutLastMs = -1;
    }

    public sealed class PhoneLogResult
    {
        public long Lines;
        public long Kept;
        public long Cut;
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

        static string Clock(int ms)
        {
            if (ms < 0) return "?";
            return string.Format(Inv, "{0:00}:{1:00}:{2:00}.{3:000}",
                ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000);
        }

        static string Cap(string s, int n)
        {
            return s.Length <= n ? s : s.Substring(0, n) + "...";
        }

        static StreamReader Open(string path)
        {
            return new StreamReader(path, new UTF8Encoding(false), true);
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

        public static PhoneLogResult Fold(string phoneLog, string into,
            bool append, string appId, int keepApp, int keepOther, int top)
        {
            // Pass 1: which processes are the app's. The app's own messages
            // carry the tag "flutter"; every process that printed one is
            // the app (more than one means it was restarted).
            var appPids = new Dictionary<int, bool>();
            long total = 0;
            using (var r = Open(phoneLog))
            {
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    total++;
                    char lv; string tag; int pid; string msg; int ms;
                    if (Parse(line, out lv, out tag, out pid, out msg, out ms) &&
                        tag == "flutter")
                        appPids[pid] = true;
                }
            }
            if (total > int.MaxValue) throw new InvalidOperationException(
                "the phone log has more lines than can be counted here");

            // Pass 2: what each line is, and which ones are kept.
            var res = new PhoneLogResult();
            res.AppProcesses = appPids.Count;
            var keep = new BitArray((int)total);
            var kinds = new Dictionary<string, PhoneLogKind>(StringComparer.Ordinal);
            // Each kind of problem once, with how many more like it, so a
            // crash repeated 30 times by some other app cannot push this
            // app's own "not responding" off the screen.
            var problems = new List<string>();
            var problemCounts = new List<int>();
            var problemAt = new Dictionary<string, int>(StringComparer.Ordinal);
            var editor = new List<string>();
            int anrPid = -1, anrLeft = 0;
            using (var r = Open(phoneLog))
            {
                string line;
                int i = -1;
                while ((line = r.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    i++;
                    // A file still growing between the passes: stop at
                    // what the first pass counted.
                    if (i >= keep.Length) break;
                    res.Lines++;
                    char lv; string tag; int pid; string msg; int ms;
                    if (!Parse(line, out lv, out tag, out pid, out msg, out ms))
                    {
                        keep[i] = true;
                        res.Kept++;
                        continue;
                    }
                    bool isApp = appPids.ContainsKey(pid);
                    bool flutter = tag == "flutter";
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

                    bool kept;
                    if (flutter || problem) kept = true;
                    else if (isApp)
                    {
                        kept = k.KeptApp < keepApp;
                        if (kept) k.KeptApp++;
                    }
                    else
                    {
                        kept = k.KeptOther < keepOther;
                        if (kept) k.KeptOther++;
                    }
                    if (kept)
                    {
                        keep[i] = true;
                        res.Kept++;
                    }
                    else
                    {
                        k.Cut++;
                        res.Cut++;
                        if (k.CutFirstMs < 0) k.CutFirstMs = ms;
                        k.CutLastMs = ms;
                    }
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
            res.EditorSteps = editor.ToArray();

            var cutKinds = new List<PhoneLogKind>();
            foreach (var k in all) if (k.Cut > 0) cutKinds.Add(k);
            cutKinds.Sort(delegate (PhoneLogKind a, PhoneLogKind b)
            {
                int c = b.Cut.CompareTo(a.Cut);
                return c != 0 ? c : string.CompareOrdinal(a.Key, b.Key);
            });

            // Pass 3: write it. UTF-8, and a byte-order mark only when the
            // file is new (an append lands after the text already there).
            const string Rule = "=============================================================";
            using (var w = new StreamWriter(into, append, new UTF8Encoding(true)))
            {
                w.WriteLine();
                w.WriteLine(Rule);
                w.WriteLine(string.Format(Inv, "PHONE LOG (adb logcat): {0:N0} lines from the phone.", res.Lines));
                w.WriteLine(string.Format(Inv, "This app's own messages (tag flutter): {0:N0}, all kept.", res.AppLines));
                w.WriteLine(string.Format(Inv,
                    "Everything else is kept in order up to the first {0} lines of each kind from", keepApp));
                w.WriteLine(string.Format(Inv,
                    "this app's process and the first {0} of each kind from the rest of the phone.", keepOther));
                w.WriteLine(string.Format(Inv,
                    "The other {0:N0} lines are repeats. They are counted at the end of this", res.Cut));
                w.WriteLine("section instead of copied. Lines about a crash or an app not responding");
                w.WriteLine("are always kept.");
                w.WriteLine("Every line, uncut: " + phoneLog);
                w.WriteLine(Rule);
                w.WriteLine("THE MOST COMMON KINDS OF LINE IN THE PHONE LOG");
                w.WriteLine("(how many, then the line with its numbers shown as #)");
                foreach (var s in res.TopKinds) w.WriteLine(s);
                w.WriteLine(Rule);

                using (var r = Open(phoneLog))
                {
                    string line;
                    int i = -1;
                    while ((line = r.ReadLine()) != null)
                    {
                        if (line.Length == 0) continue;
                        i++;
                        if (i < keep.Length && keep[i]) w.WriteLine(line);
                    }
                }

                w.WriteLine(Rule);
                w.WriteLine(string.Format(Inv,
                    "END OF PHONE LOG. Repeats counted instead of copied: {0:N0} lines.", res.Cut));
                if (cutKinds.Count > 0)
                {
                    w.WriteLine("(how many more, the kind of line, and from when to when)");
                    foreach (var k in cutKinds)
                        w.WriteLine(string.Format(Inv, "{0,10:N0} more  {1}  [{2} to {3}]",
                            k.Cut, k.Key, Clock(k.CutFirstMs), Clock(k.CutLastMs)));
                }
                w.WriteLine(Rule);
            }
            return res;
        }
    }
}
'@

# Compiled on first use, not when this file is loaded: if compiling ever
# fails, the run itself has still been recorded.
#
# -IgnoreWarnings: Add-Type treats a compiler WARNING as an error. The old
# compiler on Windows does not warn about exactly the same things as the
# new one the tests compile with, so a warning only it gives would stop the
# fold on the PC alone. The tests compile without this, so the code itself
# stays free of warnings.
function Import-PhoneLogReader {
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

# Shrinks $PhoneLog into $Into (added to the end when $Append). Returns
# what was found: line counts, the most common kinds, the problems the
# phone reported, and the video editor's last steps.
function Add-PhoneLog {
    param(
        [string]$PhoneLog,
        [string]$Into,
        [bool]$Append,
        [string]$ProjectRoot
    )
    Import-PhoneLogReader
    # Full paths for C#: .NET reads a short path from the folder the
    # process started in, not from where PowerShell is.
    $full = (Get-Item -LiteralPath $PhoneLog).FullName
    $Into = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Into)
    return [BattleArena.PhoneLog]::Fold($full, $Into, $Append,
        (Get-AppId $ProjectRoot), 200, 20, 25)
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
        Import-PhoneLogReader
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

# The parts of the phone's log worth seeing without opening the file.
function Show-PhoneLogFindings($Result, [string]$PhoneLog) {
    $restarts = ''
    if ($Result.AppProcesses -gt 1) {
        $restarts = " - it ran $($Result.AppProcesses) times, so it was closed or killed and opened again"
    }
    Write-Host "  The app's own lines: $(Format-Count $Result.AppLines)$restarts"
    Write-Host "  The phone wrote $(Format-Count $Result.Lines) lines. $(Format-Count $Result.Cut) of them are repeats, counted at"
    Write-Host "  the end of the phone section instead of copied."
    Write-Host "  Every phone line, uncut: $PhoneLog ($(Format-Size $PhoneLog))"

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
