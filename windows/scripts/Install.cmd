@echo off
setlocal
rem Bootstrap always launches the bundle verifier on inbox Windows PowerShell
rem 5.1: it is the only host guaranteed present on a clean Windows 11 machine,
rem and Install-CaelestiaRelease.ps1 stays 5.1-compatible through verification.
rem After the bundle passes, the verifier locates or installs the verified x64
rem pwsh itself. Never run the first existing pwsh.exe: it may be a shim, a
rem symlink or an unsupported architecture.
set "CaelestiaPwsh=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%CaelestiaPwsh%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-CaelestiaRelease.ps1" %*
set "CaelestiaExit=%ERRORLEVEL%"
if not "%CaelestiaExit%"=="0" echo Caelestia installation failed. See the error above and INSTALL-RELEASE.md.
set "CaelestiaNoPause="
for %%A in (%*) do (
    if /I "%%~A"=="-NonInteractive" set "CaelestiaNoPause=1"
)
if not defined CaelestiaNoPause pause
exit /b %CaelestiaExit%
