#requires -Version 5.1
# OBS Full Clone Tool v1.3.0 - Common library
# Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:OverallPercent = 0
$script:OverallStatus = "Подготовка"
$script:ByteProgressActivity = $null
$script:ByteProgressTotal = [Int64]0
$script:ByteProgressLastDone = [Int64]0
$script:ByteProgressStartedUtc = [DateTime]::UtcNow
$script:ByteProgressLastRenderUtc = [DateTime]::MinValue
$script:ProgressRenderIntervalMs = 250
$script:CompactProgressActive = $false

function Get-ObsBackToolLayout([string]$EngineRoot) {
    $engine = [IO.Path]::GetFullPath($EngineRoot).TrimEnd([char[]]"\/")
    $parent = [IO.Path]::GetDirectoryName($engine)
    $tool = $engine
    $settings = $engine
    if (
        [IO.Path]::GetFileName($engine) -ieq 'app' -and
        -not [string]::IsNullOrWhiteSpace($parent) -and
        (Test-Path -LiteralPath (Join-Path $parent 'OBSback.bat') -PathType Leaf)
    ) {
        $tool = $parent
        $settings = Join-Path $parent 'settings'
    }
    return [PSCustomObject]@{ EngineRoot = $engine; ToolRoot = $tool; SettingsRoot = $settings }
}

function Get-SafeConsoleWidth {
    [int]$width = 110

    try {
        $candidate = [Console]::WindowWidth
        if ($candidate -gt 0) {
            $width = [int]$candidate
        }
    }
    catch {}

    if ($width -lt 30) { $width = 30 }
    if ($width -gt 180) { $width = 180 }

    return $width
}

function Clear-CompactProgressLine {
    if (-not $script:CompactProgressActive) {
        return
    }

    try {
        $width = Get-SafeConsoleWidth
        $clearWidth = $width - 1
        if ($clearWidth -lt 1) { $clearWidth = 1 }

        [Console]::Write(
            "`r" +
            (" " * $clearWidth) +
            "`r"
        )
    }
    catch {
        try { [Console]::Write("`r") } catch {}
    }

    $script:CompactProgressActive = $false
}

function Write-CompactProgressLine([string]$Text) {
    if ($null -eq $Text) {
        $Text = ""
    }

    $width = Get-SafeConsoleWidth
    $maxLength = $width - 1

    if ($maxLength -lt 20) {
        $maxLength = 20
    }

    if ($Text.Length -gt $maxLength) {
        if ($maxLength -gt 3) {
            $Text = $Text.Substring(0, $maxLength - 3) + "..."
        }
        else {
            $Text = $Text.Substring(0, $maxLength)
        }
    }

    $render = $Text.PadRight($maxLength)

    try {
        $oldColor = [Console]::ForegroundColor
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        [Console]::Write("`r" + $render)
        [Console]::ForegroundColor = $oldColor
    }
    catch {
        Write-Host ("`r" + $render) -NoNewline
    }

    $script:CompactProgressActive = $true
}

function Write-Info([string]$Text) {
    Clear-CompactProgressLine
    Write-Host $Text -ForegroundColor Cyan
}

function Write-Ok([string]$Text) {
    Clear-CompactProgressLine
    Write-Host $Text -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Clear-CompactProgressLine
    Write-Host $Text -ForegroundColor Yellow
}

function Write-Bad([string]$Text) {
    Clear-CompactProgressLine
    Write-Host $Text -ForegroundColor Red
}

function Show-AuthorSupportBlock {
    Clear-CompactProgressLine

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "                  OBS FULL CLONE" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host "В качестве благодарности вы можете подписаться на Twitch автора:" -ForegroundColor White
    Write-Host "https://www.twitch.tv/wither_101" -ForegroundColor Magenta
    Write-Host "YouTube:" -ForegroundColor White
    Write-Host "https://www.youtube.com/@Witheres" -ForegroundColor Red
    Write-Host ""
    Write-Host "ДАННЫЙ СКРИПТ РАСПРОСТРАНЯЕТСЯ БЕСПЛАТНО." -ForegroundColor Yellow
    Write-Host "Единственное место, где можно скачать проверенную версию от разработчика:" -ForegroundColor White
    Write-Host "https://github.com/WitherOffic/OBSback" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Open-AuthorPagesPrompt {
    Clear-CompactProgressLine

    while ($true) {
        $answer = (
            Read-Host "Открыть Twitch, YouTube автора и официальный GitHub в браузере? Y/N"
        ).Trim().ToUpperInvariant()

        if (
            $answer -eq "Y" -or
            $answer -eq "YES" -or
            $answer -eq "Д" -or
            $answer -eq "ДА"
        ) {
            foreach ($url in @(
                "https://www.twitch.tv/wither_101",
                "https://www.youtube.com/@Witheres",
                "https://github.com/WitherOffic/OBSback"
            )) {
                try {
                    Start-Process $url -ErrorAction Stop
                }
                catch {
                    Write-Warn "Не удалось открыть браузер автоматически: $url"
                }
            }

            break
        }

        if (
            $answer -eq "N" -or
            $answer -eq "NO" -or
            $answer -eq "Н" -or
            $answer -eq "НЕТ"
        ) {
            break
        }

        Write-Warn "Введите Y или N."
    }
}

function Format-Bytes([Int64]$Bytes) {
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-TextProgressBar(
    [int]$Percent,
    [int]$Width = 18
) {
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    if ($Width -lt 8) { $Width = 8 }
    if ($Width -gt 36) { $Width = 36 }

    $filled = [int][Math]::Floor(($Percent * $Width) / 100.0)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }

    return (
        "[" +
        ("#" * $filled) +
        ("-" * ($Width - $filled)) +
        "]"
    )
}

function Format-RemainingTime([double]$Seconds) {
    if (
        [Double]::IsNaN($Seconds) -or
        [Double]::IsInfinity($Seconds) -or
        $Seconds -lt 0
    ) {
        return "расчёт..."
    }

    $secondsRounded = [Int64][Math]::Ceiling($Seconds)

    if ($secondsRounded -lt 60) {
        return ("00:{0:00}" -f $secondsRounded)
    }

    $hours = [Int64][Math]::Floor($secondsRounded / 3600)
    $minutes = [Int64][Math]::Floor(($secondsRounded % 3600) / 60)
    $secondsPart = [Int64]($secondsRounded % 60)

    if ($hours -gt 0) {
        return ("{0:00}:{1:00}:{2:00}" -f $hours, $minutes, $secondsPart)
    }

    return ("{0:00}:{1:00}" -f $minutes, $secondsPart)
}

function Get-CompactProgressActivity(
    [string]$Text,
    [int]$MaxLength = 24
) {
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return "Операция"
    }

    $value = $Text.Trim()

    if ($value.Length -le $MaxLength) {
        return $value
    }

    if ($MaxLength -le 3) {
        return $value.Substring(0, $MaxLength)
    }

    return $value.Substring(0, $MaxLength - 3) + "..."
}

function Reset-ByteProgressTracker(
    [string]$Activity,
    [Int64]$Total
) {
    $script:ByteProgressActivity = $Activity
    $script:ByteProgressTotal = $Total
    $script:ByteProgressLastDone = [Int64]0
    $script:ByteProgressStartedUtc = [DateTime]::UtcNow
    $script:ByteProgressLastRenderUtc = [DateTime]::MinValue
}

function Show-OverallProgress(
    [int]$Percent,
    [string]$Status
) {
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $script:OverallPercent = $Percent
    $script:OverallStatus = $Status

    $consoleWidth = Get-SafeConsoleWidth
    [int]$barWidth = 10

    if ($consoleWidth -ge 90) { $barWidth = 14 }
    if ($consoleWidth -ge 130) { $barWidth = 18 }

    $bar = Get-TextProgressBar $Percent $barWidth
    $statusText = Get-CompactProgressActivity $Status 36

    Write-CompactProgressLine (
        "Общий $bar $Percent% | $statusText"
    )
}

function Show-ByteProgress(
    [string]$Activity,
    [string]$Status,
    [Int64]$Done,
    [Int64]$Total
) {
    if (
        $script:ByteProgressActivity -ne $Activity -or
        $script:ByteProgressTotal -ne $Total -or
        $Done -lt $script:ByteProgressLastDone
    ) {
        Reset-ByteProgressTracker $Activity $Total
    }

    $script:ByteProgressLastDone = $Done
    $now = [DateTime]::UtcNow

    if (
        $Done -lt $Total -and
        $script:ByteProgressLastRenderUtc -ne [DateTime]::MinValue -and
        ($now - $script:ByteProgressLastRenderUtc).TotalMilliseconds -lt
            $script:ProgressRenderIntervalMs
    ) {
        return
    }

    $script:ByteProgressLastRenderUtc = $now

    $percent = 100

    if ($Total -gt 0) {
        $percent = [int][Math]::Floor(($Done * 100.0) / $Total)
        if ($percent -lt 0) { $percent = 0 }
        if ($percent -gt 100) { $percent = 100 }
    }

    $elapsed = ($now - $script:ByteProgressStartedUtc).TotalSeconds
    $speedText = "расчёт..."
    $etaText = "расчёт..."

    if ($elapsed -ge 1.0 -and $Done -gt 0) {
        [double]$speed = [double]$Done / $elapsed

        if ($speed -gt 0) {
            $speedText = "$(Format-Bytes ([Int64]$speed))/с"

            [double]$remaining = [double]($Total - $Done)
            if ($remaining -lt 0) { $remaining = 0 }

            $etaText = Format-RemainingTime ($remaining / $speed)
        }
    }

    $consoleWidth = Get-SafeConsoleWidth
    [int]$barWidth = 8

    if ($consoleWidth -ge 90) { $barWidth = 12 }
    if ($consoleWidth -ge 125) { $barWidth = 16 }
    if ($consoleWidth -ge 155) { $barWidth = 20 }

    $bar = Get-TextProgressBar $percent $barWidth
    $activityText = Get-CompactProgressActivity $Activity 24

    $line = (
        "Общий $($script:OverallPercent)% | " +
        "$activityText | " +
        "$bar $percent% | " +
        "$(Format-Bytes $Done)/$(Format-Bytes $Total) | " +
        "$speedText | ETA $etaText"
    )

    if (
        $consoleWidth -ge 145 -and
        -not [string]::IsNullOrWhiteSpace($Status)
    ) {
        $fileText = $Status

        try {
            $leaf = [IO.Path]::GetFileName($Status)
            if ($leaf) { $fileText = $leaf }
        }
        catch {}

        $fileText = Get-CompactProgressActivity $fileText 26
        $line += " | $fileText"
    }

    Write-CompactProgressLine $line
}

