# Runs the app and saves everything it prints to a log file, while still
# showing it on screen.
#
# Usage, from the project folder (F:\devf):
#
#   tools\run_profile.bat                       profile build, log to F:\logs.txt
#   tools\run_profile.bat -Mode debug           debug build instead
#   tools\run_profile.bat -LogFile F:\run2.txt  write somewhere else
#   tools\run_profile.bat -Append               add to the log instead of replacing it
#   tools\run_profile.bat -NoLogcat             skip the phone-side recording
#
# The phone's own log is captured as well, ALWAYS, and folded into the same
# file at the end — so there is one file to read and one file to send.
#
# Anything else you pass is handed straight to "flutter run", so
# "tools\run_profile.bat -d R58M12345" still works.
#
# Why this exists: "flutter run" prints the [reel] cache stats and the
# ExoPlayer render counters we measure playback with, and those scroll out
# of the terminal buffer before they can be read. This keeps a full copy.
#
# Keep this file plain ASCII. Windows PowerShell 5.1 misreads UTF-8 files
# that have no byte-order mark, which would corrupt the script.

param(
    # Default target. Falls back to the project folder if there is no F: drive
    # on this machine, so the script still works for anyone else.
    [string]$LogFile = 'F:\logs.txt',

    [ValidateSet('profile', 'debug', 'release')]
    [string]$Mode = 'profile',

    # Keep previous runs in the same file instead of starting fresh.
    [switch]$Append,

    # Turn OFF the phone-side recording. It is ON by default.
    #
    # WHY IT IS ON BY DEFAULT. "flutter run" only prints for as long as it
    # stays attached to the app it launched. A run arrived with 297 lines in
    # it, ending in the middle of the first video's decoder starting,
    # followed by "Application finished." — the app stopped being followed
    # about two seconds in, and everything done after that was on a phone
    # nothing was listening to. The whole session was lost, and nobody knew
    # until the file was opened.
    #
    # adb logcat does not care. It records the PHONE, not one app process,
    # so it keeps going through the app being killed, restarted, or opened
    # again from the home screen.
    #
    # Being a flag nobody remembers to pass is the same as not existing, so
    # it is not a flag any more. The cost is a bigger file; the cost of the
    # other way is finding out afterwards that the run captured nothing.
    [switch]$NoLogcat,

    # Everything not matched above goes to "flutter run" untouched.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Extra = @()
)

# Deliberately NOT 'Stop'. Under 'Stop', the 2>&1 below turns the first line
# flutter writes to stderr into a terminating error and kills the run, which
# is exactly the output this script exists to capture.
$ErrorActionPreference = 'Continue'

# Read the tool's output as UTF-8. Windows PowerShell otherwise decodes a
# native command's bytes using the console's legacy OEM code page, which
# renders flutter's "Built ..." check mark as three unrelated symbols and
# mangles every other non-ASCII character in the log.
$previousOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Run from the project root no matter where the script was launched from,
# so double-clicking it from Explorer works the same as calling it from the
# terminal. The root is this script's parent folder.
$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Host "flutter was not found on your PATH." -ForegroundColor Red
    Write-Host "Open a new terminal, or reinstall Flutter and tick 'Add to PATH'."
    exit 1
}

# If the requested folder does not exist (no F: drive, or a typo), fall back
# to the project folder rather than failing after the build has started.
$logDir = Split-Path -Parent $LogFile
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    $fallback = Join-Path $projectRoot 'logs.txt'
    Write-Host "$logDir does not exist. Writing to $fallback instead." -ForegroundColor Yellow
    $LogFile = $fallback
}

$flutterArgs = @('run', "--$Mode") + $Extra

