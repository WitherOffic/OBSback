#requires -Version 5.1
# OBS Full Clone Tool v1.3.1 - Restore

. (Join-Path $PSScriptRoot "ObsClone.Common.ps1")

$BackupRoot = $PSScriptRoot
$PayloadRoot = $null
$RollbackItems = New-Object System.Collections.ArrayList
$EnvironmentRollback = New-Object System.Collections.ArrayList
$TransactionStarted = $false
$StartedObsProcess = $null
$ShaVerificationSkipped = $false

function Test-ObsCloneBackupRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        $full = [IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        return $false
    }

    foreach ($name in @(
        "backup_status.json",
        "manifest.json",
        "file_manifest.json",
        "directory_manifest.json",
        "metadata_hashes.json"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $full $name) -PathType Leaf)) {
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $full "payload") -PathType Container)) {
        return $false
    }

    return $true
}

function Get-MissingBackupMarkerFiles([string]$Path) {
    $missing = New-Object System.Collections.ArrayList

    foreach ($name in @(
        "backup_status.json",
        "manifest.json",
        "file_manifest.json",
        "directory_manifest.json",
        "metadata_hashes.json",
        "payload"
    )) {
        $candidate = Join-Path $Path $name

        if (-not (Test-Path -LiteralPath $candidate)) {
            [void]$missing.Add($name)
        }
    }

    return @($missing)
}

function Resolve-BackupRootForRestore([string]$InitialPath) {
    if (Test-ObsCloneBackupRoot $InitialPath) {
        return [IO.Path]::GetFullPath($InitialPath)
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "      RESTORE ЗАПУЩЕН НЕ ИЗ ПАПКИ ГОТОВОГО BACKUP" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Warn "Это НЕ означает, что ваш backup повреждён."
    Write-Host ""
    Write-Info "Сейчас запущена папка инструмента:"
    Write-Host $InitialPath -ForegroundColor DarkYellow
    Write-Host ""
    Write-Info "Для Restore нужна папка вида:"
    Write-Host "C:\...\OBS_BACKUP_2026-...\\" -ForegroundColor Yellow
    Write-Host "В ней должны лежать manifest.json, backup_status.json, payload и RESTORE_OBS.bat."
    Write-Host ""
    Write-Info "Если у вас файл OBS_BACKUP_....zip:"
    Write-Host "1. Сначала распакуйте ZIP."
    Write-Host "2. Затем укажите РАСПАКОВАННУЮ папку OBS_BACKUP_...."
    Write-Host ""
    Write-Info "Можно перетащить нужную папку прямо в это окно и нажать Enter."
    Write-Host "Для выхода введите Q."
    Write-Host ""

    while ($true) {
        $inputPath = Read-Host "Путь к папке OBS_BACKUP_..."

        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            Write-Warn "Путь не введён."
            continue
        }

        $inputPath = $inputPath.Trim().Trim('"').Trim("'")

        if ($inputPath -match '^(?i)q|quit|exit$') {
            throw "Restore отменён пользователем до любых изменений."
        }

        if (
            (Test-Path -LiteralPath $inputPath -PathType Leaf) -and
            ([IO.Path]::GetExtension($inputPath) -ieq ".zip")
        ) {
            Write-Warn "Вы указали ZIP. Сначала распакуйте его, затем укажите папку OBS_BACKUP_...."
            continue
        }

        if (-not (Test-Path -LiteralPath $inputPath -PathType Container)) {
            Write-Bad "Папка не найдена: $inputPath"
            continue
        }

        $fullInput = [IO.Path]::GetFullPath($inputPath)

        if (Test-ObsCloneBackupRoot $fullInput) {
            Write-Ok "Backup найден:"
            Write-Host $fullInput -ForegroundColor Yellow
            return $fullInput
        }

        $missing = @(Get-MissingBackupMarkerFiles $fullInput)

        Write-Bad "Эта папка не является полным OBS Full Clone backup."
        if ($missing.Count -gt 0) {
            Write-Warn "Не хватает:"
            foreach ($item in $missing) {
                Write-Warn "  - $item"
            }
        }

        Write-Host ""
        Write-Info "Выберите именно распакованную папку OBS_BACKUP_..., а не папку самого tool."
    }
}

function Add-RollbackItem(
    [string]$CurrentPath,
    [string]$RollbackPath
) {
    [void]$RollbackItems.Add([PSCustomObject]@{
        CurrentPath = $CurrentPath
        RollbackPath = $RollbackPath
    })
}

