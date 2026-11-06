@echo off
setlocal

echo [1] Starting Browser Time Tracker installer
echo     This launcher runs PowerShell with -ExecutionPolicy Bypass for this process only.
echo     Working directory: %~dp0

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set EXIT_CODE=%ERRORLEVEL%

if not "%EXIT_CODE%"=="0" (
  echo ERROR: Browser Time Tracker installer failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo.
echo [DONE] Browser Time Tracker installer finished.
endlocal