function Complete-SubProgress {
    Clear-CompactProgressLine

    $script:ByteProgressActivity = $null
    $script:ByteProgressTotal = [Int64]0
    $script:ByteProgressLastDone = [Int64]0
    $script:ByteProgressStartedUtc = [DateTime]::UtcNow
    $script:ByteProgressLastRenderUtc = [DateTime]::MinValue
}

function Complete-AllProgress {
    Clear-CompactProgressLine
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-PathRootNormalized([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return [IO.Path]::GetPathRoot($full)
}

function Get-PathExtensionSafe([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        return [IO.Path]::GetExtension($Path)
    }
    catch {
        return ""
    }
}

function Get-WindowsAbsolutePathMatches([string]$Text) {
    $results = New-Object System.Collections.ArrayList

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    # Important: require a non-word boundary before the drive letter.
    # Without this, the trailing "s:/" in "https://..." can be misread as S:\...
    $drivePattern = '(?i)(?<![A-Z0-9_])(?:file:/+)?[A-Z]:[\\/][^"\r\n<>\|\?\*]+'
    $uncPattern = '(?<![A-Z0-9_])\\\\[^\\/\s"\r\n]+\\[^"\r\n<>\|\?\*]+'

    foreach ($match in [regex]::Matches($Text, $drivePattern)) {
        $value = $match.Value.Trim().TrimEnd([char[]]',;)]}')

        # Belt-and-suspenders: never return URL-looking matches.
        if ($value -match '^(?i)https?[:/\\]') {
            continue
        }

        [void]$results.Add($value)
    }

    foreach ($match in [regex]::Matches($Text, $uncPattern)) {
        $value = $match.Value.Trim().TrimEnd([char[]]',;)]}')
        [void]$results.Add($value)
    }

    return @($results)
}

function Test-PathInside([string]$Child, [string]$Parent) {
    try {
        $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd([char[]]"\/") + "\"
        $childFull = [IO.Path]::GetFullPath($Child)

        return $childFull.StartsWith(
            $parentFull,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Test-SamePath([string]$A, [string]$B) {
    try {
        $aFull = [IO.Path]::GetFullPath($A).TrimEnd([char[]]"\/")
        $bFull = [IO.Path]::GetFullPath($B).TrimEnd([char[]]"\/")

        return $aFull.Equals(
            $bFull,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Test-DriveRoot([string]$Path) {
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\/")
        $rootPath = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]"\/")

        return $full.Equals(
            $rootPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Get-RelativePathSafe([string]$Root, [string]$FullPath) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]"\/") + "\"
    $full = [IO.Path]::GetFullPath($FullPath)

    if (-not $full.StartsWith(
        $rootFull,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Путь '$full' не находится внутри '$rootFull'."
    }

    return $full.Substring($rootFull.Length)
}

function Resolve-ObsExeFromInput([string]$InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        return $null
    }

    $path = $InputPath.Trim().Trim('"')

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        if ([IO.Path]::GetFileName($path) -ieq "obs64.exe") {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    if (Test-Path -LiteralPath $path -PathType Container) {
        $candidates = @(
            (Join-Path $path "obs64.exe"),
            (Join-Path $path "bin\64bit\obs64.exe"),
            (Join-Path $path "OBS Studio\bin\64bit\obs64.exe")
        )

        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    return $null
}

function Get-ObsExeCandidates {
    $candidateMap = @{}

    function Add-Candidate([string]$Path) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }

        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $resolved = (Resolve-Path -LiteralPath $Path).Path
                $candidateMap[$resolved.ToLowerInvariant()] = $resolved
            }
        }
        catch {}
    }

    function Scan-PortableSearchRoot(
        [string]$SearchRoot,
        [int]$MaxDepth = 2,
        [int]$MaxDirectories = 2500
    ) {
        if (
            [string]::IsNullOrWhiteSpace($SearchRoot) -or
            -not (Test-Path -LiteralPath $SearchRoot -PathType Container)
        ) {
            return
        }

        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([PSCustomObject]@{
            Path = [IO.Path]::GetFullPath($SearchRoot)
            Depth = 0
        })

        [int]$visited = 0

        while ($queue.Count -gt 0 -and $visited -lt $MaxDirectories) {
            $entry = $queue.Dequeue()
            $current = [string]$entry.Path
            [int]$depth = [int]$entry.Depth
            $visited++

            Add-Candidate (
                Join-Path $current "bin\64bit\obs64.exe"
            )

            if ($depth -ge $MaxDepth) {
                continue
            }

            foreach ($directory in @(
                Get-ChildItem `
                    -LiteralPath $current `
                    -Directory `
                    -Force `
                    -ErrorAction SilentlyContinue
            )) {
                if (
                    $directory.Name -match
                    '^(?i)(Windows|ProgramData|\$Recycle\.Bin|System Volume Information)$'
                ) {
                    continue
                }

                $queue.Enqueue([PSCustomObject]@{
                    Path = $directory.FullName
                    Depth = $depth + 1
                })
            }
        }
    }

    try {
        foreach ($process in @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name='obs64.exe'" `
                -ErrorAction Stop
        )) {
            if ($process.ExecutablePath) {
                Add-Candidate ([string]$process.ExecutablePath)
            }
        }
    }
    catch {}

    if ($env:ProgramFiles) {
        Add-Candidate (
            Join-Path $env:ProgramFiles "obs-studio\bin\64bit\obs64.exe"
        )
        Add-Candidate (
            Join-Path $env:ProgramFiles "OBS Studio\bin\64bit\obs64.exe"
        )
    }

    if (${env:ProgramFiles(x86)}) {
        Add-Candidate (
            Join-Path ${env:ProgramFiles(x86)} "obs-studio\bin\64bit\obs64.exe"
        )
        Add-Candidate (
            Join-Path ${env:ProgramFiles(x86)} "OBS Studio\bin\64bit\obs64.exe"
        )
    }

    foreach ($regPath in @(
        "HKLM:\SOFTWARE\OBS Studio",
        "HKLM:\SOFTWARE\WOW6432Node\OBS Studio"
    )) {
        try {
            $key = Get-Item -LiteralPath $regPath -ErrorAction Stop
            $installRoot = [string]$key.GetValue("")

            if ($installRoot) {
                Add-Candidate (
                    Join-Path $installRoot "bin\64bit\obs64.exe"
                )
            }
        }
        catch {}
    }

    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        ForEach-Object {
            $driveRoot = $_.Root

            Add-Candidate (
                Join-Path $driveRoot "SteamLibrary\steamapps\common\OBS Studio\bin\64bit\obs64.exe"
            )

            foreach ($portableName in @(
                "OBS",
                "OBS Portable",
                "OBS Studio Portable",
                "OBS-Studio-Portable"
            )) {
                Add-Candidate (
                    Join-Path $driveRoot (
                        "$portableName\bin\64bit\obs64.exe"
                    )
                )
            }
        }

    $steamRoots = @{}

    foreach ($regPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        try {
            $properties = Get-ItemProperty `
                -LiteralPath $regPath `
                -ErrorAction Stop

            foreach ($propertyName in @("SteamPath", "InstallPath")) {
                $value = [string]$properties.$propertyName

                if ($value) {
                    $steamRoots[$value.ToLowerInvariant()] = $value
                }
            }
        }
        catch {}
    }

    foreach ($steamRoot in $steamRoots.Values) {
        Add-Candidate (
            Join-Path $steamRoot "steamapps\common\OBS Studio\bin\64bit\obs64.exe"
        )

        $libraryFile = Join-Path `
            $steamRoot `
            "steamapps\libraryfolders.vdf"

        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            try {
                $text = [IO.File]::ReadAllText($libraryFile)

                foreach ($match in [regex]::Matches(
                    $text,
                    '"path"\s+"([^"]+)"'
                )) {
                    $libraryRoot = (
                        $match.Groups[1].Value -replace '\\\\', '\'
                    )

                    Add-Candidate (
                        Join-Path $libraryRoot "steamapps\common\OBS Studio\bin\64bit\obs64.exe"
                    )
                }
            }
            catch {}
        }
    }

    foreach ($searchRoot in @(
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Documents"),
        $env:OneDrive,
        $env:OneDriveConsumer,
        $env:OneDriveCommercial
    ) | Where-Object { $_ } | Sort-Object -Unique) {
        Scan-PortableSearchRoot $searchRoot 2 2500
    }

    return @($candidateMap.Values | Sort-Object)
}

function Get-ObsVersionSafe([string]$ObsExe) {
    try {
        $info = (
            Get-Item `
                -LiteralPath $ObsExe `
                -ErrorAction Stop
        ).VersionInfo

        $version = [string]$info.FileVersion

        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = [string]$info.ProductVersion
        }

        if (-not [string]::IsNullOrWhiteSpace($version)) {
            return $version.Trim()
        }
    }
    catch {}

    return "неизвестно"
}

function Get-ObsInstallationType(
    [string]$ObsExe,
    [string]$RunningCommandLine = $null
) {
    $root = Get-ObsRoot $ObsExe

    if (
        (Test-Path -LiteralPath (Join-Path $root "portable_mode") -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $root "portable_mode.txt") -PathType Leaf) -or
        (
            $RunningCommandLine -and
            $RunningCommandLine -match
            '(?i)(?:^|\s)(?:--portable|-p)(?:\s|$)'
        )
    ) {
        return "Portable"
    }

    if (
        $ObsExe -match
        '(?i)\\steamapps\\common\\OBS Studio\\bin\\64bit\\obs64\.exe$'
    ) {
        return "Steam"
    }

    # An old config directory alone does not enable OBS portable mode.
    # Offline ambiguity is resolved explicitly before creating a backup.
    return "Standard"
}

