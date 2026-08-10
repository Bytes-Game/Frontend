@echo off
REM Wrapper so run_profile.ps1 can be started from cmd.exe without worrying
REM about PowerShell's script-signing rules.
REM
REM   tools\run_profile.bat
REM   tools\run_profile.bat -Mode debug
REM   tools\run_profile.bat -LogFile F:\run2.txt
REM
REM See tools\run_profile.ps1 for the full list of options.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_profile.ps1" %*
exit /b %ERRORLEVEL%
