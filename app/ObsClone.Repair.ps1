#requires -Version 5.1
# OBS Full Clone Tool v1.3.0 - Missing-reference diagnostics and repair

Set-StrictMode -Version 2.0

$script:ObsCloneRepairBackups = @{}

function Get-ObsObjectProperty(
    $Object,
    [string]$Name
) {
    if ($null -eq $Object) {
        return $null
    }

    try {
        $property = $Object.PSObject.Properties[$Name]

        if ($property) {
            return $property.Value
        }
    }
    catch {}

    return $null
}

function ConvertTo-ObsRepairPath(
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
            return [IO.Path]::GetFullPath(($text -replace '/', '\'))
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
        if ($text -match '[<>:"|?*\x00-\x1F]') {
            return $null
        }

        if (
            $text.Contains("\") -or
            $text.Contains("/") -or
            (Get-PathExtensionSafe $text)
        ) {
            try {
                return [IO.Path]::GetFullPath(
                    (Join-Path $BaseDirectory ($text -replace '/', '\'))
                )
            }
            catch {}
        }
    }

    return $null
}

function New-ObsMissingPathMap([string[]]$MissingPaths) {
    $map = @{}

    foreach ($path in @($MissingPaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        try {
            $full = [IO.Path]::GetFullPath([string]$path)
            $map[$full.ToLowerInvariant()] = $full
        }
        catch {}
    }

    return $map
}

function Get-ObsRepairStringMatches(
    $Object,
    [string]$BaseDirectory,
    [hashtable]$MissingMap,
    [string]$PropertyPath = ""
) {
    if ($null -eq $Object) {
        return
    }

    if ($Object -is [string]) {
        $candidate = ConvertTo-ObsRepairPath `
            ([string]$Object) `
            $BaseDirectory

        if ($candidate) {
            $key = $candidate.ToLowerInvariant()

            if ($MissingMap.ContainsKey($key)) {
                [PSCustomObject]@{
                    MissingPath = [string]$MissingMap[$key]
                    PropertyPath = $PropertyPath
                    RawValue = [string]$Object
                }
            }
        }

        return
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($property in $Object.PSObject.Properties) {
            $nextPath = [string]$property.Name
            if ($PropertyPath) {
                $nextPath = "$PropertyPath.$($property.Name)"
            }

            Get-ObsRepairStringMatches `
                $property.Value `
                $BaseDirectory `
                $MissingMap `
                $nextPath
        }

        return
    }

    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($keyName in $Object.Keys) {
            $nextPath = [string]$keyName
            if ($PropertyPath) {
                $nextPath = "$PropertyPath.$keyName"
            }

            Get-ObsRepairStringMatches `
                $Object[$keyName] `
                $BaseDirectory `
                $MissingMap `
                $nextPath
        }

        return
    }

    if (
        $Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string])
    ) {
        $index = 0

        foreach ($item in $Object) {
            $nextPath = "[$index]"
            if ($PropertyPath) {
                $nextPath = "$PropertyPath[$index]"
            }

            Get-ObsRepairStringMatches `
                $item `
                $BaseDirectory `
                $MissingMap `
                $nextPath

            $index++
        }
    }
}

function Get-ObsMissingReferenceDetails(
    [string]$SceneRoot,
    [string[]]$MissingPaths
) {
    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    $missingMap = New-ObsMissingPathMap $MissingPaths

    if (
        $missingMap.Count -eq 0 -or
        -not (Test-Path -LiteralPath $SceneRoot -PathType Container)
    ) {
        return @()
    }

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $SceneRoot `
            -File `
            -Filter "*.json" `
            -Force `
            -ErrorAction SilentlyContinue
    )) {
        $json = $null

        try {
            $json = Read-JsonFile $file.FullName
        }
        catch {
            continue
        }

        $sources = @($json.sources)

        for ($sourceIndex = 0; $sourceIndex -lt $sources.Count; $sourceIndex++) {
            $source = $sources[$sourceIndex]

            if ($null -eq $source) {
                continue
            }

            $sourceName = [string](Get-ObsObjectProperty $source "name")
            $sourceUuid = [string](Get-ObsObjectProperty $source "uuid")
            $sourceId = [string](Get-ObsObjectProperty $source "id")
            $sourceSettings = Get-ObsObjectProperty $source "settings"

            foreach ($match in @(
                Get-ObsRepairStringMatches `
                    $sourceSettings `
                    $file.DirectoryName `
                    $missingMap `
                    "settings"
            )) {
                $repairType = "Source"

                if (
                    [string]$match.PropertyPath -match
                    '(?i)(^|\.|\])playlist(?:\[|\.|$)'
                ) {
                    $repairType = "PlaylistEntry"
                }

                $repairKey = (
                    "$repairType|" +
                    $file.FullName.ToLowerInvariant() + "|" +
                    $sourceUuid + "|" +
                    $sourceName
                )

                if ($repairType -eq "PlaylistEntry") {
                    $repairKey += "|" + ([string]$match.MissingPath).ToLowerInvariant()
                }

                $detailKey = (
                    $repairKey + "|" +
                    ([string]$match.MissingPath).ToLowerInvariant() + "|" +
                    [string]$match.PropertyPath
                )

                if (-not $seen.ContainsKey($detailKey)) {
                    $seen[$detailKey] = $true

                    [void]$results.Add([PSCustomObject]@{
                        ConfigFile = $file.FullName
                        CollectionName = $file.BaseName
                        SourceName = $sourceName
                        SourceUuid = $sourceUuid
                        SourceId = $sourceId
                        SourceIndex = $sourceIndex
                        FilterName = ""
                        FilterUuid = ""
                        FilterId = ""
                        FilterIndex = -1
                        RepairType = $repairType
                        RepairKey = $repairKey
                        MissingPath = [string]$match.MissingPath
                        PropertyPath = [string]$match.PropertyPath
                    })
                }
            }

            $filtersValue = Get-ObsObjectProperty $source "filters"
            $filters = @()

            if ($null -ne $filtersValue) {
                $filters = @($filtersValue)
            }

            for ($filterIndex = 0; $filterIndex -lt $filters.Count; $filterIndex++) {
                $filter = $filters[$filterIndex]

                if ($null -eq $filter) {
                    continue
                }

                $filterSettings = Get-ObsObjectProperty $filter "settings"

                foreach ($match in @(
                    Get-ObsRepairStringMatches `
                        $filterSettings `
                        $file.DirectoryName `
                        $missingMap `
                        "filter.settings"
                )) {
                    $filterName = [string](Get-ObsObjectProperty $filter "name")
                    $filterUuid = [string](Get-ObsObjectProperty $filter "uuid")
                    $filterId = [string](Get-ObsObjectProperty $filter "id")

                    $repairKey = (
                        "Filter|" +
                        $file.FullName.ToLowerInvariant() + "|" +
                        $sourceUuid + "|" +
                        $sourceName + "|" +
                        $filterUuid + "|" +
                        $filterName
                    )

                    $detailKey = (
                        $repairKey + "|" +
                        ([string]$match.MissingPath).ToLowerInvariant() + "|" +
                        [string]$match.PropertyPath
                    )

                    if (-not $seen.ContainsKey($detailKey)) {
                        $seen[$detailKey] = $true

                        [void]$results.Add([PSCustomObject]@{
                            ConfigFile = $file.FullName
                            CollectionName = $file.BaseName
                            SourceName = $sourceName
                            SourceUuid = $sourceUuid
                            SourceId = $sourceId
                            SourceIndex = $sourceIndex
                            FilterName = $filterName
                            FilterUuid = $filterUuid
                            FilterId = $filterId
                            FilterIndex = $filterIndex
                            RepairType = "Filter"
                            RepairKey = $repairKey
                            MissingPath = [string]$match.MissingPath
                            PropertyPath = [string]$match.PropertyPath
                        })
                    }
                }
            }
        }
    }

    return @($results)
}