function Get-ObsBackupInstallationType($Manifest) {
    # Backups before v1.1.0 do not have OriginalObsInstallType.
    # Check for the property before reading it under StrictMode.
    $typeProperty = $Manifest.PSObject.Properties['OriginalObsInstallType']

    if ($typeProperty -and -not [string]::IsNullOrWhiteSpace([string]$typeProperty.Value)) {
        return [string]$typeProperty.Value
    }

    if ([bool]$Manifest.IsPortable) {
        return "Portable"
    }

    if ([string]$Manifest.OriginalObsExe -match '(?i)\\steamapps\\common\\OBS Studio\\bin\\64bit\\obs64\.exe$') {
        return "Steam"
    }

    return "Standard"
}

function Get-ObsInstallationInfo([string]$ObsExe) {
    $resolved = Resolve-ObsExeFromInput $ObsExe

    if (-not $resolved) {
        throw "Не удалось определить obs64.exe: $ObsExe"
    }

    $root = Get-ObsRoot $resolved
    $commandLine = Get-RunningObsCommandLine $resolved
    $type = Get-ObsInstallationType $resolved $commandLine
    $configRoot = Join-Path $env:APPDATA "obs-studio"

    if ($type -eq "Portable") {
        $configRoot = Join-Path $root "config\obs-studio"
    }

    return [PSCustomObject]@{
        ExePath = $resolved
        Root = $root
        Type = $type
        Version = Get-ObsVersionSafe $resolved
        IsRunning = [bool](Test-ObsRunning $resolved)
        RunningCommandLine = $commandLine
        ConfigRoot = $configRoot
    }
}

function Get-ObsInstallationInfos {
    $items = New-Object System.Collections.ArrayList

    foreach ($exe in @(Get-ObsExeCandidates)) {
        try {
            [void]$items.Add(
                (Get-ObsInstallationInfo $exe)
            )
        }
        catch {}
    }

    return @(
        $items |
        Sort-Object `
            @{ Expression = {
                if ($_.IsRunning) { 0 } else { 1 }
            }; Ascending = $true }, `
            @{ Expression = { [string]$_.Type }; Ascending = $true }, `
            @{ Expression = { [string]$_.ExePath }; Ascending = $true }
    )
}

function Write-ObsInstallationEntry(
    [int]$Index,
    $Installation
) {
    $runningText = "не запущена"
    $runningColor = "DarkGray"

    if ([bool]$Installation.IsRunning) {
        $runningText = "ЗАПУЩЕНА"
        $runningColor = "Green"
    }

    Write-Host (
        "[{0}] {1,-8} | OBS {2} | " -f
        $Index,
        [string]$Installation.Type,
        [string]$Installation.Version
    ) -NoNewline

    Write-Host $runningText -ForegroundColor $runningColor
    Write-Host ("    EXE:    " + [string]$Installation.ExePath)
    Write-Host ("    Config: " + [string]$Installation.ConfigRoot)
}

function Read-ManualObsInstallation([string]$Purpose) {
    while ($true) {
        $manual = Read-Host (
            "Вставьте путь к obs64.exe или папке OBS Studio ($Purpose)"
        )

        $resolved = Resolve-ObsExeFromInput $manual

        if ($resolved) {
            return Get-ObsInstallationInfo $resolved
        }

        Write-Warn "obs64.exe по этому пути не найден."
    }
}

function Select-ObsInstallation([string]$Purpose) {
    $installations = @(Get-ObsInstallationInfos)

    if ($installations.Count -eq 0) {
        Write-Warn "OBS не найден автоматически ($Purpose)."
        return Read-ManualObsInstallation $Purpose
    }

    if ($installations.Count -eq 1) {
        Write-Info "Найдена одна установка OBS ($Purpose):"
        Write-ObsInstallationEntry 1 $installations[0]
        Write-Info "Enter или 1 — использовать её; M — указать другую установку."
    }
    else {
        Write-Host ""
        Write-Warn "Найдено несколько установок OBS ($Purpose):"
        Write-Host ""

        for ($i = 0; $i -lt $installations.Count; $i++) {
            Write-ObsInstallationEntry ($i + 1) $installations[$i]
            Write-Host ""
        }
    }

    $types = @(
        $installations |
        ForEach-Object { [string]$_.Type } |
        Sort-Object -Unique
    )

    if (
        "Steam" -in $types -and
        "Standard" -in $types
    ) {
        Write-Warn (
            "Steam и Standard OBS обычно используют общий " +
            "%APPDATA%\obs-studio. Программные файлы и плагины установок " +
            "при этом могут отличаться."
        )
        Write-Host ""
    }

    Write-Host "[M] Указать другой путь вручную"
    Write-Host ""

    while ($true) {
        $answer = (
            Read-Host "Выберите нужную установку OBS"
        ).Trim()

        if ($installations.Count -eq 1 -and $answer -eq "") {
            return $installations[0]
        }

        if ($answer -match '^(?i)(m|manual|м)$') {
            return Read-ManualObsInstallation $Purpose
        }

        [int]$number = 0

        if (
            [int]::TryParse($answer, [ref]$number) -and
            $number -ge 1 -and
            $number -le $installations.Count
        ) {
            return $installations[$number - 1]
        }

        Write-Warn "Введите номер установки или M."
    }
}

function Select-ObsExe([string]$Purpose) {
    return [string](
        (Select-ObsInstallation $Purpose).ExePath
    )
}

function Get-ObsInstallationsUsingConfig(
    [string]$ConfigRoot,
    [bool]$OnlyRunning = $false
) {
    $matches = New-Object System.Collections.ArrayList

    foreach ($installation in @(Get-ObsInstallationInfos)) {
        if (
            $OnlyRunning -and
            -not [bool]$installation.IsRunning
        ) {
            continue
        }

        if (
            Test-SamePath `
                ([string]$installation.ConfigRoot) `
                $ConfigRoot
        ) {
            [void]$matches.Add($installation)
        }
    }

    return @($matches)
}

function Stop-ObsInstallationsUsingConfig([string]$ConfigRoot) {
    $running = @(
        Get-ObsInstallationsUsingConfig `
            $ConfigRoot `
            $true
    )

    if ($running.Count -gt 1) {
        Write-Warn (
            "Несколько запущенных OBS используют один config. " +
            "Для консистентности будут закрыты все:"
        )

        foreach ($installation in $running) {
            Write-Warn (
                "  $([string]$installation.Type) | " +
                [string]$installation.ExePath
            )
        }
    }

    foreach ($installation in $running) {
        Stop-ObsSafely ([string]$installation.ExePath)
    }
}

function Test-ObsConfigInUse([string]$ConfigRoot) {
    return (
        @(
            Get-ObsInstallationsUsingConfig `
                $ConfigRoot `
                $true
        ).Count -gt 0
    )
}

function Get-ObsRoot([string]$ObsExe) {
    $path = [IO.Path]::GetDirectoryName($ObsExe)
    $path = [IO.Path]::GetDirectoryName($path)
    $path = [IO.Path]::GetDirectoryName($path)

    return $path
}

function Get-RunningObsCommandLine([string]$ObsExe = $null) {
    try {
        $processes = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name='obs64.exe'" `
                -ErrorAction Stop
        )

        foreach ($process in $processes) {
            if (
                $ObsExe -and
                $process.ExecutablePath -and
                (Test-SamePath ([string]$process.ExecutablePath) $ObsExe)
            ) {
                return [string]$process.CommandLine
            }
        }

        if (-not $ObsExe -and $processes.Count -gt 0) {
            return [string]$processes[0].CommandLine
        }
    }
    catch {}

    return $null
}

function Get-ObsConfigInfo(
    [string]$ObsRoot,
    [string]$RunningCommandLine
) {
    $portableMarker1 = Join-Path $ObsRoot "portable_mode"
    $portableMarker2 = Join-Path $ObsRoot "portable_mode.txt"

    $portableByMarker =
        (Test-Path -LiteralPath $portableMarker1 -PathType Leaf) -or
        (Test-Path -LiteralPath $portableMarker2 -PathType Leaf)

    $portableByArgument = $false

    if ($RunningCommandLine) {
        $portableByArgument = (
            $RunningCommandLine -match
            '(?i)(?:^|\s)(?:--portable|-p)(?:\s|$)'
        )
    }

    $isPortable = $portableByMarker -or $portableByArgument

    if ($isPortable) {
        $configRoot = Join-Path $ObsRoot "config\obs-studio"
    }
    else {
        $configRoot = Join-Path $env:APPDATA "obs-studio"
    }

    return [PSCustomObject]@{
        IsPortable = $isPortable
        ConfigRoot = $configRoot
        PortableByMarker = $portableByMarker
        PortableByArgument = $portableByArgument
    }
}

function Resolve-ObsBackupConfigInfo(
    [string]$ObsRoot,
    [string]$RunningCommandLine
) {
    $configInfo = Get-ObsConfigInfo $ObsRoot $RunningCommandLine

    # If portable config exists but no marker/command line was visible, do not guess silently.
    $portableCandidate = Join-Path $ObsRoot "config\\obs-studio"

    if (
        -not $configInfo.IsPortable -and
        -not $runningCommandLine -and
        (Test-Path -LiteralPath $portableCandidate -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $portableCandidate "basic") -PathType Container)
    ) {
        $roamingCandidate = Join-Path $env:APPDATA "obs-studio"

        if (-not (Test-Path -LiteralPath $roamingCandidate -PathType Container)) {
            $configInfo = [PSCustomObject]@{
                IsPortable = $true
                ConfigRoot = $portableCandidate
                PortableByMarker = $false
                PortableByArgument = $false
            }

            Write-Warn "Обнаружен portable config внутри OBS; использую его."
        }
        else {
            Write-Warn "Найдены и обычный, и portable config OBS."
            Write-Host "[1] Roaming:  $roamingCandidate"
            Write-Host "[2] Portable: $portableCandidate"

            while ($true) {
                $answer = Read-Host "Какой config является текущим? Введите 1 или 2"

                if ($answer -eq "1") {
                    $configInfo = [PSCustomObject]@{
                        IsPortable = $false
                        ConfigRoot = $roamingCandidate
                        PortableByMarker = $false
                        PortableByArgument = $false
                    }
                    break
                }

                if ($answer -eq "2") {
                    $configInfo = [PSCustomObject]@{
                        IsPortable = $true
                        ConfigRoot = $portableCandidate
                        PortableByMarker = $false
                        PortableByArgument = $false
                    }
                    break
                }

                Write-Warn "Введите 1 или 2."
            }
        }
    }

    return $configInfo
}

