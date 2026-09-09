@echo off
setlocal
cd /d "%~dp0"

rem Check administrator rights before PowerShell restore starts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id); if($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"

if errorlevel 1 (
    echo.
    echo ============================================================
    echo   RESTORE NEEDS ADMINISTRATOR RIGHTS
    echo ============================================================
    echo UAC will open now.
    echo After you press YES, a NEW administrator window will appear
    echo and the Restore output will be shown there.
    echo.
    set "OBSCLONE_RESTORE_BAT=%~f0"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$bat=$env:OBSCLONE_RESTORE_BAT; try { Start-Process -FilePath $env:ComSpec -Verb RunAs -ArgumentList @('/d','/c',('""{0}""' -f $bat)); exit 0 } catch { Write-Host ('UAC start failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"
    if errorlevel 1 (
        echo.
        echo UAC was cancelled or the administrator window could not be started.
        echo Run RESTORE_OBS.bat again and press YES in UAC.
        echo.
        pause
    )
    exit /b
)

echo.
echo ============================================================
echo   OBS FULL CLONE - RESTORE
echo ============================================================
echo Administrator rights: OK
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Restore-ObsBackup.ps1"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo Restore finished with error code %RC%.
)
pause
exit /b %RC%
