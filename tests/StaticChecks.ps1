$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $repo 'Engine'
$files = @(
    (Join-Path $repo 'Manager.ps1'),
    (Join-Path $engine 'Scanner.ps1'),
    (Join-Path $engine 'Downloader.ps1'),
    (Join-Path $engine 'Supervisor.ps1')
)

$failed = $false
foreach ($path in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "Parse errors in $path" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host ("  {0} @ line {1}" -f $_.Message,$_.Extent.StartLineNumber) -ForegroundColor Red }
    }
}

$scanner = Get-Content -LiteralPath (Join-Path $engine 'Scanner.ps1') -Raw -Encoding UTF8
$downloader = Get-Content -LiteralPath (Join-Path $engine 'Downloader.ps1') -Raw -Encoding UTF8
$supervisor = Get-Content -LiteralPath (Join-Path $engine 'Supervisor.ps1') -Raw -Encoding UTF8
$manager = Get-Content -LiteralPath (Join-Path $repo 'Manager.ps1') -Raw -Encoding UTF8

if ($scanner -match '(?im)Get-ChildItem[^\r\n]*-Filter\s+\*\.txt') {
    Write-Host 'Scanner still contains a *.txt-only Get-ChildItem filter.' -ForegroundColor Red
    $failed = $true
}

if ($scanner -notmatch "all_urls\.txt") {
    Write-Host 'Scanner does not contain all_urls.txt generation.' -ForegroundColor Red
    $failed = $true
}

if ($scanner -notmatch '\[int\]\$MaxFiles\s*=\s*0' -or $scanner -notmatch '\[System\.IO\.Directory\]::EnumerateFiles') {
    Write-Host 'Scanner source discovery is missing bounded, lazy file enumeration.' -ForegroundColor Red
    $failed = $true
}

$scanPassAt = $supervisor.IndexOf('$scanCode = Run-Child -ScriptPath $scanner')
$downloadPassAt = $supervisor.IndexOf('$downloadCode = Run-Child -ScriptPath $downloader')
if ($scanPassAt -lt 0 -or $downloadPassAt -le $scanPassAt -or $supervisor -match 'Start-ChildAsync|Invoke-NewCompletedCacheDownloads|incremental_downloader') {
    Write-Host 'Supervisor must finish one Full Scanner pass before starting Downloader; repeated incremental Downloader launches are too expensive.' -ForegroundColor Red
    $failed = $true
}

if ($supervisor -notmatch '\$downloadCode\s*=\s*Run-Child\s+-ScriptPath\s+\$downloader') {
    Write-Host 'Supervisor does not run Downloader after Scanner completes.' -ForegroundColor Red
    $failed = $true
}

$versions = @()
foreach ($raw in @($scanner,$downloader,$supervisor)) {
    if ($raw -match "\`$EngineVersion\s*=\s*'([^']+)'") { $versions += $matches[1] }
}
if (($versions | Select-Object -Unique).Count -ne 1 -or $versions.Count -ne 3) {
    Write-Host ('Engine version mismatch: ' + ($versions -join ', ')) -ForegroundColor Red
    $failed = $true
}

$allRaw = ($files | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding UTF8 }) -join "`n"
if ($allRaw -match '(?i)C:\\Users\\[^\\\r\n]+') {
    Write-Host 'A local C:\Users\... absolute path appears in tracked PowerShell source.' -ForegroundColor Red
    $failed = $true
}

if ($manager -notmatch 'LOCALAPPDATA') {
    Write-Host 'Manager recent-project state is not redirected to LocalAppData.' -ForegroundColor Yellow
}

if ($downloader -notmatch 'If-Range' -or $downloader -notmatch 'Content-Range') {
    Write-Host 'Downloader resume validator safeguards (If-Range / Content-Range) are missing.' -ForegroundColor Red
    $failed = $true
}

if ($downloader -notmatch 'Compact-Checkpoint') {
    Write-Host 'Downloader checkpoint compaction is missing.' -ForegroundColor Red
    $failed = $true
}

$hasIncrementalDownloader = $downloader.Contains('$InventoryCsv') -or $downloader.Contains('incrementalMode') -or $downloader.Contains('INCREMENTAL_PASS_COMPLETE')
if ($hasIncrementalDownloader -or -not $downloader.Contains('Compact-Checkpoint -Path $checkpointPath')) {
    Write-Host 'Downloader must process the complete inventory once and compact its checkpoint after each pass.' -ForegroundColor Red
    $failed = $true
}

if ($supervisor -notmatch 'completion\.json' -or $supervisor -notmatch 'Remove-CompletedCaches') {
    Write-Host 'Supervisor completion marker / cache cleanup wiring is missing.' -ForegroundColor Red
    $failed = $true
}

if ($manager -notmatch 'AutoCleanupCache') {
    Write-Host 'Manager does not persist AutoCleanupCache.' -ForegroundColor Red
    $failed = $true
}

$launcherMain=Join-Path $repo 'Launcher\main.go'
$buildScript=Join-Path $repo 'build\build-exe.ps1'
$iconGenerator=Join-Path $repo 'build\make-icon.go'
$winresConfig=Join-Path $repo 'Launcher\winres\winres.json'
if (-not (Test-Path -LiteralPath $launcherMain) -or -not (Test-Path -LiteralPath $buildScript) -or -not (Test-Path -LiteralPath $iconGenerator) -or -not (Test-Path -LiteralPath $winresConfig)) {
    Write-Host 'Native EXE launcher/build sources are missing.' -ForegroundColor Red
    $failed = $true
}
else {
    $launcherRaw=Get-Content -LiteralPath $launcherMain -Raw -Encoding UTF8
    $buildRaw=Get-Content -LiteralPath $buildScript -Raw -Encoding UTF8
    $winresRaw=Get-Content -LiteralPath $winresConfig -Raw -Encoding UTF8
    if ($launcherRaw -notmatch 'payload/ChatAttachmentManager\.png' -or $manager -notmatch 'ChatAttachmentManager\.png') {
        Write-Host 'Application icon is not embedded in the launcher and loaded by the GUI.' -ForegroundColor Red
        $failed = $true
    }
    if ($buildRaw -notmatch 'go-winres@v0\.3\.3' -or $winresRaw -notmatch 'RT_GROUP_ICON' -or $winresRaw -notmatch 'ProductName' -or $winresRaw -notmatch 'FileDescription') {
        Write-Host 'Pinned Windows icon/version resource build configuration is missing.' -ForegroundColor Red
        $failed = $true
    }
    if ($manager -notmatch 'Set-ModernTheme') {
        Write-Host 'Manager does not apply the modern visual theme.' -ForegroundColor Red
        $failed = $true
    }
}

if ($failed) { exit 1 }
Write-Host 'Static checks passed.' -ForegroundColor Green