function Test-ObsRunning([string]$ObsExe = $null) {
    try {
        $processes = @(
            Get-CimInstance `
                -ClassName Win32_Process `
                -Filter "Name='obs64.exe'" `
                -ErrorAction Stop
        )

        if (-not $ObsExe) {
            return ($processes.Count -gt 0)
        }

        foreach ($process in $processes) {
            if (
                $process.ExecutablePath -and
                (Test-SamePath ([string]$process.ExecutablePath) $ObsExe)
            ) {
                return $true
            }
        }
    }
    catch {
        if (-not $ObsExe) {
            return (@(Get-Process -Name obs64 -ErrorAction SilentlyContinue).Count -gt 0)
        }
    }

    return $false
}

function Stop-ObsSafely([string]$ObsExe = $null) {
    $processes = @()

    if ($ObsExe) {
        try {
            $cimProcesses = @(
                Get-CimInstance `
                    -ClassName Win32_Process `
                    -Filter "Name='obs64.exe'" `
                    -ErrorAction Stop
            )

            foreach ($cim in $cimProcesses) {
                if (
                    $cim.ExecutablePath -and
                    (Test-SamePath ([string]$cim.ExecutablePath) $ObsExe)
                ) {
                    try {
                        $processes += Get-Process `
                            -Id ([int]$cim.ProcessId) `
                            -ErrorAction Stop
                    }
                    catch {}
                }
            }
        }
        catch {}
    }
    else {
        $processes = @(Get-Process -Name obs64 -ErrorAction SilentlyContinue)
    }

    if ($processes.Count -eq 0) {
        return
    }

    Write-Info "Закрываю OBS для консистентного снимка..."

    foreach ($process in $processes) {
        try {
            [void]$process.CloseMainWindow()
        }
        catch {}
    }

    $ids = @($processes | ForEach-Object { $_.Id })
    $deadline = [DateTime]::UtcNow.AddSeconds(8)

    do {
        Start-Sleep -Milliseconds 250

        $left = @()
        foreach ($id in $ids) {
            try {
                $left += Get-Process -Id $id -ErrorAction Stop
            }
            catch {}
        }

        if ($left.Count -eq 0) {
            return
        }
    }
    while ([DateTime]::UtcNow -lt $deadline)

    Write-Warn "OBS не завершился штатно за 8 секунд. Завершаю процесс принудительно."

    foreach ($id in $ids) {
        Stop-Process `
            -Id $id `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
}

function Test-ReparsePoint($Item) {
    $hasReparse = (
        ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    )

    if (-not $hasReparse) {
        return $false
    }

    # Directory reparse points can redirect traversal to another tree/mount.
    if ($Item.PSIsContainer) {
        return $true
    }

    # File symlinks must not be followed silently. OneDrive/Cloud Files can also
    # carry the ReparsePoint attribute but usually have no SymbolicLink LinkType;
    # those are allowed and will be hydrated/read normally by FileStream.
    try {
        if ($Item.PSObject.Properties.Name -contains "LinkType") {
            $linkType = [string]$Item.LinkType

            if ($linkType -match '(?i)(SymbolicLink|Junction)') {
                return $true
            }
        }
    }
    catch {}

    return $false
}

