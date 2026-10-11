param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$EngineVersion = 'UNIVERSAL-1.4.1-GITHUB'
$NetworkRetrySeconds = 60
$CrashRetrySeconds = 30
$MaxRetrySeconds = 900

function Write-JsonAtomic {
    param([string]$Path, $Object)
    $dir=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

$logPath = Join-Path $ProjectRoot 'auto_activity.log'
$statusPath = Join-Path $ProjectRoot 'supervisor_status.json'
$lockPath = Join-Path $ProjectRoot '.supervisor.lock'
$completionPath = Join-Path $ProjectRoot 'completion.json'

function Write-Log {
    param([string]$Message, [string]$State='INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ("[{0}] {1}" -f $stamp,$Message)
    try {
        Write-JsonAtomic -Path $statusPath -Object ([ordered]@{
            EngineVersion=$EngineVersion; State=$State; UpdatedAt=$stamp; Message=$Message
        })
    }
    catch { }
}

function Test-ScriptSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        $msg = ($errors | ForEach-Object { $_.Message + ' @ ' + $_.Extent.StartLineNumber }) -join "`r`n"
        return [pscustomobject]@{ Ok=$false; Error=$msg }
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $reservedMatches = [regex]::Matches($raw, '(?im)(?<![A-Za-z0-9_])\$(Host|PID)\s*=')
    if ($reservedMatches.Count -gt 0) {
        $bad = @($reservedMatches | ForEach-Object { $_.Value.Trim() }) -join ', '
        return [pscustomobject]@{
            Ok=$false
            Error=('Assignment to PowerShell reserved read-only automatic variable detected: ' + $bad)
        }
    }
    return [pscustomobject]@{ Ok=$true; Error='' }
}

function Run-Child {
    param(
        [string]$ScriptPath,
        [string[]]$ExtraArgs,
        [string]$Name
    )
    $outPath = Join-Path $ProjectRoot ($Name + '_last_output.log')
    $errPath = Join-Path $ProjectRoot ($Name + '_last_error.log')
    Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue

    $argParts = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $ScriptPath + '"'))
    foreach ($a in $ExtraArgs) {
        if ($a -match '\s') { $argParts += ('"' + $a.Replace('"','\"') + '"') }
        else { $argParts += $a }
    }
    $argLine = $argParts -join ' '

    try {
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WorkingDirectory $ProjectRoot -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        return [int]$p.ExitCode
    }
    catch {
        ($_ | Out-String) | Set-Content -LiteralPath $errPath -Encoding UTF8
        return 98
    }
}

function Get-AutoCleanupEnabled {
    $cfg=Read-JsonSafe -Path (Join-Path $ProjectRoot 'project.json')
    if ($null -eq $cfg) { return $true }
    try {
        $prop=$cfg.PSObject.Properties['AutoCleanupCache']
        if ($null -ne $prop) { return [bool]$prop.Value }
    }
    catch { }
    return $true
}

