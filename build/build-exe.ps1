$ErrorActionPreference='Stop'
$RepoRoot=Split-Path -Parent $PSScriptRoot
$Launcher=Join-Path $RepoRoot 'Launcher'
$Payload=Join-Path $Launcher 'payload'
$PayloadEngine=Join-Path $Payload 'Engine'
$Dist=Join-Path $RepoRoot 'dist'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go 1.22+ is required to build the launcher. GitHub Actions installs it automatically.'
}

Remove-Item -LiteralPath $Payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $PayloadEngine -Force | Out-Null
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $RepoRoot 'Manager.ps1') -Destination (Join-Path $Payload 'Manager.ps1') -Force
foreach ($name in @('Scanner.ps1','Downloader.ps1','Supervisor.ps1')) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot ('Engine\'+$name)) -Destination (Join-Path $PayloadEngine $name) -Force
}

Push-Location $Launcher
try {
    $oldCgo=$env:CGO_ENABLED; $oldGoos=$env:GOOS; $oldGoarch=$env:GOARCH
    $env:CGO_ENABLED='0'; $env:GOOS='windows'; $env:GOARCH='amd64'
    & go build -trimpath -ldflags '-s -w -H=windowsgui' -o (Join-Path $Dist 'ChatAttachmentManager.exe') .
    if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }
}
finally {
    $env:CGO_ENABLED=$oldCgo; $env:GOOS=$oldGoos; $env:GOARCH=$oldGoarch
    Pop-Location
}

$exePath=Join-Path $Dist 'ChatAttachmentManager.exe'
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash.ToLowerInvariant()
("{0}  ChatAttachmentManager.exe" -f $hash) | Set-Content -LiteralPath (Join-Path $Dist 'SHA256SUMS.txt') -Encoding ASCII
Write-Host ("Built: " + $exePath) -ForegroundColor Green
Write-Host ("SHA256: " + $hash) -ForegroundColor Green
