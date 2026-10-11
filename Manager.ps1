$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# Self-elevate before doing anything that touches Task Scheduler.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "{0}"' -f $PSCommandPath)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show('Administrator privileges are required to manage automatic startup.','Administrator') | Out-Null
    }
    exit
}

$TaskName = 'Chat Attachment Manager SAFE'
$EngineSource = Join-Path $PSScriptRoot 'Engine'
$UserStateRoot = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { Join-Path $env:LOCALAPPDATA 'ChatAttachmentManager' } else { $PSScriptRoot }
try { New-Item -ItemType Directory -Path $UserStateRoot -Force | Out-Null } catch { $UserStateRoot = $PSScriptRoot }
$RecentPath = Join-Path $UserStateRoot 'manager_recent.json'
$script:ProjectRoot = ''
$script:Project = $null

function Show-Info([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show($Message,'Chat Attachment Manager',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
function Show-Warning([string]$Message) {
    [System.Windows.Forms.MessageBox]::Show($Message,'Chat Attachment Manager',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}
function Ask-YesNo([string]$Message) {
    return ([System.Windows.Forms.MessageBox]::Show($Message,'Chat Attachment Manager',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question) -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Write-JsonAtomic([string]$Path,$Object) {
    $tmp = $Path + '.tmp'
    $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Select-Folder([string]$Description) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return ''
}

function Ensure-ProjectEngine {
    if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) { throw 'No project is selected.' }
    $dest = Join-Path $script:ProjectRoot 'Engine'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($name in @('Scanner.ps1','Downloader.ps1','Supervisor.ps1')) {
        $src = Join-Path $EngineSource $name
        if (-not (Test-Path -LiteralPath $src)) { throw "Engine file not found: $name" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $dest $name) -Force
    }
}

function Save-RecentProject {
    if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) { return }
    try { Write-JsonAtomic -Path $RecentPath -Object ([ordered]@{ ProjectRoot=$script:ProjectRoot }) } catch { }
}

function Set-StorageModeUi([string]$Mode) {
    if ($Mode -notin @('ChatFolders','FlatChatPrefix')) { $Mode='ChatFolders' }

    if ($null -ne $script:FolderModeRadio -and $null -ne $script:FlatModeRadio) {
        if ($Mode -eq 'FlatChatPrefix') { $script:FlatModeRadio.Checked=$true }
        else { $script:FolderModeRadio.Checked=$true }
    }
}

function Get-SelectedStorageMode {
    if ($null -ne $script:FlatModeRadio -and [bool]$script:FlatModeRadio.Checked) {
        return 'FlatChatPrefix'
    }
    return 'ChatFolders'
}

function Load-ProjectFromRoot([string]$Root) {
    $p = Join-Path $Root 'project.json'
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    $obj = Read-JsonSafe $p
    if ($null -eq $obj) { return $false }
    $script:ProjectRoot = $Root
    $script:Project = $obj

    $mode=[string]$obj.StorageMode
    if ($mode -notin @('ChatFolders','FlatChatPrefix')) { $mode='ChatFolders' }
    Set-StorageModeUi $mode
    if ($null -ne $script:SubfolderCheck) { $script:SubfolderCheck.Checked = [bool]$obj.ScanSubfolders }
    if ($null -ne $script:CleanupCheck) {
        if ($null -ne $obj.PSObject.Properties['AutoCleanupCache']) { $script:CleanupCheck.Checked = [bool]$obj.AutoCleanupCache }
        else { $script:CleanupCheck.Checked = $true }
    }

    Save-RecentProject
    return $true
}

function Create-NewProject {
    $source = Select-Folder 'Select the folder containing the chat/export source files. TXT, JSON, CSV, LOG, HTML, XML, MD, and extensionless text files are supported.'
    if ([string]::IsNullOrWhiteSpace($source)) { return }

    $output = Select-Folder 'Select the output folder. Downloaded files and resume state will be stored here.'
    if ([string]::IsNullOrWhiteSpace($output)) { return }

    if ($output.TrimEnd('\') -eq $source.TrimEnd('\')) {
        if (-not (Ask-YesNo 'The source and output folders are the same. Separate folders are recommended. Continue anyway?')) { return }
    }

    $defaultName = Split-Path -Leaf $output
    if ([string]::IsNullOrWhiteSpace($defaultName)) { $defaultName = 'AttachmentProject' }
    $name = [Microsoft.VisualBasic.Interaction]::InputBox('Enter a simple project name:','Project Name',$defaultName)
    if ([string]::IsNullOrWhiteSpace($name)) { return }

    $root = Join-Path $output '_chat_attachment_manager'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $projectJson = Join-Path $root 'project.json'

    if (Test-Path -LiteralPath $projectJson) {
        if (-not (Ask-YesNo 'A project already exists in this output folder. Open the existing project?')) { return }
        if (Load-ProjectFromRoot $root) { Refresh-All; return }
    }

    $obj = [ordered]@{
        Version = 3
        ProjectName = $name
        SourceFolder = $source
        OutputFolder = $output
        ScanSubfolders = [bool]$script:SubfolderCheck.Checked
        StorageMode = Get-SelectedStorageMode
        RequestDelayMs = 50
        AutoCleanupCache = [bool]$script:CleanupCheck.Checked
        CreatedAt = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    Write-JsonAtomic -Path $projectJson -Object $obj
    $script:ProjectRoot = $root
    $script:Project = (Read-JsonSafe $projectJson)
    Ensure-ProjectEngine
    Save-RecentProject
    Refresh-All
    Show-Info "Project created.`r`n`r`nThe scan has not started yet. When you click Start / Continue, a short preflight test will run on up to 3 detected text files."
}

function Open-ExistingProject {
    $output = Select-Folder 'Select the Output folder of the existing project.'
    if ([string]::IsNullOrWhiteSpace($output)) { return }
    $root = Join-Path $output '_chat_attachment_manager'
    if (-not (Load-ProjectFromRoot $root)) {
        Show-Warning 'No project was found in this folder. _chat_attachment_manager\project.json must exist.'
        return
    }
    Ensure-ProjectEngine
    Refresh-All
}

function Register-And-StartTask {
    if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) { Show-Warning 'Create a new project or open an existing project first.'; return }
    Ensure-ProjectEngine

    # Save current project options.
    # Once download/storage state exists, changing storage mode is blocked so one
    # project cannot accidentally mix two output layouts.
    $projectPath = Join-Path $script:ProjectRoot 'project.json'
    $pobj = Read-JsonSafe $projectPath
    if ($null -ne $pobj) {
        $selectedMode=Get-SelectedStorageMode
        $savedMode=[string]$pobj.StorageMode
        if ($savedMode -notin @('ChatFolders','FlatChatPrefix')) { $savedMode='ChatFolders' }

        $hasStorageState=$false
        foreach ($stateName in @('download_state.jsonl','storage_map.jsonl')) {
            $statePath=Join-Path $script:ProjectRoot $stateName
            if (Test-Path -LiteralPath $statePath) {
                try {
                    if ((Get-Item -LiteralPath $statePath).Length -gt 0) {
                        $hasStorageState=$true
                        break
                    }
                }
                catch { }
            }
        }

        if ($hasStorageState -and $selectedMode -ne $savedMode) {
            Set-StorageModeUi $savedMode
            Show-Warning "This project has already started downloading with a specific storage mode.`r`n`r`nTo prevent mixed file layouts, the storage mode cannot be changed during a project.`r`nCreate a new project with a new Output folder to use another mode."
            return
        }

        $newObj = [ordered]@{
            Version=3
            ProjectName=[string]$pobj.ProjectName
            SourceFolder=[string]$pobj.SourceFolder
            OutputFolder=[string]$pobj.OutputFolder
            ScanSubfolders=[bool]$script:SubfolderCheck.Checked
            StorageMode=$selectedMode
            RequestDelayMs=$(if($null -ne $pobj.PSObject.Properties['RequestDelayMs']){[int]$pobj.RequestDelayMs}else{50})
            AutoCleanupCache=[bool]$script:CleanupCheck.Checked
            CreatedAt=[string]$pobj.CreatedAt
        }
        Write-JsonAtomic -Path $projectPath -Object $newObj
        $script:Project = Read-JsonSafe $projectPath
    }

    # Pressing Start / Continue is an explicit request to run again.
    # A completion marker prevents an already-finished project from re-running only on automatic Windows startup.
    Remove-Item -LiteralPath (Join-Path $script:ProjectRoot 'completion.json') -Force -ErrorAction SilentlyContinue

    try {
        $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }

        $supervisor = Join-Path $script:ProjectRoot 'Engine\Supervisor.ps1'
        $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -ProjectRoot "{1}"' -f $supervisor,$script:ProjectRoot
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Milliseconds 700
        Refresh-All
    }
    catch {
        Show-Warning ("Task Scheduler error:`r`n`r`n" + ($_ | Out-String))
    }
}

function Stop-ProjectProcesses {
    if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) { return }
    try {
        $escaped = $script:ProjectRoot
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            ($_.Name -ieq 'powershell.exe' -or $_.Name -ieq 'pwsh.exe') -and
            (-not [string]::IsNullOrWhiteSpace([string]$_.CommandLine)) -and
            ([string]$_.CommandLine).IndexOf($escaped,[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            $_.ProcessId -ne $PID
        } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

function Pause-Project {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
        }
        Stop-ProjectProcesses
        Start-Sleep -Milliseconds 400
        Refresh-All
    }
    catch { Show-Warning ($_ | Out-String) }
}

function Remove-AutoStart {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $task) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        Stop-ProjectProcesses
        Refresh-All
    }
    catch { Show-Warning ($_ | Out-String) }
}

function Get-TaskText {
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) { return 'Auto-Start: Not installed' }
        return ('Auto-Start: {0} | Task: {1}' -f $(if([string]$task.State -eq 'Disabled'){'Disabled'}else{'Enabled'}),[string]$task.State)
    }
    catch { return 'Auto-Start: Unknown' }
}