function Remove-CompletedCaches {
    if (-not (Get-AutoCleanupEnabled)) {
        Write-Log 'Project completed. AutoCleanupCache is disabled; resumable caches were kept.' 'FINALIZING'
        return
    }

    Write-Log 'Project completed. Removing rebuildable scan/preflight/partial caches; compact resume checkpoints are preserved.' 'FINALIZING'
    foreach ($dirName in @('scan','preflight','partials')) {
        $p=Join-Path $ProjectRoot $dirName
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }

    try {
        Get-ChildItem -LiteralPath $ProjectRoot -File -Filter '*.tmp' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Write-CompletionMarker {
    param([string]$State,$Scan,$Download)
    $old=Read-JsonSafe -Path $completionPath
    $started=''
    if ($null -ne $old -and -not [string]::IsNullOrWhiteSpace([string]$old.FinalizingStartedAt)) { $started=[string]$old.FinalizingStartedAt }
    if ([string]::IsNullOrWhiteSpace($started)) { $started=[DateTime]::Now.ToString('o') }

    Write-JsonAtomic -Path $completionPath -Object ([ordered]@{
        EngineVersion=$EngineVersion
        Status=$State
        FinalizingStartedAt=$started
        CompletedAt=$(if($State -eq 'COMPLETE'){[DateTime]::Now.ToString('o')}else{''})
        ScanFiles=$(if($null -ne $Scan){[int]$Scan.TxtTotal}else{0})
        Urls=$(if($null -ne $Scan){[long]$Scan.UrlsFound}else{0})
        AttachmentsFound=$(if($null -ne $Scan){[long]$Scan.AttachmentsFound}else{0})
        Downloaded=$(if($null -ne $Download){[int]$Download.Downloaded}else{0})
        PermanentFailures=$(if($null -ne $Download){[int]$Download.PermanentFailures}else{0})
        SkippedNonFiles=$(if($null -ne $Download){[int]$Download.SkippedNonFiles}else{0})
        ResumeStatePreserved=$true
    })
}

function Finish-CompletedProject {
    param($Scan,$Download)
    Write-CompletionMarker -State 'FINALIZING' -Scan $Scan -Download $Download
    Remove-CompletedCaches
    Write-CompletionMarker -State 'COMPLETE' -Scan $Scan -Download $Download
    Write-Log 'Project is COMPLETE. Rebuildable cache was cleaned; final reports and compact resume state were preserved. Supervisor is stopping.' 'COMPLETE'
}

function Sleep-WithBackoff {
    param([int]$Seconds,[string]$Reason,[string]$State)
    $s=[Math]::Max(1,[Math]::Min($MaxRetrySeconds,$Seconds))
    Write-Log (("{0} Retrying in {1} seconds." -f $Reason,$s)) $State
    Start-Sleep -Seconds $s
}

$lockStream = $null
try {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) { exit 0 }
    try {
        $lockStream = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
    }
    catch { exit 0 }

    # If the previous run had already finished downloading, never start the whole job again just because Windows rebooted.
    $completion=Read-JsonSafe -Path $completionPath
    if ($null -ne $completion -and [string]$completion.EngineVersion -eq $EngineVersion) {
        if ([string]$completion.Status -eq 'FINALIZING') {
            Write-Log 'Previous shutdown happened during final cleanup. Finishing idempotent cleanup now.' 'FINALIZING'
            Remove-CompletedCaches
            $scan=Read-JsonSafe -Path (Join-Path $ProjectRoot 'scan_status.json')
            $down=Read-JsonSafe -Path (Join-Path $ProjectRoot 'download_status.json')
            Write-CompletionMarker -State 'COMPLETE' -Scan $scan -Download $down
            Write-Log 'Final cleanup completed after restart. Project remains complete.' 'COMPLETE'
            exit 0
        }
        elseif ([string]$completion.Status -eq 'COMPLETE') {
            Write-Log 'Project was already completed before this Windows startup. Nothing to resume.' 'COMPLETE'
            exit 0
        }
    }

    $engineDir = Join-Path $ProjectRoot 'Engine'
    $scanner = Join-Path $engineDir 'Scanner.ps1'
    $downloader = Join-Path $engineDir 'Downloader.ps1'
    if (-not (Test-Path -LiteralPath $scanner) -or -not (Test-Path -LiteralPath $downloader)) {
        Write-Log 'Engine files are missing. Supervisor stopped.' 'ENGINE_MISSING'
        exit 0
    }

    foreach ($script in @($scanner,$downloader)) {
        $syntax = Test-ScriptSyntax -Path $script
        if (-not $syntax.Ok) {
            $syntax.Error | Set-Content -LiteralPath (Join-Path $ProjectRoot 'engine_syntax_error.log') -Encoding UTF8
            Write-Log 'Engine syntax self-check failed. Full scan was NOT started. See engine_syntax_error.log.' 'PREFLIGHT_FAILED'
            exit 0
        }
    }

    Write-Log 'Auto supervisor started. Resume state is enabled for scan, network loss, crash and Windows restart.' 'STARTING'

    $preflightOk = $false
    $preflightPath = Join-Path $ProjectRoot 'preflight_ok.json'
    if (Test-Path -LiteralPath $preflightPath) {
        try {
            $pf = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$pf.EngineVersion -eq $EngineVersion) { $preflightOk = $true }
        }
        catch { }
    }

    if (-not $preflightOk) {
        Write-Log 'Running short Scanner preflight on up to 3 detected text files (max 6000 lines each).' 'PREFLIGHT'
        $code = Run-Child -ScriptPath $scanner -ExtraArgs @('-ProjectRoot',$ProjectRoot,'-Mode','Preflight') -Name 'preflight_scanner'
        if ($code -ne 0) {
            Write-Log ("Scanner preflight failed with code {0}. Full scan was NOT started." -f $code) 'PREFLIGHT_FAILED'
            exit 0
        }

        Write-Log 'Scanner preflight passed. Running Downloader dry self-test with NO network requests.' 'PREFLIGHT'
        $dcode = Run-Child -ScriptPath $downloader -ExtraArgs @('-ProjectRoot',$ProjectRoot,'-SelfTest') -Name 'preflight_downloader'
        if ($dcode -ne 0) {
            Write-Log ("Downloader self-test failed with code {0}. Full scan was NOT started." -f $dcode) 'PREFLIGHT_FAILED'
            exit 0
        }

        Write-JsonAtomic -Path $preflightPath -Object ([ordered]@{
            EngineVersion=$EngineVersion; CompletedAt=[DateTime]::Now.ToString('o')
            ScannerTest='OK'; DownloaderDryTest='OK'; NetworkRequestsMade=0
        })
        Write-Log 'Preflight passed. Starting resumable full scan.' 'PREFLIGHT_OK'
    }

    $scanRetry=$CrashRetrySeconds
    $scanErrorRetry=$CrashRetrySeconds
    while ($true) {
        Write-Log 'Starting/resuming Scanner. Every completed source file is checkpointed separately.' 'SCANNING'
        $scanCode = Run-Child -ScriptPath $scanner -ExtraArgs @('-ProjectRoot',$ProjectRoot,'-Mode','Full') -Name 'scanner'

        if ($scanCode -eq 12) {
            Sleep-WithBackoff -Seconds 60 -Reason 'No readable text files found.' -State 'NO_TEXT_FILES'
            continue
        }
        elseif ($scanCode -ne 0) {
            Sleep-WithBackoff -Seconds $scanRetry -Reason ("Scanner stopped unexpectedly with code {0}; completed source caches are preserved." -f $scanCode) -State 'SCANNER_RETRY'
            $scanRetry=[Math]::Min($MaxRetrySeconds,$scanRetry*2)
            continue
        }
        $scanRetry=$CrashRetrySeconds

        $scanStatus=Read-JsonSafe -Path (Join-Path $ProjectRoot 'scan_status.json')
        $scanHasErrors=($null -eq $scanStatus -or [int]$scanStatus.TxtErrors -gt 0 -or [string]$scanStatus.State -eq 'COMPLETE_WITH_ERRORS')

        # Once the inventory exists, keep retrying Downloader directly. No pointless rescans while the internet is offline.
        $downloadRetry=$NetworkRetrySeconds
        while ($true) {
            Write-Log 'Starting/resuming HTTP-verified Downloader from saved inventory and partial files.' 'DOWNLOADING'
            $downloadCode = Run-Child -ScriptPath $downloader -ExtraArgs @('-ProjectRoot',$ProjectRoot) -Name 'downloader'

            if ($downloadCode -ne 0) {
                Sleep-WithBackoff -Seconds $downloadRetry -Reason ("Downloader stopped unexpectedly with code {0}; checkpoint and .part files are preserved." -f $downloadCode) -State 'DOWNLOADER_RETRY'
                $downloadRetry=[Math]::Min($MaxRetrySeconds,$downloadRetry*2)
                continue
            }

            $downStatus=Read-JsonSafe -Path (Join-Path $ProjectRoot 'download_status.json')
            if ($null -eq $downStatus) {
                Sleep-WithBackoff -Seconds $downloadRetry -Reason 'Downloader exited without a readable status file; resume state is preserved.' -State 'DOWNLOADER_RETRY'
                $downloadRetry=[Math]::Min($MaxRetrySeconds,$downloadRetry*2)
                continue
            }

            $hasTransient=([int]$downStatus.TransientFailures -gt 0 -or [int]$downStatus.Pending -gt 0 -or [string]$downStatus.State -eq 'PASS_COMPLETE_WITH_TRANSIENT')
            if ($hasTransient) {
                Sleep-WithBackoff -Seconds $downloadRetry -Reason ("{0} transient/network items remain. Internet/DNS/TLS/HTTP failures will be retried without rescanning." -f [int]$downStatus.TransientFailures) -State 'WAITING_FOR_NETWORK'
                $downloadRetry=[Math]::Min($MaxRetrySeconds,$downloadRetry*2)
                continue
            }

            break
        }

        if ($scanHasErrors) {
            Sleep-WithBackoff -Seconds $scanErrorRetry -Reason 'Download pass is stable, but one or more source files had scan errors; only unfinished/error sources will be retried.' -State 'SCAN_ERRORS_RETRY'
            $scanErrorRetry=[Math]::Min($MaxRetrySeconds,$scanErrorRetry*2)
            continue
        }
        $scanErrorRetry=$CrashRetrySeconds

        Finish-CompletedProject -Scan $scanStatus -Download $downStatus
        exit 0
    }
}
catch {
    try {
        ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $ProjectRoot 'supervisor_fatal.log') -Encoding UTF8
        Write-Log 'Supervisor fatal error. Task Scheduler can restart it and all checkpoints remain on disk.' 'SUPERVISOR_FATAL'
    }
    catch { }
    exit 1
}
finally {
    try { if ($null -ne $lockStream) { $lockStream.Dispose() } } catch { }
}
