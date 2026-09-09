#requires -Version 5.1
# OBSback v1.3.1 - Launcher
param(
    [ValidateSet('Menu','Backup','Restore','Verify','SelfTest')]
    [string]$Action = 'Menu',
    [string]$BackupPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'ObsClone.Common.ps1')
$layout = Get-ObsBackToolLayout $PSScriptRoot
$script:ActionExitCode = 0

function Invoke-ObsBackAction([string]$SelectedAction) {
    $script:ActionExitCode = 0
    switch ($SelectedAction) {
        'Backup' {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'SelfTest-ObsClone.ps1') | Out-Host
            $script:ActionExitCode = $LASTEXITCODE
            if ($script:ActionExitCode -ne 0) {
                Write-Bad 'Самопроверка не пройдена. Создание бекапа остановлено.'
                return
            }
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Create-ObsBackup.ps1') | Out-Host
            $script:ActionExitCode = $LASTEXITCODE
        }
        'Restore' {
            # Keep the established UAC flow and restore engine for old backups.
            & (Join-Path $PSScriptRoot 'RESTORE_OBS.bat') | Out-Host
            $script:ActionExitCode = $LASTEXITCODE
        }
        'Verify' {
            $verifyArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Verify-ObsBackup.ps1'))
            if (-not [string]::IsNullOrWhiteSpace($BackupPath)) { $verifyArgs += @('-BackupRoot',$BackupPath) }
            & powershell.exe @verifyArgs | Out-Host
            $script:ActionExitCode = $LASTEXITCODE
        }
        'SelfTest' {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'SelfTest-ObsClone.ps1') | Out-Host
            $script:ActionExitCode = $LASTEXITCODE
        }
    }
}

try {
    if ($Action -ne 'Menu') {
        Invoke-ObsBackAction $Action
        exit $script:ActionExitCode
    }
    while ($true) {
        Write-Host ''
        Write-Info '================ OBSback v1.3.1 ================'
        Write-Host '  1  Создать бекап'
        Write-Host '  2  Восстановить бекап'
        Write-Host '  3  Проверить бекап'
        Write-Host '  4  Проверить работу инструмента'
        Write-Host '  5  Открыть папку настроек'
        Write-Host '  0  Выход'
        Write-Host ''
        $choice = Read-Host 'Выберите действие'
        if ($null -eq $choice -or $choice.Trim() -match '^(?i:0|q|exit)$') { exit 0 }
        switch ($choice.Trim()) {
            '1' { Invoke-ObsBackAction 'Backup' }
            '2' { Invoke-ObsBackAction 'Restore' }
            '3' { Invoke-ObsBackAction 'Verify' }
            '4' { Invoke-ObsBackAction 'SelfTest' }
            '5' {
                Start-Process -FilePath explorer.exe -ArgumentList ('"' + $layout.SettingsRoot + '"') | Out-Null
                continue
            }
            default { Write-Warn 'Введите число от 0 до 5.'; continue }
        }
        if ($script:ActionExitCode -ne 0) { Write-Warn "Действие завершилось с кодом $script:ActionExitCode." }
        [void](Read-Host 'Нажмите Enter, чтобы вернуться в меню')
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