function Get-ObsRepairPriority($Detail) {
    switch ([string]$Detail.RepairType) {
        "Filter" {
            return 10
        }

        "PlaylistEntry" {
            return 20
        }

        "Source" {
            return 30
        }

        default {
            return 100
        }
    }
}

function Get-ObsRepairTargetDescription($Detail) {
    switch ([string]$Detail.RepairType) {
        "Filter" {
            return (
                "Удалить фильтр '$($Detail.FilterName)' " +
                "у источника '$($Detail.SourceName)'"
            )
        }

        "PlaylistEntry" {
            return (
                "Удалить только отсутствующий элемент playlist " +
                "из источника '$($Detail.SourceName)'"
            )
        }

        "Source" {
            return (
                "Удалить источник '$($Detail.SourceName)' " +
                "и его размещения в сценах этой коллекции"
            )
        }
    }

    return "Автоматическое исправление недоступно"
}

function Get-ObsMissingReferenceReportLines(
    [string[]]$MissingPaths,
    $Details
) {
    $lines = New-Object System.Collections.ArrayList

    [void]$lines.Add("OBS Full Clone v1.3.0")
    [void]$lines.Add("")
    [void]$lines.Add("Отсутствующие локальные ссылки:")
    [void]$lines.Add("")

    $detailIndex = 0

    foreach ($group in @($Details | Group-Object RepairKey)) {
        $detailIndex++
        $first = $group.Group[0]

        [void]$lines.Add("[$detailIndex]")
        [void]$lines.Add("Коллекция: $($first.CollectionName)")
        [void]$lines.Add("Файл коллекции: $($first.ConfigFile)")
        [void]$lines.Add("Источник: $($first.SourceName)")
        [void]$lines.Add("Тип источника: $($first.SourceId)")

        if ($first.RepairType -eq "Filter") {
            [void]$lines.Add("Фильтр: $($first.FilterName)")
            [void]$lines.Add("Тип фильтра: $($first.FilterId)")
        }

        [void]$lines.Add("Что можно сделать: $(Get-ObsRepairTargetDescription $first)")

        foreach ($detail in @($group.Group)) {
            [void]$lines.Add("Отсутствует: $($detail.MissingPath)")
            [void]$lines.Add("Настройка: $($detail.PropertyPath)")
        }

        [void]$lines.Add("")
    }

    $mapped = @{}
    foreach ($detail in @($Details)) {
        $mapped[([string]$detail.MissingPath).ToLowerInvariant()] = $true
    }

    foreach ($path in @($MissingPaths | Sort-Object -Unique)) {
        if (-not $mapped.ContainsKey(([string]$path).ToLowerInvariant())) {
            [void]$lines.Add("[НЕ ОПРЕДЕЛЁН ЭЛЕМЕНТ]")
            [void]$lines.Add("Отсутствует: $path")
            [void]$lines.Add(
                "Не удалось безопасно определить источник/фильтр для автоматического удаления."
            )
            [void]$lines.Add("")
        }
    }

    return @($lines)
}