function Get-TreePlan(
    [string]$Root,
    [scriptblock]$Exclude = $null
) {
    $files = New-Object System.Collections.ArrayList
    $directories = New-Object System.Collections.ArrayList
    $reparsePoints = New-Object System.Collections.ArrayList

    [Int64]$totalBytes = 0
    [Int64]$scannedItems = 0

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [PSCustomObject]@{
            Root = $Root
            Files = @()
            Directories = @()
            ReparsePoints = @()
            TotalBytes = [Int64]0
        }
    }

    $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    if (Test-ReparsePoint $rootItem) {
        return [PSCustomObject]@{
            Root = $rootItem.FullName
            Files = @()
            Directories = @()
            ReparsePoints = @($rootItem.FullName)
            TotalBytes = [Int64]0
        }
    }

    $rootFull = (Resolve-Path -LiteralPath $Root).Path

    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)

    while ($stack.Count -gt 0) {
        $current = [string]$stack.Pop()

        $children = @(
            Get-ChildItem `
                -LiteralPath $current `
                -Force `
                -ErrorAction Stop
        )

        foreach ($item in $children) {
            $scannedItems++

            if (($scannedItems % 500) -eq 0) {
                Write-CompactProgressLine (
                    "Сканирование файлов | объектов $scannedItems | " +
                    "файлов $($files.Count) | $(Format-Bytes $totalBytes)"
                )
            }

            $relative = Get-RelativePathSafe $rootFull $item.FullName

            if ($Exclude) {
                $skip = & $Exclude $item $relative
                if ($skip) {
                    continue
                }
            }

            if (Test-ReparsePoint $item) {
                [void]$reparsePoints.Add($item.FullName)
                continue
            }

            if ($item.PSIsContainer) {
                [void]$directories.Add($relative)
                $stack.Push($item.FullName)
            }
            else {
                [Int64]$size = $item.Length
                $totalBytes += $size

                [void]$files.Add([PSCustomObject]@{
                    SourcePath = $item.FullName
                    RelativePath = $relative
                    Size = $size
                    LastWriteTimeUtc = $item.LastWriteTimeUtc
                })
            }
        }
    }

    Complete-SubProgress

    return [PSCustomObject]@{
        Root = $rootFull
        Files = @($files)
        Directories = @($directories)
        ReparsePoints = @($reparsePoints)
        TotalBytes = [Int64]$totalBytes
    }
}

function Assert-TreePlanUnchanged(
    [string]$Root,
    $OriginalPlan,
    [scriptblock]$Exclude = $null
) {
    $currentPlan = Get-TreePlan $Root $Exclude

    if (@($currentPlan.ReparsePoints).Count -gt 0) {
        throw (
            "Дерево изменилось: появился reparse point в '$Root':`r`n" +
            (@($currentPlan.ReparsePoints) -join "`r`n")
        )
    }

    $originalFiles = @{}
    foreach ($file in @($OriginalPlan.Files)) {
        $originalFiles[([string]$file.RelativePath).ToLowerInvariant()] = [PSCustomObject]@{
            Size = [Int64]$file.Size
            LastWriteTimeUtc = $file.LastWriteTimeUtc
        }
    }

    $currentFiles = @{}
    foreach ($file in @($currentPlan.Files)) {
        $currentFiles[([string]$file.RelativePath).ToLowerInvariant()] = [PSCustomObject]@{
            Size = [Int64]$file.Size
            LastWriteTimeUtc = $file.LastWriteTimeUtc
        }
    }

    if ($originalFiles.Count -ne $currentFiles.Count) {
        throw (
            "Состав файлов изменился во время backup: '$Root'. " +
            "Было $($originalFiles.Count), стало $($currentFiles.Count)."
        )
    }

    foreach ($key in $originalFiles.Keys) {
        if (-not $currentFiles.ContainsKey($key)) {
            throw "Файл исчез во время backup: $Root\\$key"
        }

        $before = $originalFiles[$key]
        $after = $currentFiles[$key]

        if ([Int64]$before.Size -ne [Int64]$after.Size) {
            throw "Размер файла изменился во время backup: $Root\\$key"
        }

        if ($before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) {
            throw "Время изменения файла поменялось во время backup: $Root\\$key"
        }
    }

    $originalDirs = @{}
    foreach ($directory in @($OriginalPlan.Directories)) {
        $originalDirs[([string]$directory).ToLowerInvariant()] = $true
    }

    $currentDirs = @{}
    foreach ($directory in @($currentPlan.Directories)) {
        $currentDirs[([string]$directory).ToLowerInvariant()] = $true
    }

    if ($originalDirs.Count -ne $currentDirs.Count) {
        throw "Состав каталогов изменился во время backup: '$Root'."
    }

    foreach ($key in $originalDirs.Keys) {
        if (-not $currentDirs.ContainsKey($key)) {
            throw "Каталог исчез во время backup: $Root\\$key"
        }
    }
}

function Add-PrefixToPlan($Plan, [string]$Prefix) {
    $files = New-Object System.Collections.ArrayList
    $directories = New-Object System.Collections.ArrayList

    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        [void]$directories.Add($Prefix)
    }

    foreach ($file in @($Plan.Files)) {
        $relative = $file.RelativePath

        if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
            $relative = Join-Path $Prefix $relative
        }

        [void]$files.Add([PSCustomObject]@{
            SourcePath = $file.SourcePath
            RelativePath = $relative
            Size = [Int64]$file.Size
            LastWriteTimeUtc = $file.LastWriteTimeUtc
        })
    }

    foreach ($directory in @($Plan.Directories)) {
        $relative = $directory

        if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
            $relative = Join-Path $Prefix $relative
        }

        [void]$directories.Add($relative)
    }

    return [PSCustomObject]@{
        Root = $Plan.Root
        Files = @($files)
        Directories = @($directories)
        ReparsePoints = @($Plan.ReparsePoints)
        TotalBytes = [Int64]$Plan.TotalBytes
    }
}

function New-SingleFilePlan(
    [string]$SourcePath,
    [string]$TargetRelativePath
) {
    $item = Get-Item `
        -LiteralPath $SourcePath `
        -Force `
        -ErrorAction Stop

    if ($item.PSIsContainer) {
        throw "Ожидался файл, получен каталог: $SourcePath"
    }

    if (Test-ReparsePoint $item) {
        throw "Source-файл является symlink/reparse link и не будет молча разыменован: $SourcePath"
    }

    return [PSCustomObject]@{
        Root = [IO.Path]::GetDirectoryName($item.FullName)
        Files = @(
            [PSCustomObject]@{
                SourcePath = $item.FullName
                RelativePath = $TargetRelativePath
                Size = [Int64]$item.Length
                LastWriteTimeUtc = $item.LastWriteTimeUtc
            }
        )
        Directories = @()
        ReparsePoints = @()
        TotalBytes = [Int64]$item.Length
    }
}

function Copy-FileAndHash(
    [string]$Source,
    [string]$Destination,
    [ref]$Done,
    [Int64]$Total,
    [string]$Activity
) {
    $sourceBefore = Get-Item `
        -LiteralPath $Source `
        -Force `
        -ErrorAction Stop

    $parent = [IO.Path]::GetDirectoryName($Destination)

    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $input = $null
    $output = $null
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        $input = [IO.File]::Open(
            $Source,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )

        $output = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::Create,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )

        [byte[]]$buffer = New-Object byte[] (16MB)

        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)

            [void]$sha.TransformBlock(
                $buffer,
                0,
                $read,
                $buffer,
                0
            )

            $Done.Value = [Int64]$Done.Value + $read

            Show-ByteProgress `
                $Activity `
                ("Копирование: " + [IO.Path]::GetFileName($Source)) `
                $Done.Value `
                $Total
        }

        [byte[]]$empty = @()
        [void]$sha.TransformFinalBlock($empty, 0, 0)

        $output.Flush()
        $hashText = ([BitConverter]::ToString($sha.Hash)).Replace("-", "")
    }
    finally {
        if ($output) {
            $output.Dispose()
        }

        if ($input) {
            $input.Dispose()
        }

        $sha.Dispose()
    }

    $sourceAfter = Get-Item `
        -LiteralPath $Source `
        -Force `
        -ErrorAction Stop

    $destinationInfo = Get-Item `
        -LiteralPath $Destination `
        -Force `
        -ErrorAction Stop

    if ([Int64]$destinationInfo.Length -ne [Int64]$sourceBefore.Length) {
        Remove-Item `
            -LiteralPath $Destination `
            -Force `
            -ErrorAction SilentlyContinue

        throw "Размер копии не совпал с источником: $Source"
    }

    if (
        [Int64]$sourceBefore.Length -ne [Int64]$sourceAfter.Length -or
        $sourceBefore.LastWriteTimeUtc -ne $sourceAfter.LastWriteTimeUtc
    ) {
        Remove-Item `
            -LiteralPath $Destination `
            -Force `
            -ErrorAction SilentlyContinue

        throw "Файл изменился прямо во время backup: $Source"
    }

    try {
        [IO.File]::SetLastWriteTimeUtc(
            $Destination,
            $sourceBefore.LastWriteTimeUtc
        )
    }
    catch {}

    return $hashText
}

function Get-Sha256WithProgress(
    [string]$Path,
    [ref]$Done,
    [Int64]$Total,
    [string]$Activity,
    [string]$StatusPrefix
) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null

    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )

        [byte[]]$buffer = New-Object byte[] (16MB)

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock(
                $buffer,
                0,
                $read,
                $buffer,
                0
            )

            $Done.Value = [Int64]$Done.Value + $read

            Show-ByteProgress `
                $Activity `
                ($StatusPrefix + [IO.Path]::GetFileName($Path)) `
                $Done.Value `
                $Total
        }

        [byte[]]$empty = @()
        [void]$sha.TransformFinalBlock($empty, 0, 0)

        return ([BitConverter]::ToString($sha.Hash)).Replace("-", "")
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }

        $sha.Dispose()
    }
}

function Get-Sha256Simple([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = $null

    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )

        return (
            [BitConverter]::ToString(
                $sha.ComputeHash($stream)
            )
        ).Replace("-", "")
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }

        $sha.Dispose()
    }
}

function Write-JsonUtf8(
    [string]$Path,
    $Object,
    [int]$Depth = 30
) {
    if ($Depth -gt 100) {
        $Depth = 100
    }

    $json = ConvertTo-Json -InputObject $Object -Depth $Depth

    [IO.File]::WriteAllText(
        $Path,
        $json,
        (New-Object Text.UTF8Encoding($false))
    )
}

function Read-JsonFile([string]$Path) {
    return (
        [IO.File]::ReadAllText($Path) |
        ConvertFrom-Json
    )
}

function Read-ObsAccountDataChoice {
    Write-Host ""
    Write-Info "ДАННЫЕ ПОДКЛЮЧЕНИЙ И АККАУНТОВ"
    Write-Host "Y — сохранить вход в аккаунты, ключи трансляций и сессии браузера OBS."
    Write-Host "N — исключить эти данные из backup; после Restore войти заново."
    Write-Host "При N адрес и параметры пользовательского сервера трансляции нужно будет задать заново."
    Write-Host "Настройки сторонних плагинов и секреты в URL источников этим режимом не очищаются."

    while ($true) {
        $answer = (Read-Host "Копировать данные входа в аккаунты и ключи трансляций? Y/N [N]").Trim()
        if ($answer -match '^(?i)(y|yes|д|да)$') { return $true }
        if ($answer -eq '' -or $answer -match '^(?i)(n|no|н|нет)$') { return $false }
        Write-Warn "Введите Y или N. Enter — не копировать данные входа."
    }
}

function Get-ObsAccountFileAction(
    [string]$RelativePath,
    [string]$SourcePath = ''
) {
    foreach ($candidate in @($RelativePath, $SourcePath)) {
        $path = $candidate.Replace('/', '\')
        if ($path -match '(?i)(?:^|\\)plugin_config\\obs-browser(?:[._-][^\\]*)?(?:\\|$)') {
            return 'Omit'
        }
    }

    # Also match copies included through an inactive portable config, a plugin
    # path or EXTRA_SOURCES, using the original filename when it is available.
    $leaf = [IO.Path]::GetFileName($RelativePath.Replace('/', '\'))
    if ($SourcePath) { $leaf = [IO.Path]::GetFileName($SourcePath) }
    if ($leaf -match '^(?i)(?:basic|global|user)\.ini$') { return 'Ini' }
    if ($leaf -ieq 'service.json') { return 'Service' }
    if ($leaf -match '^(?i)(?:(?:basic|global|user)\.ini|service\.json)[.~_-]') {
        # Old/safe-save copies can retain credentials that the current file no
        # longer contains. They are unnecessary when restoring a valid config.
        return 'Omit'
    }
    return 'Copy'
}

function ConvertTo-ObsAccountFreeIni([string]$Text) {
    $lines = [regex]::Split($Text, '(?<=\n)')
    $authSections = @{}
    foreach ($name in @('Auth', 'Twitch', 'Restream', 'YouTube', 'YouTube - RTMP', 'YouTube - RTMPS', 'YouTube - HLS')) {
        $authSections[$name] = $true
    }
    $section = ''
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]') { $section = $matches[1].Trim() }
        elseif ($section -ieq 'Auth' -and $line -match '^\s*Type\s*=\s*([^\r\n]+)') {
            $service = $matches[1].Trim().Trim('"')
            if ($service) { $authSections[$service] = $true }
        }
    }

    $result = New-Object Text.StringBuilder
    $omitSection = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $section = $matches[1].Trim()
            $omitSection = $authSections.ContainsKey($section)
        }
        if ($omitSection) { continue }
        if ($line -match '^\s*(?:RefreshToken|AccessToken|Token|ClientSecret|Password|Username|UserName|StreamKey|Key|CookieId)\s*=') {
            continue
        }
        [void]$result.Append($line)
    }
    return $result.ToString()
}

function ConvertTo-ObsAccountFreeService([string]$Text) {
    try { $service = ConvertFrom-Json -InputObject $Text -ErrorAction Stop }
    catch { throw 'Некорректный service.json: очистка данных входа невозможна.' }
    if ($null -eq $service -or $service -isnot [PSCustomObject]) {
        throw 'Неподдерживаемая структура service.json: очистка данных входа невозможна.'
    }
    $settingsProperty = $service.PSObject.Properties['settings']
    if (-not $settingsProperty -or $settingsProperty.Value -isnot [PSCustomObject]) {
        throw 'В service.json отсутствует объект settings: очистка данных входа невозможна.'
    }
    $settings = $settingsProperty.Value
    foreach ($name in @('key', 'username', 'password', 'token', 'access_token', 'refresh_token', 'client_secret')) {
        $settings.PSObject.Properties.Remove($name)
        $service.PSObject.Properties.Remove($name)
    }
    $settings | Add-Member -MemberType NoteProperty -Name 'use_auth' -Value $false -Force
    $typeProperty = $service.PSObject.Properties['type']
    if (-not $typeProperty -or [string]$typeProperty.Value -ne 'rtmp_common') {
        # Custom service implementations can put a stream key into the URL or
        # arbitrary settings. Keep the service type, reset all connection data.
        $service.settings = [PSCustomObject]@{}
    }
    return ConvertTo-Json -InputObject $service -Depth 100
}

function Copy-ObsAccountFreeFile(
    [string]$Source,
    [string]$Destination,
    [string]$Action
) {
    if (Test-SamePath $Source $Destination) {
        throw 'Очистка данных аккаунта разрешена только в отдельной копии.'
    }
    $before = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($before.Length -gt 32MB) { throw "Слишком большой файл настроек для очистки: $Source" }
    try {
        $text = [IO.File]::ReadAllText($Source, (New-Object Text.UTF8Encoding($false, $true)))
        if ($Action -eq 'Ini') { $clean = ConvertTo-ObsAccountFreeIni $text }
        elseif ($Action -eq 'Service') { $clean = ConvertTo-ObsAccountFreeService $text }
        else { throw 'Unsupported account file action' }
    }
    catch {
        # Do not print parser exceptions: they can contain the original secret.
        throw "Не удалось очистить данные входа в файле: $Source. Backup остановлен."
    }
    $after = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    if ($before.Length -ne $after.Length -or $before.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) {
        throw "Файл изменился во время подготовки backup: $Source"
    }
    $parent = [IO.Path]::GetDirectoryName($Destination)
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    # Never write the original credentials to the backup, even temporarily.
    [IO.File]::WriteAllText($Destination, $clean, (New-Object Text.UTF8Encoding($false)))
    return Get-Sha256Simple $Destination
}

function Get-ObsAccountDataNotice($Manifest) {
    $property = $Manifest.PSObject.Properties['AccountDataIncluded']
    if ($property -and $property.Value -is [bool] -and -not $property.Value) {
        return 'Backup создан без данных входа OBS, ключей трансляций и сессий браузера. Подключите аккаунты и настройте трансляцию заново.'
    }
    return ''
}


function Copy-PlanToBackup(
    $Plan,
    [string]$DestinationRoot,
    [string]$BackupRoot,
    [string]$Category,
    [System.Collections.ArrayList]$FileManifest,
    [System.Collections.ArrayList]$DirectoryManifest,
    [string]$Activity,
    [bool]$IncludeAccountData = $true
) {
    if (@($Plan.ReparsePoints).Count -gt 0) {
        throw (
            "Найдены symlink/junction/reparse point, которые нельзя " +
            "молча пропустить:`r`n" +
            (@($Plan.ReparsePoints) -join "`r`n")
        )
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $DestinationRoot |
        Out-Null

    foreach ($relativeDirectory in @($Plan.Directories)) {
        if (-not $IncludeAccountData -and (Get-ObsAccountFileAction $relativeDirectory (Join-Path $Plan.Root $relativeDirectory)) -eq 'Omit') {
            continue
        }
        $targetDirectory = Join-Path `
            $DestinationRoot `
            $relativeDirectory

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $targetDirectory |
            Out-Null

        $backupRelativeDirectory = Get-RelativePathSafe `
            $BackupRoot `
            $targetDirectory

        [void]$DirectoryManifest.Add([PSCustomObject]@{
            Category = $Category
            RelativePath = $relativeDirectory
            BackupRelativePath = $backupRelativeDirectory
        })
    }

    [Int64]$total = [Int64]$Plan.TotalBytes
    [Int64]$done = 0

    foreach ($file in @($Plan.Files)) {
        $action = 'Copy'
        if (-not $IncludeAccountData) {
            $action = Get-ObsAccountFileAction $file.RelativePath $file.SourcePath
        }
        if ($action -eq 'Omit') {
            $done += [Int64]$file.Size
            continue
        }
        $destination = Join-Path `
            $DestinationRoot `
            $file.RelativePath

        if ($action -eq 'Copy') {
            $hash = Copy-FileAndHash `
                $file.SourcePath `
                $destination `
                ([ref]$done) `
                $total `
                $Activity
        }
        else {
            $hash = Copy-ObsAccountFreeFile $file.SourcePath $destination $action
            $done += [Int64]$file.Size
        }
        $storedSize = [Int64](Get-Item -LiteralPath $destination -Force).Length

        $backupRelative = Get-RelativePathSafe `
            $BackupRoot `
            $destination

        [void]$FileManifest.Add([PSCustomObject]@{
            Category = $Category
            RelativePath = $file.RelativePath
            BackupRelativePath = $backupRelative
            Size = $storedSize
            SHA256 = $hash
        })
    }

    Complete-SubProgress
}

