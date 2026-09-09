#requires -Version 5.1
# OBS Full Clone Tool v1.3.1 - Verify extracted backup

param([string]$BackupRoot = $PSScriptRoot)

. (Join-Path $PSScriptRoot "ObsClone.Common.ps1")

try {
    if (-not $PSBoundParameters.ContainsKey('BackupRoot') -and -not (Test-Path -LiteralPath (Join-Path $BackupRoot 'backup_status.json') -PathType Leaf)) {
        Write-Info "Сначала распакуйте ZIP, затем укажите папку OBS_BACKUP_..."
        $BackupRoot = Read-Host 'Папка бекапа (Q — отмена)'
        if ([string]::IsNullOrWhiteSpace($BackupRoot) -or $BackupRoot.Trim() -match '^(?i:q|quit|exit)$') { exit 0 }
        $BackupRoot = $BackupRoot.Trim().Trim('"').Trim("'")
    }
    Write-Info "=== OBS FULL CLONE v1.3.1: ПРОВЕРКА BACKUP ==="
    Show-OverallProgress 2 "Проверка структуры и SHA-256"

    $result = Verify-BackupPackage `
        $BackupRoot `
        $true `
        $true

    if (-not $result.Success) {
        Complete-AllProgress

        Write-Host ""
        Write-Bad "SHA-256 / полная проверка не прошла:"
        foreach ($verifyError in @($result.Errors)) {
            Write-Bad ("  - " + [string]$verifyError)
        }

        $structureOnly = Verify-BackupPackage `
            $BackupRoot `
            $false `
            $true `
            @() `
            $true

        if (-not $structureOnly.Success) {
            throw (
                "Backup имеет не только SHA-ошибки. " +
                "Есть проблемы со структурой/размерами/обязательными файлами:`r`n" +
                (@($structureOnly.Errors) -join "`r`n")
            )
        }

        Write-Host ""
        Write-Warn "Структура и размеры backup выглядят корректно."
        Write-Warn "SHA-256 при этом НЕ подтверждена."

        while ($true) {
            $answer = (
                Read-Host "Пропустить SHA-256 и принять только структурную проверку? Y/N"
            ).Trim().ToUpperInvariant()

            if (
                $answer -eq "Y" -or
                $answer -eq "YES" -or
                $answer -eq "Д" -or
                $answer -eq "ДА"
            ) {
                Write-Host ""
                Write-Warn "=== BACKUP ПРОШЁЛ ТОЛЬКО СТРУКТУРНУЮ ПРОВЕРКУ ==="
                Write-Warn "SHA-256 ПРОПУЩЕНА ПО ПОДТВЕРЖДЕНИЮ ПОЛЬЗОВАТЕЛЯ."
                Write-Host "Проверено файлов: $($structureOnly.FileCount)"
                Write-Host "Объём данных: $(Format-Bytes $structureOnly.TotalBytes)"
                exit 0
            }

            if (
                $answer -eq "N" -or
                $answer -eq "NO" -or
                $answer -eq "Н" -or
                $answer -eq "НЕТ"
            ) {
                throw "Проверка отменена: SHA-256 не подтверждена."
            }

            Write-Warn "Введите Y или N."
        }
    }

    Show-OverallProgress 100 "Backup целостный"
    Complete-AllProgress

    Write-Host ""
    Write-Ok "=== BACKUP ЦЕЛОСТНЫЙ ==="
    Write-Host "Проверено файлов: $($result.FileCount)"
    Write-Host "Объём проверенных данных: $(Format-Bytes $result.TotalBytes)"
}
catch {
    Complete-AllProgress

    Write-Host ""
    Write-Bad "=== BACKUP НЕ ПРОШЁЛ ПРОВЕРКУ ==="
    Write-Bad $_.Exception.Message
    exit 1
}
