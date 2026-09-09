#requires -Version 5.1
# OBS Full Clone Tool v1.3.1 - Non-destructive self test
param([switch]$Detailed)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

# Capture the existing diagnostics in a child process, including direct console
# progress writes. The same full test suite runs in both display modes.
if (-not $Detailed) {
    $process = $null
    try {
        Write-Host 'Проверка инструмента...' -ForegroundColor Cyan
        $logDirectory = Join-Path $env:LOCALAPPDATA 'OBSback\Logs'
        [void][IO.Directory]::CreateDirectory($logDirectory)
        $logPath = Join-Path $logDirectory 'self-test.log'
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $PSHOME 'powershell.exe'
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Detailed'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.RedirectStandardInput = $true
        $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
        $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        [void]$process.Start()
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $details = $stdout.Result + $stderr.Result
        [IO.File]::WriteAllText($logPath,((Get-Date).ToString('o') + "`r`n" + $details),(New-Object Text.UTF8Encoding($true)))
        if ($process.ExitCode -eq 0 -and $details.Contains('SELF-TEST PASSED')) {
            Write-Host 'Проверка пройдена. Ошибок нет.' -ForegroundColor Green
            exit 0
        }
        $failure = [regex]::Match($details,'(?m)^SELF-TEST FAIL: ([^\r\n]+)')
        $reason = 'Не удалось завершить все проверки.'
        if ($failure.Success) { $reason = $failure.Groups[1].Value }
        if ($reason.Length -gt 240) { $reason = $reason.Substring(0,240) + '...' }
        Write-Host ('Проверка не пройдена: ' + $reason) -ForegroundColor Red
        Write-Host ('Подробности: ' + $logPath)
        exit 1
    }
    catch {
        $reason = ($_.Exception.Message -split '\r?\n')[0]
        Write-Host ('Ошибка самопроверки: ' + $reason) -ForegroundColor Red
        exit 1
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

$tempRoot = $null
$selfTestTempBase = [IO.Path]::GetFullPath($env:TEMP)

function Remove-SelfTestDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\/")
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $leaf = [IO.Path]::GetFileName($fullPath)

    if (
        -not [string]::Equals($parent.TrimEnd([char[]]"\/"), $selfTestTempBase.TrimEnd([char[]]"\/"), [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^OBSCloneSelfTest_[0-9a-f]{32}$'
    ) {
        throw "Refusing to remove a path outside the self-test directory: $fullPath"
    }

    if (Test-Path -LiteralPath $fullPath -PathType Container) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function Fail([string]$Message) {
    Write-Host "SELF-TEST FAIL: $Message" -ForegroundColor Red
    exit 1
}

function Pass([string]$Message) {
    Write-Host "  OK: $Message" -ForegroundColor Green
}

try {
    Write-Host "OBS Full Clone v1.3.1 - self-test" -ForegroundColor Cyan

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Fail "Требуется Windows PowerShell 5.1+."
    }

    $requiredFiles = @(
        "ObsClone.Common.ps1",
        "ObsClone.Repair.ps1",
        "Create-ObsBackup.ps1",
        "Restore-ObsBackup.ps1",
        "Verify-ObsBackup.ps1",
        "CREATE_BACKUP.bat",
        "RESTORE_OBS.bat",
        "VERIFY_BACKUP.bat",
        "SELF_TEST.bat"
    )

    foreach ($name in $requiredFiles) {
        $path = Join-Path $PSScriptRoot $name

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Fail "Нет обязательного файла: $name"
        }
    }

    Pass "required files"

    # Exact PowerShell parser check for every .ps1 file.
    foreach ($script in @(
        Get-ChildItem `
            -LiteralPath $PSScriptRoot `
            -File `
            -Filter "*.ps1" `
            -Force
    )) {
        $tokens = $null
        $parseErrors = $null

        [void][Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )

        if (@($parseErrors).Count -gt 0) {
            $text = @(
                $parseErrors |
                ForEach-Object {
                    "$($_.Extent.StartLineNumber):$($_.Extent.StartColumnNumber) $($_.Message)"
                }
            ) -join "`r`n"

            Fail "PowerShell syntax error in $($script.Name):`r`n$text"
        }
    }

    Pass "PowerShell parser: all scripts"

    $selfTestSource = [IO.File]::ReadAllText($PSCommandPath)
    $strictModeLiteralPattern = (
        '(?m)^[ \t]*(?!#).*' +
        '\[regex\]::Escape\("[^"\r\n]*\$[A-Za-z_][^"\r\n]*"\)'
    )

    if ($selfTestSource -match $strictModeLiteralPattern) {
        Fail (
            "Self-test содержит double-quoted regex literal с `$variable. " +
            "Для literal проверки используйте single quotes."
        )
    }

    Pass "StrictMode-safe literal regex checks"

    # BAT BOM regression test.
    foreach ($batName in @(
        "CREATE_BACKUP.bat",
        "RESTORE_OBS.bat",
        "VERIFY_BACKUP.bat",
        "SELF_TEST.bat"
    )) {
        $batPath = Join-Path $PSScriptRoot $batName
        $bytes = [IO.File]::ReadAllBytes($batPath)

        if (
            $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF
        ) {
            Fail "$batName содержит UTF-8 BOM."
        }

        $prefixLength = [Math]::Min(9, $bytes.Length)
        $prefix = [Text.Encoding]::ASCII.GetString(
            $bytes,
            0,
            $prefixLength
        )

        if (-not $prefix.StartsWith("@echo off")) {
            Fail "$batName не начинается с @echo off."
        }
    }

    Pass "BAT encoding/no BOM"

    . (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    . (Join-Path $PSScriptRoot "ObsClone.Repair.ps1")

    $layout = Get-ObsBackToolLayout $PSScriptRoot
    foreach ($setting in @('BACKUP_DESTINATION.txt','EXTRA_SOURCES.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $layout.SettingsRoot $setting) -PathType Leaf)) {
            Fail "Missing settings file: $setting"
        }
    }
    if ($layout.ToolRoot -ne $layout.EngineRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Start-ObsBack.ps1') -PathType Leaf)) {
            Fail 'Missing OBSback menu'
        }
    }
    Pass 'compact tool layout and settings'
    Show-OverallProgress 1 "Self-test"

    $requiredFunctions = @(
        "Get-TreePlan",
        "Copy-PlanToBackup",
        "Verify-BackupPackage",
        "Zip-DirectoryWithProgress",
        "Verify-ZipAgainstFolder",
        "Replace-PathInTextConfigs",
        "Test-JsonFilesValid",
        "Get-PathExtensionSafe",
        "Get-WindowsAbsolutePathMatches",
        "Get-TextProgressBar",
        "Format-RemainingTime",
        "Reset-ByteProgressTracker",
        "Get-SafeConsoleWidth",
        "Write-CompactProgressLine",
        "Clear-CompactProgressLine",
        "Get-CompactProgressActivity",
        "Show-AuthorSupportBlock",
        "Open-AuthorPagesPrompt",
        "Get-ObsVersionSafe",
        "Get-ObsInstallationType",
        "Read-ObsAccountDataChoice",
        "Get-ObsAccountFileAction",
        "Copy-ObsAccountFreeFile",
        "Get-ObsAccountDataNotice",
        "Remove-VerifiedObsBackupFolder",
        "Open-ObsBackupArchiveLocation",
        "Get-ObsBackupInstallationType",
        "Resolve-ObsBackupConfigInfo",
        "Get-ObsInstallationInfo",
        "Get-ObsInstallationInfos",
        "Select-ObsInstallation",
        "Get-ObsInstallationsUsingConfig",
        "Stop-ObsInstallationsUsingConfig",
        "Test-ObsConfigInUse",
        "Get-ObsMissingReferenceDetails",
        "Repair-ObsMissingReferenceTarget",
        "Get-ObsMissingReferenceReportLines",
        "Get-ObsRepairPriority",
        "Get-ObsObjectProperty"
    )

    foreach ($functionName in $requiredFunctions) {
        if (-not (Get-Command $functionName -CommandType Function -ErrorAction SilentlyContinue)) {
            Fail "Не загружена функция: $functionName"
        }
    }

    Pass "common library functions"

    $commonTextForObsSelection = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    )
    $createTextForObsSelection = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "Create-ObsBackup.ps1")
    )
    $restoreTextForObsSelection = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "Restore-ObsBackup.ps1")
    )

    foreach ($requiredSelectionText in @(
        "Steam",
        "Standard",
        "Portable",
        "ЗАПУЩЕНА",
        "[M] Указать другой путь вручную",
        "Select-ObsInstallation"
    )) {
        if (
            $commonTextForObsSelection -notmatch
            [regex]::Escape($requiredSelectionText)
        ) {
            Fail "OBS multi-installation selector regression: $requiredSelectionText"
        }
    }

    if (
        $createTextForObsSelection -notmatch
        [regex]::Escape('Select-ObsInstallation "для backup"') -or
        $restoreTextForObsSelection -notmatch
        [regex]::Escape('Select-ObsInstallation "для восстановления"')
    ) {
        Fail "Create/Restore multi-installation selection regression."
    }

    if (
        $createTextForObsSelection -notmatch
        [regex]::Escape("Stop-ObsInstallationsUsingConfig") -or
        $restoreTextForObsSelection -notmatch
        [regex]::Escape("Stop-ObsInstallationsUsingConfig")
    ) {
        Fail "Shared Roaming config safety regression."
    }

    Pass "Steam + Standard + Portable selector with running-state labels"

    $progressBarRegression = Get-TextProgressBar 50 20
    if (
        -not $progressBarRegression.StartsWith("[") -or
        -not $progressBarRegression.EndsWith("]") -or
        $progressBarRegression.IndexOf("#") -lt 0 -or
        $progressBarRegression.IndexOf("-") -lt 0
    ) {
        Fail "Text progress bar regression."
    }

    if ((Format-RemainingTime 125) -ne "02:05") {
        Fail "ETA formatter regression."
    }

    Pass "visible progress bar + ETA formatting"

    $commonTextForProgressRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    )

    if (
        $commonTextForProgressRegression -notmatch [regex]::Escape("ProgressRenderIntervalMs = 250")
    ) {
        Fail "Progress redraw throttle regression."
    }

    if (
        $commonTextForProgressRegression -notmatch
        [regex]::Escape("New-Object byte[] (16MB)")
    ) {
        Fail "16MB streaming buffer regression."
    }

    if (
        $commonTextForProgressRegression -match '(?m)^\s*Write-Progress\b' -or
        $commonTextForProgressRegression -notmatch [regex]::Escape('ProgressPreference = "SilentlyContinue"') -or
        $commonTextForProgressRegression -notmatch [regex]::Escape("Write-CompactProgressLine")
    ) {
        Fail "Resize-safe compact progress renderer regression."
    }

    Pass "resize-safe compact progress + throttled redraw + 16MB buffers"

    [Int64]$largeTestBytes = 30GB
    [Int64]$largeZipNeed = [Int64](512MB)
    [Int64]$largeZipNeedBySize = [Int64][Math]::Ceiling(
        [double]$largeTestBytes * 1.05
    )

    if ($largeZipNeedBySize -gt $largeZipNeed) {
        $largeZipNeed = $largeZipNeedBySize
    }

    if ($largeZipNeed -le [Int64][Int32]::MaxValue) {
        Fail "Large-backup Int64 sizing regression."
    }

    Pass "large backup Int64 sizing"

    $createTextForUxRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "Create-ObsBackup.ps1")
    )

    if (
        $createTextForUxRegression -notmatch [regex]::Escape("BACKUP БУДЕТ СОХРАНЁН СЮДА:") -or
        $createTextForUxRegression -notmatch [regex]::Escape("Удалить незавершённый backup? Y/N")
    ) {
        Fail "Backup destination / failed-backup delete UX regression."
    }

    Pass "backup destination + failed-backup Y/N UX"

    if (
        $createTextForUxRegression -notmatch [regex]::Escape("BACKUP ГОТОВ — УСПЕШНО") -or
        $createTextForUxRegression -notmatch [regex]::Escape("ЧТО НУЖНО СОХРАНИТЬ:") -or
        $createTextForUxRegression -notmatch [regex]::Escape("ЧТО ДЕЛАТЬ ДАЛЬШЕ:") -or
        $createTextForUxRegression -notmatch [regex]::Escape("RESTORE_OBS.bat")
    ) {
        Fail "Final backup success guidance regression."
    }

    Pass "clear final success + what-to-copy + restore guidance"

    $restoreTextForUxRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "Restore-ObsBackup.ps1")
    )
    $restoreBatForUxRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "RESTORE_OBS.bat")
    )

    if (
        $restoreTextForUxRegression -notmatch [regex]::Escape("RESTORE ЗАПУЩЕН НЕ ИЗ ПАПКИ ГОТОВОГО BACKUP") -or
        $restoreTextForUxRegression -notmatch [regex]::Escape("Путь к папке OBS_BACKUP_...") -or
        $restoreTextForUxRegression -notmatch [regex]::Escape("ВОССТАНАВЛИВАЕМ ИЗ BACKUP:")
    ) {
        Fail "Restore backup-location UX regression."
    }

    if (
        $restoreBatForUxRegression -notmatch [regex]::Escape("Start-Process") -or
        $restoreBatForUxRegression -notmatch [regex]::Escape("Administrator rights: OK")
    ) {
        Fail "Restore UAC launcher regression."
    }

    Pass "restore folder guidance + visible elevated launcher"

    if (
        $restoreTextForUxRegression -notmatch
        [regex]::Escape('if ($launchArguments.Count -gt 0)') -or
        $restoreTextForUxRegression -notmatch
        [regex]::Escape("Тестовый запуск OBS без дополнительных аргументов.")
    ) {
        Fail "Restore empty ArgumentList regression."
    }

    Pass "restore empty launch-arguments handling"

    if (
        $restoreTextForUxRegression -notmatch
        [regex]::Escape('-WorkingDirectory $RestoredObsWorkingDirectory') -or
        $restoreTextForUxRegression -notmatch
        [regex]::Escape('data\\obs-studio\\locale\\en-US.ini')
    ) {
        Fail "Restore OBS working-directory / locale regression."
    }

    Pass "restore OBS working directory + locale preflight"

    $commonTextForMetadataRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    )

    if (
        $commonTextForMetadataRegression -notmatch
        [regex]::Escape("IgnoreMetadataRelativePaths") -or
        $restoreTextForUxRegression -notmatch
        [regex]::Escape("restoreEngineMetadata")
    ) {
        Fail "Restore-engine metadata compatibility regression."
    }

    Pass "new Restore engine can validate old backup payload safely"

    if (
        $commonTextForMetadataRegression -notmatch
        [regex]::Escape("SkipShaVerification") -or
        $restoreTextForUxRegression -notmatch
        [regex]::Escape("Пропустить SHA-256 и продолжить Restore? Y/N")
    ) {
        Fail "Optional SHA-skip fallback regression."
    }

    Pass "SHA failure can fall back to structural verification with Y/N"

    $createTextForSourceRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "Create-ObsBackup.ps1")
    )

    if (
        $createTextForSourceRegression -notmatch
        [regex]::Escape("Only Scene Collection JSON is authoritative for OBS source files") -or
        $createTextForSourceRegression -notmatch
        [regex]::Escape("Продолжить backup с этими крупными файлами? Y/N") -or
        $createTextForSourceRegression -notmatch
        [regex]::Escape("SOURCE_PLAN.txt")
    ) {
        Fail "Scene-only source discovery / large-source preview regression."
    }

    Pass "scene-only Sources + large-file preview + source plan report"

    if (
        $createTextForSourceRegression -match
        [regex]::Escape("В синем блоке:")
    ) {
        Fail "Obsolete blue-progress explanatory text regression."
    }

    Pass "obsolete blue-progress text removed"

    $commonTextForAuthorRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    )

    foreach ($requiredAuthorText in @(
        "https://www.twitch.tv/wither_101",
        "https://www.youtube.com/@Witheres",
        "https://github.com/WitherOffic",
        "ДАННЫЙ СКРИПТ РАСПРОСТРАНЯЕТСЯ БЕСПЛАТНО",
        "Открыть Twitch, YouTube автора и официальный GitHub в браузере? Y/N"
    )) {
        if (
            $commonTextForAuthorRegression -notmatch
            [regex]::Escape($requiredAuthorText)
        ) {
            Fail "Author/support block regression: $requiredAuthorText"
        }
    }

    Pass "author Twitch + YouTube + official GitHub + free-distribution notice"

    if (
        ($restoreTextForUxRegression -split [regex]::Escape("Show-AuthorSupportBlock")).Count -lt 3 -or
        $restoreTextForUxRegression -notmatch [regex]::Escape("Open-AuthorPagesPrompt")
    ) {
        Fail "Restore author block start/success regression."
    }

    Pass "restore author block at start + success"

    $legacyMajor = "6"
    $legacyMinor = "1"
    $legacyPattern = (
        "(?i)\bv?" +
        [regex]::Escape($legacyMajor) +
        "\." +
        [regex]::Escape($legacyMinor) +
        "(?:\.\d+|\.x)?\b"
    )

    foreach ($releaseFile in @(
        "ObsClone.Common.ps1",
        "Create-ObsBackup.ps1",
        "Restore-ObsBackup.ps1",
        "Verify-ObsBackup.ps1",
        "ObsClone.Repair.ps1",
        "SelfTest-ObsClone.ps1"
    )) {
        $releaseText = [IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot $releaseFile)
        )

        if ($releaseText -notmatch [regex]::Escape("v1.3.1")) {
            Fail "Версия v1.3.1 не найдена в $releaseFile"
        }

        if ($releaseText -match $legacyPattern) {
            Fail "В $releaseFile осталось старое обозначение версии."
        }
    }

    Pass "release version 1.3.1 everywhere"



    try {
        $badExtension = Get-PathExtensionSafe 'not<a|valid?windows*path>.mp4'
    }
    catch {
        Fail "Get-PathExtensionSafe threw on arbitrary config text."
    }

    if ($badExtension -ne "") {
        Fail "Get-PathExtensionSafe must return empty for invalid path text."
    }

    Pass "invalid config string path handling"

    $twitchUrl = 'https://dashboard.twitch.tv/widgets/alertbox#eyJhbGciOiJIUzI1NiJ9'
    $pathMatches = @(Get-WindowsAbsolutePathMatches $twitchUrl)

    if ($pathMatches.Count -ne 0) {
        Fail (
            "URL was incorrectly detected as Windows path: " +
            (@($pathMatches) -join ", ")
        )
    }

    $mixedText = 'x="https://example.com/a"; media="F:\OBS\intro.mp4"'
    $mixedMatches = @(Get-WindowsAbsolutePathMatches $mixedText)

    if (
        $mixedMatches.Count -ne 1 -or
        [string]$mixedMatches[0] -ne 'F:\OBS\intro.mp4'
    ) {
        Fail (
            "Windows absolute path matcher regression: " +
            (@($mixedMatches) -join ", ")
        )
    }

    Pass "URL vs Windows-path scanner regression"

    $commonTextForRegression = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
    )

    if (
        $commonTextForRegression -notmatch [regex]::Escape("%USERPROFILE%\OBSBackup\") -or
        $commonTextForRegression -notmatch [regex]::Escape("КАК ИСПРАВИТЬ:")
    ) {
        Fail "Path-length error help text is missing from common library."
    }

    Pass "short backup root + actionable long-path guidance"

    $tempRoot = Join-Path `
        $env:TEMP `
        ("OBSCloneSelfTest_" + [Guid]::NewGuid().ToString("N"))

    # Behavioral regressions run only on fixtures. Process discovery, process
    # termination and interactive answers are mocked in this child scope.
    & {
        param([string]$FixtureRoot)
        $savedAppData = $env:APPDATA
        try {
            $env:APPDATA = Join-Path $FixtureRoot 'roaming'
            $standardRoot = Join-Path $FixtureRoot 'Standard'
            $steamRoot = Join-Path $FixtureRoot 'Steam\steamapps\common\OBS Studio'
            $portableRoot = Join-Path $FixtureRoot 'Portable'
            $markerRoot = Join-Path $FixtureRoot 'Marker'
            $standardExe = Join-Path $standardRoot 'bin\64bit\obs64.exe'
            $steamExe = Join-Path $steamRoot 'bin\64bit\obs64.exe'
            $portableExe = Join-Path $portableRoot 'bin\64bit\obs64.exe'
            $markerExe = Join-Path $markerRoot 'bin\64bit\obs64.exe'
            $roamingConfig = Join-Path $env:APPDATA 'obs-studio'
            $portableCandidate = Join-Path $standardRoot 'config\obs-studio'
            foreach ($fixtureExe in @($standardExe, $steamExe, $portableExe, $markerExe)) {
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($fixtureExe)) -Force | Out-Null
                [IO.File]::WriteAllBytes($fixtureExe, [byte[]]@())
            }
            foreach ($fixtureConfig in @($roamingConfig, $portableCandidate)) {
                New-Item -ItemType Directory -Path (Join-Path $fixtureConfig 'basic') -Force | Out-Null
            }
            [IO.File]::WriteAllText((Join-Path $portableRoot 'portable_mode.txt'), '')
            [IO.File]::WriteAllText((Join-Path $markerRoot 'portable_mode'), '')

            function Assert-Selection([bool]$Condition, [string]$Message) {
                if (-not $Condition) { throw "Selection regression: $Message" }
            }
            # Keep mock menus out of the normal self-test output.
            function Write-Host { param($Object, $ForegroundColor, [switch]$NoNewline) }
            function Pass([string]$Message) {
                Microsoft.PowerShell.Utility\Write-Host "  OK: $Message" -ForegroundColor Green
            }
            $answers = New-Object System.Collections.Queue
            function Read-Host {
                param([string]$Prompt)
                if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
                return [string]$answers.Dequeue()
            }
            function Get-ObsVersionSafe { param([string]$ObsExe) return 'fixture' }
            function Test-ObsRunning { param([string]$ObsExe) return $true }
            function Get-RunningObsCommandLine { param([string]$ObsExe) return ('"' + $ObsExe + '"') }
            function Get-ObsExeCandidates { return @($portableExe, $steamExe, $standardExe) }
            $stoppedExes = New-Object System.Collections.ArrayList
            function Stop-ObsSafely { param([string]$ObsExe) [void]$stoppedExes.Add($ObsExe) }

            # A leftover portable config must not override a running normal OBS.
            Assert-Selection ((Get-ObsInstallationType $standardExe ('"' + $standardExe + '"')) -eq 'Standard') 'stale directory changes running OBS type'
            $config = Resolve-ObsBackupConfigInfo $standardRoot ('"' + $standardExe + '"')
            Assert-Selection (-not $config.IsPortable -and (Test-SamePath $config.ConfigRoot $roamingConfig)) 'running normal OBS uses wrong config'
            foreach ($portableFlag in @('--portable', '-p')) {
                $commandLine = '"' + $standardExe + '" ' + $portableFlag
                Assert-Selection ((Get-ObsInstallationType $standardExe $commandLine) -eq 'Portable') "flag $portableFlag type"
                $config = Resolve-ObsBackupConfigInfo $standardRoot $commandLine
                Assert-Selection ($config.IsPortable -and (Test-SamePath $config.ConfigRoot $portableCandidate)) "flag $portableFlag config"
            }
            Assert-Selection ((Get-ObsInstallationType $standardExe 'obs64.exe --portable-other') -eq 'Standard') 'partial portable flag'
            Assert-Selection ((Get-ObsInstallationType $steamExe) -eq 'Steam') 'Steam classification'
            foreach ($fixtureExe in @($portableExe, $markerExe)) {
                Assert-Selection ((Get-ObsInstallationType $fixtureExe) -eq 'Portable') 'portable marker type'
                $config = Resolve-ObsBackupConfigInfo (Get-ObsRoot $fixtureExe) ''
                Assert-Selection $config.IsPortable 'portable marker config'
            }
            Pass 'runtime: Steam/Standard/Portable, markers, flags and stale config'

            # Offline ambiguity must preserve both choices, including retries.
            $answers.Enqueue('invalid')
            $answers.Enqueue('1')
            $config = Resolve-ObsBackupConfigInfo $standardRoot ''
            Assert-Selection (-not $config.IsPortable -and (Test-SamePath $config.ConfigRoot $roamingConfig)) 'offline Roaming choice'
            $answers.Enqueue('2')
            $config = Resolve-ObsBackupConfigInfo $standardRoot ''
            Assert-Selection ($config.IsPortable -and (Test-SamePath $config.ConfigRoot $portableCandidate)) 'offline Portable choice'
            $env:APPDATA = Join-Path $FixtureRoot 'empty-roaming'
            $config = Resolve-ObsBackupConfigInfo $standardRoot ''
            Assert-Selection $config.IsPortable 'only portable config available'
            $env:APPDATA = Join-Path $FixtureRoot 'roaming'
            Assert-Selection ($answers.Count -eq 0) 'offline config prompt was bypassed'
            Pass 'runtime: explicit offline config choice and missing Roaming config'

            # Use actual installation discovery/comparison with fake processes.
            $found = @(Get-ObsInstallationInfos)
            Assert-Selection ($found.Count -eq 3) 'installation list size'
            Assert-Selection (@($found | Where-Object { $_.Type -eq 'Portable' }).Count -eq 1) 'stale config misclassified in installation list'
            $shared = @(Get-ObsInstallationsUsingConfig $roamingConfig $true)
            Assert-Selection ($shared.Count -eq 2) 'shared Roaming config matching'
            Assert-Selection (Test-ObsConfigInUse $roamingConfig) 'shared config in-use detection'
            Stop-ObsInstallationsUsingConfig $roamingConfig
            Assert-Selection ($stoppedExes.Count -eq 2 -and $standardExe -in $stoppedExes -and $steamExe -in $stoppedExes -and $portableExe -notin $stoppedExes) 'shared config closes wrong installation'
            function Test-ObsRunning { param([string]$ObsExe) return (Test-SamePath $ObsExe $steamExe) }
            $found = @(Get-ObsInstallationInfos)
            Assert-Selection ((Test-SamePath $found[0].ExePath $steamExe) -and $found[0].IsRunning) 'running installation not first'
            $shared = @(Get-ObsInstallationsUsingConfig $roamingConfig $true)
            Assert-Selection ($shared.Count -eq 1 -and (Test-SamePath $shared[0].ExePath $steamExe)) 'OnlyRunning filter'
            Pass 'runtime: shared config process selection and running-first order'

            # Menu paths execute the real selector and manual path resolver.
            $menuInstallations = @($found | Where-Object { Test-SamePath $_.ExePath $standardExe })
            function Get-ObsInstallationInfos { return $menuInstallations }
            $answers.Enqueue('')
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $standardExe) 'single install Enter default'
            $answers.Enqueue('invalid')
            $answers.Enqueue('1')
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $standardExe) 'single install numeric choice'
            $answers.Enqueue('M')
            $answers.Enqueue((Join-Path $FixtureRoot 'missing'))
            $answers.Enqueue(('"' + $portableRoot + '"'))
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $portableExe) 'single install manual override'
            $menuInstallations = @($found)
            $answers.Enqueue('')
            $answers.Enqueue('0')
            $answers.Enqueue('99')
            $answers.Enqueue('2')
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $found[1].ExePath) 'multiple install numeric selection'
            $answers.Enqueue('м')
            $answers.Enqueue($markerExe)
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $markerExe) 'multiple install manual selection'
            $menuInstallations = @()
            $answers.Enqueue($steamRoot)
            $selected = Select-ObsInstallation 'self-test'
            Assert-Selection (Test-SamePath $selected.ExePath $steamExe) 'manual selection with no discovered installs'
            Assert-Selection ($answers.Count -eq 0) 'selector silently bypassed answers'
            Pass 'runtime: zero/one/multiple installations, manual paths and invalid answers'

            foreach ($legacyCase in @(
                @{ Portable = $false; Exe = $standardExe; Expected = 'Standard' },
                @{ Portable = $false; Exe = $steamExe; Expected = 'Steam' },
                @{ Portable = $true; Exe = $steamExe; Expected = 'Portable' }
            )) {
                # Round-trip through JSON to match manifests loaded by Restore.
                $legacyManifest = [PSCustomObject]@{ IsPortable = $legacyCase.Portable; OriginalObsExe = $legacyCase.Exe } | ConvertTo-Json | ConvertFrom-Json
                Assert-Selection ((Get-ObsBackupInstallationType $legacyManifest) -eq $legacyCase.Expected) 'legacy manifest without type field'
                $legacyManifest | Add-Member NoteProperty OriginalObsInstallType ''
                Assert-Selection ((Get-ObsBackupInstallationType $legacyManifest) -eq $legacyCase.Expected) 'empty type field fallback'
                $legacyManifest.OriginalObsInstallType = $null
                Assert-Selection ((Get-ObsBackupInstallationType $legacyManifest) -eq $legacyCase.Expected) 'null type field fallback'
            }
            $currentManifest = [PSCustomObject]@{ IsPortable = $false; OriginalObsExe = $standardExe; OriginalObsInstallType = 'Steam' }
            Assert-Selection ((Get-ObsBackupInstallationType $currentManifest) -eq 'Steam') 'stored manifest type precedence'
            Pass 'runtime: legacy and current backup installation-type metadata'
        }
        finally {
            $env:APPDATA = $savedAppData
        }
    } (Join-Path $tempRoot 'selection')


    & {
        param([string]$FixtureRoot)
        function Assert-Privacy([bool]$Condition, [string]$Message) {
            if (-not $Condition) { throw "Account/ZIP regression: $Message" }
        }
        function Write-Host { param($Object, $ForegroundColor, [switch]$NoNewline) }
        function Pass([string]$Message) {
            Microsoft.PowerShell.Utility\Write-Host "  OK: $Message" -ForegroundColor Green
        }
        $answers = New-Object System.Collections.Queue
        function Read-Host {
            param($Prompt)
            if ($answers.Count -eq 0) { throw 'Unexpected account prompt' }
            return $answers.Dequeue()
        }
        foreach ($case in @(
            @{ Answer = ''; Expected = $false }, @{ Answer = 'N'; Expected = $false },
            @{ Answer = 'нет'; Expected = $false }, @{ Answer = 'Y'; Expected = $true },
            @{ Answer = 'да'; Expected = $true }
        )) {
            $answers.Enqueue('invalid')
            $answers.Enqueue($case.Answer)
            Assert-Privacy ((Read-ObsAccountDataChoice) -eq $case.Expected) 'Y/N prompt selection'
            Assert-Privacy ($answers.Count -eq 0) 'Y/N prompt did not consume answers'
        }
        Pass 'runtime: account-data Y/N, Russian answers, retry and Enter=N'

        $source = Join-Path $FixtureRoot 'source'
        $ini = @'
[General]
Name=Keep Profile Name
CookieId=SECRET_COOKIE_ID
[Auth]
Type=Twitch
[Twitch]
Name=SECRET_LOGIN
Token=SECRET_ACCESS
RefreshToken=SECRET_REFRESH
[YouTube - RTMPS]
RefreshToken=SECRET_YOUTUBE
[Restream]
Token=SECRET_RESTREAM
[Video]
BaseCX=1920
OutputCY=1080
[Output]
Mode=Advanced
[Other]
Password=SECRET_PASSWORD
'@
        $paths = @{
            'basic\profiles\One\basic.ini' = $ini
            'basic\profiles\Two\basic.ini' = $ini
            'basic\profiles\One\basic.ini.bak' = $ini
            'basic\profiles\One\basic.ini.tmp' = $ini
            'global.ini' = "[Panels]`r`nCookieId=SECRET_PANEL`r`n[General]`r`nLanguage=ru-RU`r`n"
            'user.ini' = "[General]`r`nPassword=SECRET_USER_PASSWORD`r`nLanguage=ru-RU`r`n"
            'user.ini.bak' = 'SECRET_OLD_USER'
            'basic\profiles\One\service.json' = '{"type":"rtmp_common","settings":{"service":"Twitch","server":"auto","key":"SECRET_KEY","username":"SECRET_RTMP_USER","password":"SECRET_RTMP_PASSWORD","use_auth":true,"bwtest":false}}'
            'basic\profiles\Two\service.json' = '{"type":"rtmp_custom","settings":{"server":"rtmp://SECRET_SERVER_LOGIN:SECRET_SERVER_PASSWORD@example.test/live/SECRET_PATH","key":"SECRET_CUSTOM_KEY","username":"SECRET_CUSTOM_USER","password":"SECRET_CUSTOM_PASSWORD","use_auth":true}}'
            'basic\profiles\One\service.json.bak' = '{"key":"SECRET_OLD_KEY"}'
            'plugin_config\obs-browser\Cookies' = 'SECRET_COOKIES'
            'plugin_config\obs-browser\Local Storage\leveldb\00001.ldb' = 'SECRET_BROWSER_TOKEN'
            'plugin_config\obs-browser\Network\Cookies' = 'SECRET_NETWORK_COOKIES'
            'plugin_config\obs-browser.old\Cookies' = 'SECRET_OLD_BROWSER'
            'plugin_config\keep-plugin\config.json' = '{"enabled":true,"account":"PLUGIN_DATA_OUTSIDE_SCOPE"}'
            'basic\scenes\Keep.json' = '{"name":"Keep","sources":[]}'
            'media\keep.txt' = 'Keep bytes unchanged'
            'config\obs-studio\basic\profiles\Inactive\basic.ini' = $ini
            'config\obs-studio\plugin_config\obs-browser\Cookies' = 'SECRET_INACTIVE_CONFIG'
        }
        foreach ($relative in $paths.Keys) {
            $path = Join-Path $source $relative
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
            [IO.File]::WriteAllText($path, $paths[$relative], (New-Object Text.UTF8Encoding($false)))
        }
        # StreamReader's BOM detection must also handle UTF16 config files.
        [IO.File]::WriteAllText((Join-Path $source 'user.ini'), $paths['user.ini'], [Text.Encoding]::Unicode)
        $originalHashes = @{}
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) { $originalHashes[$file.FullName] = Get-Sha256Simple $file.FullName }
        $plan = Get-TreePlan $source
        $cleanRoot = Join-Path $FixtureRoot 'clean'
        $fullRoot = Join-Path $FixtureRoot 'full'
        $cleanFiles = New-Object Collections.ArrayList
        $cleanDirs = New-Object Collections.ArrayList
        $fullFiles = New-Object Collections.ArrayList
        $fullDirs = New-Object Collections.ArrayList
        $cleanConfig = Join-Path $cleanRoot 'payload\config'
        Copy-PlanToBackup $plan $cleanConfig $cleanRoot 'Config' $cleanFiles $cleanDirs 'Private data test' $false
        Copy-PlanToBackup $plan (Join-Path $fullRoot 'payload\config') $fullRoot 'Config' $fullFiles $fullDirs 'Full data test' $true
        Assert-TreePlanUnchanged $source $plan
        foreach ($path in $originalHashes.Keys) { Assert-Privacy ((Get-Sha256Simple $path) -eq $originalHashes[$path]) 'source config changed' }
        foreach ($file in $fullFiles) {
            Assert-Privacy ($file.SHA256 -eq $originalHashes[(Join-Path $source $file.RelativePath)]) 'Y mode changed source bytes'
        }
        foreach ($file in Get-ChildItem -LiteralPath $cleanRoot -Recurse -File) {
            Assert-Privacy (-not [IO.File]::ReadAllText($file.FullName).Contains('SECRET_')) 'secret remains in N-mode backup'
        }
        Assert-Privacy (-not (Test-Path -LiteralPath (Join-Path $cleanConfig 'plugin_config\obs-browser'))) 'browser profile directory copied'
        Assert-Privacy (-not (Test-Path -LiteralPath (Join-Path $cleanConfig 'basic\profiles\One\service.json.bak'))) 'old credentials copied'
        foreach ($relative in @('basic\scenes\Keep.json','plugin_config\keep-plugin\config.json','media\keep.txt')) {
            Assert-Privacy ((Get-Sha256Simple (Join-Path $cleanConfig $relative)) -eq $originalHashes[(Join-Path $source $relative)]) 'unrelated settings changed'
        }
        $cleanIni = [IO.File]::ReadAllText((Join-Path $cleanConfig 'basic\profiles\One\basic.ini'))
        Assert-Privacy ($cleanIni.Contains('BaseCX=1920') -and $cleanIni.Contains('Mode=Advanced') -and $cleanIni.Contains('Name=Keep Profile Name')) 'video/output/profile settings lost'
        $commonService = Read-JsonFile (Join-Path $cleanConfig 'basic\profiles\One\service.json')
        Assert-Privacy ($commonService.settings.service -eq 'Twitch' -and $commonService.settings.server -eq 'auto' -and -not $commonService.settings.use_auth) 'common streaming service lost'
        $customService = Read-JsonFile (Join-Path $cleanConfig 'basic\profiles\Two\service.json')
        Assert-Privacy ($customService.type -eq 'rtmp_custom' -and @($customService.settings.PSObject.Properties).Count -eq 0) 'custom server credentials retained'
        Assert-Privacy (@($cleanFiles | Where-Object { $_.RelativePath -like '*obs-browser*' }).Count -eq 0) 'omitted files still in manifest'
        foreach ($file in $cleanFiles) {
            $path = Join-Path $cleanRoot $file.BackupRelativePath
            Assert-Privacy ($file.Size -eq (Get-Item -LiteralPath $path).Length -and $file.SHA256 -eq (Get-Sha256Simple $path)) 'sanitized size/SHA manifest mismatch'
        }
        Pass 'runtime: Y byte-identical; N strips OBS auth, stream credentials, browser state and stale copies; originals unchanged'

        $badSource = Join-Path $FixtureRoot 'broken\service.json'
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($badSource)) -Force | Out-Null
        [IO.File]::WriteAllText($badSource, '{"password":"SECRET_BROKEN"')
        $badDestination = Join-Path $FixtureRoot 'broken-copy\service.json'
        $rejected = $false
        try { Copy-ObsAccountFreeFile $badSource $badDestination 'Service' | Out-Null }
        catch { $rejected = $true; Assert-Privacy (-not $_.Exception.Message.Contains('SECRET_BROKEN')) 'parser leaked secret to log' }
        Assert-Privacy ($rejected -and -not (Test-Path -LiteralPath $badDestination)) 'malformed config written before sanitization'
        $rejected = $false
        try { Copy-ObsAccountFreeFile $badSource $badSource 'Service' | Out-Null }
        catch { $rejected = $true }
        Assert-Privacy $rejected 'in-place auth cleanup allowed'
        Assert-Privacy ((Get-ObsAccountDataNotice ([PSCustomObject]@{})) -eq '') 'old manifest breaks restore notice'
        Assert-Privacy ((Get-ObsAccountDataNotice ([PSCustomObject]@{AccountDataIncluded=$true})) -eq '') 'full backup incorrectly asks login'
        Assert-Privacy (-not [string]::IsNullOrEmpty((Get-ObsAccountDataNotice ([PSCustomObject]@{AccountDataIncluded=$false})))) 'sanitized restore notice missing'
        Pass 'runtime: malformed credentials fail before writing; old/new restore notices'

        Write-JsonUtf8 (Join-Path $cleanRoot 'manifest.json') ([PSCustomObject]@{AccountDataIncluded=$false}) 10
        Write-JsonUtf8 (Join-Path $cleanRoot 'file_manifest.json') @($cleanFiles) 20
        Write-JsonUtf8 (Join-Path $cleanRoot 'directory_manifest.json') @($cleanDirs) 20
        $hashes = New-MetadataHashList $cleanRoot @('manifest.json','file_manifest.json','directory_manifest.json')
        Write-JsonUtf8 (Join-Path $cleanRoot 'metadata_hashes.json') $hashes 20
        Write-JsonUtf8 (Join-Path $cleanRoot 'backup_status.json') ([PSCustomObject]@{Complete=$true; MetadataHashesSHA256=(Get-Sha256Simple (Join-Path $cleanRoot 'metadata_hashes.json'))}) 20
        $verified = Verify-BackupPackage $cleanRoot $false $true
        Assert-Privacy $verified.Success ('sanitized package verification: ' + ($verified.Errors -join '; '))
        $restored = Join-Path $FixtureRoot 'restored-config'
        Copy-BackupCategoryToTarget $cleanRoot $cleanFiles $cleanDirs 'Config' $restored 'Restore clean fixture'
        Assert-Privacy ((Test-JsonFilesValid $restored).Success) 'restored sanitized JSON invalid'
        Assert-Privacy (-not [IO.File]::ReadAllText((Join-Path $restored 'basic\profiles\One\basic.ini')).Contains('SECRET_')) 'restored auth came back'
        Pass 'runtime: sanitized backup metadata SHA chain and restore copy verification'

        $archiveHome = Join-Path $FixtureRoot 'archive-home'
        New-Item -ItemType Directory -Path $archiveHome -Force | Out-Null
        foreach ($case in @('Success','Unverified','CorruptZip','BadSidecar','WrongHome','DeleteError')) {
            $suffix = @('Success','Unverified','CorruptZip','BadSidecar','WrongHome','DeleteError').IndexOf($case).ToString('000')
            $root = Join-Path $archiveHome ('OBS_BACKUP_2026-09-08_12-00-00-' + $suffix)
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            Copy-Item -Path (Join-Path $cleanRoot '*') -Destination $root -Recurse
            $zipPath = $root + '.zip'
            Zip-DirectoryWithProgress $root $zipPath
            Verify-ZipAgainstFolder $root $zipPath
            $expectedHash = Get-Sha256Simple $zipPath
            [IO.File]::WriteAllText(($zipPath + '.sha256'), ($expectedHash + ' *' + [IO.Path]::GetFileName($zipPath)))
            if ($case -eq 'CorruptZip') { [IO.File]::AppendAllText($zipPath, 'changed') }
            if ($case -eq 'BadSidecar') { [IO.File]::WriteAllText(($zipPath + '.sha256'), 'wrong') }
            $homeArgument = $archiveHome
            if ($case -eq 'WrongHome') { $homeArgument = $FixtureRoot }
            $rejected = $false
            $removed = $false
            $archiveConfirmed = $false
            try {
                if ($case -eq 'DeleteError') {
                    & {
                        function Remove-Item { param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) throw 'Simulated locked directory' }
                        Remove-VerifiedObsBackupFolder $root $homeArgument $zipPath $true $expectedHash
                    } | Out-Null
                }
                else { $removed = Remove-VerifiedObsBackupFolder $root $homeArgument $zipPath ($case -ne 'Unverified') $expectedHash ([ref]$archiveConfirmed) }
            }
            catch { $rejected = $true }
            Assert-Privacy (Test-Path -LiteralPath $zipPath -PathType Leaf) 'cleanup failure deleted ZIP'
            if ($case -ne 'DeleteError') {
                Assert-Privacy ($archiveConfirmed -eq ($case -eq 'Success')) 'ZIP validation receipt is inaccurate'
            }
            if ($case -eq 'Success') {
                Assert-Privacy ($removed -and -not (Test-Path -LiteralPath $root)) 'successful verified ZIP did not remove unpacked copy'
                $extracted = Join-Path $FixtureRoot 'extracted'
                Expand-Archive -LiteralPath $zipPath -DestinationPath $extracted
                $extractedRoot = Join-Path $extracted ([IO.Path]::GetFileName($root))
                Assert-Privacy ((Verify-BackupPackage $extractedRoot $false $true).Success) 'only remaining ZIP cannot be restored'
            }
            else {
                Assert-Privacy (Test-Path -LiteralPath $root -PathType Container) 'unsafe cleanup deleted original folder'
                if ($case -ne 'Unverified') { Assert-Privacy $rejected 'unsafe cleanup accepted' }
            }
        }
        Pass 'runtime: delete only after verified ZIP + SHA; preserve folder on failures; remaining ZIP extracts and verifies'

        $explorerCalls = New-Object Collections.ArrayList
        function Start-Process {
            param($FilePath, $ArgumentList, $ErrorAction)
            [void]$explorerCalls.Add([PSCustomObject]@{File=$FilePath;Arguments=$ArgumentList})
        }
        Open-ObsBackupArchiveLocation $zipPath
        Assert-Privacy ($explorerCalls.Count -eq 1 -and $explorerCalls[0].File -eq 'explorer.exe' -and $explorerCalls[0].Arguments -eq ('/select,"' + [IO.Path]::GetFullPath($zipPath) + '"')) 'Explorer selection argument'
        function Start-Process { param($FilePath, $ArgumentList, $ErrorAction) throw 'Explorer unavailable' }
        Open-ObsBackupArchiveLocation $zipPath
        Assert-Privacy (Test-Path -LiteralPath $zipPath) 'Explorer error removed ZIP'
        Pass 'runtime: Explorer selects ZIP; opening failure is non-fatal'
    } (Join-Path $tempRoot 'privacy')


    $sourceRoot = Join-Path $tempRoot "source_тест"
    $backupRoot = Join-Path $tempRoot "backup"
    $payloadRoot = Join-Path $backupRoot "payload"

    New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot "nested") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $sourceRoot "empty_dir") | Out-Null
    New-Item -ItemType Directory -Force -Path $payloadRoot | Out-Null

    [IO.File]::WriteAllText(
        (Join-Path $sourceRoot "кириллица.txt"),
        "OBS Clone Unicode test",
        (New-Object Text.UTF8Encoding($false))
    )

    [IO.File]::WriteAllBytes(
        (Join-Path $sourceRoot "zero.bin"),
        [byte[]]@()
    )

    # A few MB are enough to exercise streaming/progress without wasting time.
    $randomPath = Join-Path $sourceRoot "nested\\random.bin"
    $random = New-Object Random 12345
    $stream = [IO.File]::Open(
        $randomPath,
        [IO.FileMode]::Create,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )

    try {
        [byte[]]$buffer = New-Object byte[] (1MB)
        for ($i = 0; $i -lt 4; $i++) {
            $random.NextBytes($buffer)
            $stream.Write($buffer, 0, $buffer.Length)
        }
    }
    finally {
        $stream.Dispose()
    }

    $plan = Get-TreePlan $sourceRoot

    if (@($plan.ReparsePoints).Count -ne 0) {
        Fail "Unexpected reparse point in self-test tree."
    }

    if (@($plan.Files).Count -ne 3) {
        Fail "Get-TreePlan expected 3 files, got $(@($plan.Files).Count)."
    }

    Pass "tree planning + Unicode + zero-byte files"

    $fileManifest = New-Object System.Collections.ArrayList
    $dirManifest = New-Object System.Collections.ArrayList

    Copy-PlanToBackup `
        $plan `
        $payloadRoot `
        $backupRoot `
        "Test" `
        $fileManifest `
        $dirManifest `
        "Self-test copy"

    Assert-TreePlanUnchanged $sourceRoot $plan

    if ($fileManifest.Count -ne 3) {
        Fail "Expected 3 file manifest entries, got $($fileManifest.Count)."
    }

    foreach ($item in $fileManifest) {
        $copyPath = Join-Path $backupRoot ([string]$item.BackupRelativePath)

        if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
            Fail "Copied test file missing: $copyPath"
        }

        if ((Get-Sha256Simple $copyPath) -ne [string]$item.SHA256) {
            Fail "Copied test hash mismatch: $copyPath"
        }
    }

    Pass "stream copy + SHA-256 manifests"

    # JSON array serialization regression test.
    $arrayJsonPath = Join-Path $backupRoot "array_test.json"
    $arrayObject = @(
        [PSCustomObject]@{ Name = "one" },
        [PSCustomObject]@{ Name = "two" }
    )

    Write-JsonUtf8 $arrayJsonPath $arrayObject 10
    $arrayRead = @(Read-JsonFile $arrayJsonPath)

    if ($arrayRead.Count -ne 2) {
        Fail "Write-JsonUtf8 did not preserve a 2-item array."
    }

    Pass "JSON array serialization"

    # Path rewrite + JSON validity test.
    $configRoot = Join-Path $tempRoot "config"
    $sceneRoot = Join-Path $configRoot "basic\\scenes"
    New-Item -ItemType Directory -Force -Path $sceneRoot | Out-Null

    $oldMedia = "F:\\важный мусор\\intro.mp4"
    $newMedia = "C:\\Users\\Test\\Documents\\OBS_Full_Clone\\Sources\\intro.mp4"

    $sceneObject = [PSCustomObject]@{
        sources = @(
            [PSCustomObject]@{
                name = "intro"
                settings = [PSCustomObject]@{
                    local_file = $oldMedia
                }
            }
        )
    }

    $scenePath = Join-Path $sceneRoot "TEST.json"
    Write-JsonUtf8 $scenePath $sceneObject 20

    Replace-PathInTextConfigs $configRoot $oldMedia $newMedia

    $sceneRead = Read-JsonFile $scenePath

    if ([string]$sceneRead.sources[0].settings.local_file -ne $newMedia) {
        Fail "Path rewrite failed."
    }

    $jsonCheck = Test-JsonFilesValid $configRoot

    if (-not $jsonCheck.Success) {
        Fail "JSON validation failed after path rewrite."
    }

    Pass "path rewrite + JSON validation"

    # Missing-reference diagnostics + repair regression.
    $repairSceneRoot = Join-Path $tempRoot "repair_config\basic\scenes"
    $repairBackupRoot = Join-Path $tempRoot "repair_backups"
    New-Item -ItemType Directory -Force -Path $repairSceneRoot | Out-Null

    $missingIntro = "C:\missing\intro.mp4"
    $missingVst = "C:\missing\reeq.dll"
    $missingPlaylist = "C:\missing\playlist.mp4"

    $repairScene = [PSCustomObject]@{
        current_scene = "Scene"
        sources = @(
            [PSCustomObject]@{
                name = "INTRO"
                uuid = "src-intro"
                id = "ffmpeg_source"
                settings = [PSCustomObject]@{
                    local_file = $missingIntro
                }
                filters = @(
                    [PSCustomObject]@{
                        name = "ReaEQ"
                        uuid = "filter-reaeq"
                        id = "vst_filter"
                        settings = [PSCustomObject]@{
                            plugin_path = $missingVst
                        }
                    }
                )
            },
            [PSCustomObject]@{
                name = "PLAYLIST"
                uuid = "src-playlist"
                id = "vlc_source"
                settings = [PSCustomObject]@{
                    playlist = @(
                        [PSCustomObject]@{
                            value = $missingPlaylist
                        }
                    )
                }
                filters = @()
            },
            [PSCustomObject]@{
                name = "Scene"
                uuid = "scene-main"
                id = "scene"
                settings = [PSCustomObject]@{
                    items = @(
                        [PSCustomObject]@{
                            name = "INTRO"
                            source_uuid = "src-intro"
                        },
                        [PSCustomObject]@{
                            name = "PLAYLIST"
                            source_uuid = "src-playlist"
                        }
                    )
                }
                filters = @()
            },
            [PSCustomObject]@{
                name = "NO_FILTERS_SOURCE"
                uuid = "src-no-filters"
                id = "dummy_source"
            }
        )
    }

    $repairScenePath = Join-Path $repairSceneRoot "REPAIR_TEST.json"
    Write-JsonUtf8 $repairScenePath $repairScene 50

    $repairDetails = @(
        Get-ObsMissingReferenceDetails `
            $repairSceneRoot `
            @(
                $missingIntro,
                $missingVst,
                $missingPlaylist
            )
    )

    if ($repairDetails.Count -ne 3) {
        Fail "Expected 3 repair details, got $($repairDetails.Count)."
    }

    # Regression: heterogeneous OBS sources are allowed to omit filters/settings.
    $noFiltersDetails = @(
        Get-ObsMissingReferenceDetails `
            $repairSceneRoot `
            @($missingIntro)
    )

    if ($noFiltersDetails.Count -lt 1) {
        Fail "Missing-property OBS source regression."
    }

    Pass "OBS sources without filters/settings"

    $types = @($repairDetails.RepairType | Sort-Object -Unique)

    foreach ($expectedType in @(
        "Source",
        "Filter",
        "PlaylistEntry"
    )) {
        if ($expectedType -notin $types) {
            Fail "Missing repair type: $expectedType"
        }
    }

    $orderedRepairGroups = @(
        $repairDetails |
        Group-Object RepairKey |
        Sort-Object `
            @{ Expression = { Get-ObsRepairPriority $_.Group[0] }; Ascending = $true }, `
            @{ Expression = { [string]$_.Group[0].SourceName }; Ascending = $true }
    )

    $orderedRepairTypes = @(
        $orderedRepairGroups |
        ForEach-Object { [string]$_.Group[0].RepairType }
    )

    if (
        $orderedRepairTypes.Count -ne 3 -or
        $orderedRepairTypes[0] -ne "Filter" -or
        $orderedRepairTypes[1] -ne "PlaylistEntry" -or
        $orderedRepairTypes[2] -ne "Source"
    ) {
        Fail (
            "Repair ordering regression: " +
            (@($orderedRepairTypes) -join ", ")
        )
    }

    foreach ($group in $orderedRepairGroups) {
        $result = Repair-ObsMissingReferenceTarget `
            @($group.Group) `
            $repairBackupRoot

        if (-not $result.Success) {
            Fail "Repair regression failed: $($result.Message)"
        }
    }

    $repairedScene = Read-JsonFile $repairScenePath

    if (@($repairedScene.sources | Where-Object { $_.name -eq "INTRO" }).Count -ne 0) {
        Fail "Source repair did not remove INTRO."
    }

    $playlistSource = @(
        $repairedScene.sources |
        Where-Object { $_.name -eq "PLAYLIST" }
    ) | Select-Object -First 1

    if (@($playlistSource.settings.playlist).Count -ne 0) {
        Fail "Playlist repair did not remove missing entry."
    }

    $sceneSource = @(
        $repairedScene.sources |
        Where-Object { $_.name -eq "Scene" }
    ) | Select-Object -First 1

    if (
        @(
            $sceneSource.settings.items |
            Where-Object { $_.source_uuid -eq "src-intro" }
        ).Count -ne 0
    ) {
        Fail "Source repair did not remove scene item reference."
    }

    if (-not (Test-Path -LiteralPath $repairBackupRoot -PathType Container)) {
        Fail "Repair backup directory was not created."
    }

    Pass "missing-reference context + safe Y/N repair engine"

    # ZIP create + full entry SHA comparison.
    $zipPath = Join-Path $tempRoot "selftest.zip"
    Zip-DirectoryWithProgress $backupRoot $zipPath
    Verify-ZipAgainstFolder $backupRoot $zipPath

    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
        Fail "ZIP was not created."
    }

    Pass "ZIP create + full content verification"

    Remove-SelfTestDirectory $tempRoot

    Complete-AllProgress
    Write-Host "SELF-TEST PASSED" -ForegroundColor Green
    exit 0
}
catch {
    try {
        if (Get-Command Complete-AllProgress -CommandType Function -ErrorAction SilentlyContinue) {
            Complete-AllProgress
        }
    }
    catch {}

    try {
        if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
            Remove-SelfTestDirectory $tempRoot
        }
    }
    catch {}

    Fail $_.Exception.Message
}
