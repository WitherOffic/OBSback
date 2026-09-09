#requires -Version 5.1
# OBS Full Clone Tool v1.3.1 - Create backup

. (Join-Path $PSScriptRoot "ObsClone.Common.ps1")
. (Join-Path $PSScriptRoot "ObsClone.Repair.ps1")

$ToolLayout = Get-ObsBackToolLayout $PSScriptRoot
$EngineRoot = $ToolLayout.EngineRoot
$ToolRoot = $ToolLayout.ToolRoot
$SettingsRoot = $ToolLayout.SettingsRoot
$Warnings = New-Object System.Collections.ArrayList
$IncompleteRoot = $null
$FinalRoot = $null
$BackupFolderComplete = $false

function Add-Warning([string]$Text) {
    [void]$Warnings.Add($Text)
    Write-Warn $Text
}

function Get-AllStrings($Object) {
    if ($null -eq $Object) {
        return
    }

    if ($Object -is [string]) {
        $Object
        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            Get-AllStrings $Object[$key]
        }
        return
    }

    if (
        $Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string])
    ) {
        foreach ($item in $Object) {
            Get-AllStrings $item
        }
        return
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            Get-AllStrings $property.Value
        }
    }
}

function Get-NamedStringEntries($Object) {
    if ($null -eq $Object) {
        return
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            if ($property.Value -is [string]) {
                [PSCustomObject]@{
                    Name = [string]$property.Name
                    Value = [string]$property.Value
                }
            }

            Get-NamedStringEntries $property.Value
        }

        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            $value = $Object[$key]

            if ($value -is [string]) {
                [PSCustomObject]@{
                    Name = [string]$key
                    Value = [string]$value
                }
            }

            Get-NamedStringEntries $value
        }

        return
    }

    if (
        $Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string])
    ) {
        foreach ($item in $Object) {
            Get-NamedStringEntries $item
        }
    }
}

function Normalize-LocalReference(
    [string]$Value,
    [string]$BaseDirectory = $null
) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $text = $Value.Trim().Trim('"').Trim("'")
    $text = [Environment]::ExpandEnvironmentVariables($text)

    if ($text -match '^(?i)(https?|rtmp|rtmps|srt|rist|udp|tcp|data|blob|javascript):') {
        return $null
    }

    if ($text -match '^(?i)file:/+') {
        try {
            $uri = New-Object Uri($text)

            if ($uri.IsFile) {
                return [IO.Path]::GetFullPath($uri.LocalPath)
            }
        }
        catch {}

        return $null
    }

    if ($text -match '^[A-Za-z]:[\\/]') {
        try {
            return [IO.Path]::GetFullPath(
                ($text -replace '/', '\\')
            )
        }
        catch {
            return $null
        }
    }

    if ($text -match '^\\\\[^\\]+\\[^\\]+') {
        try {
            return [IO.Path]::GetFullPath($text)
        }
        catch {
            return $null
        }
    }

    if ($BaseDirectory) {
        # Config values are arbitrary strings, not necessarily valid paths.
        # Invalid Windows path characters must never abort the whole backup.
        if ($text -match '[<>:"|?*\x00-\x1F]') {
            return $null
        }

        if (
            $text.Contains("\\") -or
            $text.Contains("/") -or
            (Get-PathExtensionSafe $text)
        ) {
            try {
                return [IO.Path]::GetFullPath(
                    (Join-Path $BaseDirectory ($text -replace '/', '\\'))
                )
            }
            catch {}
        }
    }

    return $null
}

function Test-SkipExternalReference(
    [string]$Path,
    [string[]]$SkipRoots
) {
    foreach ($root in $SkipRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        if (Test-SamePath $Path $root) {
            return $true
        }

        if (Test-PathInside $Path $root) {
            return $true
        }
    }

    return $false
}

function Add-ExistingReference(
    [string]$Value,
    [string]$BaseDirectory,
    [bool]$TrackMissing,
    [System.Collections.Generic.HashSet[string]]$Existing,
    [System.Collections.Generic.HashSet[string]]$Missing,
    [string[]]$SkipRoots
) {
    $path = Normalize-LocalReference $Value $BaseDirectory

    if (-not $path) {
        return
    }

    if (Test-SkipExternalReference $path $SkipRoots) {
        return
    }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [void]$Existing.Add($path)
        return
    }

    # Automatic directory inclusion is deliberately conservative.
    # Directories can be force-included via EXTRA_SOURCES.txt.
    if ($TrackMissing) {
        $extension = (Get-PathExtensionSafe $path)

        if ($extension) {
            [void]$Missing.Add($path)
        }
    }
}

