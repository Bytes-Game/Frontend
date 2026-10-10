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
# The phone's own log is captured as well, ALWAYS, and goes into the same
# file - so there is one file to read and one file to send. Every line of
# it, straight into the log as the phone writes it: no copy anywhere, no
# temp file, nothing shrunk or left out (see phone_log.ps1).
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
    # followed by "Application finished." - the app stopped being followed
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

# Shrinking the phone's log, and reporting what was saved. Shared with
# shrink_phone_log.ps1.
. (Join-Path $PSScriptRoot 'phone_log.ps1')

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
# A full path: the file is written by .NET, which would read a short path
# from the folder PowerShell started in rather than this one.
$LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)

# Older versions left the phone's whole log next to this one as a second
# file. Everything in it went into the log as well, so it is only clutter -
# and the log is meant to be the one file.
$leftOver = "$LogFile.device.txt"
if (Test-Path -LiteralPath $leftOver -PathType Leaf) {
    Remove-Item -LiteralPath $leftOver -Force
    Write-Host "Removed $leftOver, left by an older version of this script." -ForegroundColor Yellow
}

# Logs used to be written in UTF-16. Adding UTF-8 to the end of one of
# those garbles everything after the join, so an old one is turned into
# UTF-8 first, in place - not moved aside into a second file.
if ($Append -and (Test-Path -LiteralPath $LogFile -PathType Leaf)) {
    $head = New-Object byte[] 2
    $stream = [System.IO.File]::OpenRead($LogFile)
    $read = $stream.Read($head, 0, 2)
    $stream.Dispose()
    if ($read -eq 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
        $text = [System.IO.File]::ReadAllText($LogFile)
        [System.IO.File]::WriteAllText($LogFile, $text, (New-Object System.Text.UTF8Encoding($true)))
        $text = $null
        Write-Host "The old log was in the old format; it is now UTF-8, so this run can be added." -ForegroundColor Yellow
    }
}

$flutterArgs = @('run', "--$Mode") + $Extra

# Notifications outside the app (new messages, missed calls) need this
# app's Firebase values - see README, "Phone notifications". They live in
# firebase_push.json next to pubspec.yaml and are passed in when it is there.
if (Test-Path -LiteralPath (Join-Path $projectRoot 'firebase_push.json')) {
    $flutterArgs += '--dart-define-from-file=firebase_push.json'
}

# One writer, in UTF-8, for everything: what flutter prints and the
# phone's log, a whole line at a time (phone_log.ps1).
#
# This used to be Tee-Object, which on Windows PowerShell 5.1 writes UTF-16:
# two bytes for every letter. UTF-8 is half the size, opens anywhere, and
# is what adb writes the phone's log in.
$tools = $true
try {
    Import-LogTools
} catch {
    $tools = $false
    Write-Host "COULD NOT LOAD THE LOG TOOLS: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  flutter's output is still saved; the phone's log will not be." -ForegroundColor Red
}
function Open-Log([string]$Path, [bool]$Add) {
    if ($tools) { return New-Object BattleArena.RunLog($Path, $Add) }
    $writer = New-Object System.IO.StreamWriter($Path, $Add, (New-Object System.Text.UTF8Encoding($true)))
    $writer.AutoFlush = $true
    return $writer
}
try {
    $log = Open-Log $LogFile ([bool]$Append)
} catch {
    # Most often: the old log is open in another program that holds on to
    # it. Better a log somewhere else than no log.
    $fallback = Join-Path $projectRoot 'logs.txt'
    Write-Host "Could not write to $LogFile ($($_.Exception.Message))." -ForegroundColor Yellow
    Write-Host "Writing to $fallback instead." -ForegroundColor Yellow
    $LogFile = $fallback
    $log = Open-Log $LogFile ([bool]$Append)
}

foreach ($line in @(
    '',
    '=============================================================',
    "flutter $($flutterArgs -join ' ')",
    "started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    '============================================================='
)) {
    $log.WriteLine($line)
    Write-Host $line
}

# Start the phone-side recording before the app launches, so nothing from
# the first seconds is missed. Its lines go straight into the log as adb
# writes them, and it is stopped in the finally block below whatever
# happens.
$phone = $null
$wantLogcat = -not $NoLogcat