function Open-PathSafe([string]$Path) {
    if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) { Start-Process explorer.exe -ArgumentList ('"' + $Path + '"') }
}

function Open-ErrorLog {
    if ([string]::IsNullOrWhiteSpace($script:ProjectRoot)) { return }
    $candidates = @('engine_syntax_error.log','preflight_scanner_last_error.log','preflight_downloader_last_error.log','scanner_fatal.log','scanner_last_error.log','downloader_fatal.log','downloader_last_error.log','supervisor_fatal.log')
    foreach ($n in $candidates) {
        $p = Join-Path $script:ProjectRoot $n
        if (Test-Path -LiteralPath $p) { Start-Process notepad.exe -ArgumentList ('"' + $p + '"'); return }
    }
    Show-Info 'No technical error log has been recorded yet.'
}

function Get-TailText([string]$Path,[int]$Count=18) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { return (@(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Count) -join "`r`n") } catch { return '' }
}

function Refresh-All {
    try {
        if ([string]::IsNullOrWhiteSpace($script:ProjectRoot) -or $null -eq $script:Project) {
            $script:ProjectNameLabel.Text = 'Project: None selected'
            $script:SourceLabel.Text = 'Source folder: —'
            $script:OutputLabel.Text = 'Output folder: —'
            $script:TaskLabel.Text = Get-TaskText
            return
        }

        # Reload project in case it was edited by a newer copy.
        $script:Project = Read-JsonSafe (Join-Path $script:ProjectRoot 'project.json')
        $script:ProjectNameLabel.Text = 'Project: ' + [string]$script:Project.ProjectName
        $script:SourceLabel.Text = 'Source folder: ' + [string]$script:Project.SourceFolder
        $script:OutputLabel.Text = 'Output folder: ' + [string]$script:Project.OutputFolder
        $script:TaskLabel.Text = Get-TaskText

        $savedMode=[string]$script:Project.StorageMode
        if ($savedMode -notin @('ChatFolders','FlatChatPrefix')) { $savedMode='ChatFolders' }
        if ($null -ne $script:StorageModeInfoLabel) {
            if ($savedMode -eq 'FlatChatPrefix') {
                $script:StorageModeInfoLabel.Text='Current storage mode: all files in one folder with chat ID in the filename'
            }
            else {
                $script:StorageModeInfoLabel.Text='Current storage mode: folders only for chats with downloaded files'
            }
        }

        $sup = Read-JsonSafe (Join-Path $script:ProjectRoot 'supervisor_status.json')
        $scan = Read-JsonSafe (Join-Path $script:ProjectRoot 'scan_status.json')
        if ($null -eq $scan) { $scan = Read-JsonSafe (Join-Path $script:ProjectRoot 'preflight_status.json') }
        $down = Read-JsonSafe (Join-Path $script:ProjectRoot 'download_status.json')

        if ($null -ne $sup) {
            $script:MainStateLabel.Text = 'Status: ' + [string]$sup.Message
        }
        else { $script:MainStateLabel.Text = 'Status: Ready to start' }

        if ($null -ne $scan) {
            $script:ScanStateValue.Text = [string]$scan.State
            $script:ScanTxtValue.Text = ('{0} / {1}' -f [int]$scan.TxtCompleted,[int]$scan.TxtTotal)
            if ([long]$scan.ChatsExpected -gt 0) { $script:ScanChatsValue.Text = ('{0:N0} / {1:N0}' -f [long]$scan.ChatsDone,[long]$scan.ChatsExpected) }
            else { $script:ScanChatsValue.Text = ('{0:N0}' -f [long]$scan.ChatsDone) }
            $script:ScanAttachValue.Text = ('{0:N0}' -f [long]$scan.AttachmentsFound)
            $script:ScanErrorValue.Text = [string]$scan.TxtErrors
            if ($null -ne $script:ScanUrlValue) { $script:ScanUrlValue.Text = ('{0:N0}' -f [long]$scan.UrlsFound) }
            $script:ScanCurrentValue.Text = [string]$scan.CurrentTxt
            $v = [int][Math]::Max(0,[Math]::Min(100,[double]$scan.Percent))
            $script:ScanBar.Value = $v
            $script:ScanPercent.Text = "$v%"
        }
        else {
            $script:ScanStateValue.Text='—'; $script:ScanTxtValue.Text='0 / 0'; $script:ScanChatsValue.Text='0'; $script:ScanAttachValue.Text='0'; $script:ScanErrorValue.Text='0'; if ($null -ne $script:ScanUrlValue) { $script:ScanUrlValue.Text='0' }; $script:ScanCurrentValue.Text='—'; $script:ScanBar.Value=0; $script:ScanPercent.Text='0%'
        }

        if ($null -ne $down) {
            $script:DownStateValue.Text = [string]$down.State
            $script:DownTotalValue.Text = ('{0:N0}' -f [int]$down.Total)
            $script:DownDoneValue.Text = ('{0:N0}' -f [int]$down.Downloaded)
            $script:DownPermanentValue.Text = ('{0:N0}' -f [int]$down.PermanentFailures)
            $script:DownTransientValue.Text = ('{0:N0}' -f [int]$down.TransientFailures)
            $script:DownPendingValue.Text = ('{0:N0}' -f [int]$down.Pending)
            if ($null -ne $script:DownSkippedValue) { $script:DownSkippedValue.Text = ('{0:N0}' -f [int]$down.SkippedNonFiles) }
            $script:DownCurrentValue.Text = [string]$down.CurrentFile
            $v2 = [int][Math]::Max(0,[Math]::Min(100,[double]$down.Percent))
            $script:DownBar.Value = $v2
            $script:DownPercent.Text = "$v2%"
        }
        else {
            $script:DownStateValue.Text='—'; $script:DownTotalValue.Text='0'; $script:DownDoneValue.Text='0'; $script:DownPermanentValue.Text='0'; $script:DownTransientValue.Text='0'; $script:DownPendingValue.Text='0'; if ($null -ne $script:DownSkippedValue) { $script:DownSkippedValue.Text='0' }; $script:DownCurrentValue.Text='—'; $script:DownBar.Value=0; $script:DownPercent.Text='0%'
        }

        $script:LogBox.Text = Get-TailText (Join-Path $script:ProjectRoot 'auto_activity.log') 20
    }
    catch {
        $script:MainStateLabel.Text = 'Status: GUI refresh failed'
    }
}