function Get-FreeBytesForPath([string]$Path) {
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $rootPath = [IO.Path]::GetPathRoot($full)
        $drive = New-Object IO.DriveInfo($rootPath)

        return [Int64]$drive.AvailableFreeSpace
    }
    catch {
        return [Int64]::MaxValue
    }
}

function Get-DriveFormatForPath([string]$Path) {
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $rootPath = [IO.Path]::GetPathRoot($full)
        $drive = New-Object IO.DriveInfo($rootPath)
        return [string]$drive.DriveFormat
    }
    catch {
        return $null
    }
}

function Assert-FileSystemCanStorePlan(
    $Plan,
    [string]$DestinationRoot
) {
    $format = Get-DriveFormatForPath $DestinationRoot

    if ($format -ne "FAT32") {
        return
    }

    [Int64]$fat32Max = 4294967295

    foreach ($file in @($Plan.Files)) {
        if ([Int64]$file.Size -gt $fat32Max) {
            throw (
                "Диск назначения использует FAT32, а файл больше 4 GB: " +
                "$($file.SourcePath) ($(Format-Bytes $file.Size)). " +
                "Используйте NTFS или exFAT."
            )
        }
    }
}

function Assert-FreeSpace(
    [string]$Path,
    [Int64]$RequiredBytes,
    [string]$Purpose
) {
    $free = Get-FreeBytesForPath $Path

    if ($free -eq [Int64]::MaxValue) {
        Write-Warn "Не удалось определить свободное место: $Path"
        return
    }

    [Int64]$reserve = [Int64](512MB)
    [Int64]$reserveBySize = [Int64][Math]::Ceiling(
        [double]$RequiredBytes * 0.05
    )

    if ($reserveBySize -gt $reserve) {
        $reserve = $reserveBySize
    }

    [Int64]$minimum = $RequiredBytes + $reserve

    Write-Info (
        "${Purpose}: нужно ~$(Format-Bytes $RequiredBytes), " +
        "свободно $(Format-Bytes $free)"
    )

    if ($free -lt $minimum) {
        throw (
            "Недостаточно места для '$Purpose'. " +
            "Нужно минимум $(Format-Bytes $minimum), " +
            "доступно $(Format-Bytes $free)."
        )
    }
}

function Assert-ReasonablePathLengths(
    $Plan,
    [string]$DestinationRoot,
    [int]$WarningLimit = 235
) {
    $tooLong = New-Object System.Collections.ArrayList

    foreach ($file in @($Plan.Files)) {
        $target = Join-Path $DestinationRoot $file.RelativePath

        if ($target.Length -gt $WarningLimit) {
            [void]$tooLong.Add($target)
        }
    }

    foreach ($directory in @($Plan.Directories)) {
        $target = Join-Path $DestinationRoot $directory

        if ($target.Length -gt $WarningLimit) {
            [void]$tooLong.Add($target)
        }
    }

    if ($tooLong.Count -gt 0) {
        $sample = @($tooLong | Select-Object -First 10) -join "`r`n"

        throw (
            "Некоторые целевые пути длиннее $WarningLimit символов. " +
            "Для Windows PowerShell 5.1 это риск ошибки Win32 path.`r`n`r`n" +
            "КАК ИСПРАВИТЬ:`r`n" +
            "1. Закройте это окно.`r`n" +
            "2. Удалите незавершённую папку OBS_BACKUP_*_INCOMPLETE.`r`n" +
            "3. По умолчанию backup создаётся в короткой папке:`r`n" +
            "   %USERPROFILE%\OBSBackup\`r`n" +
            "4. Если даже этого недостаточно, создайте рядом с CREATE_BACKUP.bat файл:`r`n" +
            "   BACKUP_DESTINATION.txt`r`n" +
            "   и впишите туда ещё более короткий путь, например:`r`n" +
            "   D:\OBSBK`r`n" +
            "5. Снова запустите CREATE_BACKUP.bat.`r`n`r`n" +
            "Переименовывать исходные media-файлы обычно не требуется. " +
            "Проблема именно в общей длине полного пути.`r`n`r`n" +
            "Пути, которые не проходят проверку:`r`n" +
            $sample
        )
    }
}

function New-MetadataHashList(
    [string]$BackupRoot,
    [string[]]$RelativePaths
) {
    $items = New-Object System.Collections.ArrayList

    foreach ($relativePath in $RelativePaths) {
        $path = Join-Path $BackupRoot $relativePath

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Не найден metadata-файл: $relativePath"
        }

        $info = Get-Item -LiteralPath $path -Force

        [void]$items.Add([PSCustomObject]@{
            RelativePath = $relativePath
            Size = [Int64]$info.Length
            SHA256 = Get-Sha256Simple $path
        })
    }

    return @($items)
}