function Replace-Insensitive(
    [string]$InputText,
    [string]$OldValue,
    [string]$NewValue
) {
    if ([string]::IsNullOrWhiteSpace($InputText)) {
        return $InputText
    }

    if ([string]::IsNullOrWhiteSpace($OldValue)) {
        return $InputText
    }

    $pattern = [regex]::Escape($OldValue)

    $evaluator = {
        param($match)
        return $NewValue
    }

    return [regex]::Replace(
        $InputText,
        $pattern,
        $evaluator,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Assert-RestorePathLengths(
    $FileManifest,
    [hashtable]$CategoryTargets,
    [int]$Limit = 235
) {
    $tooLong = New-Object System.Collections.ArrayList

    foreach ($file in $FileManifest) {
        $category = [string]$file.Category

        if (-not $CategoryTargets.ContainsKey($category)) {
            continue
        }

        $targetRoot = [string]$CategoryTargets[$category]
        $target = Join-Path $targetRoot ([string]$file.RelativePath)

        if ($target.Length -gt $Limit) {
            [void]$tooLong.Add($target)
        }
    }

    if ($tooLong.Count -gt 0) {
        throw (
            "Некоторые пути после Restore будут длиннее $Limit символов и могут не работать в Windows PowerShell 5.1.`r`n`r`n" +
            "КАК ИСПРАВИТЬ:`r`n" +
            "1. Установите OBS в более короткий путь, например C:\OBS\ или стандартный C:\Program Files\obs-studio\.`r`n" +
            "2. Распакуйте backup в короткий путь, например C:\OBSBackup\.`r`n" +
            "3. Запустите RESTORE_OBS.bat повторно.`r`n`r`n" +
            "Пути, которые не проходят проверку:`r`n" +
            (@($tooLong | Select-Object -First 10) -join "`r`n")
        )
    }
}

function Get-NewEnvironmentValue(
    $EnvironmentItem,
    $Manifest,
    [string]$NewObsRoot,
    [string]$NewConfigRoot,
    [string]$NewLocalConfigRoot,
    [string]$NewProgramDataRoot,
    [string]$NewUserProfile,
    [string]$CustomBase
) {
    $value = [string]$EnvironmentItem.Effective

    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    $value = Replace-Insensitive `
        $value `
        ([string]$Manifest.OriginalObsRoot) `
        $NewObsRoot

    $value = Replace-Insensitive `
        $value `
        ([string]$Manifest.OriginalConfigRoot) `
        $NewConfigRoot

    if ($Manifest.OriginalLocalConfigRoot) {
        $value = Replace-Insensitive `
            $value `
            ([string]$Manifest.OriginalLocalConfigRoot) `
            $NewLocalConfigRoot
    }

    if ($Manifest.OriginalProgramDataRoot) {
        $value = Replace-Insensitive `
            $value `
            ([string]$Manifest.OriginalProgramDataRoot) `
            $NewProgramDataRoot
    }

    if ($Manifest.OriginalUserProfile) {
        $value = Replace-Insensitive `
            $value `
            ([string]$Manifest.OriginalUserProfile) `
            $NewUserProfile
    }

    foreach ($custom in @($Manifest.CustomPluginPaths)) {
        $newCustomRoot = Join-Path `
            $CustomBase `
            (Join-Path ([string]$custom.Id) "root")

        $newComponent = $newCustomRoot

        if ($custom.ModuleSuffix) {
            $newComponent = Join-Path `
                $newCustomRoot `
                ([string]$custom.ModuleSuffix)
        }

        # Prefer replacing the original raw env component. This also works
        # when it contained %USERPROFILE% or another environment variable.
        if ($custom.OriginalComponent) {
            $value = Replace-Insensitive `
                $value `
                ([string]$custom.OriginalComponent) `
                $newComponent
        }

        # Fallback for already-expanded environment values.
        $value = Replace-Insensitive `
            $value `
            ([string]$custom.OriginalRoot) `
            $newCustomRoot
    }

    return $value
}

function Write-RestoreLogWarnings([string]$ConfigRoot) {
    $logsRoot = Join-Path $ConfigRoot "logs"

    if (-not (Test-Path -LiteralPath $logsRoot -PathType Container)) {
        return
    }

    $latestLog = Get-ChildItem `
        -LiteralPath $logsRoot `
        -File `
        -Filter "*.txt" `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestLog) {
        return
    }

    $patterns = @(
        "Failed to load module",
        "Failed to initialize module",
        "LoadLibrary failed",
        "Module.*not loaded",
        "Unable to load"
    )

    $hits = @()

    foreach ($pattern in $patterns) {
        $hits += @(
            Select-String `
                -LiteralPath $latestLog.FullName `
                -Pattern $pattern `
                -ErrorAction SilentlyContinue
        )
    }

    if ($hits.Count -gt 0) {
        Write-Warn "В новом OBS log есть строки загрузки модулей, которые стоит проверить:"

        foreach ($hit in @($hits | Select-Object -First 20)) {
            Write-Warn ("  " + $hit.Line.Trim())
        }
    }
}