function Save-ObsSceneCollectionRepairBackup(
    [string]$ConfigFile,
    [string]$RepairBackupRoot
) {
    $full = [IO.Path]::GetFullPath($ConfigFile)
    $key = $full.ToLowerInvariant()

    if ($script:ObsCloneRepairBackups.ContainsKey($key)) {
        return [string]$script:ObsCloneRepairBackups[$key]
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $RepairBackupRoot |
        Out-Null

    $destination = Join-Path `
        $RepairBackupRoot `
        ([IO.Path]::GetFileName($ConfigFile))

    if (Test-Path -LiteralPath $destination) {
        $destination = Join-Path `
            $RepairBackupRoot `
            (
                [IO.Path]::GetFileNameWithoutExtension($ConfigFile) +
                "_" +
                [Guid]::NewGuid().ToString("N").Substring(0, 8) +
                ".json"
            )
    }

    Copy-Item `
        -LiteralPath $ConfigFile `
        -Destination $destination `
        -Force

    $script:ObsCloneRepairBackups[$key] = $destination
    return $destination
}

function Find-ObsRepairSource($Json, $Detail) {
    $sources = @($Json.sources)

    for ($i = 0; $i -lt $sources.Count; $i++) {
        $source = $sources[$i]

        if ($null -eq $source) {
            continue
        }

        if (
            $Detail.SourceUuid -and
            [string](Get-ObsObjectProperty $source "uuid") -eq [string]$Detail.SourceUuid
        ) {
            return [PSCustomObject]@{
                Source = $source
                Index = $i
            }
        }
    }

    for ($i = 0; $i -lt $sources.Count; $i++) {
        $source = $sources[$i]

        if ($null -eq $source) {
            continue
        }

        if (
            [string](Get-ObsObjectProperty $source "name") -eq [string]$Detail.SourceName -and
            (
                -not $Detail.SourceId -or
                [string](Get-ObsObjectProperty $source "id") -eq [string]$Detail.SourceId
            )
        ) {
            return [PSCustomObject]@{
                Source = $source
                Index = $i
            }
        }
    }

    return $null
}

function Remove-ObsSceneItemReferences(
    $Object,
    [string]$TargetUuid,
    [string]$TargetName,
    [ref]$Removed
) {
    if ($null -eq $Object) {
        return
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($property in @($Object.PSObject.Properties)) {
            if (
                [string]$property.Name -eq "items" -and
                $property.Value -is [System.Collections.IEnumerable] -and
                -not ($property.Value -is [string])
            ) {
                $newItems = New-Object System.Collections.ArrayList

                foreach ($item in @($property.Value)) {
                    $remove = $false

                    if ($item -is [PSCustomObject]) {
                        if (
                            $TargetUuid -and
                            [string](Get-ObsObjectProperty $item "source_uuid") -eq $TargetUuid
                        ) {
                            $remove = $true
                        }
                        elseif (
                            -not $TargetUuid -and
                            $TargetName -and
                            [string](Get-ObsObjectProperty $item "name") -eq $TargetName
                        ) {
                            $remove = $true
                        }
                    }

                    if ($remove) {
                        $Removed.Value = [int]$Removed.Value + 1
                        continue
                    }

                    Remove-ObsSceneItemReferences `
                        $item `
                        $TargetUuid `
                        $TargetName `
                        $Removed

                    [void]$newItems.Add($item)
                }

                $Object.($property.Name) = @($newItems)
            }
            else {
                Remove-ObsSceneItemReferences `
                    $property.Value `
                    $TargetUuid `
                    $TargetName `
                    $Removed
            }
        }

        return
    }

    if (
        $Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string])
    ) {
        foreach ($item in $Object) {
            Remove-ObsSceneItemReferences `
                $item `
                $TargetUuid `
                $TargetName `
                $Removed
        }
    }
}

function Remove-ObsPlaylistMissingPath(
    $Object,
    [string]$MissingPath,
    [string]$BaseDirectory,
    [ref]$Removed
) {
    if ($null -eq $Object) {
        return
    }

    if ($Object -is [PSCustomObject]) {
        foreach ($property in @($Object.PSObject.Properties)) {
            if (
                [string]$property.Name -eq "playlist" -and
                $property.Value -is [System.Collections.IEnumerable] -and
                -not ($property.Value -is [string])
            ) {
                $newEntries = New-Object System.Collections.ArrayList

                foreach ($entry in @($property.Value)) {
                    $entryPath = $null

                    if ($entry -is [string]) {
                        $entryPath = ConvertTo-ObsRepairPath `
                            ([string]$entry) `
                            $BaseDirectory
                    }
                    elseif ($entry -is [PSCustomObject]) {
                        foreach ($candidateName in @(
                            "value",
                            "path",
                            "file",
                            "local_file"
                        )) {
                            $candidateProperty = $entry.PSObject.Properties[$candidateName]

                            if (
                                $candidateProperty -and
                                $candidateProperty.Value -is [string]
                            ) {
                                $entryPath = ConvertTo-ObsRepairPath `
                                    ([string]$candidateProperty.Value) `
                                    $BaseDirectory

                                if ($entryPath) {
                                    break
                                }
                            }
                        }
                    }

                    if (
                        $entryPath -and
                        (Test-SamePath $entryPath $MissingPath)
                    ) {
                        $Removed.Value = [int]$Removed.Value + 1
                        continue
                    }

                    [void]$newEntries.Add($entry)
                }

                $Object.($property.Name) = @($newEntries)
            }
            else {
                Remove-ObsPlaylistMissingPath `
                    $property.Value `
                    $MissingPath `
                    $BaseDirectory `
                    $Removed
            }
        }

        return
    }

    if (
        $Object -is [System.Collections.IEnumerable] -and
        -not ($Object -is [string])
    ) {
        foreach ($item in $Object) {
            Remove-ObsPlaylistMissingPath `
                $item `
                $MissingPath `
                $BaseDirectory `
                $Removed
        }
    }
}

function Repair-ObsMissingReferenceTarget(
    $Details,
    [string]$RepairBackupRoot
) {
    $detailsArray = @($Details)

    if ($detailsArray.Count -eq 0) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Нет данных для repair."
            BackupPath = ""
            Removed = 0
        }
    }

    $detail = $detailsArray[0]
    $configFile = [string]$detail.ConfigFile
    $backupPath = Save-ObsSceneCollectionRepairBackup `
        $configFile `
        $RepairBackupRoot

    $json = Read-JsonFile $configFile
    $target = Find-ObsRepairSource $json $detail

    if (-not $target) {
        return [PSCustomObject]@{
            Success = $false
            Message = "Не найден исходный OBS source для repair."
            BackupPath = $backupPath
            Removed = 0
        }
    }

    [int]$removed = 0

    try {
        switch ([string]$detail.RepairType) {
            "Filter" {
                $filtersValue = Get-ObsObjectProperty $target.Source "filters"
                $filters = @()

                if ($null -ne $filtersValue) {
                    $filters = @($filtersValue)
                }

                $newFilters = New-Object System.Collections.ArrayList
                $matched = $false

                for ($i = 0; $i -lt $filters.Count; $i++) {
                    $filter = $filters[$i]
                    $remove = $false

                    if (
                        $detail.FilterUuid -and
                        [string](Get-ObsObjectProperty $filter "uuid") -eq [string]$detail.FilterUuid
                    ) {
                        $remove = $true
                    }
                    elseif (
                        -not $detail.FilterUuid -and
                        [string](Get-ObsObjectProperty $filter "name") -eq [string]$detail.FilterName -and
                        (
                            -not $detail.FilterId -or
                            [string](Get-ObsObjectProperty $filter "id") -eq [string]$detail.FilterId
                        )
                    ) {
                        $remove = $true
                    }

                    if ($remove -and -not $matched) {
                        $removed++
                        $matched = $true
                        continue
                    }

                    [void]$newFilters.Add($filter)
                }

                $filtersProperty = $target.Source.PSObject.Properties["filters"]

                if ($filtersProperty) {
                    $target.Source.filters = @($newFilters)
                }
                else {
                    Add-Member `
                        -InputObject $target.Source `
                        -NotePropertyName "filters" `
                        -NotePropertyValue @($newFilters)
                }
            }

            "PlaylistEntry" {
                foreach ($path in @(
                    $detailsArray.MissingPath |
                    Sort-Object -Unique
                )) {
                    $targetSettings = Get-ObsObjectProperty $target.Source "settings"

                    Remove-ObsPlaylistMissingPath `
                        $targetSettings `
                        ([string]$path) `
                        ([IO.Path]::GetDirectoryName($configFile)) `
                        ([ref]$removed)
                }
            }

            "Source" {
                $sources = @($json.sources)
                $newSources = New-Object System.Collections.ArrayList
                $removedSource = $false

                foreach ($source in $sources) {
                    $remove = $false

                    if (
                        $detail.SourceUuid -and
                        [string](Get-ObsObjectProperty $source "uuid") -eq [string]$detail.SourceUuid
                    ) {
                        $remove = $true
                    }
                    elseif (
                        -not $detail.SourceUuid -and
                        [string](Get-ObsObjectProperty $source "name") -eq [string]$detail.SourceName -and
                        (
                            -not $detail.SourceId -or
                            [string](Get-ObsObjectProperty $source "id") -eq [string]$detail.SourceId
                        )
                    ) {
                        $remove = $true
                    }

                    if ($remove -and -not $removedSource) {
                        $removed++
                        $removedSource = $true
                        continue
                    }

                    [void]$newSources.Add($source)
                }

                $json.sources = @($newSources)

                foreach ($source in @($json.sources)) {
                    $sourceSettings = Get-ObsObjectProperty $source "settings"

                    Remove-ObsSceneItemReferences `
                        $sourceSettings `
                        ([string]$detail.SourceUuid) `
                        ([string]$detail.SourceName) `
                        ([ref]$removed)
                }
            }

            default {
                return [PSCustomObject]@{
                    Success = $false
                    Message = "Этот тип ссылки нельзя безопасно удалить автоматически."
                    BackupPath = $backupPath
                    Removed = 0
                }
            }
        }

        if ($removed -le 0) {
            return [PSCustomObject]@{
                Success = $false
                Message = "Repair не нашёл элемент, который нужно удалить."
                BackupPath = $backupPath
                Removed = 0
            }
        }

        Write-JsonUtf8 $configFile $json 100

        try {
            [void](Read-JsonFile $configFile)
        }
        catch {
            Copy-Item `
                -LiteralPath $backupPath `
                -Destination $configFile `
                -Force

            throw (
                "После repair Scene Collection JSON стал невалидным. " +
                "Исходный файл автоматически восстановлен."
            )
        }

        return [PSCustomObject]@{
            Success = $true
            Message = (Get-ObsRepairTargetDescription $detail)
            BackupPath = $backupPath
            Removed = $removed
        }
    }
    catch {
        try {
            Copy-Item `
                -LiteralPath $backupPath `
                -Destination $configFile `
                -Force
        }
        catch {}

        return [PSCustomObject]@{
            Success = $false
            Message = $_.Exception.Message
            BackupPath = $backupPath
            Removed = 0
        }
    }
}