function Scan-ObsConfigReferences(
    [string]$ConfigRoot,
    [string[]]$SkipRoots
) {
    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $missing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $remote = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $localHtml = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $sceneRoot = Join-Path $ConfigRoot "basic\\scenes"

    $extensions = @(
        ".json",
        ".ini",
        ".txt",
        ".conf",
        ".cfg"
    )

    $files = @(
        Get-ChildItem `
            -LiteralPath $ConfigRoot `
            -Recurse `
            -File `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant()
        }
    )

    $index = 0

    foreach ($file in $files) {
        $index++

        $percent = 100
        if ($files.Count -gt 0) {
            $percent = [int](($index * 100.0) / $files.Count)
        }

        Write-Progress `
            -Id 2 `
            -ParentId 1 `
            -Activity "Поиск локальных ресурсов в конфиге OBS" `
            -Status $file.Name `
            -PercentComplete $percent

        $baseDirectory = $file.DirectoryName
        $isSceneFile = Test-PathInside $file.FullName $sceneRoot
        $strings = @()
        $namedEntries = @()

        if ($file.Extension -ieq ".json") {
            try {
                $object = [IO.File]::ReadAllText($file.FullName) |
                    ConvertFrom-Json

                $strings = @(Get-AllStrings $object)
                $namedEntries = @(Get-NamedStringEntries $object)
            }
            catch {}
        }

        foreach ($value in $strings) {
            if ($value -isnot [string]) {
                continue
            }

            if ($value -match '^(?i)https?://') {
                [void]$remote.Add($value)
                continue
            }

            # IMPORTANT:
            # Only Scene Collection JSON is authoritative for OBS source files.
            # Other OBS config files may keep history/recent/output/plugin paths
            # long after a source was removed. Those paths must not become Sources.
            if ($isSceneFile) {
                Add-ExistingReference `
                    $value `
                    $baseDirectory `
                    $true `
                    $existing `
                    $missing `
                    $SkipRoots
            }
        }

        if ($isSceneFile) {
            foreach ($entry in $namedEntries) {
                if (
                    [string]$entry.Name -notmatch
                    '(?i)(path|file|dir|directory|folder|playlist|image|media|script|lut|mask)'
                ) {
                    continue
                }

                $candidate = Normalize-LocalReference `
                    ([string]$entry.Value) `
                    $baseDirectory

                if (-not $candidate) {
                    continue
                }

                if (Test-SkipExternalReference $candidate $SkipRoots) {
                    continue
                }

                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    if (Test-DriveRoot $candidate) {
                        throw "Scene Collection ссылается на корень диска как на ресурс: $candidate"
                    }

                    [void]$existing.Add($candidate)
                }
                elseif (
                    -not (Test-Path -LiteralPath $candidate -PathType Leaf)
                ) {
                    [void]$missing.Add($candidate)
                }
            }
        }

        # Raw fallback for malformed/non-JSON text configs.
        try {
            $text = [IO.File]::ReadAllText($file.FullName)

            foreach ($match in [regex]::Matches(
                $text,
                '(?i)https?://[^\s"<>\r\n]+'
            )) {
                [void]$remote.Add(
                    $match.Value.TrimEnd([char[]]',;)]}')
                )
            }

            if ($isSceneFile) {
                foreach ($value in @(Get-WindowsAbsolutePathMatches $text)) {
                    Add-ExistingReference `
                        $value `
                        $baseDirectory `
                        $true `
                        $existing `
                        $missing `
                        $SkipRoots
                }
            }
        }
        catch {}
    }

    foreach ($path in @($existing)) {
        if (
            (Test-Path -LiteralPath $path -PathType Leaf) -and
            ((Get-PathExtensionSafe $path).ToLowerInvariant() -in @(
                ".html",
                ".htm"
            ))
        ) {
            [void]$localHtml.Add($path)
        }
    }

    Complete-SubProgress

    return [PSCustomObject]@{
        Existing = @($existing)
        Missing = @($missing)
        Remote = @($remote)
        LocalHtml = @($localHtml)
    }
}

function Expand-TextDependencies(
    [string[]]$InitialFiles,
    [string[]]$SkipRoots
) {
    $allFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $queue = New-Object 'System.Collections.Generic.Queue[string]'

    foreach ($path in $InitialFiles) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if ($allFiles.Add($path)) {
                $queue.Enqueue($path)
            }
        }
    }

    while ($queue.Count -gt 0) {
        $file = $queue.Dequeue()

        if (-not $processed.Add($file)) {
            continue
        }

        $extension = (Get-PathExtensionSafe $file).ToLowerInvariant()

        if ($extension -notin @(
            ".m3u",
            ".m3u8",
            ".html",
            ".htm",
            ".css",
            ".js"
        )) {
            continue
        }

        $baseDirectory = [IO.Path]::GetDirectoryName($file)

        try {
            $text = [IO.File]::ReadAllText($file)
        }
        catch {
            Add-Warning "Не удалось прочитать dependency-файл: $file"
            continue
        }

        $references = New-Object System.Collections.ArrayList

        if ($extension -in @(".m3u", ".m3u8")) {
            foreach ($line in ($text -split "`r?`n")) {
                $value = $line.Trim()

                if (-not $value -or $value.StartsWith("#")) {
                    continue
                }

                [void]$references.Add($value)
            }
        }
        else {
            foreach ($pattern in @(
                '(?i)(?:src|href|poster)\s*=\s*["'']([^"'']+)["'']',
                '(?i)url\(\s*["'']?([^"''\)]+)',
                '(?i)@import\s+(?:url\()?\s*["'']?([^"''\)\s;]+)',
                '(?i)(?:fetch|require)\s*\(\s*["'']([^"'']+)["'']',
                '(?i)\bfrom\s+["'']([^"'']+)["'']',
                '(?i)\bimport\s+["'']([^"'']+)["'']'
            )) {
                foreach ($match in [regex]::Matches($text, $pattern)) {
                    [void]$references.Add($match.Groups[1].Value)
                }
            }
        }

        foreach ($reference in $references) {
            $candidate = Normalize-LocalReference `
                ([string]$reference) `
                $baseDirectory

            if (-not $candidate) {
                continue
            }

            if (Test-SkipExternalReference $candidate $SkipRoots) {
                continue
            }

            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                if ($allFiles.Add($candidate)) {
                    $queue.Enqueue($candidate)
                }
            }
        }
    }

    return @($allFiles)
}

function Get-DangerousWebParentRoots {
    $roots = New-Object System.Collections.ArrayList

    foreach ($path in @(
        $env:USERPROFILE,
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyPictures),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyMusic),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyVideos),
        (Join-Path $env:USERPROFILE "Downloads")
    )) {
        if (
            $path -and
            (Test-Path -LiteralPath $path -PathType Container)
        ) {
            [void]$roots.Add(
                [IO.Path]::GetFullPath($path).TrimEnd([char[]]"\/")
            )
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-SafeWebProjectDirectories(
    [string[]]$HtmlFiles,
    [string[]]$SkipRoots
) {
    $result = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $dangerousRoots = @(Get-DangerousWebParentRoots)

    foreach ($htmlFile in $HtmlFiles) {
        $parent = [IO.Path]::GetDirectoryName($htmlFile)

        if (-not $parent) {
            continue
        }

        if (Test-DriveRoot $parent) {
            throw (
                "Local Browser Source находится прямо в корне диска: $htmlFile. " +
                "Нельзя гарантировать перенос относительных CSS/JS/images без копирования всего диска. " +
                "Переместите web source в отдельную папку и повторите backup."
            )
        }

        $dangerous = $false

        foreach ($root in $dangerousRoots) {
            if (Test-SamePath $parent $root) {
                $dangerous = $true
                break
            }
        }

        if ($dangerous) {
            throw (
                "Local Browser Source лежит прямо в общей пользовательской папке: $htmlFile. " +
                "Для целостного переноса относительных CSS/JS/images пришлось бы копировать всю эту папку. " +
                "Переместите web source в отдельную папку-проект и повторите backup."
            )
        }

        if (Test-SkipExternalReference $parent $SkipRoots) {
            continue
        }

        [void]$result.Add($parent)
    }

    return @($result)
}

function Collapse-ExternalReferences([string[]]$Paths) {
    $unique = @($Paths | Select-Object -Unique)

    $directories = @(
        $unique |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Container
        } |
        Sort-Object { $_.Length }
    )

    $result = New-Object System.Collections.ArrayList

    foreach ($path in $unique) {
        $covered = $false

        foreach ($directory in $directories) {
            if (Test-SamePath $path $directory) {
                continue
            }

            if (Test-PathInside $path $directory) {
                $covered = $true
                break
            }
        }

        if (-not $covered) {
            [void]$result.Add($path)
        }
    }

    return @($result)
}

function Get-ObsEnvironmentSnapshot {
    $items = New-Object System.Collections.ArrayList

    foreach ($name in @(
        "OBS_PLUGINS_PATH",
        "OBS_PLUGINS_DATA_PATH"
    )) {
        $user = [Environment]::GetEnvironmentVariable($name, "User")
        $machine = [Environment]::GetEnvironmentVariable($name, "Machine")
        $process = [Environment]::GetEnvironmentVariable($name, "Process")

        $effective = $process
        if (-not $effective) { $effective = $user }
        if (-not $effective) { $effective = $machine }

        [void]$items.Add([PSCustomObject]@{
            Name = $name
            User = $user
            Machine = $machine
            Process = $process
            Effective = $effective
        })
    }

    return @($items)
}

function Get-CustomPluginRoots(
    $EnvironmentSnapshot,
    [string[]]$SkipRoots
) {
    $result = New-Object System.Collections.ArrayList
    $counter = 0

    foreach ($item in $EnvironmentSnapshot) {
        $effective = [string]$item.Effective

        if ([string]::IsNullOrWhiteSpace($effective)) {
            continue
        }

        foreach ($rawComponent in ($effective -split ';')) {
            $component = $rawComponent.Trim()

            if (-not $component) {
                continue
            }

            $expanded = [Environment]::ExpandEnvironmentVariables($component)
            $moduleSuffix = ""

            $modulePosition = $expanded.IndexOf(
                "%module%",
                [StringComparison]::OrdinalIgnoreCase
            )

            if ($modulePosition -ge 0) {
                $moduleSuffix = $expanded.Substring($modulePosition)
                $expanded = $expanded.Substring(0, $modulePosition)
                $expanded = $expanded.TrimEnd([char[]]"\/")
            }

            if (-not $expanded) {
                continue
            }

            try {
                $expanded = [IO.Path]::GetFullPath($expanded)
            }
            catch {
                continue
            }

            if (Test-SkipExternalReference $expanded $SkipRoots) {
                continue
            }

            if (Test-Path -LiteralPath $expanded -PathType Container) {
                $counter++

                [void]$result.Add([PSCustomObject]@{
                    Id = "CustomPluginPath$counter"
                    VariableName = [string]$item.Name
                    OriginalComponent = $component
                    OriginalRoot = $expanded
                    ModuleSuffix = $moduleSuffix
                })
            }
            else {
                Add-Warning (
                    "OBS custom plugin path указан, но каталог не найден: " +
                    "$($item.Name) = $component"
                )
            }
        }
    }

    return @($result)
}

function Confirm-LargeDirectoryPlan(
    [string]$Path,
    $Plan,
    [string]$Reason
) {
    [Int64]$sizeLimit = 25GB
    [int]$fileLimit = 100000

    $fileCount = @($Plan.Files).Count

    if (
        [Int64]$Plan.TotalBytes -le $sizeLimit -and
        $fileCount -le $fileLimit
    ) {
        return
    }

    Write-Warn "Обнаружена очень большая автоматически включаемая папка:"
    Write-Warn "  $Path"
    Write-Warn "Причина: $Reason"
    Write-Warn "Файлов: $fileCount"
    Write-Warn "Размер: $(Format-Bytes $Plan.TotalBytes)"

    while ($true) {
        $answer = (Read-Host "Действительно включить ВСЮ эту папку? Y/N").Trim().ToUpperInvariant()

        if (
            $answer -eq "Y" -or
            $answer -eq "YES" -or
            $answer -eq "Д" -or
            $answer -eq "ДА"
        ) {
            return
        }

        if (
            $answer -eq "N" -or
            $answer -eq "NO" -or
            $answer -eq "Н" -or
            $answer -eq "НЕТ"
        ) {
            throw (
                "Пользователь отказался включать большую папку '$Path'. " +
                "Переместите нужные ресурсы в отдельную папку или скорректируйте EXTRA_SOURCES.txt."
            )
        }

        Write-Warn "Введите Y или N."
    }
}

function New-StoredReferenceName(
    [string]$OriginalPath,
    [hashtable]$NameCounts
) {
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($OriginalPath)
        $hash = (
            [BitConverter]::ToString(
                $sha.ComputeHash($bytes)
            )
        ).Replace("-", "").Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }

    if (Test-Path -LiteralPath $OriginalPath -PathType Container) {
        $leaf = [IO.Path]::GetFileName(
            $OriginalPath.TrimEnd([char[]]"\/")
        )

        if (-not $leaf) {
            $leaf = "Folder"
        }

        return Join-Path `
            (Join-Path "_folders" $hash) `
            $leaf
    }

    $fileName = [IO.Path]::GetFileName($OriginalPath)
    $key = $fileName.ToLowerInvariant()

    $reserved = @(
        "_folders",
        "_duplicates",
        "_files"
    )

    if (
        $NameCounts.ContainsKey($key) -and
        $NameCounts[$key] -eq 1 -and
        $fileName -notin $reserved
    ) {
        return $fileName
    }

    return Join-Path `
        (Join-Path "_duplicates" $hash) `
        $fileName
}

try {
    Write-Info "=== OBS FULL CLONE v1.3.1: СОЗДАНИЕ BACKUP ==="
    Show-AuthorSupportBlock
    Show-OverallProgress 1 "Определение OBS"

    $ObsInstallation = Select-ObsInstallation "для backup"
    $ObsExe = [string]$ObsInstallation.ExePath
    $ObsRoot = [string]$ObsInstallation.Root
    $runningCommandLine = [string]$ObsInstallation.RunningCommandLine

    if (Test-PathInside $ToolRoot $ObsRoot) {
        throw (
            "Tool нельзя запускать изнутри папки OBS. " +
            "Иначе backup начнёт включать сам себя. " +
            "Переместите OBS_Full_Clone_Tool, например, на Desktop."
        )
    }

    $configInfo = Resolve-ObsBackupConfigInfo $ObsRoot $runningCommandLine
    $ObsInstallation.ConfigRoot = [string]$configInfo.ConfigRoot

    # The manifest and summary must reflect the config actually chosen.
    if ([bool]$configInfo.IsPortable) {
        $ObsInstallation.Type = "Portable"

        if (-not $configInfo.PortableByMarker -and -not $configInfo.PortableByArgument) {
            Add-Warning "Выбран portable config внутри OBS без marker/аргумента запуска."
        }
    }
    else {
        $ObsInstallation.Type = Get-ObsInstallationType $ObsExe $runningCommandLine
    }

    $ConfigRoot = [string]$configInfo.ConfigRoot
    $LocalConfigRoot = Join-Path $env:LOCALAPPDATA "obs-studio"
    $ProgramDataRoot = "C:\\ProgramData\\obs-studio"

    if (-not (Test-Path -LiteralPath $ConfigRoot -PathType Container)) {
        throw "Не найден активный config OBS: $ConfigRoot"
    }

    $obsVersion = [string]$ObsInstallation.Version

    Write-Ok "OBS: $ObsExe"
    Write-Ok "Тип установки: $([string]$ObsInstallation.Type)"
    Write-Ok "Версия: $obsVersion"
    Write-Ok "Была запущена при выборе: $([bool]$ObsInstallation.IsRunning)"
    Write-Ok "Config: $ConfigRoot"
    Write-Ok "Portable mode: $($configInfo.IsPortable)"

    $IncludeAccountData = Read-ObsAccountDataChoice
    $AccountDataSummary = 'Включены данные входа OBS, ключи трансляций и сессии браузера.'
    if (-not $IncludeAccountData) {
        $AccountDataSummary = 'Исключены данные входа OBS, ключи трансляций и сессии браузера; после Restore войдите заново.'
    }
    Write-Info $AccountDataSummary

    Show-OverallProgress 3 "Остановка OBS"
    Stop-ObsInstallationsUsingConfig $ConfigRoot
    Stop-ObsSafely $ObsExe

    if (
        (Test-ObsRunning $ObsExe) -or
        (Test-ObsConfigInUse $ConfigRoot)
    ) {
        throw (
            "OBS всё ещё использует выбранный config. " +
            "Нельзя делать консистентный backup."
        )
    }

    Start-Sleep -Milliseconds 400

    $preJsonCheck = Test-JsonFilesValid $ConfigRoot
    if (-not $preJsonCheck.Success) {
        throw (
            "Scene Collection JSON уже повреждён до начала backup:`r`n" +
            (@($preJsonCheck.Errors) -join "`r`n")
        )
    }

    $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss-fff"

    # Keep backup output independent from the tool extraction path.
    # This prevents deep/nested tool folders from making every backup path huge.
    $BackupHome = Join-Path $env:USERPROFILE "OBSBackup"
    $BackupDestinationFile = Join-Path $SettingsRoot "BACKUP_DESTINATION.txt"

    if (Test-Path -LiteralPath $BackupDestinationFile -PathType Leaf) {
        $configuredDestination = @(
            [IO.File]::ReadAllLines($BackupDestinationFile) |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
        ) | Select-Object -First 1

        if ($configuredDestination) {
            $configuredDestination = [Environment]::ExpandEnvironmentVariables(
                [string]$configuredDestination
            )

            try {
                $BackupHome = [IO.Path]::GetFullPath($configuredDestination)
            }
            catch {
                throw (
                    "BACKUP_DESTINATION.txt содержит некорректный путь: " +
                    [string]$configuredDestination
                )
            }
        }
    }

    if (
        (Test-SamePath $BackupHome $ObsRoot) -or
        (Test-PathInside $BackupHome $ObsRoot) -or
        (Test-PathInside $ObsRoot $BackupHome)
    ) {
        throw (
            "Папка backup не должна находиться внутри OBS и OBS не должен находиться внутри backup root: " +
            $BackupHome
        )
    }

    New-Item -ItemType Directory -Force -Path $BackupHome | Out-Null

    $IncompleteRoot = Join-Path $BackupHome "OBS_BACKUP_${stamp}_INCOMPLETE"
    $FinalRoot = Join-Path $BackupHome "OBS_BACKUP_$stamp"

    Write-Host ""
    Write-Info "BACKUP БУДЕТ СОХРАНЁН СЮДА:"
    Write-Host $FinalRoot -ForegroundColor Yellow
    Write-Info "Временная папка до завершения проверки:"
    Write-Host $IncompleteRoot -ForegroundColor DarkYellow
    Write-Host ""

    New-Item -ItemType Directory -Force -Path $IncompleteRoot | Out-Null

    $PayloadRoot = Join-Path $IncompleteRoot "payload"
    $ProgramDestination = Join-Path $PayloadRoot "obs_program"
    $ConfigDestination = Join-Path $PayloadRoot "config_obs-studio"
    $LocalDestination = Join-Path $PayloadRoot "localappdata_obs-studio"
    $ProgramDataDestination = Join-Path $PayloadRoot "programdata_obs-studio"
    $CustomDestination = Join-Path $PayloadRoot "custom_plugin_paths"
    $SourcesDestination = Join-Path $IncompleteRoot "Sources"

    foreach ($path in @(
        $PayloadRoot,
        $ProgramDestination,
        $ConfigDestination,
        $ProgramDataDestination,
        $CustomDestination,
        $SourcesDestination
    )) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }

    $configExclude = {
        param($item, $relative)

        $parts = $relative -split '\\'
        $top = ""

        if ($parts.Count -gt 0) {
            $top = $parts[0]
        }

        if ($top -in @(
            "logs",
            "crashes",
            "profiler_data",
            "updates"
        )) {
            return $true
        }

        # Disposable Chromium/OBS Browser caches are intentionally excluded.
        # Cookies, Local Storage, IndexedDB and other persistent browser state
        # remain in the backup.
        if ($relative -match '^(?i)plugin_config\\obs-browser\\(?:Cache|Code Cache|GPUCache|DawnCache|ShaderCache)(?:\\|$)') {
            return $true
        }

        if ($relative -match '^(?i)plugin_config\\obs-browser\\Service Worker\\CacheStorage(?:\\|$)') {
            return $true
        }

        if ($relative -match '^(?i)plugin_config\\obs-browser\\Service Worker\\ScriptCache(?:\\|$)') {
            return $true
        }

        if ($item.Name -in @(
            ".sentinel",
            "safe_mode"
        )) {
            return $true
        }

        if ($relative -match '^(?i)plugin_config\\obs-teleport(?:\\|$)') {
            return $true
        }

        return $false
    }

    $programExclude = {
        param($item, $relative)

        if ($relative -match '(?i)(^|\\)obs-teleport(?:\\|$)') {
            return $true
        }

        if ($item.Name -match '(?i)^obs-teleport(?:\.dll)?$') {
            return $true
        }

        if (
            $configInfo.IsPortable -and
            $relative -match '^(?i)config\\obs-studio(?:\\|$)'
        ) {
            return $true
        }

        return $false
    }

    $programDataExclude = {
        param($item, $relative)

        if ($relative -match '(?i)(^|\\)obs-teleport(?:\\|$)') {
            return $true
        }

        if ($item.Name -match '(?i)^obs-teleport(?:\.dll)?$') {
            return $true
        }

        return $false
    }

    Show-OverallProgress 6 "Построение плана OBS"

    $ConfigPlan = Get-TreePlan $ConfigRoot $configExclude
    $ProgramPlan = Get-TreePlan $ObsRoot $programExclude

    if (@($ConfigPlan.ReparsePoints).Count -gt 0) {
        throw (
            "В config OBS найдены symlink/junction/reparse point. " +
            "Чтобы не выдать ложный полный backup, операция остановлена:`r`n" +
            (@($ConfigPlan.ReparsePoints) -join "`r`n")
        )
    }

    if (@($ProgramPlan.ReparsePoints).Count -gt 0) {
        throw (
            "В папке OBS найдены symlink/junction/reparse point. " +
            "Операция остановлена:`r`n" +
            (@($ProgramPlan.ReparsePoints) -join "`r`n")
        )
    }

    $LocalPlan = $null

    if (
        -not $configInfo.IsPortable -and
        (Test-Path -LiteralPath $LocalConfigRoot -PathType Container)
    ) {
        $LocalPlan = Get-TreePlan $LocalConfigRoot $configExclude

        if (@($LocalPlan.ReparsePoints).Count -gt 0) {
            throw (
                "В LocalAppData OBS найдены reparse points:`r`n" +
                (@($LocalPlan.ReparsePoints) -join "`r`n")
            )
        }
    }

    $ProgramDataPlan = $null

    if (Test-Path -LiteralPath $ProgramDataRoot -PathType Container) {
        $ProgramDataPlan = Get-TreePlan `
            $ProgramDataRoot `
            $programDataExclude

        if (@($ProgramDataPlan.ReparsePoints).Count -gt 0) {
            throw (
                "В ProgramData OBS найдены reparse points:`r`n" +
                (@($ProgramDataPlan.ReparsePoints) -join "`r`n")
            )
        }
    }

    $skipRoots = @(
        $ObsRoot,
        $ConfigRoot,
        $LocalConfigRoot,
        $ProgramDataRoot,
        $IncompleteRoot
    )

    $environmentSnapshot = @(Get-ObsEnvironmentSnapshot)
    $customRoots = @(Get-CustomPluginRoots $environmentSnapshot $skipRoots)

    foreach ($custom in $customRoots) {
        $skipRoots += [string]$custom.OriginalRoot
    }

    Show-OverallProgress 10 "Поиск всех локальных source-файлов"

    $scan = Scan-ObsConfigReferences $ConfigRoot $skipRoots

    if (@($scan.Missing).Count -gt 0) {
        $missingFile = Join-Path $IncompleteRoot "MISSING_REFERENCES.txt"
        $sceneRoot = Join-Path $ConfigRoot "basic\scenes"

        $missingDetails = @(
            Get-ObsMissingReferenceDetails `
                $sceneRoot `
                @($scan.Missing)
        )

        Get-ObsMissingReferenceReportLines `
            @($scan.Missing) `
            $missingDetails |
            Set-Content `
                -LiteralPath $missingFile `
                -Encoding UTF8

        Write-Host ""
        Write-Bad "НАЙДЕНЫ ОТСУТСТВУЮЩИЕ ЭЛЕМЕНТЫ OBS"
        Write-Warn "Подробный отчёт:"
        Write-Host $missingFile -ForegroundColor Yellow
        Write-Host ""

        $repairBackupRoot = Join-Path `
            $BackupHome `
            ("OBS_REPAIR_BACKUPS\" + $stamp)

        $repairedAny = $false

        foreach ($repairGroup in @(
            $missingDetails |
            Group-Object RepairKey |
            Sort-Object `
                @{ Expression = { Get-ObsRepairPriority $_.Group[0] }; Ascending = $true }, `
                @{ Expression = { [string]$_.Group[0].SourceName }; Ascending = $true }
        )) {
            $firstDetail = $repairGroup.Group[0]

            Write-Host "----------------------------------------"
            Write-Warn "Отсутствует:"
            foreach ($detail in @($repairGroup.Group)) {
                Write-Host ("  " + [string]$detail.MissingPath) -ForegroundColor Yellow
            }

            Write-Info "Scene Collection: $($firstDetail.CollectionName)"
            Write-Info "Источник: $($firstDetail.SourceName)"
            Write-Info "Тип источника: $($firstDetail.SourceId)"

            if ($firstDetail.RepairType -eq "Filter") {
                Write-Info "Фильтр: $($firstDetail.FilterName)"
                Write-Info "Тип фильтра: $($firstDetail.FilterId)"
            }

            Write-Info "Настройка: $($firstDetail.PropertyPath)"
            Write-Warn (
                "Предлагаемое исправление: " +
                (Get-ObsRepairTargetDescription $firstDetail)
            )

            while ($true) {
                $repairAnswer = (
                    Read-Host "Удалить этот сломанный элемент из OBS? Y/N"
                ).Trim().ToUpperInvariant()

                if (
                    $repairAnswer -eq "Y" -or
                    $repairAnswer -eq "YES" -or
                    $repairAnswer -eq "Д" -or
                    $repairAnswer -eq "ДА"
                ) {
                    $repairResult = Repair-ObsMissingReferenceTarget `
                        @($repairGroup.Group) `
                        $repairBackupRoot

                    if ($repairResult.Success) {
                        $repairedAny = $true
                        Write-Ok "Элемент удалён из OBS Scene Collection."
                        Write-Info "Резервная копия Scene Collection перед repair:"
                        Write-Host $repairResult.BackupPath -ForegroundColor Yellow
                    }
                    else {
                        Write-Bad (
                            "Автоматическое удаление не удалось: " +
                            $repairResult.Message
                        )
                    }

                    break
                }

                if (
                    $repairAnswer -eq "N" -or
                    $repairAnswer -eq "NO" -or
                    $repairAnswer -eq "Н" -or
                    $repairAnswer -eq "НЕТ"
                ) {
                    Write-Warn "Элемент оставлен без изменений."
                    break
                }

                Write-Warn "Введите Y или N."
            }

            Write-Host ""
        }

        if ($repairedAny) {
            $postRepairJsonCheck = Test-JsonFilesValid $ConfigRoot

            if (-not $postRepairJsonCheck.Success) {
                throw (
                    "После repair обнаружен повреждённый JSON:`r`n" +
                    (@($postRepairJsonCheck.Errors) -join "`r`n")
                )
            }

            # Rebuild the config plan because Scene Collection files changed.
            $ConfigPlan = Get-TreePlan $ConfigRoot $configExclude

            if (@($ConfigPlan.ReparsePoints).Count -gt 0) {
                throw (
                    "После repair в config OBS обнаружены reparse points:`r`n" +
                    (@($ConfigPlan.ReparsePoints) -join "`r`n")
                )
            }

            Show-OverallProgress 11 "Повторная проверка отсутствующих элементов"
            $scan = Scan-ObsConfigReferences $ConfigRoot $skipRoots
        }

        if (@($scan.Missing).Count -gt 0) {
            $missingDetails = @(
                Get-ObsMissingReferenceDetails `
                    $sceneRoot `
                    @($scan.Missing)
            )

            Get-ObsMissingReferenceReportLines `
                @($scan.Missing) `
                $missingDetails |
                Set-Content `
                    -LiteralPath $missingFile `
                    -Encoding UTF8

            throw (
                "В OBS остались отсутствующие локальные элементы. " +
                "Backup остановлен, чтобы не помечать его как полный. " +
                "Список: $missingFile"
            )
        }

        Remove-Item `
            -LiteralPath $missingFile `
            -Force `
            -ErrorAction SilentlyContinue

        Write-Ok "Все отсутствующие элементы устранены. Backup продолжается."
    }

    $initialFiles = @(
        $scan.Existing |
        Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        }
    )

    $dependencyFiles = @(
        Expand-TextDependencies $initialFiles $skipRoots
    )

    # Do NOT automatically include the entire parent directory of a local
    # Browser Source. Only the HTML file + dependencies detected from
    # HTML/CSS/JS are copied. Copying the whole parent could include unrelated
    # large files which OBS no longer references.
    $safeWebDirectories = @()

    # A local Browser project is considered portable only when all detected
    # local dependencies stay inside its project directory.
    foreach ($htmlFile in @($scan.LocalHtml)) {
        $webRoot = [IO.Path]::GetDirectoryName($htmlFile)
        $webDependencies = @(
            Expand-TextDependencies @($htmlFile) $skipRoots
        )

        foreach ($dependency in $webDependencies) {
            if (Test-SamePath $dependency $htmlFile) {
                continue
            }

            if (-not (Test-PathInside $dependency $webRoot)) {
                throw (
                    "Local Browser Source '$htmlFile' использует локальный файл вне папки проекта: " +
                    "$dependency. Для гарантированного переноса переместите dependency внутрь '$webRoot'."
                )
            }
        }
    }

    $allExternal = @(
        $scan.Existing +
        $dependencyFiles +
        $safeWebDirectories
    )

    $extraSourcesFile = Join-Path $SettingsRoot "EXTRA_SOURCES.txt"

    if (Test-Path -LiteralPath $extraSourcesFile -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($extraSourcesFile)) {
            $value = $line.Trim()

            if (-not $value -or $value.StartsWith("#")) {
                continue
            }

            $path = Normalize-LocalReference $value

            if (-not $path) {
                throw "Некорректный путь в EXTRA_SOURCES.txt: $value"
            }

            if (
                -not (Test-Path -LiteralPath $path -PathType Leaf) -and
                -not (Test-Path -LiteralPath $path -PathType Container)
            ) {
                throw "Путь из EXTRA_SOURCES.txt не существует: $path"
            }

            if (Test-DriveRoot $path) {
                throw "Нельзя force-include корень диска: $path"
            }

            $allExternal += $path
        }
    }

    $externalPaths = @(
        Collapse-ExternalReferences (
            @($allExternal | Select-Object -Unique)
        )
    )

    foreach ($path in $externalPaths) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            if (
                (Test-SamePath $ToolRoot $path) -or
                (Test-PathInside $ToolRoot $path)
            ) {
                throw (
                    "Source-каталог содержит папку самого backup tool. " +
                    "Это вызовет рекурсивный backup: $path"
                )
            }
        }
    }

    $nameCounts = @{}

    foreach ($path in $externalPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $name = [IO.Path]::GetFileName($path)
            $key = $name.ToLowerInvariant()

            if (-not $nameCounts.ContainsKey($key)) {
                $nameCounts[$key] = 0
            }

            $nameCounts[$key]++
        }
    }

    $sourceAssets = New-Object System.Collections.ArrayList
    $storedSourceTargets = @{}
    [Int64]$sourceBytes = 0

    Show-OverallProgress 14 "Планирование Sources"

    foreach ($path in $externalPaths) {
        $storedRelative = New-StoredReferenceName `
            $path `
            $nameCounts

        $storedKey = $storedRelative.Replace("/", "\").ToLowerInvariant()
        if ($storedSourceTargets.ContainsKey($storedKey)) {
            throw (
                "Внутренняя коллизия путей Sources. Это крайне редкий случай:`r`n" +
                "$path`r`n" +
                [string]$storedSourceTargets[$storedKey]
            )
        }
        $storedSourceTargets[$storedKey] = $path

        $rawPlan = $null

        if (Test-Path -LiteralPath $path -PathType Container) {
            $rawPlan = Get-TreePlan $path
            $plan = $rawPlan

            if (@($plan.ReparsePoints).Count -gt 0) {
                throw (
                    "Source-каталог содержит symlink/junction/reparse point: " +
                    "$path`r`n" +
                    (@($plan.ReparsePoints) -join "`r`n")
                )
            }

            Confirm-LargeDirectoryPlan `
                $path `
                $rawPlan `
                "OBS source / Browser project / EXTRA_SOURCES"

            $plan = Add-PrefixToPlan $plan $storedRelative
        }
        else {
            $plan = New-SingleFilePlan $path $storedRelative
        }

        Assert-ReasonablePathLengths `
            $plan `
            $SourcesDestination

        $sourceBytes += [Int64]$plan.TotalBytes

        [void]$sourceAssets.Add([PSCustomObject]@{
            OriginalPath = $path
            StoredRelative = $storedRelative
            Type = $(
                if (Test-Path -LiteralPath $path -PathType Container) {
                    "Directory"
                }
                else {
                    "File"
                }
            )
            Size = [Int64]$plan.TotalBytes
            Plan = $plan
            RawPlan = $rawPlan
        })
    }

    Write-Host ""
    Write-Info "ЧТО ИМЕННО ПОПАДЁТ В SOURCES:"

    $largestSourceAssets = @(
        $sourceAssets |
        Sort-Object Size -Descending |
        Select-Object -First 10
    )

    foreach ($asset in $largestSourceAssets) {
        Write-Host (
            "  " +
            (Format-Bytes ([Int64]$asset.Size)).PadLeft(10) +
            "  " +
            [string]$asset.OriginalPath
        )
    }

    if ($sourceAssets.Count -gt 10) {
        Write-Info "Показаны 10 самых больших из $($sourceAssets.Count) корневых Sources."
    }

    $largeUnexpected = @(
        $sourceAssets |
        Where-Object { [Int64]$_.Size -ge 2GB } |
        Sort-Object Size -Descending
    )

    if ($largeUnexpected.Count -gt 0) {
        Write-Host ""
        Write-Warn "Найдены крупные Sources (>= 2 GB). Проверьте, что они действительно нужны OBS."

        foreach ($asset in $largeUnexpected) {
            Write-Warn (
                "  $(Format-Bytes ([Int64]$asset.Size))  $([string]$asset.OriginalPath)"
            )
        }

        while ($true) {
            $largeAnswer = (
                Read-Host "Продолжить backup с этими крупными файлами? Y/N"
            ).Trim().ToUpperInvariant()

            if (
                $largeAnswer -eq "Y" -or
                $largeAnswer -eq "YES" -or
                $largeAnswer -eq "Д" -or
                $largeAnswer -eq "ДА"
            ) {
                break
            }

            if (
                $largeAnswer -eq "N" -or
                $largeAnswer -eq "NO" -or
                $largeAnswer -eq "Н" -or
                $largeAnswer -eq "НЕТ"
            ) {
                throw (
                    "Backup остановлен пользователем после просмотра крупных Sources. " +
                    "Удалите ненужный Source из нужной Scene Collection OBS и запустите backup снова."
                )
            }

            Write-Warn "Введите Y или N."
        }
    }

    $customPlans = New-Object System.Collections.ArrayList
    [Int64]$customBytes = 0

    foreach ($custom in $customRoots) {
        if (
            (Test-SamePath $ToolRoot ([string]$custom.OriginalRoot)) -or
            (Test-PathInside $ToolRoot ([string]$custom.OriginalRoot))
        ) {
            throw (
                "Custom plugin path содержит папку tool и вызовет recursion: " +
                [string]$custom.OriginalRoot
            )
        }

        $rawCustomPlan = Get-TreePlan ([string]$custom.OriginalRoot)
        $plan = $rawCustomPlan

        if (@($plan.ReparsePoints).Count -gt 0) {
            throw (
                "Custom plugin path содержит reparse point: " +
                [string]$custom.OriginalRoot
            )
        }

        Confirm-LargeDirectoryPlan `
            ([string]$custom.OriginalRoot) `
            $rawCustomPlan `
            ("custom plugin env: " + [string]$custom.VariableName)

        $prefix = Join-Path ([string]$custom.Id) "root"
        $plan = Add-PrefixToPlan $plan $prefix

        Assert-ReasonablePathLengths `
            $plan `
            $CustomDestination

        $customBytes += [Int64]$plan.TotalBytes

        [void]$customPlans.Add([PSCustomObject]@{
            Id = [string]$custom.Id
            VariableName = [string]$custom.VariableName
            OriginalComponent = [string]$custom.OriginalComponent
            OriginalRoot = [string]$custom.OriginalRoot
            ModuleSuffix = [string]$custom.ModuleSuffix
            StoredPrefix = $prefix
            Plan = $plan
            RawPlan = $rawCustomPlan
        })
    }

    Assert-ReasonablePathLengths $ConfigPlan $ConfigDestination
    Assert-ReasonablePathLengths $ProgramPlan $ProgramDestination

    if ($LocalPlan) {
        Assert-ReasonablePathLengths $LocalPlan $LocalDestination
    }

    if ($ProgramDataPlan) {
        Assert-ReasonablePathLengths `
            $ProgramDataPlan `
            $ProgramDataDestination
    }

    Assert-FileSystemCanStorePlan $ConfigPlan $ConfigDestination
    Assert-FileSystemCanStorePlan $ProgramPlan $ProgramDestination

    if ($LocalPlan) {
        Assert-FileSystemCanStorePlan $LocalPlan $LocalDestination
    }

    if ($ProgramDataPlan) {
        Assert-FileSystemCanStorePlan $ProgramDataPlan $ProgramDataDestination
    }

    foreach ($asset in $sourceAssets) {
        if (
            -not $IncludeAccountData -and
            (Get-ObsAccountFileAction ([string]$asset.StoredRelative) ([string]$asset.OriginalPath)) -eq 'Omit'
        ) {
            throw 'В Sources включён профиль браузера или старая копия данных входа OBS. Исключите этот путь из EXTRA_SOURCES/источников либо выберите backup с данными аккаунтов.'
        }
        Assert-FileSystemCanStorePlan $asset.Plan $SourcesDestination
    }

    foreach ($customPlan in $customPlans) {
        Assert-FileSystemCanStorePlan $customPlan.Plan $CustomDestination
    }

    [Int64]$estimatedBytes =
        [Int64]$ConfigPlan.TotalBytes +
        [Int64]$ProgramPlan.TotalBytes +
        [Int64]$sourceBytes +
        [Int64]$customBytes

    if ($LocalPlan) {
        $estimatedBytes += [Int64]$LocalPlan.TotalBytes
    }

    if ($ProgramDataPlan) {
        $estimatedBytes += [Int64]$ProgramDataPlan.TotalBytes
    }

    Show-OverallProgress 18 "Проверка свободного места"
    Assert-FreeSpace `
        $BackupHome `
        $estimatedBytes `
        "основной backup"

    $sourcePlanReport = Join-Path $IncompleteRoot "SOURCE_PLAN.txt"

    @(
        "OBS Full Clone v1.3.1",
        "",
        "Файлы/папки, которые будут скопированы в Sources:",
        ""
    ) + @(
        $sourceAssets |
        Sort-Object Size -Descending |
        ForEach-Object {
            "$(Format-Bytes ([Int64]$_.Size))`t$([string]$_.OriginalPath)"
        }
    ) |
        Set-Content `
            -LiteralPath $sourcePlanReport `
            -Encoding UTF8

    Write-Info "Оценочный объём backup: $(Format-Bytes $estimatedBytes)"
    Write-Info "Sources: $($sourceAssets.Count) корневых ссылок, $(Format-Bytes $sourceBytes)"
    Write-Info "Полный список Sources: $sourcePlanReport"
    Write-Info "Полный снимок OBS: $(Format-Bytes $ProgramPlan.TotalBytes)"
    $FileManifest = New-Object System.Collections.ArrayList
    $DirectoryManifest = New-Object System.Collections.ArrayList

    Show-OverallProgress 22 "Копирование конфигурации OBS"

    Copy-PlanToBackup `
        $ConfigPlan `
        $ConfigDestination `
        $IncompleteRoot `
        "Config" `
        $FileManifest `
        $DirectoryManifest `
        "Конфигурация OBS" `
        $IncludeAccountData

    Assert-TreePlanUnchanged $ConfigRoot $ConfigPlan $configExclude

    if ($LocalPlan) {
        New-Item `
            -ItemType Directory `
            -Force `
            -Path $LocalDestination |
            Out-Null

        Show-OverallProgress 30 "Копирование LocalAppData OBS"

        Copy-PlanToBackup `
            $LocalPlan `
            $LocalDestination `
            $IncompleteRoot `
            "LocalAppData" `
            $FileManifest `
            $DirectoryManifest `
            "LocalAppData OBS" `
            $IncludeAccountData

        Assert-TreePlanUnchanged $LocalConfigRoot $LocalPlan $configExclude
    }

    Show-OverallProgress 36 "Полный снимок папки OBS + plugins"

    Copy-PlanToBackup `
        $ProgramPlan `
        $ProgramDestination `
        $IncompleteRoot `
        "ObsProgram" `
        $FileManifest `
        $DirectoryManifest `
        "OBS Studio + плагины" `
        $IncludeAccountData

    Assert-TreePlanUnchanged $ObsRoot $ProgramPlan $programExclude

    if ($ProgramDataPlan) {
        Show-OverallProgress 48 "Копирование ProgramData OBS"

        Copy-PlanToBackup `
            $ProgramDataPlan `
            $ProgramDataDestination `
            $IncompleteRoot `
            "ProgramData" `
            $FileManifest `
            $DirectoryManifest `
            "ProgramData OBS" `
            $IncludeAccountData

        Assert-TreePlanUnchanged $ProgramDataRoot $ProgramDataPlan $programDataExclude
    }

    if ($customPlans.Count -gt 0) {
        Show-OverallProgress 54 "Копирование custom plugin paths"

        foreach ($customPlan in $customPlans) {
            Copy-PlanToBackup `
                $customPlan.Plan `
                $CustomDestination `
                $IncompleteRoot `
                ([string]$customPlan.Id) `
                $FileManifest `
                $DirectoryManifest `
                "Custom OBS plugin path" `
                $IncludeAccountData

            Assert-TreePlanUnchanged `
                ([string]$customPlan.OriginalRoot) `
                $customPlan.RawPlan
        }
    }

    Show-OverallProgress 60 "Копирование всех Sources"

    foreach ($asset in $sourceAssets) {
        Copy-PlanToBackup `
            $asset.Plan `
            $SourcesDestination `
            $IncompleteRoot `
            "Sources" `
            $FileManifest `
            $DirectoryManifest `
            "OBS Sources" `
            $IncludeAccountData

        if ($asset.Type -eq "Directory") {
            Assert-TreePlanUnchanged `
                ([string]$asset.OriginalPath) `
                $asset.RawPlan
        }
    }

    Show-OverallProgress 70 "Формирование manifest"

    $sourceMapLines = @(
        "OBS FULL CLONE v1.3.1 - SOURCE MAP",
        "Создан: $((Get-Date).ToString('o'))",
        "",
        "СТАРЫЙ ПУТЬ -> ПУТЬ В BACKUP",
        "--------------------------------"
    )

    foreach ($asset in $sourceAssets) {
        $sourceMapLines += (
            "{0} -> Sources\\{1}" -f
            [string]$asset.OriginalPath,
            [string]$asset.StoredRelative
        )
    }

    $SourceMapPath = Join-Path $IncompleteRoot "SOURCE_MAP.txt"

    $sourceMapLines |
        Set-Content -LiteralPath $SourceMapPath -Encoding UTF8

    $RemotePath = Join-Path $IncompleteRoot "REMOTE_DEPENDENCIES.txt"

    @(
        "OBS FULL CLONE v1.3.1 - REMOTE DEPENDENCIES",
        "",
        "Эти URL найдены в конфигурации OBS.",
        "Они не являются локальными файлами и требуют сети/доступности сервиса.",
        ""
    ) + @($scan.Remote | Sort-Object) |
        Set-Content -LiteralPath $RemotePath -Encoding UTF8

    $SourcesHelpPath = Join-Path $IncompleteRoot "SOURCES_README.txt"

    @"
OBS Full Clone v1.3.1 - Sources
=============================

Все обнаруженные локальные файлы/папки, которые использовал OBS,
находятся в каталоге Sources.

После RESTORE они будут перенесены в:
%USERPROFILE%\Documents\OBS_Full_Clone\Sources

Restore сам перепишет старые пути в конфигурации OBS.

Если OBS всё равно откроет Missing Files:
Search Directory... -> выберите папку Sources выше.

SOURCE_MAP.txt показывает старый путь и его место внутри backup.
"@ |
        Set-Content -LiteralPath $SourcesHelpPath -Encoding UTF8

    $externalManifest = @(
        $sourceAssets |
        ForEach-Object {
            [PSCustomObject]@{
                OriginalPath = [string]$_.OriginalPath
                StoredRelative = [string]$_.StoredRelative
                Type = [string]$_.Type
                Size = [Int64]$_.Size
            }
        }
    )

    $customManifest = @(
        $customPlans |
        ForEach-Object {
            [PSCustomObject]@{
                Id = [string]$_.Id
                VariableName = [string]$_.VariableName
                OriginalComponent = [string]$_.OriginalComponent
                OriginalRoot = [string]$_.OriginalRoot
                ModuleSuffix = [string]$_.ModuleSuffix
                StoredPrefix = [string]$_.StoredPrefix
            }
        }
    )

    $Manifest = [PSCustomObject]@{
        ToolVersion = "1.3.1"
        CreatedAt = (Get-Date).ToString("o")
        ComputerName = $env:COMPUTERNAME
        OriginalUserProfile = $env:USERPROFILE
        OriginalObsExe = $ObsExe
        OriginalObsRoot = $ObsRoot
        OriginalObsInstallType = [string]$ObsInstallation.Type
        OriginalObsWasRunning = [bool]$ObsInstallation.IsRunning
        ObsVersion = $obsVersion
        OriginalLaunchCommandLine = $(if ($IncludeAccountData) { $runningCommandLine } else { $null })
        IsPortable = [bool]$configInfo.IsPortable
        OriginalConfigRoot = $ConfigRoot
        OriginalLocalConfigRoot = $LocalConfigRoot
        OriginalProgramDataRoot = $ProgramDataRoot
        ExternalAssets = $externalManifest
        ObsEnvironment = $environmentSnapshot
        CustomPluginPaths = $customManifest
        RemoteDependenciesCount = @($scan.Remote).Count
        AccountDataIncluded = [bool]$IncludeAccountData
        AccountDataPolicyVersion = 1
        TeleportExcluded = $true
    }

    $ManifestPath = Join-Path $IncompleteRoot "manifest.json"
    Write-JsonUtf8 $ManifestPath $Manifest 40

    $FileManifestPath = Join-Path $IncompleteRoot "file_manifest.json"
    Write-JsonUtf8 $FileManifestPath @($FileManifest) 20

    $DirectoryManifestPath = Join-Path $IncompleteRoot "directory_manifest.json"
    Write-JsonUtf8 $DirectoryManifestPath @($DirectoryManifest) 20

    $Integrity = [PSCustomObject]@{
        ToolVersion = "1.3.1"
        MissingSceneReferencesCount = @($scan.Missing).Count
        MissingSceneReferences = @($scan.Missing)
        RemoteDependenciesCount = @($scan.Remote).Count
        ExternalRootReferenceCount = $sourceAssets.Count
        ExternalSourceBytes = [Int64]$sourceBytes
        FileManifestEntries = $FileManifest.Count
        DirectoryManifestEntries = $DirectoryManifest.Count
        EstimatedBackupBytes = [Int64]$estimatedBytes
        ReparsePointsAccepted = 0
        AllDetectedLocalReferencesBackedUp = [bool]$IncludeAccountData
        FullObsProgramSnapshot = [bool]$IncludeAccountData
        AccountDataIncluded = [bool]$IncludeAccountData
        AccountDataPolicyVersion = 1
        TeleportExcluded = $true
    }

    $IntegrityPath = Join-Path $IncompleteRoot "integrity.json"
    Write-JsonUtf8 $IntegrityPath $Integrity 20

    # Runtime audit generated from the actual machine used for backup.
    $runtimeAudit = @"
OBS FULL CLONE v1.3.1 - RUNTIME AUDIT
===================================

OBS executable:
$ObsExe

OBS version:
$obsVersion

Config:
$ConfigRoot

Portable:
$($configInfo.IsPortable)

Program snapshot:
$(@($ProgramPlan.Files).Count) files
$(Format-Bytes $ProgramPlan.TotalBytes)

Config snapshot:
$(@($ConfigPlan.Files).Count) files
$(Format-Bytes $ConfigPlan.TotalBytes)

LocalAppData snapshot:
$(if ($LocalPlan) { @($LocalPlan.Files).Count } else { 0 }) files
$(if ($LocalPlan) { Format-Bytes $LocalPlan.TotalBytes } else { "0 B" })

ProgramData snapshot:
$(if ($ProgramDataPlan) { @($ProgramDataPlan.Files).Count } else { 0 }) files
$(if ($ProgramDataPlan) { Format-Bytes $ProgramDataPlan.TotalBytes } else { "0 B" })

Sources:
$($sourceAssets.Count) root references
$(Format-Bytes $sourceBytes)

Remote URLs:
$(@($scan.Remote).Count)

Custom OBS plugin paths:
$($customPlans.Count)

Missing local Scene references:
0

Reparse points accepted:
0

Teleport:
EXCLUDED INTENTIONALLY

Account data policy: $AccountDataSummary
"@

    $RuntimeAuditPath = Join-Path $IncompleteRoot "AUDIT_RUNTIME.txt"

    $runtimeAudit |
        Set-Content -LiteralPath $RuntimeAuditPath -Encoding UTF8

    # Make every backup self-contained for restore and verification.
    foreach ($name in @(
        "RESTORE_OBS.bat",
        "Restore-ObsBackup.ps1",
        "VERIFY_BACKUP.bat",
        "Verify-ObsBackup.ps1",
        "ObsClone.Common.ps1",
        "ObsClone.Repair.ps1"
    )) {
        $source = Join-Path $EngineRoot $name

        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "В tool отсутствует обязательный файл: $source"
        }

        Copy-Item `
            -LiteralPath $source `
            -Destination $IncompleteRoot `
            -Force
    }

    $BackupReadmePath = Join-Path $IncompleteRoot "README_BACKUP.txt"

    @"