if (-not (Test-IsAdministrator)) {
    Write-Bad "Restore запущен без прав администратора."
    Write-Warn "Запускайте RESTORE_OBS.bat — он сам откроет понятное UAC-окно."
    Write-Warn "Никакие данные не изменены."
    exit 5
}

try {
    Write-Info "=== OBS FULL CLONE v1.3.1: ВОССТАНОВЛЕНИЕ ==="


    Show-AuthorSupportBlock
    $BackupRoot = Resolve-BackupRootForRestore $PSScriptRoot
    $PayloadRoot = Join-Path $BackupRoot "payload"

    Write-Host ""
    Write-Info "ВОССТАНАВЛИВАЕМ ИЗ BACKUP:"
    Write-Host $BackupRoot -ForegroundColor Yellow
    Write-Host ""

    Show-OverallProgress 2 "Полная проверка backup до любых изменений"

    $restoreEngineMetadata = @(
        "RESTORE_OBS.bat",
        "Restore-ObsBackup.ps1",
        "ObsClone.Common.ps1",
        "ObsClone.Repair.ps1",
        "Verify-ObsBackup.ps1",
        "VERIFY_BACKUP.bat",
        "README_RU.txt",
        "AUDIT_RU.txt",
        "BUILD_AUDIT.txt"
    )

    Write-Info "Проверяю payload/Sources/manifests по SHA-256."
    Write-Info "Файлы самого Restore engine могут отличаться, если вы обновили tool."

    $verification = Verify-BackupPackage `
        $BackupRoot `
        $true `
        $true `
        $restoreEngineMetadata

    if (-not $verification.Success) {
        Write-Host ""
        Write-Bad "СТРОГАЯ SHA-256 ПРОВЕРКА BACKUP НЕ ПРОШЛА:"
        foreach ($verifyError in @($verification.Errors)) {
            Write-Bad ("  - " + [string]$verifyError)
        }

        Write-Host ""
        Write-Info "Проверяю, можно ли продолжить хотя бы по структуре и размерам..."

        $structuralVerification = Verify-BackupPackage `
            $BackupRoot `
            $false `
            $true `
            $restoreEngineMetadata `
            $true

        if (-not $structuralVerification.Success) {
            throw (
                "Ошибка НЕ ограничивается SHA-256. " +
                "Есть проблемы со структурой, обязательными файлами, JSON или размерами. " +
                "Пропуск SHA запрещён.`r`n" +
                (@($structuralVerification.Errors) -join "`r`n")
            )
        }

        Write-Host ""
        Write-Warn "ВНИМАНИЕ: структура backup и размеры файлов корректны,"
        Write-Warn "но криптографическая SHA-256 проверка не подтверждена."
        Write-Warn "Продолжение может восстановить повреждённые/изменённые данные."
        Write-Warn "Исходный backup НЕ удаляйте, пока не проверите восстановленный OBS."
        Write-Host ""

        while ($true) {
            $skipShaAnswer = (
                Read-Host "Пропустить SHA-256 и продолжить Restore? Y/N"
            ).Trim().ToUpperInvariant()

            if (
                $skipShaAnswer -eq "Y" -or
                $skipShaAnswer -eq "YES" -or
                $skipShaAnswer -eq "Д" -or
                $skipShaAnswer -eq "ДА"
            ) {
                $ShaVerificationSkipped = $true
                $verification = $structuralVerification
                Write-Warn "SHA-256 ПРОПУЩЕНА ПО ПОДТВЕРЖДЕНИЮ ПОЛЬЗОВАТЕЛЯ."
                break
            }

            if (
                $skipShaAnswer -eq "N" -or
                $skipShaAnswer -eq "NO" -or
                $skipShaAnswer -eq "Н" -or
                $skipShaAnswer -eq "НЕТ"
            ) {
                throw (
                    "Restore отменён пользователем из-за ошибки SHA-256. " +
                    "Ничего на компьютере не изменено."
                )
            }

            Write-Warn "Введите Y или N."
        }
    }

    if ($ShaVerificationSkipped) {
        Write-Warn (
            "Backup прошёл только структурную проверку: " +
            "$($verification.FileCount) файлов, " +
            "$(Format-Bytes $verification.TotalBytes). SHA-256 ПРОПУЩЕНА."
        )
    }
    else {
        Write-Ok (
            "Основные данные backup SHA-256 проверены: " +
            "$($verification.FileCount) файлов, " +
            "$(Format-Bytes $verification.TotalBytes)"
        )
    }

    Write-Warn (
        "Restore engine/docs не входят в строгую metadata-проверку во время Restore, " +
        "чтобы можно было безопасно использовать более новую версию Restore с более старым backup."
    )

    $Manifest = Read-JsonFile (
        Join-Path $BackupRoot "manifest.json"
    )

    $FileManifest = @(
        Read-JsonFile (
            Join-Path $BackupRoot "file_manifest.json"
        )
    )

    $DirectoryManifest = @(
        Read-JsonFile (
            Join-Path $BackupRoot "directory_manifest.json"
        )
    )

    if ([string]$Manifest.ToolVersion -notmatch '^1\.') {
        Write-Warn (
            "Backup создан другой основной версией tool: " +
            [string]$Manifest.ToolVersion
        )
    }
    else {
        Write-Info "Версия backup: $([string]$Manifest.ToolVersion)"
    }

    Show-OverallProgress 16 "Поиск целевой установки OBS"

    $TargetInstallation = Select-ObsInstallation "для восстановления"
    $TargetObsExe = [string]$TargetInstallation.ExePath
    $TargetObsRoot = [string]$TargetInstallation.Root

    if (Test-PathInside $BackupRoot $TargetObsRoot) {
        throw (
            "Backup находится внутри целевой папки OBS. " +
            "Restore удалил бы собственные файлы. Переместите backup в другое место."
        )
    }

    $SourceInstallType = Get-ObsBackupInstallationType $Manifest
    $AccountDataNotice = Get-ObsAccountDataNotice $Manifest
    if ($AccountDataNotice) { Write-Warn $AccountDataNotice }

    Write-Info "Backup создан из OBS типа: $SourceInstallType"
    Write-Info (
        "Выбранная целевая установка: " +
        [string]$TargetInstallation.Type +
        " | OBS " +
        [string]$TargetInstallation.Version
    )

    if (
        $SourceInstallType -ne
        [string]$TargetInstallation.Type
    ) {
        Write-Warn (
            "Тип исходной и целевой OBS отличается. " +
            "Restore восстановит выбранную установку до состояния backup."
        )
    }

    $TargetProgramData = "C:\\ProgramData\\obs-studio"
    $TargetLocalConfig = Join-Path $env:LOCALAPPDATA "obs-studio"

    if ([bool]$Manifest.IsPortable) {
        $TargetConfig = Join-Path $TargetObsRoot "config\\obs-studio"
    }
    else {
        $TargetConfig = Join-Path $env:APPDATA "obs-studio"
    }

    $RestoreBase = Join-Path $env:USERPROFILE "Documents\\OBS_Full_Clone"
    $RestoreSources = Join-Path $RestoreBase "Sources"
    $CustomBase = Join-Path $TargetProgramData "OBS_Full_Clone_Custom"

    Write-Ok "Целевой OBS: $TargetObsExe"
    Write-Ok "Тип целевой установки: $([string]$TargetInstallation.Type)"
    Write-Ok "Версия целевой установки: $([string]$TargetInstallation.Version)"
    Write-Ok "Была запущена при выборе: $([bool]$TargetInstallation.IsRunning)"
    Write-Ok "Целевой config: $TargetConfig"
    Write-Ok "Sources: $RestoreSources"

    $CategoryTargets = @{
        "ObsProgram" = $TargetObsRoot
        "Config" = $TargetConfig
        "LocalAppData" = $TargetLocalConfig
        "ProgramData" = $TargetProgramData
        "Sources" = $RestoreSources
    }

    foreach ($custom in @($Manifest.CustomPluginPaths)) {
        $CategoryTargets[[string]$custom.Id] = Join-Path `
            $CustomBase `
            (Join-Path ([string]$custom.Id) "root")
    }

    Assert-RestorePathLengths `
        $FileManifest `
        $CategoryTargets

    [Int64]$programBytes = 0
    [Int64]$configBytes = 0
    [Int64]$localBytes = 0
    [Int64]$programDataBytes = 0
    [Int64]$sourcesBytes = 0
    [Int64]$customBytes = 0

    foreach ($file in $FileManifest) {
        switch ([string]$file.Category) {
            "ObsProgram" {
                $programBytes += [Int64]$file.Size
            }
            "Config" {
                $configBytes += [Int64]$file.Size
            }
            "LocalAppData" {
                $localBytes += [Int64]$file.Size
            }
            "ProgramData" {
                $programDataBytes += [Int64]$file.Size
            }
            "Sources" {
                $sourcesBytes += [Int64]$file.Size
            }
            default {
                if ([string]$file.Category -like "CustomPluginPath*") {
                    $customBytes += [Int64]$file.Size
                }
            }
        }
    }

    $HasLocalCategory = (
        @($FileManifest | Where-Object { $_.Category -eq "LocalAppData" }).Count -gt 0 -or
        @($DirectoryManifest | Where-Object { $_.Category -eq "LocalAppData" }).Count -gt 0
    )

    $HasProgramDataCategory = (
        @($FileManifest | Where-Object { $_.Category -eq "ProgramData" }).Count -gt 0 -or
        @($DirectoryManifest | Where-Object { $_.Category -eq "ProgramData" }).Count -gt 0
    )

    Show-OverallProgress 20 "Проверка свободного места"

    Assert-FreeSpace `
        $TargetObsRoot `
        $programBytes `
        "OBS program snapshot"

    if (-not [bool]$Manifest.IsPortable) {
        Assert-FreeSpace `
            $TargetConfig `
            $configBytes `
            "OBS config"
    }

    if ($HasLocalCategory) {
        Assert-FreeSpace `
            $TargetLocalConfig `
            $localBytes `
            "OBS LocalAppData"
    }

    Assert-FreeSpace `
        $TargetProgramData `
        ($programDataBytes + $customBytes) `
        "OBS ProgramData/plugins"

    Assert-FreeSpace `
        $RestoreSources `
        $sourcesBytes `
        "OBS Sources"

    Show-OverallProgress 24 "Остановка OBS"
    Stop-ObsSafely $TargetObsExe
    Stop-ObsInstallationsUsingConfig $TargetConfig

    if (
        (Test-ObsRunning $TargetObsExe) -or
        (Test-ObsConfigInUse $TargetConfig)
    ) {
        throw (
            "Целевая OBS или другой экземпляр OBS всё ещё использует " +
            "config, который требуется восстановить."
        )
    }

    foreach ($environmentName in @(
        "OBS_PLUGINS_PATH",
        "OBS_PLUGINS_DATA_PATH"
    )) {
        [void]$EnvironmentRollback.Add([PSCustomObject]@{
            Name = $environmentName
            UserValue = [Environment]::GetEnvironmentVariable(
                $environmentName,
                "User"
            )
        })
    }

    $rollbackTag = Get-Date -Format "yyyyMMddHHmmss"

    Show-OverallProgress 27 "Создание rollback текущего состояния"

    # Rollback must be armed BEFORE the first mutation.
    $TransactionStarted = $true

    $oldObsRoot = Rename-ForRollback `
        $TargetObsRoot `
        $rollbackTag

    Add-RollbackItem $TargetObsRoot $oldObsRoot

    if (-not [bool]$Manifest.IsPortable) {
        $oldConfig = Rename-ForRollback `
            $TargetConfig `
            $rollbackTag

        Add-RollbackItem $TargetConfig $oldConfig
    }

    $oldLocal = Rename-ForRollback `
        $TargetLocalConfig `
        $rollbackTag

    Add-RollbackItem $TargetLocalConfig $oldLocal

    $oldProgramData = Rename-ForRollback `
        $TargetProgramData `
        $rollbackTag

    Add-RollbackItem $TargetProgramData $oldProgramData

    $oldSources = Rename-ForRollback `
        $RestoreSources `
        $rollbackTag

    Add-RollbackItem $RestoreSources $oldSources

    Show-OverallProgress 32 "Восстановление полного снимка OBS"

    Copy-BackupCategoryToTarget `
        $BackupRoot `
        $FileManifest `
        $DirectoryManifest `
        "ObsProgram" `
        $TargetObsRoot `
        "OBS Studio + plugins"

    if ([bool]$Manifest.IsPortable) {
        # Make portable mode deterministic even if backup originally used only --portable.
        $portableMarker = Join-Path $TargetObsRoot "portable_mode.txt"

        if (-not (Test-Path -LiteralPath $portableMarker -PathType Leaf)) {
            [IO.File]::WriteAllText(
                $portableMarker,
                "OBS Full Clone v1.3.1 portable restore`r`n",
                (New-Object Text.UTF8Encoding($false))
            )
        }
    }

    Show-OverallProgress 50 "Восстановление config OBS"

    Copy-BackupCategoryToTarget `
        $BackupRoot `
        $FileManifest `
        $DirectoryManifest `
        "Config" `
        $TargetConfig `
        "OBS config"

    if ($HasLocalCategory) {
        Show-OverallProgress 58 "Восстановление LocalAppData OBS"

        Copy-BackupCategoryToTarget `
            $BackupRoot `
            $FileManifest `
            $DirectoryManifest `
            "LocalAppData" `
            $TargetLocalConfig `
            "OBS LocalAppData"
    }

    if ($HasProgramDataCategory) {
        Show-OverallProgress 64 "Восстановление ProgramData/plugins"

        Copy-BackupCategoryToTarget `
            $BackupRoot `
            $FileManifest `
            $DirectoryManifest `
            "ProgramData" `
            $TargetProgramData `
            "OBS ProgramData"
    }
    else {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $TargetProgramData |
            Out-Null
    }

    Show-OverallProgress 70 "Восстановление единой папки Sources"

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $RestoreBase |
        Out-Null

    Copy-BackupCategoryToTarget `
        $BackupRoot `
        $FileManifest `
        $DirectoryManifest `
        "Sources" `
        $RestoreSources `
        "OBS Sources"

    if (@($Manifest.CustomPluginPaths).Count -gt 0) {
        Show-OverallProgress 78 "Восстановление custom plugin paths"

        foreach ($custom in @($Manifest.CustomPluginPaths)) {
            $targetCustomRoot = Join-Path `
                $CustomBase `
                (Join-Path ([string]$custom.Id) "root")

            Copy-BackupCategoryToTarget `
                $BackupRoot `
                $FileManifest `
                $DirectoryManifest `
                ([string]$custom.Id) `
                $targetCustomRoot `
                "Custom OBS plugin path"
        }
    }

    Show-OverallProgress 84 "Перепривязка путей Sources и plugin paths"

    foreach ($asset in @($Manifest.ExternalAssets)) {
        $oldPath = [string]$asset.OriginalPath
        $newPath = Join-Path `
            $RestoreSources `
            ([string]$asset.StoredRelative)

        if (-not (Test-Path -LiteralPath $newPath)) {
            throw "После Restore отсутствует source: $newPath"
        }

        if ([string]$asset.Type -eq "Directory") {
            foreach ($rewriteRoot in @(
                (Join-Path $TargetConfig "basic\scenes"),
                (Join-Path $TargetConfig "plugin_config")
            )) {
                if (Test-Path -LiteralPath $rewriteRoot -PathType Container) {
                    Replace-PathInTextConfigs `
                        $rewriteRoot `
                        $oldPath `
                        $newPath
                }
            }
        }
        else {
            # Exact file-path replacement is safe across the entire config.
            Replace-PathInTextConfigs `
                $TargetConfig `
                $oldPath `
                $newPath
        }

        # Rewrite absolute paths inside copied playlists/local web/scripts too.
        Replace-PathInTextConfigs `
            $RestoreSources `
            $oldPath `
            $newPath `
            @(
                ".m3u",
                ".m3u8",
                ".html",
                ".htm",
                ".css",
                ".js",
                ".lua",
                ".py"
            )
    }

    Replace-PathInTextConfigs `
        $TargetConfig `
        ([string]$Manifest.OriginalObsRoot) `
        $TargetObsRoot

    Replace-PathInTextConfigs `
        $TargetConfig `
        ([string]$Manifest.OriginalConfigRoot) `
        $TargetConfig

    if ($Manifest.OriginalLocalConfigRoot) {
        Replace-PathInTextConfigs `
            $TargetConfig `
            ([string]$Manifest.OriginalLocalConfigRoot) `
            $TargetLocalConfig
    }

    if ($Manifest.OriginalUserProfile) {
        Replace-PathInTextConfigs `
            $TargetConfig `
            ([string]$Manifest.OriginalUserProfile) `
            $env:USERPROFILE
    }

    # Restore the effective custom OBS plugin environment values, remapped to new paths.
    foreach ($environmentItem in @($Manifest.ObsEnvironment)) {
        $newValue = Get-NewEnvironmentValue `
            $environmentItem `
            $Manifest `
            $TargetObsRoot `
            $TargetConfig `
            $TargetLocalConfig `
            $TargetProgramData `
            $env:USERPROFILE `
            $CustomBase

        [Environment]::SetEnvironmentVariable(
            [string]$environmentItem.Name,
            $newValue,
            "User"
        )

        if ($newValue) {
            Write-Info (
                [string]$environmentItem.Name +
                " -> " +
                $newValue
            )
        }
    }

    # Teleport remains intentionally absent.
    Remove-Item `
        -LiteralPath (Join-Path $TargetConfig "plugin_config\\obs-teleport") `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath (Join-Path $TargetObsRoot "obs-plugins\\64bit\\obs-teleport.dll") `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath (Join-Path $TargetObsRoot "data\\obs-plugins\\obs-teleport") `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath (Join-Path $TargetProgramData "plugins\\obs-teleport") `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Get-ChildItem `
        -LiteralPath $TargetConfig `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @(
                ".sentinel",
                "safe_mode"
            )
        } |
        Sort-Object { $_.FullName.Length } -Descending |
        ForEach-Object {
            Remove-Item `
                -LiteralPath $_.FullName `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

    $mapSource = Join-Path $BackupRoot "SOURCE_MAP.txt"

    if (Test-Path -LiteralPath $mapSource -PathType Leaf) {
        Copy-Item `
            -LiteralPath $mapSource `
            -Destination (Join-Path $RestoreBase "SOURCE_MAP.txt") `
            -Force
    }

    # A backup downloaded from cloud/browser may inherit Mark-of-the-Web.
    # Remove Zone.Identifier from restored executables/DLLs so OBS can load plugins normally.
    foreach ($unblockRoot in @(
        $TargetObsRoot,
        $TargetProgramData
    )) {
        if (Test-Path -LiteralPath $unblockRoot -PathType Container) {
            Get-ChildItem `
                -LiteralPath $unblockRoot `
                -Recurse `
                -File `
                -Force `
                -ErrorAction SilentlyContinue |
                Unblock-File -ErrorAction SilentlyContinue
        }
    }

    Show-OverallProgress 89 "Проверка переписанного config JSON"

    $jsonValidation = Test-JsonFilesValid $TargetConfig

    if (-not $jsonValidation.Success) {
        throw (
            "После перепривязки путей JSON-конфиги повреждены:`r`n" +
            (@($jsonValidation.Errors) -join "`r`n")
        )
    }

    foreach ($asset in @($Manifest.ExternalAssets)) {
        $newPath = Join-Path `
            $RestoreSources `
            ([string]$asset.StoredRelative)

        if (-not (Test-Path -LiteralPath $newPath)) {
            throw "Финальная проверка Sources: отсутствует $newPath"
        }
    }

    $RestoredObsExe = Join-Path $TargetObsRoot "bin\\64bit\\obs64.exe"
    $RestoredObsWorkingDirectory = Join-Path $TargetObsRoot "bin\\64bit"
    $RestoredObsLocaleFile = Join-Path `
        $TargetObsRoot `
        "data\\obs-studio\\locale\\en-US.ini"

    if (-not (Test-Path -LiteralPath $RestoredObsExe -PathType Leaf)) {
        throw "В полном снимке не найден obs64.exe: $RestoredObsExe"
    }

    if (
        -not (Test-Path `
            -LiteralPath $RestoredObsWorkingDirectory `
            -PathType Container)
    ) {
        throw (
            "Не найдена рабочая папка OBS: " +
            $RestoredObsWorkingDirectory
        )
    }

    if (-not (Test-Path -LiteralPath $RestoredObsLocaleFile -PathType Leaf)) {
        throw (
            "В восстановленном OBS отсутствует обязательный locale-файл: " +
            $RestoredObsLocaleFile
        )
    }

    if ($Manifest.ObsVersion) {
        try {
            $restoredVersion = (
                Get-Item -LiteralPath $RestoredObsExe
            ).VersionInfo.FileVersion

            if (
                $restoredVersion -and
                [string]$restoredVersion -ne [string]$Manifest.ObsVersion
            ) {
                throw (
                    "Версия восстановленного obs64.exe не совпала. " +
                    "Backup=$($Manifest.ObsVersion), Restore=$restoredVersion"
                )
            }
        }
        catch {
            if ($_.Exception.Message -like "Версия восстановленного*") {
                throw
            }
        }
    }

    Show-OverallProgress 94 "Тестовый запуск OBS перед удалением rollback"

    $launchArguments = New-Object System.Collections.ArrayList

    if ([bool]$Manifest.IsPortable) {
        [void]$launchArguments.Add("--portable")
    }

    $originalCommand = [string]$Manifest.OriginalLaunchCommandLine

    if (
        $TargetObsRoot -match '(?i)\\steamapps\\common\\OBS Studio(?:\\|$)' -and
        $originalCommand -match '(?i)(?:^|\s)--steam(?:\s|$)'
    ) {
        [void]$launchArguments.Add("--disable-updater")
        [void]$launchArguments.Add("--steam")
    }

    if ($launchArguments.Count -gt 0) {
        Write-Info (
            "Тестовый запуск OBS с аргументами: " +
            (@($launchArguments) -join " ")
        )
    }
    else {
        Write-Info "Тестовый запуск OBS без дополнительных аргументов."
    }

    Write-Info (
        "Рабочая папка запуска OBS: " +
        $RestoredObsWorkingDirectory
    )

    if ($launchArguments.Count -gt 0) {
        $StartedObsProcess = Start-Process `
            -FilePath $RestoredObsExe `
            -WorkingDirectory $RestoredObsWorkingDirectory `
            -ArgumentList @($launchArguments) `
            -PassThru
    }
    else {
        $StartedObsProcess = Start-Process `
            -FilePath $RestoredObsExe `
            -WorkingDirectory $RestoredObsWorkingDirectory `
            -PassThru
    }

    Start-Sleep -Seconds 5

    if ($StartedObsProcess.HasExited) {
        throw (
            "Восстановленный OBS завершился сразу после запуска. " +
            "Rollback будет выполнен автоматически."
        )
    }

    Write-RestoreLogWarnings $TargetConfig

    Show-OverallProgress 98 "Фиксация Restore"

    # Only now, after verified copy + valid JSON + live OBS process, remove old data.
    foreach ($rollbackItem in $RollbackItems) {
        $oldPath = [string]$rollbackItem.RollbackPath

        if (
            $oldPath -and
            (Test-Path -LiteralPath $oldPath)
        ) {
            try {
                Remove-Item `
                    -LiteralPath $oldPath `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                Write-Warn (
                    "Restore успешен, но не удалось удалить rollback-папку: " +
                    "$oldPath :: $($_.Exception.Message)"
                )
            }
        }
    }

    $TransactionStarted = $false

    Show-OverallProgress 100 "Готово"
    Complete-AllProgress

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "             OBS УСПЕШНО ВОССТАНОВЛЕН" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Ok "Restore завершён. OBS запущен и прошёл контрольный запуск."

    if ($ShaVerificationSkipped) {
        Write-Host ""
        Write-Warn "ВАЖНО: этот Restore был выполнен БЕЗ успешной SHA-256 проверки."
        Write-Warn "Не удаляйте исходный backup до ручной проверки сцен, плагинов и Sources."
    }

    Write-Host ""
    Write-Info "Локальные файлы OBS восстановлены сюда:"
    Write-Host $RestoreSources -ForegroundColor Yellow
    Write-Host ""
    if ($AccountDataNotice) { Write-Warn $AccountDataNotice }
    Write-Info "ЧТО ДЕЛАТЬ ДАЛЬШЕ:"
    Write-Host "1. Проверьте сцены, микрофоны, камеры и Browser Sources в OBS."
    Write-Host "2. Если OBS покажет Missing Files:"
    Write-Host "   Search Directory... -> укажите папку Sources выше."
    Write-Host "3. После проверки можно закрыть это окно."
    Write-Host "============================================================" -ForegroundColor Green

    Show-AuthorSupportBlock
    Open-AuthorPagesPrompt
}
catch {
    Complete-AllProgress

    Write-Host ""
    Write-Bad "RESTORE ERROR: $($_.Exception.Message)"

    if ($StartedObsProcess) {
        try {
            if (-not $StartedObsProcess.HasExited) {
                Stop-Process `
                    -Id $StartedObsProcess.Id `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    if ($TransactionStarted) {
        Write-Warn "Запускаю автоматический rollback..."

        Stop-ObsSafely

        for ($index = $RollbackItems.Count - 1; $index -ge 0; $index--) {
            $item = $RollbackItems[$index]

            Restore-RollbackPath `
                ([string]$item.CurrentPath) `
                ([string]$item.RollbackPath)
        }

        foreach ($environmentItem in $EnvironmentRollback) {
            try {
                [Environment]::SetEnvironmentVariable(
                    [string]$environmentItem.Name,
                    $environmentItem.UserValue,
                    "User"
                )
            }
            catch {}
        }

        Write-Warn "Rollback завершён. Старое состояние восстановлено настолько полно, насколько позволила файловая система."
    }
    else {
        Write-Warn "Изменения ещё не были начаты; rollback не требуется."
    }

    exit 1
}