# Start the phone-side recording before the app launches, so nothing from
# the first seconds is missed. Runs as its own process, writing its own
# file, and is stopped in the finally block below whatever happens.
$deviceLog = "$LogFile.device.txt"
$logcatProc = $null
$wantLogcat = -not $NoLogcat
if ($wantLogcat) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Write-Host "adb was not found on your PATH, so the phone-side recording is off." -ForegroundColor Yellow
        Write-Host "It ships with Android Studio, in platform-tools."
    } else {
        # -c clears whatever the phone was already holding, so the file
        # starts at this run rather than at some earlier one.
        & adb logcat -c 2>&1 | Out-Null
        $logcatProc = Start-Process -FilePath 'adb' `
            -ArgumentList @('logcat', '-v', 'time') `
            -RedirectStandardOutput $deviceLog `
            -NoNewWindow -PassThru
        Write-Host "Also recording the phone to $deviceLog" -ForegroundColor Cyan
    }
}

# The header goes through Tee-Object as well, rather than Out-File, so the
# whole file is written by one cmdlet in one encoding. Windows PowerShell
# defaults Out-File to UTF-8 only when told to, and Tee-Object to UTF-16;
# mixing the two in one file produces a garbled log.
$teeStart = @{ FilePath = $LogFile }
if ($Append) { $teeStart['Append'] = $true }

@(
    '',
    '=============================================================',
    "flutter $($flutterArgs -join ' ')",
    "started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    '============================================================='
) | Tee-Object @teeStart

Write-Host "Logging to $LogFile" -ForegroundColor Cyan

try {
    # 2>&1 folds the error stream in so warnings are captured too. Native
    # commands surface those as ErrorRecord objects, which the file writer
    # would expand into several lines of PowerShell diagnostics, so flatten
    # every item to its own text first. Tee-Object then writes to the file
    # and passes the line through to the screen.
    #
    # Read the message off the exception rather than calling ToString() on
    # the record: a blank line on stderr produces a record with an empty
    # message, and ToString() falls back to printing the exception's type
    # name, so every blank line in the log came out as a wall of
    # "System.Management.Automation.RemoteException".
    & flutter @flutterArgs 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            } else {
                "$_"
            }
        } |
        Tee-Object -FilePath $LogFile -Append
} finally {
    [Console]::OutputEncoding = $previousOutputEncoding

    if ($logcatProc -and -not $logcatProc.HasExited) {
        Stop-Process -Id $logcatProc.Id -Force -ErrorAction SilentlyContinue
        # adb writes through a buffer. Stopping it does not mean the last
        # lines have reached the disk, and appending a file that is still
        # being written truncates it mid-line.
        Start-Sleep -Milliseconds 700
    }

    # Fold the phone's log into the main one, so there is a single file to
    # read and a single file to send.
    #
    # Appended AFTER the run rather than written alongside it: two writers
    # on one file interleave mid-line and produce a log that cannot be
    # trusted, which is worse than two files. By here the flutter stream
    # has finished, so this is the one safe moment to join them.
    #
    # The device copy is left in place as well. If this append fails — disk
    # full, file locked by an editor — the phone's log still exists on its
    # own rather than being lost inside a half-written merge.
    if ($wantLogcat -and (Test-Path -LiteralPath $deviceLog)) {
        try {
            $deviceLines = (Get-Content -LiteralPath $deviceLog | Measure-Object -Line).Lines
            @(
                '',
                '=============================================================',
                "PHONE LOG (adb logcat) - $deviceLines lines",
                'Everything below is from the phone itself, so it covers any',
                'stretch where flutter run stopped following the app.',
                '============================================================='
            ) | Add-Content -LiteralPath $LogFile -Encoding Unicode

            # -Encoding Unicode, NOT the default.
            #
            # Tee-Object above wrote this file as UTF-16, and Add-Content on
            # Windows PowerShell 5.1 defaults to ASCII. Mixing the two in
            # one file produces a garbled log — which the header comment at
            # the top of this script already warns about, and which this
            # append walked straight into on the first attempt.
            #
            # -ReadCount batches the lines instead of sending them through
            # the pipeline one at a time. A phone log is hundreds of
            # thousands of lines, and one-at-a-time takes minutes.
            Get-Content -LiteralPath $deviceLog -ReadCount 2000 |
                ForEach-Object { Add-Content -LiteralPath $LogFile -Value $_ -Encoding Unicode }
            Write-Host "Phone log ($deviceLines lines) folded into $LogFile" -ForegroundColor Cyan
            Write-Host "  (also kept on its own at $deviceLog)"
        } catch {
            # Say so loudly. A silent failure here means sending a log that
            # is missing exactly the part that was added to stop logs being
            # missing.
            Write-Host "COULD NOT FOLD THE PHONE LOG IN: $_" -ForegroundColor Yellow
            Write-Host "  Send BOTH files: $LogFile and $deviceLog"
        }
    }

    Write-Host ""
    Write-Host "Full log saved to $LogFile" -ForegroundColor Cyan

    # The playback measurement lives on one line near the end of the run.
    # Pull it back out so it does not have to be hunted for in the file.
    $searchIn = @($LogFile)
    if ($wantLogcat -and (Test-Path -LiteralPath $deviceLog)) { $searchIn += $deviceLog }
    # Match on 'starts=' alone, NOT on '[reel] starts='.
    #
    # Those two words stopped being next to each other the day the decoder
    # reading was added to the front of the summary, which now reads
    #
    #     [reel] decoders{...} hardware=15  starts=122  proxy=95 (78%) ...
    #
    # so the old search matched nothing, and a perfectly good 63,000-line
    # log with sixteen summaries in it was reported as having none. A false
    # 'nothing here' is worse than no check at all: it tells somebody to
    # throw away the run that had the answer in it.
    $stats = Select-String -LiteralPath $searchIn -Pattern 'starts=\d+' |
        Select-Object -Last 1
    if ($stats) {
        Write-Host "Cache stats from this run:" -ForegroundColor Cyan
        Write-Host "  $($stats.Line.Trim())"
    } else {
        # Say so. A missing measurement that nobody mentions is how a run
        # with no numbers in it gets sent off as though it had some.
        Write-Host "NO PLAYBACK STATS IN THIS LOG." -ForegroundColor Yellow
        Write-Host "  The app never got far enough to print one. If you did"
        Write-Host "  watch videos, the log stopped following the app - re-run"
        Write-Host "  with -Logcat, which keeps recording regardless."
    }
}