OBS Full Clone v1.3.1 backup
==========================

Создан:
$((Get-Date).ToString('o'))

OBS:
$ObsExe

Версия:
$obsVersion

Перед восстановлением можно запустить VERIFY_BACKUP.bat.

Для восстановления:
1. Установите OBS Studio на новый Windows-ПК.
2. Распакуйте этот backup.
3. Запустите RESTORE_OBS.bat.
4. Restore сначала полностью проверит SHA-256 backup.
5. Только затем начнёт менять систему.

После Restore все локальные ресурсы будут здесь:
%USERPROFILE%\Documents\OBS_Full_Clone\Sources

Если OBS откроет Missing Files:
Search Directory... -> выберите эту папку Sources.

Данные аккаунтов:
$AccountDataSummary
Секреты в URL источников и сторонних плагинах не очищаются этим режимом.
Backup может содержать приватные данные и не предназначен для публикации.
"@ |
        Set-Content -LiteralPath $BackupReadmePath -Encoding UTF8

    Show-OverallProgress 76 "Создание hash-цепочки metadata"

    $metadataRelative = @(
        "manifest.json",
        "file_manifest.json",
        "directory_manifest.json",
        "integrity.json",
        "SOURCE_MAP.txt",
        "SOURCE_PLAN.txt",
        "REMOTE_DEPENDENCIES.txt",
        "SOURCES_README.txt",
        "AUDIT_RUNTIME.txt",
        "README_BACKUP.txt",
        "RESTORE_OBS.bat",
        "Restore-ObsBackup.ps1",
        "VERIFY_BACKUP.bat",
        "Verify-ObsBackup.ps1",
        "ObsClone.Common.ps1",
        "ObsClone.Repair.ps1"
    )

    $MetadataHashes = New-MetadataHashList `
        $IncompleteRoot `
        $metadataRelative

    $MetadataHashesPath = Join-Path $IncompleteRoot "metadata_hashes.json"
    Write-JsonUtf8 $MetadataHashesPath $MetadataHashes 20

    $metadataHashesSha = Get-Sha256Simple $MetadataHashesPath

    # Complete=false until full validation has succeeded.
    $Status = [PSCustomObject]@{
        ToolVersion = "1.3.1"
        Complete = $false
        CreatedAt = (Get-Date).ToString("o")
        MetadataHashesSHA256 = $metadataHashesSha
        FileCount = $FileManifest.Count
        ExternalRootReferenceCount = $sourceAssets.Count
        EstimatedPayloadBytes = [Int64]$estimatedBytes
        Warnings = @($Warnings)
        Errors = @()
    }

    $StatusPath = Join-Path $IncompleteRoot "backup_status.json"
    Write-JsonUtf8 $StatusPath $Status 20

    Show-OverallProgress 80 "Полная повторная SHA-256 проверка backup"

    $verification = Verify-BackupPackage `
        $IncompleteRoot `
        $true `
        $false

    if (-not $verification.Success) {
        $Status.Errors = @($verification.Errors)
        Write-JsonUtf8 $StatusPath $Status 20

        throw (
            "Полная проверка backup НЕ ПРОШЛА:`r`n" +
            (@($verification.Errors) -join "`r`n")
        )
    }

    Write-Ok "Полная SHA-256 проверка backup: OK"

    # Only now mark the package complete.
    $Status.Complete = $true
    Write-JsonUtf8 $StatusPath $Status 20

    if (Test-Path -LiteralPath $FinalRoot) {
        throw "Папка с именем готового backup уже существует: $FinalRoot"
    }

    Move-Item `
        -LiteralPath $IncompleteRoot `
        -Destination $FinalRoot

    $IncompleteRoot = $null
    $BackupFolderComplete = $true

    Write-Host ""
    Write-Ok "ОСНОВНАЯ ПАПКА BACKUP ГОТОВА И ПРОВЕРЕНА:"
    Write-Host $FinalRoot -ForegroundColor Yellow
    Write-Host ""

    Show-OverallProgress 90 "Создание ZIP"

    $FinalPlan = Get-TreePlan $FinalRoot
    [Int64]$folderBytes = [Int64]$FinalPlan.TotalBytes

    $ZipPath = "$FinalRoot.zip"
    $ZipShaPath = "$ZipPath.sha256"
    $zipCreated = $false
    $UnpackedBackupRemoved = $false

    $freeBytes = Get-FreeBytesForPath $BackupHome
    [Int64]$zipNeed = [Int64](512MB)
    [Int64]$zipNeedBySize = [Int64][Math]::Ceiling(
        [double]$folderBytes * 1.05
    )

    if ($zipNeedBySize -gt $zipNeed) {
        $zipNeed = $zipNeedBySize
    }

    $backupDriveFormat = Get-DriveFormatForPath $BackupHome
    $fat32ZipTooLarge = (
        $backupDriveFormat -eq "FAT32" -and
        $folderBytes -gt 4000000000
    )

    if ($fat32ZipTooLarge) {
        Add-Warning (
            "Основная backup-папка готова, но ZIP больше 4 GB нельзя записать на FAT32. " +
            "ZIP пропущен. Используйте NTFS/exFAT для одного большого архива."
        )
    }
    elseif ($freeBytes -ge $zipNeed) {
        try {
            Zip-DirectoryWithProgress $FinalRoot $ZipPath

            Show-OverallProgress 95 "Полная SHA-256 проверка ZIP"
            Verify-ZipAgainstFolder $FinalRoot $ZipPath

            Show-OverallProgress 98 "SHA-256 всего ZIP"

            [Int64]$zipSize = (Get-Item -LiteralPath $ZipPath).Length
            [Int64]$zipDone = 0

            $zipHash = Get-Sha256WithProgress `
                $ZipPath `
                ([ref]$zipDone) `
                $zipSize `
                "SHA-256 ZIP" `
                "SHA-256: "

            Complete-SubProgress

            (
                "$zipHash *" +
                [IO.Path]::GetFileName($ZipPath)
            ) |
                Set-Content -LiteralPath $ZipShaPath -Encoding ASCII

            $zipCreated = $true
        }
        catch {
            Remove-Item `
                -LiteralPath $ZipPath `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                -LiteralPath $ZipShaPath `
                -Force `
                -ErrorAction SilentlyContinue

            Add-Warning (
                "Основная backup-папка полностью готова и проверена, " +
                "но ZIP создать/проверить не удалось: " +
                $_.Exception.Message
            )
        }
    }
    else {
        Add-Warning (
            "Папка backup полностью готова и проверена, но для второго " +
            "экземпляра данных в ZIP не хватает свободного места. ZIP пропущен."
        )
    }

    if ($zipCreated) {
        $archiveStillVerified = $false
        try {
            Show-OverallProgress 99 "Удаление распакованной копии backup"
            $UnpackedBackupRemoved = Remove-VerifiedObsBackupFolder $FinalRoot $BackupHome $ZipPath $zipCreated $zipHash ([ref]$archiveStillVerified)
        }
        catch {
            # A cleanup failure must never delete the already verified ZIP.
            if ($archiveStillVerified) {
                Add-Warning ("Не удалось полностью удалить распакованную папку: " + $FinalRoot + ". Проверенный ZIP сохранён. " + $_.Exception.Message)
            }
            else {
                $zipCreated = $false
                Add-Warning ("Повторная проверка ZIP перед удалением не прошла. Сохраните всю распакованную папку: " + $FinalRoot + ". " + $_.Exception.Message)
            }
        }
    }

    Show-OverallProgress 100 "Готово"
    Complete-AllProgress

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "               BACKUP ГОТОВ — УСПЕШНО" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Ok "Backup создан с выбранными параметрами и проверен SHA-256."
    Write-Info $AccountDataSummary
    Write-Host ""

    if ($zipCreated) {
        $zipSizeText = "неизвестно"

        try {
            $zipSizeText = Format-Bytes (
                (Get-Item -LiteralPath $ZipPath -ErrorAction Stop).Length
            )
        }
        catch {}

        Write-Info "ЧТО НУЖНО СОХРАНИТЬ:"
        Write-Host "1. ZIP backup — это основной файл для переноса:" -ForegroundColor White
        Write-Host "   $ZipPath" -ForegroundColor Yellow
        Write-Host "   Размер: $zipSizeText" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "2. SHA-256 файл — нужен для проверки ZIP:" -ForegroundColor White
        Write-Host "   $ZipShaPath" -ForegroundColor Yellow
        Write-Host ""

        Write-Info "ВАЖНО:"
        Write-Host "- Отдельно копировать папку Sources НЕ НУЖНО — она уже внутри ZIP."
        if ($UnpackedBackupRemoved) {
            Write-Ok "Распакованная папка backup удалена. Остались ZIP и .sha256."
        }
        else {
            Write-Warn "Остатки распакованной папки можно удалить вручную: $FinalRoot"
        }
        Open-ObsBackupArchiveLocation $ZipPath
    }
    else {
        Write-Warn "ZIP не создан или не прошёл проверку. Основная папка backup полностью готова и проверена."
        Write-Info "ЧТО НУЖНО СОХРАНИТЬ:"
        Write-Host "Скопируйте ВСЮ эту папку целиком:" -ForegroundColor White
        Write-Host "  $FinalRoot" -ForegroundColor Yellow
        Write-Host ""
        Write-Warn "Не копируйте только Sources отдельно — для восстановления нужна вся папка."
    }

    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Info "ЧТО ДЕЛАТЬ ДАЛЬШЕ:"
    Write-Host "1. Скопируйте backup на другой физический диск, флешку/NAS или в облако."
    if ($zipCreated) {
        Write-Host "   Рекомендуемый набор: ZIP + .sha256."
    }
    else {
        Write-Host "   Рекомендуемый набор: вся папка backup целиком."
    }
    Write-Host "2. После переустановки Windows установите OBS Studio."
    Write-Host "3. Верните backup на новый ПК."
    if ($zipCreated) {
        Write-Host "4. Распакуйте ZIP."
        Write-Host "5. Внутри распакованного backup запустите RESTORE_OBS.bat."
    }
    else {
        Write-Host "4. Откройте сохранённую папку backup."
        Write-Host "5. Запустите RESTORE_OBS.bat."
    }
    Write-Host "6. Restore сначала проверит целостность и только потом изменит OBS."
    Write-Host ""
    Write-Warn "Не переименовывайте и не перемещайте файлы внутри backup вручную."
    Write-Host "============================================================" -ForegroundColor Green

    Show-AuthorSupportBlock
    Open-AuthorPagesPrompt
}
catch {
    Complete-AllProgress

    Write-Host ""
    Write-Bad "BACKUP ОСТАНОВЛЕН: $($_.Exception.Message)"

    if (
        $BackupFolderComplete -and
        $FinalRoot -and
        (Test-Path -LiteralPath $FinalRoot -PathType Container)
    ) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Host "        ОСНОВНОЙ BACKUP УСПЕШЕН, ZIP НЕ ЗАВЕРШЁН" -ForegroundColor Yellow
        Write-Host "============================================================" -ForegroundColor Yellow
        Write-Ok "Основная папка backup уже полностью создана и проверена SHA-256."
        Write-Info "Ошибка произошла только после этого этапа."
        Write-Info "СОХРАНИТЕ ВСЮ ЭТУ ПАПКУ ЦЕЛИКОМ:"
        Write-Host $FinalRoot -ForegroundColor Yellow
        Write-Host ""
        Write-Warn "Не копируйте только Sources — для восстановления нужна вся папка."
        Write-Info "После переноса на другой ПК запустите внутри неё RESTORE_OBS.bat."
        Write-Info "Проверенный backup автоматически удалять не буду."
        Write-Host "============================================================" -ForegroundColor Yellow
    }
    elseif (
        $IncompleteRoot -and
        (Test-Path -LiteralPath $IncompleteRoot -PathType Container)
    ) {
        try {
            $failedStatus = [PSCustomObject]@{
                ToolVersion = "1.3.1"
                Complete = $false
                FailedAt = (Get-Date).ToString("o")
                Error = $_.Exception.Message
                Warnings = @($Warnings)
            }

            Write-JsonUtf8 `
                (Join-Path $IncompleteRoot "backup_status.json") `
                $failedStatus `
                20
        }
        catch {}

        Write-Host ""
        Write-Warn "НЕУСПЕШНЫЙ / НЕЗАВЕРШЁННЫЙ BACKUP НАХОДИТСЯ ЗДЕСЬ:"
        Write-Host $IncompleteRoot -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $deleteAnswer = (
                Read-Host "Удалить незавершённый backup? Y/N"
            ).Trim().ToUpperInvariant()

            if (
                $deleteAnswer -eq "Y" -or
                $deleteAnswer -eq "YES" -or
                $deleteAnswer -eq "Д" -or
                $deleteAnswer -eq "ДА"
            ) {
                try {
                    Remove-Item `
                        -LiteralPath $IncompleteRoot `
                        -Recurse `
                        -Force `
                        -ErrorAction Stop

                    Write-Ok "Незавершённый backup удалён."
                }
                catch {
                    Write-Bad (
                        "Не удалось удалить незавершённый backup: " +
                        $_.Exception.Message
                    )
                    Write-Warn "Удалите его вручную:"
                    Write-Warn $IncompleteRoot
                }

                break
            }

            if (
                $deleteAnswer -eq "N" -or
                $deleteAnswer -eq "NO" -or
                $deleteAnswer -eq "Н" -or
                $deleteAnswer -eq "НЕТ"
            ) {
                Write-Warn "Незавершённый backup оставлен для диагностики:"
                Write-Warn $IncompleteRoot
                break
            }

            Write-Warn "Введите Y или N."
        }
    }

    exit 1
}