# Where adb is. If flutter can reach the phone, adb is on this computer:
# flutter uses it. It is just often not on PATH, and looking only there
# turned the phone-side recording off on a computer that had adb all along.
# So look where flutter looks: the Android SDK folder flutter writes into
# android\local.properties when it builds, then the usual settings and the
# folder Android Studio installs to.
function Get-AdbCandidates {
    $sdks = @()
    $props = Join-Path $projectRoot 'android\local.properties'
    if (Test-Path -LiteralPath $props) {
        foreach ($line in Get-Content -LiteralPath $props) {
            if ($line -match '^\s*sdk\.dir\s*=\s*(.+?)\s*$') {
                # The file escapes ':' and '\' with a backslash:
                # sdk.dir=C\:\\Users\\me\\AppData\\Local\\Android\\Sdk
                $sdks += ($matches[1] -replace '\\(.)', '$1')
            }
        }
    }
    $sdks += @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    if ($env:LOCALAPPDATA) {
        $sdks += [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Android', 'Sdk')
    }
    foreach ($sdk in $sdks) {
        # Quotes typed into a Windows setting stay part of its value.
        if ($sdk) { $sdk = $sdk.Trim().Trim('"') }
        if ($sdk) {
            # Path.Combine, not Join-Path: Join-Path throws when the folder
            # is on a drive this computer does not have, which a copied or
            # stale local.properties can easily name.
            [System.IO.Path]::Combine($sdk, 'platform-tools', 'adb.exe')
            [System.IO.Path]::Combine($sdk, 'platform-tools', 'adb')
        }
    }
}

function Find-Adb {
    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($candidate in Get-AdbCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

if ($wantLogcat) {
    $adb = Find-Adb
    if (-not $adb) {
        Write-Host "adb was not found, so the phone-side recording is off. Looked on PATH and in:" -ForegroundColor Yellow
        foreach ($candidate in Get-AdbCandidates) {
            Write-Host "  $candidate"
        }
        Write-Host "It ships with Android Studio, in the SDK's platform-tools folder."
    } else {
        Write-Host "Using adb at $adb" -ForegroundColor Cyan
        # -c clears whatever the phone was already holding, so the file
        # starts at this run rather than at some earlier one.
        & $adb logcat -c 2>&1 | Out-Null
        if (-not $tools) {
            Write-Host "The phone-side recording is off: the log tools did not load (above)." -ForegroundColor Red
        } else {
            try {
                $phone = [BattleArena.PhoneRecorder]::Start($adb, $log)
                Write-Host "Also recording the phone, straight into $LogFile" -ForegroundColor Cyan
            } catch {
                Write-Host "COULD NOT START THE PHONE RECORDING: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

Write-Host "Logging to $LogFile" -ForegroundColor Cyan

try {
    # 2>&1 folds the error stream in so warnings are captured too. Native
    # commands surface those as ErrorRecord objects, which the file writer
    # would expand into several lines of PowerShell diagnostics, so flatten
    # every item to its own text first, then write it to the file and pass
    # it on to the screen.
    #
    # Read the message off the exception rather than calling ToString() on
    # the record: a blank line on stderr produces a record with an empty
    # message, and ToString() falls back to printing the exception's type
    # name, so every blank line in the log came out as a wall of
    # "System.Management.Automation.RemoteException".
    & flutter @flutterArgs 2>&1 |
        ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $line = $_.Exception.Message
            } else {
                $line = "$_"
            }
            $log.WriteLine($line)
            $line
        }
} finally {
    [Console]::OutputEncoding = $previousOutputEncoding

    # Stop the phone's recording first, and wait for the last of its lines
    # to be in the log - stopping adb does not mean they have been read -
    # then close the log.
    if ($phone) {
        $phone.Stop()
        Write-Host ""
        Write-Host "Phone log: $(Format-Count $phone.Lines) lines, written straight into $LogFile" -ForegroundColor Cyan
        if ($phone.Failure) {
            Write-Host "  THE PHONE RECORDING STOPPED EARLY: $($phone.Failure)" -ForegroundColor Red
        }
    }
    $log.Dispose()

    # What is really on disk, read back - not a message printed whatever
    # happened. "Full log saved" used to be said about a file nobody could
    # use.
    Write-Host ""
    Show-SavedFile $LogFile
    if ($tools -and (Test-Path -LiteralPath $LogFile -PathType Leaf)) {
        try {
            $found = [BattleArena.PhoneLog]::Scan($LogFile, (Get-AppId $projectRoot), 25)
            $recorded = -1
            if ($phone -and -not $Append) { $recorded = $phone.Lines }
            Show-PhoneLogFindings $found $recorded
        } catch {
            Write-Host "COULD NOT READ THE LOG BACK: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # The playback measurement lives on one line near the end of the run.
    # Pull it back out so it does not have to be hunted for in the file.
    # The phone's lines are in the same file, so this sees them too.
    $searchIn = @($LogFile)
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
        Write-Host "  watch videos, the log stopped following the app. The phone's"
        Write-Host "  own log, folded in above when adb was found, keeps"
        Write-Host "  recording regardless."
    }
}
