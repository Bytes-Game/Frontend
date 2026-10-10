# Makes a log from an older version of run_profile small, in place. The log
# stays where it is, with the same name; nothing else is created.
#
# Usage, from the project folder (F:\devf):
#
#   tools\shrink_log.bat                        shrinks F:\logs.txt
#   tools\shrink_log.bat -LogFile F:\run2.txt   shrinks another one
#
# Older versions copied the phone's whole log into F:\logs.txt - once,
# 817,837 lines and a couple of hundred megabytes, too big to open or send -
# and left a second copy beside it, F:\logs.txt.device.txt. This shrinks the
# phone's part of the log the way run_profile now does at the end of every
# run (see phone_log.ps1), and removes that second copy once its lines are
# in the log.
#
# Keep this file plain ASCII. Windows PowerShell 5.1 misreads UTF-8 files
# that have no byte-order mark, which would corrupt the script.

param(
    [string]$LogFile = 'F:\logs.txt'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $projectRoot
. (Join-Path $PSScriptRoot 'phone_log.ps1')

$LogFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
if (-not (Test-Path -LiteralPath $LogFile -PathType Leaf)) {
    Write-Host "There is no log at $LogFile." -ForegroundColor Red
    Write-Host "Pass another with: tools\shrink_log.bat -LogFile <file>"
    exit 1
}
$oldCopy = "$LogFile.device.txt"

Write-Host "Shrinking $LogFile ($(Format-Size $LogFile))..." -ForegroundColor Cyan
try {
    $done = Invoke-ShrinkLog -LogFile $LogFile -OldPhoneLog $oldCopy -ProjectRoot $projectRoot
} catch {
    Write-Host "COULD NOT SHRINK IT: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  $LogFile is unchanged."
    exit 1
}

if ($done.Why) {
    Write-Host "Nothing to do: $($done.Why)." -ForegroundColor Cyan
} else {
    # Its lines are in the log now; the log is the one file.
    if (Test-Path -LiteralPath $oldCopy -PathType Leaf) {
        Remove-Item -LiteralPath $oldCopy -Force
        Write-Host "Removed $oldCopy - its lines are in $LogFile now." -ForegroundColor Cyan
    }
}

Write-Host ""
Show-SavedFile $LogFile
if ($done.Result) { Show-PhoneLogFindings $done.Result }
Write-Host ""
Write-Host "Attach $LogFile" -ForegroundColor Cyan
