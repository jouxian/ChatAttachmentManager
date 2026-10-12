$ErrorActionPreference='Stop'
$RepoRoot=Split-Path -Parent $PSScriptRoot
$Launcher=Join-Path $RepoRoot 'Launcher'
$Payload=Join-Path $Launcher 'payload'
$PayloadEngine=Join-Path $Payload 'Engine'
$Dist=Join-Path $RepoRoot 'dist'
$Icon=Join-Path $Launcher 'winres\ChatAttachmentManager.png'

if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw 'Go 1.22+ is required to build the launcher. GitHub Actions installs it automatically.'
}

Push-Location $Launcher
try {
    & go run (Join-Path $RepoRoot 'build\make-icon.go') -out $Icon
    if ($LASTEXITCODE -ne 0) { throw "Icon generation failed with exit code $LASTEXITCODE" }
}
finally { Pop-Location }

Remove-Item -LiteralPath $Payload -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $PayloadEngine -Force | Out-Null
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $RepoRoot 'Manager.ps1') -Destination (Join-Path $Payload 'Manager.ps1') -Force
foreach ($name in @('Scanner.ps1','Downloader.ps1','Supervisor.ps1')) {
    Copy-Item -LiteralPath (Join-Path $RepoRoot ('Engine\'+$name)) -Destination (Join-Path $PayloadEngine $name) -Force
}
Copy-Item -LiteralPath $Icon -Destination (Join-Path $Payload 'ChatAttachmentManager.png') -Force

$goBin=& go env GOBIN
if ([string]::IsNullOrWhiteSpace([string]$goBin)) { $goBin=Join-Path (& go env GOPATH) 'bin' }
$winresExe=Join-Path ([string]$goBin) 'go-winres.exe'
if (-not (Test-Path -LiteralPath $winresExe)) {
    & go install github.com/tc-hib/go-winres@v0.3.3
    if ($LASTEXITCODE -ne 0) { throw "go-winres installation failed with exit code $LASTEXITCODE" }
}
if (-not (Test-Path -LiteralPath $winresExe)) { throw 'Pinned go-winres executable was not found after installation.' }

Push-Location $Launcher
try {
    $oldCgo=$env:CGO_ENABLED; $oldGoos=$env:GOOS; $oldGoarch=$env:GOARCH
    & $winresExe make
    if ($LASTEXITCODE -ne 0) { throw "Windows resource generation failed with exit code $LASTEXITCODE" }
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
