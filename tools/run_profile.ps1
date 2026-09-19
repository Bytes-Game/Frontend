# Runs the app and saves everything it prints to a log file, while still
# showing it on screen.
#
# Usage, from the project folder (F:\devf):
#
#   tools\run_profile.bat                       profile build, log to F:\logs.txt
#   tools\run_profile.bat -Mode debug           debug build instead
#   tools\run_profile.bat -LogFile F:\run2.txt  write somewhere else
#   tools\run_profile.bat -Append               add to the log instead of replacing it
#   tools\run_profile.bat -Logcat               ALSO capture straight from the
#                                               phone, which keeps recording
#                                               even if the app restarts
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

    # Also record straight off the phone with "adb logcat", into
    # <LogFile>.device.txt.
    #
    # WHY THIS EXISTS. "flutter run" only prints for as long as it is
    # attached to the app it launched. A run arrived with 297 lines in it,
    # ending in the middle of the first video's decoder starting, followed
    # by "Application finished." — the app stopped being followed about two
    # seconds in. Everything the person then did was on a phone nothing was
    # listening to.
    #
    # adb logcat does not care. It records the phone, not one app process,
    # so it keeps going through an app being killed, restarted, or opened
    # again from the home screen.
    [switch]$Logcat,

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
if ($Logcat) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        Write-Host "adb was not found on your PATH, so -Logcat is skipped." -ForegroundColor Yellow
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
        Write-Host "Phone recording saved to $deviceLog" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "Full log saved to $LogFile" -ForegroundColor Cyan

    # The playback measurement lives on one line near the end of the run.
    # Pull it back out so it does not have to be hunted for in the file.
    $searchIn = @($LogFile)
    if ($Logcat -and (Test-Path -LiteralPath $deviceLog)) { $searchIn += $deviceLog }
    $stats = Select-String -LiteralPath $searchIn -SimpleMatch '[reel] starts=' |
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
