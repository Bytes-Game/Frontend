@echo off
REM Makes F:\logs.txt from an older run small enough to open and to attach,
REM in place. Nothing else is created.
REM
REM   tools\shrink_log.bat
REM   tools\shrink_log.bat -LogFile F:\run2.txt
REM
REM See tools\shrink_log.ps1 for what it does.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0shrink_log.ps1" %*
exit /b %ERRORLEVEL%