function Verify-BackupPackage(
    [string]$BackupRoot,
    [bool]$ShowProgress = $true,
    [bool]$RequireComplete = $true,
    [string[]]$IgnoreMetadataRelativePaths = @(),
    [bool]$SkipShaVerification = $false
) {
    $errors = New-Object System.Collections.ArrayList
    $ignoredMetadata = @{}

    foreach ($ignorePath in @($IgnoreMetadataRelativePaths)) {
        if ([string]::IsNullOrWhiteSpace($ignorePath)) {
            continue
        }

        $ignoredMetadata[
            $ignorePath.Replace("/", "\").ToLowerInvariant()
        ] = $true
    }

    $statusPath = Join-Path $BackupRoot "backup_status.json"
    $fileManifestPath = Join-Path $BackupRoot "file_manifest.json"
    $directoryManifestPath = Join-Path $BackupRoot "directory_manifest.json"
    $metadataHashesPath = Join-Path $BackupRoot "metadata_hashes.json"

    foreach ($required in @(
        $statusPath,
        $fileManifestPath,
        $directoryManifestPath,
        $metadataHashesPath
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            [void]$errors.Add("Отсутствует обязательный файл: $required")
        }
    }

    if ($errors.Count -gt 0) {
        return [PSCustomObject]@{
            Success = $false
            Errors = @($errors)
            FileCount = 0
            TotalBytes = [Int64]0
        }
    }

    try {
        $status = Read-JsonFile $statusPath

        if ($RequireComplete -and -not $status.Complete) {
            [void]$errors.Add(
                "backup_status.json помечает backup как незавершённый."
            )
        }

        if (
            -not $SkipShaVerification -and
            $status.MetadataHashesSHA256
        ) {
            $actual = Get-Sha256Simple $metadataHashesPath

            if ($actual -ne [string]$status.MetadataHashesSHA256) {
                [void]$errors.Add(
                    "SHA-256 metadata_hashes.json не совпадает."
                )
            }
        }
    }
    catch {
        [void]$errors.Add(
            "Не удалось прочитать backup_status.json: " +
            $_.Exception.Message
        )
    }

    try {
        $metadataItems = @(Read-JsonFile $metadataHashesPath)

        foreach ($item in $metadataItems) {
            $relativeMetadataPath = (
                [string]$item.RelativePath
            ).Replace("/", "\")
            $metadataKey = $relativeMetadataPath.ToLowerInvariant()

            if ($ignoredMetadata.ContainsKey($metadataKey)) {
                continue
            }

            $path = Join-Path `
                $BackupRoot `
                $relativeMetadataPath

            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                [void]$errors.Add(
                    "Metadata-файл отсутствует: " +
                    $relativeMetadataPath
                )

                continue
            }

            $info = Get-Item -LiteralPath $path -Force

            if ([Int64]$info.Length -ne [Int64]$item.Size) {
                [void]$errors.Add(
                    "Размер metadata не совпадает: " +
                    $relativeMetadataPath
                )

                continue
            }

            if (-not $SkipShaVerification) {
                $hash = Get-Sha256Simple $path

                if ($hash -ne [string]$item.SHA256) {
                    [void]$errors.Add(
                        "SHA-256 metadata не совпадает: " +
                        $relativeMetadataPath
                    )
                }
            }
        }
    }
    catch {
        [void]$errors.Add(
            "Ошибка проверки metadata: " +
            $_.Exception.Message
        )
    }

    $fileItems = @()

    try {
        $fileItems = @(Read-JsonFile $fileManifestPath)
    }
    catch {
        [void]$errors.Add(
            "file_manifest.json не читается: " +
            $_.Exception.Message
        )
    }

    [Int64]$totalBytes = 0

    foreach ($file in $fileItems) {
        $totalBytes += [Int64]$file.Size
    }

    [Int64]$done = 0

    foreach ($file in $fileItems) {
        $path = Join-Path `
            $BackupRoot `
            ([string]$file.BackupRelativePath)

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [void]$errors.Add(
                "Отсутствует backup-файл: " +
                [string]$file.BackupRelativePath
            )

            continue
        }

        $info = Get-Item -LiteralPath $path -Force

        if ([Int64]$info.Length -ne [Int64]$file.Size) {
            [void]$errors.Add(
                "Неверный размер: " +
                [string]$file.BackupRelativePath
            )

            continue
        }

        if ($SkipShaVerification) {
            $done += [Int64]$file.Size
        }
        else {
            if ($ShowProgress) {
                $hash = Get-Sha256WithProgress `
                    $path `
                    ([ref]$done) `
                    $totalBytes `
                    "Полная SHA-256 проверка backup" `
                    "SHA-256: "
            }
            else {
                $hash = Get-Sha256Simple $path
                $done += [Int64]$file.Size
            }

            if ($hash -ne [string]$file.SHA256) {
                [void]$errors.Add(
                    "SHA-256 не совпадает: " +
                    [string]$file.BackupRelativePath
                )
            }
        }
    }

    if ($ShowProgress -and -not $SkipShaVerification) {
        Complete-SubProgress
    }

    try {
        $directoryItems = @(Read-JsonFile $directoryManifestPath)

        foreach ($directory in $directoryItems) {
            $path = Join-Path `
                $BackupRoot `
                ([string]$directory.BackupRelativePath)

            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                [void]$errors.Add(
                    "Отсутствует каталог: " +
                    [string]$directory.BackupRelativePath
                )
            }
        }
    }
    catch {
        [void]$errors.Add(
            "directory_manifest.json не читается: " +
            $_.Exception.Message
        )
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0)
        Errors = @($errors)
        FileCount = $fileItems.Count
        TotalBytes = [Int64]$totalBytes
        ShaSkipped = [bool]$SkipShaVerification
    }
}

function Copy-BackupCategoryToTarget(
    [string]$BackupRoot,
    $FileManifest,
    $DirectoryManifest,
    [string]$Category,
    [string]$TargetRoot,
    [string]$Activity
) {
    New-Item `
        -ItemType Directory `
        -Force `
        -Path $TargetRoot |
        Out-Null

    foreach ($directory in @(
        $DirectoryManifest |
        Where-Object { $_.Category -eq $Category }
    )) {
        $targetDirectory = Join-Path `
            $TargetRoot `
            ([string]$directory.RelativePath)

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $targetDirectory |
            Out-Null
    }

    $files = @(
        $FileManifest |
        Where-Object { $_.Category -eq $Category }
    )

    [Int64]$totalBytes = 0
    foreach ($file in $files) {
        $totalBytes += [Int64]$file.Size
    }

    [Int64]$copyDone = 0

    foreach ($file in $files) {
        $source = Join-Path `
            $BackupRoot `
            ([string]$file.BackupRelativePath)

        $destination = Join-Path `
            $TargetRoot `
            ([string]$file.RelativePath)

        $sourceHash = Copy-FileAndHash `
            $source `
            $destination `
            ([ref]$copyDone) `
            $totalBytes `
            $Activity

        if ($sourceHash -ne [string]$file.SHA256) {
            throw "Источник backup изменился во время Restore: $source"
        }
    }

    Complete-SubProgress

    # Read destination back and verify every byte by SHA-256.
    [Int64]$verifyDone = 0

    foreach ($file in $files) {
        $destination = Join-Path `
            $TargetRoot `
            ([string]$file.RelativePath)

        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "После Restore отсутствует файл: $destination"
        }

        $info = Get-Item -LiteralPath $destination -Force

        if ([Int64]$info.Length -ne [Int64]$file.Size) {
            throw "После Restore размер не совпал: $destination"
        }

        $hash = Get-Sha256WithProgress `
            $destination `
            ([ref]$verifyDone) `
            $totalBytes `
            ($Activity + " — проверка") `
            "SHA-256: "

        if ($hash -ne [string]$file.SHA256) {
            throw "После Restore SHA-256 не совпал: $destination"
        }
    }

    Complete-SubProgress
}

function Replace-PathInTextConfigs(
    [string]$Root,
    [string]$OldPath,
    [string]$NewPath,
    [string[]]$Extensions = @(
        ".json",
        ".ini",
        ".txt",
        ".conf",
        ".cfg"
    )
) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($OldPath)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($NewPath)) {
        return
    }

    if (Test-SamePath $OldPath $NewPath) {
        return
    }

    $variants = New-Object System.Collections.ArrayList

    [void]$variants.Add([PSCustomObject]@{
        Old = $OldPath
        New = $NewPath
    })

    [void]$variants.Add([PSCustomObject]@{
        Old = ($OldPath -replace '\\', '/')
        New = ($NewPath -replace '\\', '/')
    })

    [void]$variants.Add([PSCustomObject]@{
        Old = $OldPath.Replace('\', '\\')
        New = $NewPath.Replace('\', '\\')
    })

    try {
        $oldUri = (New-Object Uri($OldPath)).AbsoluteUri
        $newUri = (New-Object Uri($NewPath)).AbsoluteUri

        [void]$variants.Add([PSCustomObject]@{
            Old = $oldUri
            New = $newUri
        })
    }
    catch {}

    $files = @(
        Get-ChildItem `
            -LiteralPath $Root `
            -Recurse `
            -File `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $extensions -contains $_.Extension.ToLowerInvariant()
        }
    )

    foreach ($file in $files) {
        try {
            $text = [IO.File]::ReadAllText($file.FullName)
            $changed = $false

            foreach ($variant in $variants) {
                $oldText = [string]$variant.Old
                $newText = [string]$variant.New

                if ([string]::IsNullOrWhiteSpace($oldText)) {
                    continue
                }

                $pattern = [regex]::Escape($oldText)

                $replacementEvaluator = {
                    param($match)
                    return $newText
                }

                $newContent = [regex]::Replace(
                    $text,
                    $pattern,
                    $replacementEvaluator,
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase
                )

                if ($newContent -ne $text) {
                    $text = $newContent
                    $changed = $true
                }
            }

            if ($changed) {
                [IO.File]::WriteAllText(
                    $file.FullName,
                    $text,
                    (New-Object Text.UTF8Encoding($false))
                )
            }
        }
        catch {
            throw (
                "Не удалось безопасно переписать пути в '$($file.FullName)': " +
                $_.Exception.Message
            )
        }
    }
}

function Rename-ForRollback(
    [string]$Path,
    [string]$Tag
) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $trimmed = $Path.TrimEnd([char[]]"\/")
    $parent = [IO.Path]::GetDirectoryName($trimmed)
    $leaf = [IO.Path]::GetFileName($trimmed)

    if (-not $parent) {
        throw "Нельзя создать rollback для корня диска: $Path"
    }

    $rollbackPath = Join-Path `
        $parent `
        ($leaf + ".__OBSCLONE_OLD_" + $Tag)

    if (Test-Path -LiteralPath $rollbackPath) {
        Remove-Item `
            -LiteralPath $rollbackPath `
            -Recurse `
            -Force
    }

    Move-Item `
        -LiteralPath $Path `
        -Destination $rollbackPath `
        -Force

    return $rollbackPath
}

function Restore-RollbackPath(
    [string]$CurrentPath,
    [string]$RollbackPath
) {
    try {
        if ($CurrentPath -and (Test-Path -LiteralPath $CurrentPath)) {
            Remove-Item `
                -LiteralPath $CurrentPath `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if ($RollbackPath -and (Test-Path -LiteralPath $RollbackPath)) {
            Move-Item `
                -LiteralPath $RollbackPath `
                -Destination $CurrentPath `
                -Force
        }
    }
    catch {
        Write-Bad (
            "Ошибка rollback для '$CurrentPath': " +
            $_.Exception.Message
        )
    }
}

function Zip-DirectoryWithProgress(
    [string]$SourceDirectory,
    [string]$ZipPath
) {
    Add-Type `
        -AssemblyName System.IO.Compression `
        -ErrorAction SilentlyContinue

    Add-Type `
        -AssemblyName System.IO.Compression.FileSystem `
        -ErrorAction SilentlyContinue

    $plan = Get-TreePlan $SourceDirectory

    if (@($plan.ReparsePoints).Count -gt 0) {
        throw "В готовом backup неожиданно появились reparse points."
    }

    [Int64]$totalBytes = [Int64]$plan.TotalBytes
    [Int64]$done = 0

    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }

    $zipStream = $null
    $archive = $null

    try {
        $zipStream = [IO.File]::Open(
            $ZipPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )

        $archive = New-Object `
            -TypeName System.IO.Compression.ZipArchive `
            -ArgumentList @(
                $zipStream,
                [IO.Compression.ZipArchiveMode]::Create,
                $true
            )

        $compressionLevel = [IO.Compression.CompressionLevel]::Fastest

        try {
            $compressionLevel = [IO.Compression.CompressionLevel]::NoCompression
        }
        catch {}

        $rootName = Split-Path -Leaf $SourceDirectory

        foreach ($directory in @($plan.Directories)) {
            $entryName = (
                $rootName + "\" + $directory
            ).Replace("\", "/").TrimEnd("/") + "/"

            [void]$archive.CreateEntry($entryName)
        }

        foreach ($file in @($plan.Files)) {
            $entryName = (
                $rootName + "\" + $file.RelativePath
            ).Replace("\", "/")

            $entry = $archive.CreateEntry(
                $entryName,
                $compressionLevel
            )

            $input = $null
            $output = $null

            try {
                $input = [IO.File]::Open(
                    $file.SourcePath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read
                )

                $output = $entry.Open()

                [byte[]]$buffer = New-Object byte[] (16MB)

                while (($read = $input.Read(
                    $buffer,
                    0,
                    $buffer.Length
                )) -gt 0) {
                    $output.Write($buffer, 0, $read)

                    $done += $read

                    Show-ByteProgress `
                        "Создание ZIP" `
                        ("Упаковка: " + [IO.Path]::GetFileName($file.SourcePath)) `
                        $done `
                        $totalBytes
                }
            }
            finally {
                if ($output) {
                    $output.Dispose()
                }

                if ($input) {
                    $input.Dispose()
                }
            }
        }
    }
    finally {
        if ($archive) {
            $archive.Dispose()
        }

        if ($zipStream) {
            $zipStream.Dispose()
        }

        Complete-SubProgress
    }

    # Structural validation of the ZIP.
    $readArchive = $null

    try {
        $readArchive = [IO.Compression.ZipFile]::OpenRead($ZipPath)

        $fileEntries = @(
            $readArchive.Entries |
            Where-Object { -not $_.FullName.EndsWith("/") }
        )

        if ($fileEntries.Count -ne @($plan.Files).Count) {
            throw (
                "ZIP содержит другое число файлов. " +
                "Ожидалось $(@($plan.Files).Count), " +
                "получено $($fileEntries.Count)."
            )
        }

        $expectedLengths = @{}

        foreach ($file in @($plan.Files)) {
            $entryName = (
                (Split-Path -Leaf $SourceDirectory) +
                "\" +
                $file.RelativePath
            ).Replace("\", "/").ToLowerInvariant()

            $expectedLengths[$entryName] = [Int64]$file.Size
        }

        foreach ($entry in $fileEntries) {
            $key = $entry.FullName.ToLowerInvariant()

            if (-not $expectedLengths.ContainsKey($key)) {
                throw "В ZIP найден неожиданный файл: $($entry.FullName)"
            }

            if ([Int64]$entry.Length -ne [Int64]$expectedLengths[$key]) {
                throw "Неверный размер entry в ZIP: $($entry.FullName)"
            }
        }
    }
    finally {
        if ($readArchive) {
            $readArchive.Dispose()
        }
    }
}

function Test-JsonFilesValid([string]$Root) {
    $errors = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [PSCustomObject]@{
            Success = $true
            Errors = @()
        }
    }

    $scanRoot = Join-Path $Root "basic\scenes"
    if (-not (Test-Path -LiteralPath $scanRoot -PathType Container)) {
        $scanRoot = $Root
    }

    foreach ($file in @(
        Get-ChildItem `
            -LiteralPath $scanRoot `
            -Recurse `
            -File `
            -Filter "*.json" `
            -Force `
            -ErrorAction SilentlyContinue
    )) {
        try {
            [void]([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json)
        }
        catch {
            [void]$errors.Add(
                "JSON повреждён: $($file.FullName) :: $($_.Exception.Message)"
            )
        }
    }

    return [PSCustomObject]@{
        Success = ($errors.Count -eq 0)
        Errors = @($errors)
    }
}

function Get-StreamSha256WithProgress(
    [System.IO.Stream]$Stream,
    [ref]$Done,
    [Int64]$Total,
    [string]$Activity,
    [string]$Status
) {
    $sha = [Security.Cryptography.SHA256]::Create()

    try {
        [byte[]]$buffer = New-Object byte[] (16MB)

        while (($read = $Stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock(
                $buffer,
                0,
                $read,
                $buffer,
                0
            )

            $Done.Value = [Int64]$Done.Value + $read

            Show-ByteProgress `
                $Activity `
                $Status `
                $Done.Value `
                $Total
        }

        [byte[]]$empty = @()
        [void]$sha.TransformFinalBlock($empty, 0, 0)

        return ([BitConverter]::ToString($sha.Hash)).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Verify-ZipAgainstFolder(
    [string]$SourceDirectory,
    [string]$ZipPath
) {
    Add-Type `
        -AssemblyName System.IO.Compression `
        -ErrorAction SilentlyContinue

    Add-Type `
        -AssemblyName System.IO.Compression.FileSystem `
        -ErrorAction SilentlyContinue

    $plan = Get-TreePlan $SourceDirectory

    if (@($plan.ReparsePoints).Count -gt 0) {
        throw "Нельзя проверить ZIP: в исходной папке появились reparse points."
    }

    [Int64]$totalBytes = [Int64]$plan.TotalBytes * 2
    [Int64]$done = 0

    $archive = $null

    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)

        $entryMap = @{}
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith("/")) {
                continue
            }

            $entryMap[$entry.FullName.ToLowerInvariant()] = $entry
        }

        if ($entryMap.Count -ne @($plan.Files).Count) {
            throw (
                "ZIP содержит другое число файлов. " +
                "Ожидалось $(@($plan.Files).Count), получено $($entryMap.Count)."
            )
        }

        $rootName = Split-Path -Leaf $SourceDirectory

        foreach ($file in @($plan.Files)) {
            $entryName = (
                $rootName + "\" + $file.RelativePath
            ).Replace("\", "/")

            $key = $entryName.ToLowerInvariant()

            if (-not $entryMap.ContainsKey($key)) {
                throw "ZIP не содержит файл: $entryName"
            }

            $entry = $entryMap[$key]

            if ([Int64]$entry.Length -ne [Int64]$file.Size) {
                throw "Размер ZIP entry не совпал: $entryName"
            }

            $sourceStream = $null
            $zipStream = $null

            try {
                $sourceStream = [IO.File]::Open(
                    $file.SourcePath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read
                )

                $sourceHash = Get-StreamSha256WithProgress `
                    $sourceStream `
                    ([ref]$done) `
                    $totalBytes `
                    "Полная проверка ZIP" `
                    ("Исходная папка: " + [IO.Path]::GetFileName($file.SourcePath))

                $zipStream = $entry.Open()

                $zipHash = Get-StreamSha256WithProgress `
                    $zipStream `
                    ([ref]$done) `
                    $totalBytes `
                    "Полная проверка ZIP" `
                    ("ZIP entry: " + [IO.Path]::GetFileName($file.SourcePath))

                if ($sourceHash -ne $zipHash) {
                    throw "Содержимое ZIP entry отличается от backup-папки: $entryName"
                }
            }
            finally {
                if ($zipStream) {
                    $zipStream.Dispose()
                }

                if ($sourceStream) {
                    $sourceStream.Dispose()
                }
            }
        }
    }
    finally {
        if ($archive) {
            $archive.Dispose()
        }

        Complete-SubProgress
    }
}


function Remove-VerifiedObsBackupFolder(
    [string]$BackupRoot,
    [string]$BackupHome,
    [string]$ZipPath,
    [bool]$ZipVerified,
    [string]$ExpectedZipHash,
    [ref]$ArchiveStillVerified = $null
) {
    if ($ArchiveStillVerified) { $ArchiveStillVerified.Value = $false }
    if (-not $ZipVerified) { return $false }
    $root = [IO.Path]::GetFullPath($BackupRoot).TrimEnd([char[]]"\/")
    $homePath = [IO.Path]::GetFullPath($BackupHome).TrimEnd([char[]]"\/")
    $zipFull = [IO.Path]::GetFullPath($ZipPath)
    $leaf = [IO.Path]::GetFileName($root)
    if (
        -not (Test-SamePath ([IO.Path]::GetDirectoryName($root)) $homePath) -or
        $leaf -notmatch '^OBS_BACKUP_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}$' -or
        -not (Test-SamePath $zipFull ($root + '.zip')) -or
        $ExpectedZipHash -notmatch '^[0-9a-fA-F]{64}$'
    ) {
        throw 'Путь распакованного backup или проверенного ZIP не соответствует текущей операции.'
    }
    # Refuse directory links at any level before a recursive removal.
    $ancestor = $root
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if (Test-ReparsePoint $item) { throw 'Распакованный backup оставлен: обнаружена ссылка в пути.' }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $plan = Get-TreePlan $root
    if (@($plan.ReparsePoints).Count -gt 0) { throw 'Распакованный backup оставлен: внутри найдены ссылки.' }
    $status = Read-JsonFile (Join-Path $root 'backup_status.json')
    if (-not $status.Complete) { throw 'Нельзя удалить папку незавершённого backup.' }
    $sidecar = [IO.File]::ReadAllText($zipFull + '.sha256').Trim()
    $expectedSidecar = $ExpectedZipHash + ' *' + [IO.Path]::GetFileName($zipFull)
    if ($sidecar -ine $expectedSidecar) { throw 'Файл SHA-256 не соответствует проверенному ZIP.' }

    # Hold the ZIP open without write/delete sharing until the directory has
    # been removed. Revalidate its exact bytes before discarding the other copy.
    $stream = [IO.File]::Open($zipFull, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        [Int64]$done = 0
        $actualHash = Get-StreamSha256WithProgress $stream ([ref]$done) $stream.Length 'Проверка ZIP перед удалением папки' 'SHA-256 ZIP'
        if ($actualHash -ine $ExpectedZipHash) { throw 'ZIP изменился после проверки. Распакованный backup сохранён.' }
        if ($ArchiveStillVerified) { $ArchiveStillVerified.Value = $true }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    }
    finally { $stream.Dispose(); Complete-SubProgress }
    return $true
}

function Open-ObsBackupArchiveLocation([string]$ZipPath) {
    try {
        $full = [IO.Path]::GetFullPath($ZipPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'ZIP отсутствует' }
        # Explorer is intentionally visible: opening the result was requested.
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $full + '"') -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warn "Не удалось открыть Проводник. ZIP сохранён: $ZipPath"
    }
}

