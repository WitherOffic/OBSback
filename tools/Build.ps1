#requires -Version 5.1
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$releaseName = 'OBSback-v1.3.1'
$zipPath = Join-Path $outputRoot ($releaseName + '.zip')
$report = New-Object System.Collections.Generic.List[string]
$report.Add('OBSback v1.3.1 - Windows PowerShell ' + $PSVersionTable.PSVersion)
$report.Add('Date: ' + (Get-Date).ToString('o'))
$utf8 = New-Object Text.UTF8Encoding($true)
$testRoot = Join-Path $outputRoot ('build-test-' + [Guid]::NewGuid().ToString('N'))
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$oldLocalAppData = $env:LOCALAPPDATA

function Assert-Test([bool]$Condition, [string]$Description) {
    if (-not $Condition) { throw $Description }
    $report.Add('PASS: ' + $Description)
}
function Invoke-CheckedProcess([string]$Exe, [string]$Arguments, [string]$InputText = '', [int]$ExpectedExit = 0) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($InputText) { $process.StandardInput.WriteLine($InputText) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Test process timed out' }
        $result = $stdout.Result + $stderr.Result
        if ($process.ExitCode -ne $ExpectedExit) { throw ('Unexpected test exit code ' + $process.ExitCode + ': ' + $result) }
        return $result
    } finally { $process.Dispose() }
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:TEMP = $testRoot
    $env:TMP = $testRoot
    $env:LOCALAPPDATA = $testRoot
    $packageFiles = @('OBSback.bat','README.txt')
    $packageFiles += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'app') -File | Where-Object { $_.Extension -in '.ps1','.bat' } | ForEach-Object { 'app/' + $_.Name })
    $packageFiles += @('settings/BACKUP_DESTINATION.txt','settings/EXTRA_SOURCES.txt')
    foreach ($relative in $packageFiles) {
        $source = Join-Path $repoRoot $relative
        Assert-Test (Test-Path -LiteralPath $source -PathType Leaf) ('package file: ' + $relative)
        if ([IO.Path]::GetExtension($source) -eq '.ps1') {
            $tokens = $null
            $parseErrors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
            Assert-Test (@($parseErrors).Count -eq 0) ('PS5.1 syntax: ' + $relative)
            $bytes = [IO.File]::ReadAllBytes($source)
            Assert-Test ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ('UTF-8 BOM: ' + $relative)
        }
        if ([IO.Path]::GetExtension($source) -eq '.bat') {
            $bytes = [IO.File]::ReadAllBytes($source)
            Assert-Test ([Text.Encoding]::ASCII.GetString($bytes).StartsWith('@echo off')) ('BAT without BOM: ' + $relative)
        }
    }
    $compactOutput = Invoke-CheckedProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $repoRoot 'app\Start-ObsBack.ps1') + '" -Action SelfTest')
    Assert-Test ($compactOutput.Contains('Проверка пройдена. Ошибок нет.')) 'launcher and source self-test'
    Assert-Test (@($compactOutput -split '\r?\n' | Where-Object { $_.Trim() }).Count -eq 2) 'successful self-test shows exactly two lines'
    Assert-Test ($compactOutput -notmatch 'OK:|SELF-TEST PASSED|ETA') 'internal diagnostics and progress are hidden'
    $testLog = [IO.File]::ReadAllText((Join-Path $testRoot 'OBSback\Logs\self-test.log'))
    Assert-Test ($testLog.Contains('SELF-TEST PASSED') -and $testLog.Contains('OK: ZIP create + full content verification')) 'full diagnostics are retained in UTF-8 log'
    foreach ($match in [regex]::Matches($testLog,'OK: [^\r\n]+')) { $report.Add($match.Value) }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [IO.File]::Open($zipPath,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $archive = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in $packageFiles) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $repoRoot $relative),($releaseName + '/' + $relative),[IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $archive.Dispose(); $stream.Dispose() }

    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        Assert-Test ($zip.Entries.Count -eq $packageFiles.Count) 'ZIP entry count'
        $seen = @{}
        foreach ($entry in $zip.Entries) {
            $prefix = $releaseName + '/'
            if (-not $entry.FullName.StartsWith($prefix,[StringComparison]::Ordinal)) { throw 'Bad ZIP prefix' }
            $relative = $entry.FullName.Substring($prefix.Length)
            if ($relative -notin $packageFiles -or $seen.ContainsKey($relative)) { throw 'Unexpected/duplicate ZIP entry' }
            $seen[$relative] = $true
            $entryStream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($entryStream)).Replace('-','') }
            finally { $sha.Dispose(); $entryStream.Dispose() }
            Assert-Test ($hash -eq (Get-FileHash -LiteralPath (Join-Path $repoRoot $relative) -Algorithm SHA256).Hash) ('ZIP bytes: ' + $relative)
        }
    } finally { $zip.Dispose() }

    $extracted = Join-Path $testRoot 'Проверка пути с пробелами & символами'
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$extracted)
    $packedRoot = Join-Path $extracted $releaseName
    $rootEntries = @(Get-ChildItem -LiteralPath $packedRoot | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-Test (($rootEntries -join '|') -eq 'app|OBSback.bat|README.txt|settings') 'exactly four root entries in distribution'
    $packedTest = Invoke-CheckedProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $packedRoot 'app\Start-ObsBack.ps1') + '" -Action SelfTest')
    Assert-Test ($packedTest.Contains('Проверка пройдена. Ошибок нет.')) 'extracted launcher: Cyrillic, spaces and ampersand path'
    $menuLog = Invoke-CheckedProcess $env:ComSpec ('/d /c ""' + (Join-Path $packedRoot 'OBSback.bat') + '""') '0'
    Assert-Test ($menuLog.Contains('OBSback v1.3.1')) 'root BAT opens menu and exits cleanly'
    $invalidBackup = Join-Path $testRoot 'invalid backup'
    New-Item -ItemType Directory -Path $invalidBackup | Out-Null
    $null = Invoke-CheckedProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $packedRoot 'app\Start-ObsBack.ps1') + '" -Action Verify -BackupPath "' + $invalidBackup + '"') '' 1
    $report.Add('PASS: verification rejects incomplete backup and launcher returns failure')

    # Break only the extracted test fixture, then verify errors and the backup gate.
    $brokenFile = [IO.Path]::GetFullPath((Join-Path $packedRoot 'app\ObsClone.Repair.ps1'))
    if (-not $brokenFile.StartsWith([IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Failure fixture outside test root' }
    Remove-Item -LiteralPath $brokenFile
    $failureOutput = Invoke-CheckedProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $packedRoot 'app\Start-ObsBack.ps1') + '" -Action SelfTest') '' 1
    Assert-Test ($failureOutput.Contains('Нет обязательного файла: ObsClone.Repair.ps1') -and $failureOutput.Contains('self-test.log')) 'compact failure shows reason and log path'
    Assert-Test (@($failureOutput -split '\r?\n' | Where-Object { $_.Trim() }).Count -eq 3) 'failed self-test shows exactly three lines'
    $failureLog = [IO.File]::ReadAllText((Join-Path $testRoot 'OBSback\Logs\self-test.log'))
    Assert-Test ($failureLog.Contains('SELF-TEST FAIL:') -and -not $failureLog.Contains('SELF-TEST PASSED')) 'latest failure replaces the prior log'
    $backupFailure = Invoke-CheckedProcess 'powershell.exe' ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $packedRoot 'app\Start-ObsBack.ps1') + '" -Action Backup') '' 1
    Assert-Test ($backupFailure.Contains('Создание бекапа остановлено.')) 'self-test failure still prevents backup'

    # Layout detection must also keep standalone restore bundles flat.
    . (Join-Path $repoRoot 'app\ObsClone.Common.ps1')
    $flat = Get-ObsBackToolLayout $invalidBackup
    Assert-Test ($flat.ToolRoot -eq $invalidBackup -and $flat.SettingsRoot -eq $invalidBackup) 'standalone flat layout remains supported'
    $compact = Get-ObsBackToolLayout (Join-Path $packedRoot 'app')
    Assert-Test ($compact.ToolRoot -eq $packedRoot -and $compact.SettingsRoot -eq (Join-Path $packedRoot 'settings')) 'compact layout resolves settings outside app'

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText(($zipPath + '.sha256'),($hash + '  ' + $releaseName + ".zip`r`n"),(New-Object Text.UTF8Encoding($false)))
    $report.Add('ZIP SHA256: ' + $hash)
    $report.Add('No real OBS processes or user configurations were modified. Full restore on a real OBS installation was not performed.')
    [IO.File]::WriteAllLines((Join-Path $outputRoot ($releaseName + '-verification.txt')),$report,$utf8)
    Write-Output ('BUILD PASSED: ' + $zipPath)
    Write-Output ('SHA256: ' + $hash)
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    $env:LOCALAPPDATA = $oldLocalAppData
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (
        [IO.Path]::GetDirectoryName($resolvedTestRoot) -eq $outputRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($resolvedTestRoot) -match '^build-test-[0-9a-f]{32}$' -and
        (Test-Path -LiteralPath $resolvedTestRoot -PathType Container)
    ) {
        $testItems = @(Get-Item -LiteralPath $resolvedTestRoot) + @(Get-ChildItem -LiteralPath $resolvedTestRoot -Recurse -Force)
        if (@($testItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -eq 0) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}
