# Makes a small copy of a phone log that run_profile already saved - small
# enough to open in Notepad and to attach.
#
# Usage, from the project folder (F:\devf):
#
#   tools\shrink_phone_log.bat
#       reads  F:\logs.txt.device.txt  (the phone's log from the last run)
#       writes F:\logs.small.txt
#
#   tools\shrink_phone_log.bat -PhoneLog F:\run2.txt.device.txt -Out F:\run2.small.txt
#
# The phone's log keeps every line the app printed, and every line about a
# crash or an app not responding. Repeated lines from the rest of the
# phone are counted instead of copied. See phone_log.ps1 for exactly what
# is kept.
#
# Keep this file plain ASCII. Windows PowerShell 5.1 misreads UTF-8 files
# that have no byte-order mark, which would corrupt the script.

param(
    [string]$PhoneLog = 'F:\logs.txt.device.txt',
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
. (Join-Path $PSScriptRoot 'phone_log.ps1')

$PhoneLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PhoneLog)
if (-not (Test-Path -LiteralPath $PhoneLog -PathType Leaf)) {
    Write-Host "There is no phone log at $PhoneLog." -ForegroundColor Red
    Write-Host "tools\run_profile.bat writes one next to the main log, ending in .device.txt."
    Write-Host "Pass a different one with: tools\shrink_phone_log.bat -PhoneLog <file>"
    exit 1
}

# F:\logs.txt.device.txt -> F:\logs.small.txt
if (-not $Out) {
    $name = [System.IO.Path]::GetFileName($PhoneLog)
    if ($name.EndsWith('.device.txt')) { $name = $name.Substring(0, $name.Length - '.device.txt'.Length) }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $Out = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($PhoneLog), "$name.small.txt")
}
$Out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
if ($Out -eq $PhoneLog) {
    Write-Host "-Out is the phone log itself. Pick another file, or the log would be overwritten." -ForegroundColor Red
    exit 1
}

Write-Host "Reading $PhoneLog ($(Format-Size $PhoneLog))..." -ForegroundColor Cyan
try {
    $found = Add-PhoneLog -PhoneLog $PhoneLog -Into $Out -Append $false -ProjectRoot $projectRoot
} catch {
    Write-Host "COULD NOT SHRINK THE PHONE LOG: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Zip $PhoneLog (right-click, Send to > Compressed (zipped) folder) and attach the zip."
    exit 1
}

Write-Host ""
Show-SavedFile $Out
Show-PhoneLogFindings $found $PhoneLog
Write-Host ""
Write-Host "Attach $Out" -ForegroundColor Cyan
