@echo off
REM Makes a small copy of the phone's log from the last tools\run_profile.bat
REM run, small enough to open and to attach.
REM
REM   tools\shrink_phone_log.bat
REM   tools\shrink_phone_log.bat -PhoneLog F:\run2.txt.device.txt
REM
REM See tools\shrink_phone_log.ps1 for the options.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shrink_phone_log.ps1" %*
exit /b %ERRORLEVEL%
