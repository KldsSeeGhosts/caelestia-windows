@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CaelestiaRelease.ps1" %*
set "CaelestiaExit=%ERRORLEVEL%"
if not "%CaelestiaExit%"=="0" echo Caelestia installation failed. See the error above and INSTALL-RELEASE.md.
pause
exit /b %CaelestiaExit%