# ---------------- GUI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Chat Attachment Manager UNIVERSAL 1.4.2 GITHUB'
$form.Size = New-Object System.Drawing.Size(1050,980)
$form.MinimumSize = New-Object System.Drawing.Size(1000,920)
$form.StartPosition = 'CenterScreen'
$form.RightToLeft = [System.Windows.Forms.RightToLeft]::No
$form.RightToLeftLayout = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Chat Attachment Manager — UNIVERSAL 1.4.2 GITHUB'
$title.Font = New-Object System.Drawing.Font('Segoe UI',16,[System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(30,20)
$form.Controls.Add($title)

$script:MainStateLabel = New-Object System.Windows.Forms.Label
$script:MainStateLabel.Text='Status: Ready to start'
$script:MainStateLabel.Location=New-Object System.Drawing.Point(30,55)
$script:MainStateLabel.Size=New-Object System.Drawing.Size(970,42)
$script:MainStateLabel.Font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($script:MainStateLabel)

$projectBox = New-Object System.Windows.Forms.GroupBox
$projectBox.Text='Project'
$projectBox.Location=New-Object System.Drawing.Point(20,100)
$projectBox.Size=New-Object System.Drawing.Size(995,215)
$projectBox.Anchor='Top,Left,Right'
$form.Controls.Add($projectBox)

$script:ProjectNameLabel=New-Object System.Windows.Forms.Label; $script:ProjectNameLabel.Text='Project: None selected'; $script:ProjectNameLabel.Location=New-Object System.Drawing.Point(25,28); $script:ProjectNameLabel.Size=New-Object System.Drawing.Size(940,24); $projectBox.Controls.Add($script:ProjectNameLabel)
$script:SourceLabel=New-Object System.Windows.Forms.Label; $script:SourceLabel.Text='Source folder: —'; $script:SourceLabel.Location=New-Object System.Drawing.Point(25,55); $script:SourceLabel.Size=New-Object System.Drawing.Size(940,24); $script:SourceLabel.RightToLeft='No'; $script:SourceLabel.TextAlign='MiddleLeft'; $projectBox.Controls.Add($script:SourceLabel)
$script:OutputLabel=New-Object System.Windows.Forms.Label; $script:OutputLabel.Text='Output folder: —'; $script:OutputLabel.Location=New-Object System.Drawing.Point(25,82); $script:OutputLabel.Size=New-Object System.Drawing.Size(940,24); $script:OutputLabel.RightToLeft='No'; $script:OutputLabel.TextAlign='MiddleLeft'; $projectBox.Controls.Add($script:OutputLabel)
$script:TaskLabel=New-Object System.Windows.Forms.Label; $script:TaskLabel.Text='Auto-Start: —'; $script:TaskLabel.Location=New-Object System.Drawing.Point(25,110); $script:TaskLabel.Size=New-Object System.Drawing.Size(450,24); $projectBox.Controls.Add($script:TaskLabel)
$script:SubfolderCheck=New-Object System.Windows.Forms.CheckBox; $script:SubfolderCheck.Text='Scan source subfolders too'; $script:SubfolderCheck.Checked=$false; $script:SubfolderCheck.Location=New-Object System.Drawing.Point(690,108); $script:SubfolderCheck.Size=New-Object System.Drawing.Size(275,28); $projectBox.Controls.Add($script:SubfolderCheck)
$script:CleanupCheck=New-Object System.Windows.Forms.CheckBox; $script:CleanupCheck.Text='Clean cache after successful completion'; $script:CleanupCheck.Checked=$true; $script:CleanupCheck.Location=New-Object System.Drawing.Point(675,188); $script:CleanupCheck.Size=New-Object System.Drawing.Size(290,24); $projectBox.Controls.Add($script:CleanupCheck)

$storageModeLabel=New-Object System.Windows.Forms.Label
$storageModeLabel.Text='Downloaded-file storage mode:'
$storageModeLabel.Location=New-Object System.Drawing.Point(25,142)
$storageModeLabel.Size=New-Object System.Drawing.Size(210,24)
$storageModeLabel.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$projectBox.Controls.Add($storageModeLabel)

$script:FolderModeRadio=New-Object System.Windows.Forms.RadioButton
$script:FolderModeRadio.Text='Create folders only for chats with downloaded files (recommended)'
$script:FolderModeRadio.Location=New-Object System.Drawing.Point(235,138)
$script:FolderModeRadio.Size=New-Object System.Drawing.Size(430,30)
$script:FolderModeRadio.Checked=$true
$projectBox.Controls.Add($script:FolderModeRadio)

$script:FlatModeRadio=New-Object System.Windows.Forms.RadioButton
$script:FlatModeRadio.Text='Store all files in one folder with chat ID and file number'
$script:FlatModeRadio.Location=New-Object System.Drawing.Point(235,168)
$script:FlatModeRadio.Size=New-Object System.Drawing.Size(430,30)
$projectBox.Controls.Add($script:FlatModeRadio)

$script:StorageModeInfoLabel=New-Object System.Windows.Forms.Label
$script:StorageModeInfoLabel.Text='For a new project, select one of the storage modes above.'
$script:StorageModeInfoLabel.Location=New-Object System.Drawing.Point(675,145)
$script:StorageModeInfoLabel.Size=New-Object System.Drawing.Size(290,48)
$projectBox.Controls.Add($script:StorageModeInfoLabel)


$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Location=New-Object System.Drawing.Point(20,325); $buttons.Size=New-Object System.Drawing.Size(995,92); $buttons.Anchor='Top,Left,Right'; $buttons.RightToLeft='No'; $buttons.WrapContents=$true; $form.Controls.Add($buttons)
function Add-Button([string]$Text,[int]$Width=150) { $b=New-Object System.Windows.Forms.Button; $b.Text=$Text; $b.Size=New-Object System.Drawing.Size($Width,38); $b.Margin=New-Object System.Windows.Forms.Padding(5); $buttons.Controls.Add($b); return $b }
$newBtn=Add-Button 'New Project' 145
$openBtn=Add-Button 'Open Existing Project' 175
$startBtn=Add-Button 'Start / Continue' 145
$pauseBtn=Add-Button 'Pause' 135
$removeBtn=Add-Button 'Remove Auto-Start' 145
$outputBtn=Add-Button 'Output Folder' 135
$errorBtn=Add-Button 'Technical Error' 115
$refreshBtn=Add-Button 'Refresh' 115

$scanBox=New-Object System.Windows.Forms.GroupBox; $scanBox.Text='Resumable Scan - each source file is checkpointed separately'; $scanBox.Location=New-Object System.Drawing.Point(20,425); $scanBox.Size=New-Object System.Drawing.Size(995,180); $scanBox.Anchor='Top,Left,Right'; $form.Controls.Add($scanBox)
$script:ScanBar=New-Object System.Windows.Forms.ProgressBar; $script:ScanBar.Location=New-Object System.Drawing.Point(40,32); $script:ScanBar.Size=New-Object System.Drawing.Size(860,20); $scanBox.Controls.Add($script:ScanBar)
$script:ScanPercent=New-Object System.Windows.Forms.Label; $script:ScanPercent.Text='0%'; $script:ScanPercent.Location=New-Object System.Drawing.Point(905,31); $script:ScanPercent.Size=New-Object System.Drawing.Size(55,22); $scanBox.Controls.Add($script:ScanPercent)

function Add-Pair($parent,[string]$label,[int]$x,[int]$y,[int]$w=100) { $l=New-Object System.Windows.Forms.Label; $l.Text=$label; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size(150,24); $parent.Controls.Add($l); $v=New-Object System.Windows.Forms.Label; $v.Text='0'; $v.Font=New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold); $v.Location=New-Object System.Drawing.Point(($x+150),$y); $v.Size=New-Object System.Drawing.Size($w,24); $parent.Controls.Add($v); return $v }
$script:ScanStateValue=Add-Pair $scanBox 'Stage:' 40 65 100
$script:ScanTxtValue=Add-Pair $scanBox 'Source files:' 350 65 100
$script:ScanChatsValue=Add-Pair $scanBox 'Records / chats:' 650 65 140
$script:ScanAttachValue=Add-Pair $scanBox 'Attachments found:' 40 98 100
$script:ScanErrorValue=Add-Pair $scanBox 'Source errors:' 350 98 100
$script:ScanUrlValue=Add-Pair $scanBox 'URLs found:' 650 98 140
$currentLbl=New-Object System.Windows.Forms.Label; $currentLbl.Text='Current file:'; $currentLbl.Location=New-Object System.Drawing.Point(40,135); $currentLbl.Size=New-Object System.Drawing.Size(115,24); $scanBox.Controls.Add($currentLbl)
$script:ScanCurrentValue=New-Object System.Windows.Forms.Label; $script:ScanCurrentValue.Text='—'; $script:ScanCurrentValue.Location=New-Object System.Drawing.Point(155,135); $script:ScanCurrentValue.Size=New-Object System.Drawing.Size(805,24); $script:ScanCurrentValue.AutoEllipsis=$true; $script:ScanCurrentValue.RightToLeft='No'; $script:ScanCurrentValue.TextAlign='MiddleLeft'; $scanBox.Controls.Add($script:ScanCurrentValue)

$downBox=New-Object System.Windows.Forms.GroupBox; $downBox.Text='Download - each URL is classified using the real HTTP response'; $downBox.Location=New-Object System.Drawing.Point(20,615); $downBox.Size=New-Object System.Drawing.Size(995,180); $downBox.Anchor='Top,Left,Right'; $form.Controls.Add($downBox)
$script:DownBar=New-Object System.Windows.Forms.ProgressBar; $script:DownBar.Location=New-Object System.Drawing.Point(40,32); $script:DownBar.Size=New-Object System.Drawing.Size(860,20); $downBox.Controls.Add($script:DownBar)
$script:DownPercent=New-Object System.Windows.Forms.Label; $script:DownPercent.Text='0%'; $script:DownPercent.Location=New-Object System.Drawing.Point(905,31); $script:DownPercent.Size=New-Object System.Drawing.Size(55,22); $downBox.Controls.Add($script:DownPercent)
$script:DownStateValue=Add-Pair $downBox 'Stage:' 40 65 100
$script:DownTotalValue=Add-Pair $downBox 'Total URLs:' 330 65 90
$script:DownDoneValue=Add-Pair $downBox 'Downloaded:' 600 65 90
$script:DownPermanentValue=Add-Pair $downBox 'Permanent failures:' 40 98 80
$script:DownTransientValue=Add-Pair $downBox 'Transient failures:' 300 98 80
$script:DownPendingValue=Add-Pair $downBox 'Remaining:' 555 98 70
$script:DownSkippedValue=Add-Pair $downBox 'Skipped non-files:' 780 98 50
$curDownLbl=New-Object System.Windows.Forms.Label; $curDownLbl.Text='Current file:'; $curDownLbl.Location=New-Object System.Drawing.Point(40,135); $curDownLbl.Size=New-Object System.Drawing.Size(115,24); $downBox.Controls.Add($curDownLbl)
$script:DownCurrentValue=New-Object System.Windows.Forms.Label; $script:DownCurrentValue.Text='—'; $script:DownCurrentValue.Location=New-Object System.Drawing.Point(155,135); $script:DownCurrentValue.Size=New-Object System.Drawing.Size(805,24); $script:DownCurrentValue.AutoEllipsis=$true; $script:DownCurrentValue.RightToLeft='No'; $script:DownCurrentValue.TextAlign='MiddleLeft'; $downBox.Controls.Add($script:DownCurrentValue)

$logBoxGroup=New-Object System.Windows.Forms.GroupBox; $logBoxGroup.Text='Latest Report'; $logBoxGroup.Location=New-Object System.Drawing.Point(20,805); $logBoxGroup.Size=New-Object System.Drawing.Size(995,110); $logBoxGroup.Anchor='Top,Bottom,Left,Right'; $form.Controls.Add($logBoxGroup)
$script:LogBox=New-Object System.Windows.Forms.TextBox; $script:LogBox.Multiline=$true; $script:LogBox.ReadOnly=$true; $script:LogBox.ScrollBars='Vertical'; $script:LogBox.Location=New-Object System.Drawing.Point(20,25); $script:LogBox.Size=New-Object System.Drawing.Size(950,72); $script:LogBox.Anchor='Top,Bottom,Left,Right'; $script:LogBox.RightToLeft='No'; $script:LogBox.Font=New-Object System.Drawing.Font('Consolas',9); $logBoxGroup.Controls.Add($script:LogBox)

$newBtn.Add_Click({ try { Create-NewProject } catch { Show-Warning ($_ | Out-String) } })
$openBtn.Add_Click({ try { Open-ExistingProject } catch { Show-Warning ($_ | Out-String) } })
$startBtn.Add_Click({ Register-And-StartTask })
$pauseBtn.Add_Click({ Pause-Project })
$removeBtn.Add_Click({ Remove-AutoStart })
$outputBtn.Add_Click({ if ($null -ne $script:Project) { Open-PathSafe ([string]$script:Project.OutputFolder) } })
$errorBtn.Add_Click({ Open-ErrorLog })
$refreshBtn.Add_Click({ Refresh-All })

# Try to reopen the most recent project, but never require it.
$recent = Read-JsonSafe $RecentPath
if ($null -ne $recent -and -not [string]::IsNullOrWhiteSpace([string]$recent.ProjectRoot)) {
    [void](Load-ProjectFromRoot ([string]$recent.ProjectRoot))
}
Refresh-All

$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=2000
$timer.Add_Tick({ Refresh-All })
$timer.Start()

[void]$form.ShowDialog()
