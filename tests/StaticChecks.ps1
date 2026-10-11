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
if (-not (Test-Path -LiteralPath $launcherMain) -or -not (Test-Path -LiteralPath $buildScript)) {
    Write-Host 'Native EXE launcher/build sources are missing.' -ForegroundColor Red
    $failed = $true
}

if ($failed) { exit 1 }
Write-Host 'Static checks passed.' -ForegroundColor Green
