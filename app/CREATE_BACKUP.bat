@echo off
setlocal
cd /d "%~dp0"
echo Running OBS Full Clone self-test...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SelfTest-ObsClone.ps1"
if errorlevel 1 (
  echo.
  echo SELF-TEST FAILED. Backup was not started.
  pause
  exit /b 1
)
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create-ObsBackup.ps1"
echo.
pause
