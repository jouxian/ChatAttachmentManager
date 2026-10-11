param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectRoot,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$EngineVersion = 'UNIVERSAL-1.4.1-GITHUB'
$MaxAttemptsPerRun = 2
$ConnectTimeoutMs = 15000
$ReadWriteTimeoutMs = 25000
$NormalDelayMs = 50
$DownloadStatusMinIntervalMs = 1000
$script:LastDownloadStatusWriteUtc = [DateTime]::MinValue
$script:LastDownloadStatusState = ''
$script:CheckpointWriter = $null
$script:CheckpointWriterPath = ''
$Default429Seconds = 30
$Max429Seconds = 3600
$TemporaryHostCooldownSeconds = 30
$PermanentCodes = @(400,401,403,404,405,410,451)

# Windows PowerShell 5.1 on older servers can otherwise negotiate legacy TLS only.
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }

function Write-JsonAtomic {
    param([string]$Path,$Object)
    $dir=Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp=$Path+'.tmp'
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Remove-PartialState {
    param([string]$PartPath)
    Remove-Item -LiteralPath $PartPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($PartPath+'.meta.json') -Force -ErrorAction SilentlyContinue
}

function Get-Sha256Text {
    param([string]$Text)
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash=$sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function Get-ItemKey {
    param($Item)
    return Get-Sha256Text -Text (('{0}|{1}|{2}|{3}' -f [string]$Item.ChatID,[string]$Item.ChatNumber,[string]$Item.SourcePath,[string]$Item.URL))
}

function Get-SafeName {
    param([string]$Name,[string]$Fallback)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name=$Fallback }
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name='attachment.bin' }
    try { $Name=[Uri]::UnescapeDataString($Name) } catch { }
    $Name=[System.Net.WebUtility]::HtmlDecode($Name)
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $Name=$Name.Replace([string]$c,'_') }
    $Name=$Name.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name='attachment.bin' }
    try {
        $deviceBase=[IO.Path]::GetFileNameWithoutExtension($Name)
        if ($deviceBase -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $Name='_'+$Name }
    }
    catch { }
    if ($Name.Length -gt 150) {
        $ext=[IO.Path]::GetExtension($Name); $base=[IO.Path]::GetFileNameWithoutExtension($Name)
        if ($base.Length -gt 120) { $base=$base.Substring(0,120) }
        $Name=$base+$ext
    }
    return $Name
}

function Get-SourceBaseName {
    param($Item)
    $name=[string]$Item.SourceFile
    if ([string]::IsNullOrWhiteSpace($name)) { $name=[string]$Item.SourceTXT }
    if ([string]::IsNullOrWhiteSpace($name)) { return 'SOURCE' }
    try { $name=[IO.Path]::GetFileNameWithoutExtension($name) } catch { }
    return (Get-SafeName -Name $name -Fallback 'SOURCE')
}

function Get-ChatStorageId {
    param($Item)

    $recordNo=[string]$Item.ChatNumber
    $recordId=[string]$Item.ChatID
    $recordType=[string]$Item.RecordType

    if ([string]::IsNullOrWhiteSpace($recordType)) { $recordType='RECORD' }
    $recordType=Get-SafeName -Name ($recordType.ToUpperInvariant()) -Fallback 'RECORD'

    if (-not [string]::IsNullOrWhiteSpace($recordNo)) {
        return (Get-SafeName -Name (('{0}_{1}' -f $recordType,$recordNo)) -Fallback 'RECORD_UNKNOWN')
    }

    if (
        -not [string]::IsNullOrWhiteSpace($recordId) -and
        $recordId -ne 'UNKNOWN_RECORD' -and
        $recordId -ne 'UNKNOWN_CHAT'
    ) {
        return (Get-SafeName -Name (('{0}_{1}' -f $recordType,$recordId)) -Fallback 'RECORD_UNKNOWN')
    }

    return (Get-SafeName -Name ('SOURCE_'+(Get-SourceBaseName -Item $Item)) -Fallback 'SOURCE_UNKNOWN')
}

function Load-StorageReservations {
    param([string]$Path)

    $map=@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }

    $reader=$null
    try {
        $reader=[System.IO.StreamReader]::new($Path,[System.Text.Encoding]::UTF8,$true,65536)
        while ($true) {
            $line=$reader.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $obj=$line | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$obj.Key)) {
                    $map[[string]$obj.Key]=$obj
                }
            }
            catch { }
        }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
    }

    return $map
}

function Add-StorageReservation {
    param(
        [string]$Path,
        [string]$Key,
        [string]$ChatStorageId,
        [int]$Index,
        [string]$FilePath,
        [string]$StorageMode
    )

    $obj=[ordered]@{
        At=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        Key=$Key
        ChatStorageId=$ChatStorageId
        Index=$Index
        FilePath=$FilePath
        StorageMode=$StorageMode
    }

    # Reservation is written before download starts. Flush it to disk so a hard power loss
    # cannot easily lose the file-number/path decision and create a duplicate on resume.
    $line=($obj | ConvertTo-Json -Compress) + [Environment]::NewLine
    $bytes=[System.Text.UTF8Encoding]::new($false).GetBytes($line)
    $fs=$null
    try {
        $fs=[System.IO.File]::Open($Path,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
        $fs.Write($bytes,0,$bytes.Length)
        try { $fs.Flush($true) } catch { $fs.Flush() }
    }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
    $script:StorageReservations[$Key]=[pscustomobject]$obj
}

function Get-NextStorageIndex {
    param(
        [string]$ChatStorageId,
        [string]$FilesRoot,
        [string]$StorageMode
    )

    if ($script:ChatNextIndex.ContainsKey($ChatStorageId)) {
        $n=[int]$script:ChatNextIndex[$ChatStorageId]
        $script:ChatNextIndex[$ChatStorageId]=$n+1
        return $n
    }

    $maxIndex=0

    foreach ($entry in $script:StorageReservations.Values) {
        if ([string]$entry.ChatStorageId -eq $ChatStorageId) {
            try {
                $idx=[int]$entry.Index
                if ($idx -gt $maxIndex) { $maxIndex=$idx }
            }
            catch { }
        }
    }

    if ($StorageMode -eq 'FlatChatPrefix') {
        if (Test-Path -LiteralPath $FilesRoot) {
            $escaped=[regex]::Escape($ChatStorageId)
            try {
                Get-ChildItem -LiteralPath $FilesRoot -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($_.Name -match ('^'+$escaped+'_(\d+)_')) {
                        $idx=[int]$matches[1]
                        if ($idx -gt $maxIndex) { $maxIndex=$idx }
                    }
                }
            }
            catch { }
        }
    }
    else {
        $chatFolder=Join-Path $FilesRoot $ChatStorageId
        if (Test-Path -LiteralPath $chatFolder) {
            try {
                Get-ChildItem -LiteralPath $chatFolder -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($_.Name -match '^(\d+)_') {
                        $idx=[int]$matches[1]
                        if ($idx -gt $maxIndex) { $maxIndex=$idx }
                    }
                }
            }
            catch { }
        }
    }

    $next=$maxIndex+1
    $script:ChatNextIndex[$ChatStorageId]=$next+1
    return $next
}

function Get-OrReserveFinalPath {
    param(
        $Item,
        [string]$Key,
        [string]$ChatStorageId,
        [string]$ResolvedName,
        [string]$FilesRoot,
        [string]$StorageMode,
        [string]$StorageMapPath
    )

    if ($script:StorageReservations.ContainsKey($Key)) {
        $old=$script:StorageReservations[$Key]
        if (-not [string]::IsNullOrWhiteSpace([string]$old.FilePath)) {
            return [string]$old.FilePath
        }
    }

    $idx=Get-NextStorageIndex -ChatStorageId $ChatStorageId -FilesRoot $FilesRoot -StorageMode $StorageMode
    $number=('{0:D2}' -f $idx)
    $safeName=Get-SafeName -Name $ResolvedName -Fallback 'attachment.bin'

    if ($StorageMode -eq 'FlatChatPrefix') {
        $finalName=Get-SafeName -Name (('{0}_{1}_{2}' -f $ChatStorageId,$number,$safeName)) -Fallback ($ChatStorageId+'_'+$number+'_attachment.bin')
        $finalPath=Join-Path $FilesRoot $finalName
    }
    else {
        $chatFolder=Join-Path $FilesRoot $ChatStorageId
        $finalName=Get-SafeName -Name (($number+'_')+$safeName) -Fallback ($number+'_attachment.bin')
        $finalPath=Join-Path $chatFolder $finalName
    }

    Add-StorageReservation -Path $StorageMapPath -Key $Key -ChatStorageId $ChatStorageId -Index $idx -FilePath $finalPath -StorageMode $StorageMode
    return $finalPath
}

function Get-TargetInfo {
    param(
        $Item,
        [string]$PartialsRoot
    )

    $key=Get-ItemKey -Item $Item
    $chatStorageId=Get-ChatStorageId -Item $Item

    if (-not (Test-Path -LiteralPath $PartialsRoot)) {
        New-Item -ItemType Directory -Path $PartialsRoot -Force | Out-Null
    }

    $partPath=Join-Path $PartialsRoot ($key+'.part')

    $initialName=[string]$Item.ExplicitFileName
    if ([string]::IsNullOrWhiteSpace($initialName)) {
        try {
            $u=[Uri][string]$Item.URL
            $initialName=[IO.Path]::GetFileName([Uri]::UnescapeDataString($u.AbsolutePath))
        }
        catch { $initialName='' }
    }
    $initialName=Get-SafeName -Name $initialName -Fallback 'attachment.bin'

    $existing=$null
    if ($script:StorageReservations.ContainsKey($key)) {
        $reserved=$script:StorageReservations[$key]
        $reservedPath=[string]$reserved.FilePath
        if (-not [string]::IsNullOrWhiteSpace($reservedPath) -and (Test-Path -LiteralPath $reservedPath)) {
            try { $existing=Get-Item -LiteralPath $reservedPath -ErrorAction Stop }
            catch { $existing=$null }
        }
    }

    return [pscustomobject]@{
        Key=$key
        ChatStorageId=$chatStorageId
        PartPath=$partPath
        InitialName=$initialName
        ExistingFile=$existing
    }
}

function Load-CheckpointMap {
    param([string]$Path)
    $map=@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    $reader=$null
    try {
        $reader=[System.IO.StreamReader]::new($Path,[System.Text.Encoding]::UTF8,$true,65536)
        while ($true) {
            $line=$reader.ReadLine(); if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $obj=$line | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$obj.Key)) { $map[[string]$obj.Key]=$obj }
            }
            catch { }
        }
    }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    return $map
}

function Compact-Checkpoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $latest=Load-CheckpointMap -Path $Path
    $tmp=$Path+'.compact.tmp'
    $writer=$null
    try {
        $writer=[System.IO.StreamWriter]::new($tmp,$false,[System.Text.UTF8Encoding]::new($false),65536)
        foreach ($key in ($latest.Keys | Sort-Object)) {
            $writer.WriteLine(($latest[$key] | ConvertTo-Json -Compress))
        }
        $writer.Flush()
    }
    finally { if ($null -ne $writer) { $writer.Dispose() } }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Add-Checkpoint {
    param(
        [string]$Path,[string]$Key,[string]$Status,$Item,[string]$FilePath,[int]$HttpStatus,[string]$Error,
        [string]$FinalUrl,[string]$ContentType,[string]$ContentDisposition
    )
    $obj=[ordered]@{
        At=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Key=$Key; Status=$Status
        URL=[string]$Item.URL; FinalURL=$FinalUrl; FilePath=$FilePath; HttpStatus=$HttpStatus
        ContentType=$ContentType; ContentDisposition=$ContentDisposition
        Classification=[string]$Item.Classification; Evidence=[string]$Item.Evidence
        SourceFile=$(if(-not [string]::IsNullOrWhiteSpace([string]$Item.SourceFile)){[string]$Item.SourceFile}else{[string]$Item.SourceTXT})
        SourceLine=[string]$Item.SourceLine; Error=$Error
    }
    $line=($obj | ConvertTo-Json -Compress)
    if ($null -ne $script:CheckpointWriter -and [string]$script:CheckpointWriterPath -ieq $Path) {
        $script:CheckpointWriter.WriteLine($line)
    }
    else {
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
}

function Write-DownloadStatus {
    param(
        [string]$Path,[string]$State,[int]$Total,[int]$Downloaded,[int]$Permanent,[int]$Transient,[int]$Skipped,[int]$Pending,
        [string]$CurrentFile,[string]$CurrentHost,[string]$Message
    )
    $now=[DateTime]::UtcNow
    if (
        [string]$script:LastDownloadStatusState -eq $State -and
        ($now-$script:LastDownloadStatusWriteUtc).TotalMilliseconds -lt $DownloadStatusMinIntervalMs
    ) { return }

    $pct=0.0
    if ($Total -gt 0) { $pct=[Math]::Round([Math]::Min(100.0,(($Total-$Pending)*100.0/$Total)),2) }
    $obj=[ordered]@{
        EngineVersion=$EngineVersion; State=$State; UpdatedAt=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        Total=$Total; Downloaded=$Downloaded; PermanentFailures=$Permanent; TransientFailures=$Transient; SkippedNonFiles=$Skipped; Pending=$Pending
        Percent=$pct; CurrentFile=$CurrentFile; CurrentHost=$CurrentHost; Message=$Message
    }
    try {
        Write-JsonAtomic -Path $Path -Object $obj
        $script:LastDownloadStatusWriteUtc=$now
        $script:LastDownloadStatusState=$State
    }
    catch { }
}

function Get-RetryAfterSeconds {
    param($Response)
    $sec=$Default429Seconds
    try {
        $raw=[string]$Response.Headers['Retry-After']; $n=0
        if ([int]::TryParse($raw,[ref]$n)) { $sec=$n }
        elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
            $dt=[DateTime]::MinValue
            if ([DateTime]::TryParse($raw,[ref]$dt)) { $sec=[Math]::Ceiling(($dt.ToUniversalTime()-[DateTime]::UtcNow).TotalSeconds) }
        }
    }
    catch { }
    if ($sec -lt 1) { $sec=$Default429Seconds }
    if ($sec -gt $Max429Seconds) { $sec=$Max429Seconds }
    return [int]$sec
}

function Get-FileNameFromContentDisposition {
    param([string]$ContentDisposition)
    if ([string]::IsNullOrWhiteSpace($ContentDisposition)) { return '' }
    try {
        if ($ContentDisposition -match '(?i)filename\*\s*=\s*UTF-8''''([^;]+)') {
            $v=$matches[1].Trim().Trim('"')
            try { return [Uri]::UnescapeDataString($v) } catch { return $v }
        }
        if ($ContentDisposition -match '(?i)filename\s*=\s*"([^"]+)"') { return $matches[1] }
        if ($ContentDisposition -match '(?i)filename\s*=\s*([^;]+)') { return $matches[1].Trim().Trim('"') }
    }
    catch { }
    return ''
}

function Get-UrlFileName {
    param([string]$Url)
    try {
        $u=[Uri]$Url
        return [IO.Path]::GetFileName([Uri]::UnescapeDataString($u.AbsolutePath))
    }
    catch { return '' }
}

function Test-KnownFileExtension {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $ext=''
    try { $ext=[IO.Path]::GetExtension($Name).ToLowerInvariant() } catch { }
    return ($ext -in @(
        '.jpg','.jpeg','.png','.gif','.webp','.bmp','.tif','.tiff','.svg','.heic','.heif',
        '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.txt','.csv','.tsv','.rtf','.json','.jsonl','.xml','.yaml','.yml','.ini','.cfg','.conf','.log','.md','.html','.htm',
        '.zip','.rar','.7z','.gz','.tar','.mp3','.wav','.m4a','.ogg','.flac','.mp4','.mov','.avi','.mkv','.webm'
    ))
}

function Get-ExtensionFromMime {
    param([string]$ContentType)
    $mime=([string]$ContentType).Split(';')[0].Trim().ToLowerInvariant()
    $map=@{
        'image/jpeg'='.jpg'; 'image/png'='.png'; 'image/gif'='.gif'; 'image/webp'='.webp'; 'image/bmp'='.bmp'; 'image/tiff'='.tif'; 'image/svg+xml'='.svg';
        'application/pdf'='.pdf'; 'application/zip'='.zip'; 'application/x-7z-compressed'='.7z'; 'application/x-rar-compressed'='.rar'; 'application/gzip'='.gz';
        'application/msword'='.doc'; 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'='.docx';
        'application/vnd.ms-excel'='.xls'; 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'='.xlsx';
        'application/vnd.ms-powerpoint'='.ppt'; 'application/vnd.openxmlformats-officedocument.presentationml.presentation'='.pptx';
        'text/plain'='.txt'; 'text/csv'='.csv'; 'text/tab-separated-values'='.tsv'; 'text/markdown'='.md'; 'application/json'='.json'; 'application/xml'='.xml'; 'text/xml'='.xml'; 'application/yaml'='.yaml'; 'application/x-yaml'='.yaml'; 'text/yaml'='.yaml'; 'application/rtf'='.rtf';
        'audio/mpeg'='.mp3'; 'audio/wav'='.wav'; 'audio/ogg'='.ogg'; 'video/mp4'='.mp4'; 'video/webm'='.webm'; 'video/quicktime'='.mov'
    }
    if ($map.ContainsKey($mime)) { return [string]$map[$mime] }
    return ''
}

function Get-ResponseDecision {
    param($Item,[string]$ContentType,[string]$ContentDisposition,[string]$FinalUrl)

    $mime=([string]$ContentType).Split(';')[0].Trim().ToLowerInvariant()
    $dispName=Get-FileNameFromContentDisposition -ContentDisposition $ContentDisposition
    $dispAttachment=([string]$ContentDisposition -match '(?i)^\s*attachment\b')
    if ($dispAttachment -or -not [string]::IsNullOrWhiteSpace($dispName)) { return [pscustomobject]@{ IsFile=$true; Reason='Content-Disposition' } }

    $explicit=(-not [string]::IsNullOrWhiteSpace([string]$Item.ExplicitFileName) -or -not [string]::IsNullOrWhiteSpace([string]$Item.ExplicitMimeType) -or [string]$Item.Classification -eq 'ExplicitAttachment')
    $finalName=Get-UrlFileName -Url $FinalUrl
    $finalKnownExt=Test-KnownFileExtension -Name $finalName

    $isHtml=($mime -in @('text/html','application/xhtml+xml'))
    if ($isHtml) {
        # Avoid saving login/error/website pages as attachments. HTML is accepted only when the export explicitly said it was an HTML file.
        $explicitName=[string]$Item.ExplicitFileName
        $explicitMime=([string]$Item.ExplicitMimeType).ToLowerInvariant()
        if ($explicit -and ($explicitName.ToLowerInvariant().EndsWith('.html') -or $explicitName.ToLowerInvariant().EndsWith('.htm')) -and $explicitMime -match 'html') {
            return [pscustomobject]@{ IsFile=$true; Reason='Explicit HTML attachment' }
        }
        return [pscustomobject]@{ IsFile=$false; Reason='HTML/web page response' }
    }

    if ($explicit) { return [pscustomobject]@{ IsFile=$true; Reason='Explicit attachment metadata' } }

    # If the server omitted Content-Type and the final/source path itself is HTML,
    # be conservative: this is most likely a web page, not a downloadable attachment.
    $sourceName=Get-UrlFileName -Url ([string]$Item.URL)
    $looksHtmlByName = (
        $finalName.ToLowerInvariant().EndsWith('.html') -or
        $finalName.ToLowerInvariant().EndsWith('.htm') -or
        $sourceName.ToLowerInvariant().EndsWith('.html') -or
        $sourceName.ToLowerInvariant().EndsWith('.htm')
    )
    if ([string]::IsNullOrWhiteSpace($mime) -and $looksHtmlByName) {
        return [pscustomobject]@{ IsFile=$false; Reason='HTML-looking URL with no file headers' }
    }

    # For unknown URLs, the actual response Content-Type is authoritative except for HTML/web pages.
    # This deliberately accepts image/audio/video/PDF/office/archive as well as text/plain, JSON, XML, CSV, etc.
    if (-not [string]::IsNullOrWhiteSpace($mime)) {
        return [pscustomobject]@{ IsFile=$true; Reason=('Non-HTML Content-Type: '+$mime) }
    }

    if ([string]$Item.Classification -ne 'UnknownUrl') {
        return [pscustomobject]@{ IsFile=$true; Reason='Strong URL evidence + non-HTML/unknown response type' }
    }
    if ($finalKnownExt -and -not ($finalName.ToLowerInvariant().EndsWith('.html') -or $finalName.ToLowerInvariant().EndsWith('.htm'))) {
        return [pscustomobject]@{ IsFile=$true; Reason='Redirect/final URL has file extension' }
    }

    return [pscustomobject]@{ IsFile=$false; Reason=('No file evidence after HTTP response; Content-Type='+$mime) }
}

function Resolve-FileName {
    param($Item,[string]$ContentDisposition,[string]$FinalUrl,[string]$ContentType)

    $name=[string]$Item.ExplicitFileName
    if ([string]::IsNullOrWhiteSpace($name)) { $name=Get-FileNameFromContentDisposition -ContentDisposition $ContentDisposition }
    if ([string]::IsNullOrWhiteSpace($name)) { $name=Get-UrlFileName -Url $FinalUrl }
    $name=Get-SafeName -Name $name -Fallback 'attachment'

    $ext=''
    try { $ext=[IO.Path]::GetExtension($name) } catch { }
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $mimeExt=Get-ExtensionFromMime -ContentType $ContentType
        if (-not [string]::IsNullOrWhiteSpace($mimeExt)) { $name += $mimeExt }
        else { $name += '.bin' }
    }
    return (Get-SafeName -Name $name -Fallback 'attachment.bin')
}

function Download-One {
    param($Item,$Target)

    $url=[string]$Item.URL
    $partMetaPath=$Target.PartPath+'.meta.json'
    $resumeFrom=[long]0
    if (Test-Path -LiteralPath $Target.PartPath) { try { $resumeFrom=(Get-Item -LiteralPath $Target.PartPath).Length } catch { $resumeFrom=0 } }
    $partMeta=if($resumeFrom -gt 0){ Read-JsonSafe -Path $partMetaPath }else{$null}
    if ($resumeFrom -gt 0 -and $null -ne $partMeta -and -not [string]::IsNullOrWhiteSpace([string]$partMeta.ContentEncoding)) {
        # HTTP Range offsets apply to the wire representation. Because HttpWebRequest auto-decompresses,
        # a compressed partial cannot be resumed safely by its decompressed file length. Restart cleanly.
        Remove-PartialState -PartPath $Target.PartPath
        $resumeFrom=0; $partMeta=$null
    }

    $request=$null; $response=$null; $inStream=$null; $outStream=$null
    try {
        $request=[System.Net.HttpWebRequest]::Create($url)
        $request.Method='GET'; $request.AllowAutoRedirect=$true; $request.MaximumAutomaticRedirections=10
        $request.UserAgent='ChatAttachmentManager-UNIVERSAL/1.4.1'; $request.Timeout=$ConnectTimeoutMs; $request.ReadWriteTimeout=$ReadWriteTimeoutMs
        $request.AutomaticDecompression=[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        if ($resumeFrom -gt 0) {
            $request.AddRange($resumeFrom)
            if ($null -ne $partMeta) {
                $validator=''
                if (-not [string]::IsNullOrWhiteSpace([string]$partMeta.ETag)) { $validator=[string]$partMeta.ETag }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$partMeta.LastModified)) { $validator=[string]$partMeta.LastModified }
                if (-not [string]::IsNullOrWhiteSpace($validator)) {
                    try { $request.Headers['If-Range']=$validator } catch { }
                }
            }
        }

        try { $response=[System.Net.HttpWebResponse]$request.GetResponse() }
        catch [System.Net.WebException] {
            $webex=$_.Exception; $resp=$webex.Response
            if ($null -ne $resp) {
                $httpResp=[System.Net.HttpWebResponse]$resp; $code=[int]$httpResp.StatusCode
                $finalUrl=''; try { $finalUrl=[string]$httpResp.ResponseUri.AbsoluteUri } catch { }
                $ctype=[string]$httpResp.ContentType; $cd=[string]$httpResp.Headers['Content-Disposition']
                if ($code -eq 429) { $retrySec=Get-RetryAfterSeconds -Response $httpResp; $httpResp.Dispose(); return [pscustomobject]@{ Kind='RateLimit'; HttpStatus=$code; RetryAfter=$retrySec; Error=$webex.Message; FinalUrl=$finalUrl; ContentType=$ctype; ContentDisposition=$cd; FilePath='' } }
                if ($code -eq 416 -and $resumeFrom -gt 0) {
                    $httpResp.Dispose(); Remove-PartialState -PartPath $Target.PartPath
                    return [pscustomobject]@{ Kind='RestartFromZero'; HttpStatus=$code; RetryAfter=0; Error='Range was rejected; partial file reset.'; FinalUrl=$finalUrl; ContentType=$ctype; ContentDisposition=$cd; FilePath='' }
                }
                if ($PermanentCodes -contains $code) { $httpResp.Dispose(); return [pscustomobject]@{ Kind='Permanent'; HttpStatus=$code; RetryAfter=0; Error=$webex.Message; FinalUrl=$finalUrl; ContentType=$ctype; ContentDisposition=$cd; FilePath='' } }
                $retrySec=$TemporaryHostCooldownSeconds
                if ($code -in @(502,503,504) -and -not [string]::IsNullOrWhiteSpace([string]$httpResp.Headers['Retry-After'])) { $retrySec=Get-RetryAfterSeconds -Response $httpResp }
                $httpResp.Dispose(); return [pscustomobject]@{ Kind='TransientHttp'; HttpStatus=$code; RetryAfter=$retrySec; Error=$webex.Message; FinalUrl=$finalUrl; ContentType=$ctype; ContentDisposition=$cd; FilePath='' }
            }
            return [pscustomobject]@{ Kind='Network'; HttpStatus=0; RetryAfter=0; Error=$webex.Message; FinalUrl=''; ContentType=''; ContentDisposition=''; FilePath='' }
        }

        $statusCode=[int]$response.StatusCode; $contentType=[string]$response.ContentType; $contentDisposition=[string]$response.Headers['Content-Disposition']
        $finalUrl=''; try { $finalUrl=[string]$response.ResponseUri.AbsoluteUri } catch { $finalUrl=$url }
        $decision=Get-ResponseDecision -Item $Item -ContentType $contentType -ContentDisposition $contentDisposition -FinalUrl $finalUrl

        if (-not [bool]$decision.IsFile) {
            Remove-PartialState -PartPath $Target.PartPath
            return [pscustomobject]@{ Kind='NonFile'; HttpStatus=$statusCode; RetryAfter=0; Error=[string]$decision.Reason; FinalUrl=$finalUrl; ContentType=$contentType; ContentDisposition=$contentDisposition; FilePath='' }
        }

        $resolvedName=Resolve-FileName -Item $Item -ContentDisposition $contentDisposition -FinalUrl $finalUrl -ContentType $contentType
        $finalPath=Get-OrReserveFinalPath -Item $Item -Key ([string]$Target.Key) -ChatStorageId ([string]$Target.ChatStorageId) -ResolvedName $resolvedName -FilesRoot $script:FilesRoot -StorageMode $script:StorageMode -StorageMapPath $script:StorageMapPath

        if (Test-Path -LiteralPath $finalPath) {
            Remove-PartialState -PartPath $Target.PartPath
            return [pscustomobject]@{ Kind='AlreadyExists'; HttpStatus=$statusCode; RetryAfter=0; Error=''; FinalUrl=$finalUrl; ContentType=$contentType; ContentDisposition=$contentDisposition; FilePath=$finalPath }
        }

        $append=($resumeFrom -gt 0 -and $statusCode -eq 206)
        if ($append) {
            if ($null -ne $partMeta) {
                $oldEtag=[string]$partMeta.ETag; $newEtag=[string]$response.Headers['ETag']
                $oldLm=[string]$partMeta.LastModified; $newLm=[string]$response.Headers['Last-Modified']
                $validatorChanged=(
                    (-not [string]::IsNullOrWhiteSpace($oldEtag) -and -not [string]::IsNullOrWhiteSpace($newEtag) -and $oldEtag -ne $newEtag) -or
                    ([string]::IsNullOrWhiteSpace($oldEtag) -and -not [string]::IsNullOrWhiteSpace($oldLm) -and -not [string]::IsNullOrWhiteSpace($newLm) -and $oldLm -ne $newLm)
                )
                if ($validatorChanged) {
                    $response.Dispose(); $response=$null
                    Remove-PartialState -PartPath $Target.PartPath
                    return [pscustomobject]@{ Kind='RestartFromZero'; HttpStatus=$statusCode; RetryAfter=0; Error='Remote validator changed while resuming; partial file reset.'; FinalUrl=$finalUrl; ContentType=$contentType; ContentDisposition=$contentDisposition; FilePath='' }
                }
            }

            $contentRange=[string]$response.Headers['Content-Range']
            if ([string]::IsNullOrWhiteSpace($contentRange) -or $contentRange -notmatch ('(?i)^bytes\s+'+[regex]::Escape([string]$resumeFrom)+'-')) {
                $response.Dispose(); $response=$null
                Remove-PartialState -PartPath $Target.PartPath
                return [pscustomobject]@{ Kind='RestartFromZero'; HttpStatus=$statusCode; RetryAfter=0; Error=('Unexpected Content-Range while resuming: '+$contentRange); FinalUrl=$finalUrl; ContentType=$contentType; ContentDisposition=$contentDisposition; FilePath='' }
            }
        }
        elseif ($resumeFrom -gt 0) {
            # If-Range intentionally makes a changed remote object return 200. Replace the stale partial with this fresh body.
            Remove-PartialState -PartPath $Target.PartPath
            $resumeFrom=0
        }

        $etag=[string]$response.Headers['ETag']; $lastModified=[string]$response.Headers['Last-Modified']; $contentEncoding=[string]$response.Headers['Content-Encoding']
        Write-JsonAtomic -Path $partMetaPath -Object ([ordered]@{
            EngineVersion=$EngineVersion; OriginalUrl=$url; FinalUrl=$finalUrl; ETag=$etag; LastModified=$lastModified; ContentEncoding=$contentEncoding
            ResumeFrom=$resumeFrom; UpdatedAt=[DateTime]::Now.ToString('o')
        })

        $mode=if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $outStream=[System.IO.File]::Open($Target.PartPath,$mode,[System.IO.FileAccess]::Write,[System.IO.FileShare]::Read)
        $inStream=$response.GetResponseStream(); $buffer=New-Object byte[] 131072
        [long]$bytesSinceDurableFlush=0
        $lastDurableFlush=[DateTime]::UtcNow
        while ($true) {
            $read=$inStream.Read($buffer,0,$buffer.Length)
            if ($read -le 0) { break }
            $outStream.Write($buffer,0,$read)
            $bytesSinceDurableFlush += $read
            if ($bytesSinceDurableFlush -ge 33554432 -or ([DateTime]::UtcNow-$lastDurableFlush).TotalSeconds -ge 5) {
                try { $outStream.Flush($true) } catch { $outStream.Flush() }
                $bytesSinceDurableFlush=0; $lastDurableFlush=[DateTime]::UtcNow
            }
        }
        try { $outStream.Flush($true) } catch { $outStream.Flush() }
        $outStream.Dispose(); $outStream=$null; $inStream.Dispose(); $inStream=$null; $response.Dispose(); $response=$null

        # In ChatFolders mode the per-chat folder is created only after the entire file body downloaded successfully.
        $finalDir=Split-Path -Parent $finalPath
        if (-not (Test-Path -LiteralPath $finalDir)) { New-Item -ItemType Directory -Path $finalDir -Force | Out-Null }

        Move-Item -LiteralPath $Target.PartPath -Destination $finalPath -Force
        Remove-Item -LiteralPath $partMetaPath -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Kind='Success'; HttpStatus=$statusCode; RetryAfter=0; Error=''; FinalUrl=$finalUrl; ContentType=$contentType; ContentDisposition=$contentDisposition; FilePath=$finalPath }
    }
    catch {
        try { if ($null -ne $outStream) { try { $outStream.Flush($true) } catch { $outStream.Flush() } } } catch { }
        return [pscustomobject]@{ Kind='Network'; HttpStatus=0; RetryAfter=0; Error=($_ | Out-String); FinalUrl=''; ContentType=''; ContentDisposition=''; FilePath='' }
    }
    finally {
        try { if ($null -ne $outStream) { $outStream.Dispose() } } catch { }
        try { if ($null -ne $inStream) { $inStream.Dispose() } } catch { }
        try { if ($null -ne $response) { $response.Dispose() } } catch { }
    }
}

function Write-ReadableReports {
    param([string]$CheckpointPath,[string]$OutputRoot)
    $latest=Load-CheckpointMap -Path $CheckpointPath
    $failRows=New-Object System.Collections.ArrayList
    $indexRows=New-Object System.Collections.ArrayList
    $skipRows=New-Object System.Collections.ArrayList
    foreach ($k in $latest.Keys) {
        $o=$latest[$k]
        if (([string]$o.Status) -in @('PermanentFailure','TransientFailure')) {
            [void]$failRows.Add([pscustomobject]@{ Status=[string]$o.Status; URL=[string]$o.URL; FinalURL=[string]$o.FinalURL; HttpStatus=[int]$o.HttpStatus; ContentType=[string]$o.ContentType; Error=[string]$o.Error; FilePath=[string]$o.FilePath; SourceFile=[string]$o.SourceFile; SourceLine=[string]$o.SourceLine })
        }
        elseif (([string]$o.Status) -in @('Downloaded','AlreadyExists')) {
            [void]$indexRows.Add([pscustomobject]@{ Status=[string]$o.Status; URL=[string]$o.URL; FinalURL=[string]$o.FinalURL; ContentType=[string]$o.ContentType; ContentDisposition=[string]$o.ContentDisposition; FilePath=[string]$o.FilePath; Classification=[string]$o.Classification; Evidence=[string]$o.Evidence; SourceFile=[string]$o.SourceFile; SourceLine=[string]$o.SourceLine })
        }
        elseif ([string]$o.Status -eq 'SkippedNonFile') {
            [void]$skipRows.Add([pscustomobject]@{ URL=[string]$o.URL; FinalURL=[string]$o.FinalURL; HttpStatus=[int]$o.HttpStatus; ContentType=[string]$o.ContentType; ContentDisposition=[string]$o.ContentDisposition; Reason=[string]$o.Error; Classification=[string]$o.Classification; Evidence=[string]$o.Evidence; SourceFile=[string]$o.SourceFile; SourceLine=[string]$o.SourceLine })
        }
    }

    $failCsv=Join-Path $OutputRoot 'attachments_failed.csv'; $indexCsv=Join-Path $OutputRoot 'attachments_index.csv'; $skipCsv=Join-Path $OutputRoot 'urls_skipped_as_nonfiles.csv'
    if ($failRows.Count -gt 0) { $failRows | Export-Csv -LiteralPath $failCsv -NoTypeInformation -Encoding UTF8 } elseif (Test-Path -LiteralPath $failCsv) { Remove-Item -LiteralPath $failCsv -Force -ErrorAction SilentlyContinue }
    if ($indexRows.Count -gt 0) { $indexRows | Export-Csv -LiteralPath $indexCsv -NoTypeInformation -Encoding UTF8 } elseif (Test-Path -LiteralPath $indexCsv) { Remove-Item -LiteralPath $indexCsv -Force -ErrorAction SilentlyContinue }
    if ($skipRows.Count -gt 0) { $skipRows | Export-Csv -LiteralPath $skipCsv -NoTypeInformation -Encoding UTF8 } elseif (Test-Path -LiteralPath $skipCsv) { Remove-Item -LiteralPath $skipCsv -Force -ErrorAction SilentlyContinue }
}

try {
    $projectJson=Join-Path $ProjectRoot 'project.json'
    if (-not (Test-Path -LiteralPath $projectJson)) { throw 'project.json not found' }
    $cfg=Get-Content -LiteralPath $projectJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $outputRoot=[string]$cfg.OutputFolder

    try {
        $delayProp=$cfg.PSObject.Properties['RequestDelayMs']
        if ($null -ne $delayProp) { $NormalDelayMs=[Math]::Max(0,[Math]::Min(5000,[int]$delayProp.Value)) }
    }
    catch { }

    $storageMode=[string]$cfg.StorageMode
    if ($storageMode -notin @('ChatFolders','FlatChatPrefix')) { $storageMode='ChatFolders' }

    $script:StorageMode=$storageMode
    $script:FilesRoot=Join-Path $outputRoot 'files'
    $script:StorageMapPath=Join-Path $ProjectRoot 'storage_map.jsonl'
    $script:PartialsRoot=Join-Path $ProjectRoot 'partials'
    $script:StorageReservations=Load-StorageReservations -Path $script:StorageMapPath
    $script:ChatNextIndex=@{}

    if ($SelfTest) {
        $inventoryCsv=Join-Path $ProjectRoot 'preflight\preflight_inventory.csv'
        if (-not (Test-Path -LiteralPath $inventoryCsv)) { throw 'Preflight inventory missing.' }
        $testItems=@(Import-Csv -LiteralPath $inventoryCsv -Encoding UTF8 | Select-Object -First 10)
        $testRoot=Join-Path $ProjectRoot 'preflight\target_test'
        $testPartials=Join-Path $testRoot 'partials'
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

        $script:StorageReservations=@{}
        $script:ChatNextIndex=@{}
        $testStorageMap=Join-Path $testRoot 'storage_map.jsonl'
        if (Test-Path -LiteralPath $testStorageMap) { Remove-Item -LiteralPath $testStorageMap -Force }

        foreach ($testItem in $testItems) {
            [void](Get-TargetInfo -Item $testItem -PartialsRoot $testPartials)
            [void](Get-ItemKey -Item $testItem)
        }

        if ($testItems.Count -gt 0) {
            $ti=$testItems[0]
            $tk=Get-ItemKey -Item $ti
            $tc=Get-ChatStorageId -Item $ti

            $flat=Get-OrReserveFinalPath -Item $ti -Key $tk -ChatStorageId $tc -ResolvedName 'example.pdf' -FilesRoot $testRoot -StorageMode 'FlatChatPrefix' -StorageMapPath $testStorageMap
            if ([IO.Path]::GetFileName($flat) -notmatch ('^'+[regex]::Escape($tc)+'_01_example\.pdf$')) { throw 'Self-test: flat naming mode failed.' }

            $script:StorageReservations=@{}
            $script:ChatNextIndex=@{}
            if (Test-Path -LiteralPath $testStorageMap) { Remove-Item -LiteralPath $testStorageMap -Force }

            $folderPath=Get-OrReserveFinalPath -Item $ti -Key $tk -ChatStorageId $tc -ResolvedName 'example.pdf' -FilesRoot $testRoot -StorageMode 'ChatFolders' -StorageMapPath $testStorageMap
            $chatDir=Split-Path -Parent $folderPath
            if ([IO.Path]::GetFileName($folderPath) -ne '01_example.pdf') { throw 'Self-test: chat-folder naming mode failed.' }
            if (Test-Path -LiteralPath $chatDir) { throw 'Self-test: chat folder was created before a completed download.' }
        }

        # Header/decision logic tests: NO network requests.
        $dummy=[pscustomobject]@{ ExplicitFileName=''; ExplicitMimeType=''; Classification='UnknownUrl' }
        if ((Get-ResponseDecision -Item $dummy -ContentType 'text/html' -ContentDisposition '' -FinalUrl 'https://example.com/page').IsFile) { throw 'Self-test: normal HTML page was misclassified as file.' }
        $dummyHtml=[pscustomobject]@{ ExplicitFileName=''; ExplicitMimeType=''; Classification='FileExtension'; URL='https://example.com/page.html' }
        if ((Get-ResponseDecision -Item $dummyHtml -ContentType '' -ContentDisposition '' -FinalUrl 'https://example.com/page.html').IsFile) { throw 'Self-test: HTML-looking URL with no headers was misclassified as file.' }
        if (-not (Get-ResponseDecision -Item $dummy -ContentType 'application/pdf' -ContentDisposition '' -FinalUrl 'https://example.com/download').IsFile) { throw 'Self-test: PDF response was not classified as file.' }
        $explicit=[pscustomobject]@{ ExplicitFileName='File.jpg'; ExplicitMimeType='image/jpeg'; Classification='ExplicitAttachment' }
        if (-not (Get-ResponseDecision -Item $explicit -ContentType 'image/jpeg' -ContentDisposition '' -FinalUrl 'https://cdn.example/x').IsFile) { throw 'Self-test: explicit attachment failed.' }
        if (-not (Get-ResponseDecision -Item $dummy -ContentType 'text/plain' -ContentDisposition 'attachment; filename="notes.txt"' -FinalUrl 'https://example.com/x').IsFile) { throw 'Self-test: Content-Disposition attachment failed.' }

        Write-JsonAtomic -Path (Join-Path $ProjectRoot 'preflight_downloader_ok.json') -Object ([ordered]@{ EngineVersion=$EngineVersion; CompletedAt=[DateTime]::Now.ToString('o'); CandidatesTested=$testItems.Count; HeaderDecisionTests='OK'; NetworkRequestsMade=0 })
        exit 0
    }

    $inventoryCsv=Join-Path $outputRoot 'all_urls_inventory.csv'
    if (-not (Test-Path -LiteralPath $inventoryCsv)) { throw 'all_urls_inventory.csv not found; Scanner must finish first.' }

    $filesRoot=$script:FilesRoot
    $partialsRoot=$script:PartialsRoot
    New-Item -ItemType Directory -Path $filesRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $partialsRoot -Force | Out-Null
    $checkpointPath=Join-Path $ProjectRoot 'download_state.jsonl'; $statusPath=Join-Path $ProjectRoot 'download_status.json'
    Write-DownloadStatus -Path $statusPath -State 'PREPARING_INVENTORY' -Total 0 -Downloaded 0 -Permanent 0 -Transient 0 -Skipped 0 -Pending 0 -CurrentFile '' -CurrentHost '' -Message 'Reading inventory; all URLs will be validated using real HTTP responses'

    # IMPORTANT: UnknownUrl is intentionally included. HTTP headers/final response decide whether it is a file.
    $allItems=@(Import-Csv -LiteralPath $inventoryCsv -Encoding UTF8)
    $checkpointMap=Load-CheckpointMap -Path $checkpointPath
    $script:CheckpointWriter=[System.IO.StreamWriter]::new($checkpointPath,$true,[System.Text.UTF8Encoding]::new($false),65536)
    $script:CheckpointWriter.AutoFlush=$true
    $script:CheckpointWriterPath=$checkpointPath

    $queue=New-Object System.Collections.Queue; $attempts=@{}; $hostCooldown=@{}
    $downloaded=0; $permanent=0; $transient=0; $skipped=0

    foreach ($item in $allItems) {
        $target=Get-TargetInfo -Item $item -PartialsRoot $partialsRoot; $key=[string]$target.Key; $done=$false
        if ($checkpointMap.ContainsKey($key)) {
            $last=$checkpointMap[$key]
            if (([string]$last.Status) -in @('Downloaded','AlreadyExists','PermanentFailure','SkippedNonFile')) {
                $done=$true
                if (([string]$last.Status) -in @('Downloaded','AlreadyExists')) { $downloaded++ }
                elseif ([string]$last.Status -eq 'PermanentFailure') { $permanent++ }
                elseif ([string]$last.Status -eq 'SkippedNonFile') { $skipped++ }
            }
        }
        if (-not $done -and $null -ne $target.ExistingFile) {
            Add-Checkpoint -Path $checkpointPath -Key $key -Status 'AlreadyExists' -Item $item -FilePath $target.ExistingFile.FullName -HttpStatus 0 -Error '' -FinalUrl '' -ContentType '' -ContentDisposition ''
            $downloaded++; $done=$true
        }
        if (-not $done) { $queue.Enqueue($item) }
    }

    $total=$allItems.Count;     Write-DownloadStatus -Path $statusPath -State 'DOWNLOADING' -Total $total -Downloaded $downloaded -Permanent $permanent -Transient 0 -Skipped $skipped -Pending $queue.Count -CurrentFile '' -CurrentHost '' -Message (('Starting/resuming URL validation and downloads; storage mode: {0}' -f $storageMode))

    while ($queue.Count -gt 0) {
        $cycleCount=$queue.Count; $item=$null; $remoteHost=''
        for ($i=0; $i -lt $cycleCount; $i++) {
            $candidate=$queue.Dequeue()
            try { $candidateHost=([Uri][string]$candidate.URL).Host.ToLowerInvariant() } catch { $candidateHost='invalid-host' }
            $blocked=$false
            if ($hostCooldown.ContainsKey($candidateHost)) {
                if ([DateTime]$hostCooldown[$candidateHost] -gt [DateTime]::UtcNow) { $blocked=$true }
                else { $hostCooldown.Remove($candidateHost) }
            }
            if ($blocked) { $queue.Enqueue($candidate); continue }
            $item=$candidate; $remoteHost=$candidateHost; break
        }

        if ($null -eq $item) {
            $nearest=$null
            foreach ($v in $hostCooldown.Values) { if ($null -eq $nearest -or [DateTime]$v -lt [DateTime]$nearest) { $nearest=[DateTime]$v } }
            $sleepSec=5
            if ($null -ne $nearest) { $sleepSec=[Math]::Max(1,[Math]::Min(30,[Math]::Ceiling(($nearest-[DateTime]::UtcNow).TotalSeconds))) }
            Write-DownloadStatus -Path $statusPath -State 'HOST_COOLDOWN' -Total $total -Downloaded $downloaded -Permanent $permanent -Transient $transient -Skipped $skipped -Pending $queue.Count -CurrentFile '' -CurrentHost '' -Message ("All remaining hosts are temporarily in cooldown; waiting {0} seconds" -f $sleepSec)
            Start-Sleep -Seconds $sleepSec; continue
        }

        $target=Get-TargetInfo -Item $item -PartialsRoot $partialsRoot; $key=[string]$target.Key
        if (-not $attempts.ContainsKey($key)) { $attempts[$key]=0 }
        Write-DownloadStatus -Path $statusPath -State 'DOWNLOADING' -Total $total -Downloaded $downloaded -Permanent $permanent -Transient $transient -Skipped $skipped -Pending ($queue.Count+1) -CurrentFile $target.InitialName -CurrentHost $remoteHost -Message 'Sending HTTP request and classifying file/page from the real response'
        $result=Download-One -Item $item -Target $target

        switch ([string]$result.Kind) {
            'Success' {
                Add-Checkpoint -Path $checkpointPath -Key $key -Status 'Downloaded' -Item $item -FilePath ([string]$result.FilePath) -HttpStatus ([int]$result.HttpStatus) -Error '' -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition)
                $checkpointMap[$key]=[pscustomobject]@{Status='Downloaded'}; $downloaded++;             }
            'AlreadyExists' {
                Add-Checkpoint -Path $checkpointPath -Key $key -Status 'AlreadyExists' -Item $item -FilePath ([string]$result.FilePath) -HttpStatus ([int]$result.HttpStatus) -Error '' -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition)
                $checkpointMap[$key]=[pscustomobject]@{Status='AlreadyExists'}; $downloaded++;             }
            'NonFile' {
                Add-Checkpoint -Path $checkpointPath -Key $key -Status 'SkippedNonFile' -Item $item -FilePath '' -HttpStatus ([int]$result.HttpStatus) -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition)
                $checkpointMap[$key]=[pscustomobject]@{Status='SkippedNonFile'}; $skipped++;             }
            'Permanent' {
                Add-Checkpoint -Path $checkpointPath -Key $key -Status 'PermanentFailure' -Item $item -FilePath '' -HttpStatus ([int]$result.HttpStatus) -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition)
                $checkpointMap[$key]=[pscustomobject]@{Status='PermanentFailure'}; $permanent++;             }
            'RateLimit' {
                $attempts[$key]=[int]$attempts[$key]+1
                $sec=[int]$result.RetryAfter; $hostCooldown[$remoteHost]=[DateTime]::UtcNow.AddSeconds($sec)
                if ([int]$attempts[$key] -lt $MaxAttemptsPerRun) { $queue.Enqueue($item) }
                else { Add-Checkpoint -Path $checkpointPath -Key $key -Status 'TransientFailure' -Item $item -FilePath $target.PartPath -HttpStatus ([int]$result.HttpStatus) -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition); $transient++ }
            }
            'RestartFromZero' {
                $attempts[$key]=[int]$attempts[$key]+1
                if ([int]$attempts[$key] -lt $MaxAttemptsPerRun) { $queue.Enqueue($item) }
                else { Add-Checkpoint -Path $checkpointPath -Key $key -Status 'TransientFailure' -Item $item -FilePath '' -HttpStatus ([int]$result.HttpStatus) -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition); $transient++ }
            }
            'TransientHttp' {
                $attempts[$key]=[int]$attempts[$key]+1; $hostCooldown[$remoteHost]=[DateTime]::UtcNow.AddSeconds([int]$result.RetryAfter)
                if ([int]$attempts[$key] -lt $MaxAttemptsPerRun) { $queue.Enqueue($item) }
                else { Add-Checkpoint -Path $checkpointPath -Key $key -Status 'TransientFailure' -Item $item -FilePath $target.PartPath -HttpStatus ([int]$result.HttpStatus) -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition); $transient++ }
                            }
            default {
                # Network/DNS/TLS/socket failures belong to the CURRENT HOST only.
                # Do not stop the entire downloader after several such failures:
                # that created an endless restart loop in UNIVERSAL 1.2 because
                # per-run attempt counters were reset every time Supervisor restarted.
                $attempts[$key]=[int]$attempts[$key]+1

                if (-not [string]::IsNullOrWhiteSpace($remoteHost)) {
                    $hostCooldown[$remoteHost]=[DateTime]::UtcNow.AddSeconds($TemporaryHostCooldownSeconds)
                }

                if ([int]$attempts[$key] -lt $MaxAttemptsPerRun) {
                    $queue.Enqueue($item)
                }
                else {
                    Add-Checkpoint -Path $checkpointPath -Key $key -Status 'TransientFailure' -Item $item -FilePath $target.PartPath -HttpStatus 0 -Error ([string]$result.Error) -FinalUrl ([string]$result.FinalUrl) -ContentType ([string]$result.ContentType) -ContentDisposition ([string]$result.ContentDisposition)
                    $transient++
                }
            }
        }

        Write-DownloadStatus -Path $statusPath -State 'DOWNLOADING' -Total $total -Downloaded $downloaded -Permanent $permanent -Transient $transient -Skipped $skipped -Pending $queue.Count -CurrentFile $target.InitialName -CurrentHost $remoteHost -Message 'Result for this URL was saved'
        if ($NormalDelayMs -gt 0) { Start-Sleep -Milliseconds $NormalDelayMs }
    }

    $passState=if ($transient -gt 0) { 'PASS_COMPLETE_WITH_TRANSIENT' } else { 'PASS_COMPLETE' }
    Write-DownloadStatus -Path $statusPath -State $passState -Total $total -Downloaded $downloaded -Permanent $permanent -Transient $transient -Skipped $skipped -Pending 0 -CurrentFile '' -CurrentHost '' -Message 'This pass is complete; file/non-file/error reports were saved'
    if ($null -ne $script:CheckpointWriter) { $script:CheckpointWriter.Dispose(); $script:CheckpointWriter=$null; $script:CheckpointWriterPath='' }
    Write-ReadableReports -CheckpointPath $checkpointPath -OutputRoot $outputRoot
    $checkpointBytes=[long]0
    try { $checkpointBytes=(Get-Item -LiteralPath $checkpointPath -ErrorAction Stop).Length } catch { }
    if ($passState -eq 'PASS_COMPLETE' -or $checkpointBytes -ge 134217728) {
        Compact-Checkpoint -Path $checkpointPath
    }
    exit 0
}
catch {
    try { if ($null -ne $script:CheckpointWriter) { $script:CheckpointWriter.Dispose(); $script:CheckpointWriter=$null; $script:CheckpointWriterPath='' } } catch { }
    try {
        ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $ProjectRoot 'downloader_fatal.log') -Encoding UTF8
        Write-DownloadStatus -Path (Join-Path $ProjectRoot 'download_status.json') -State 'FATAL' -Total 0 -Downloaded 0 -Permanent 0 -Transient 0 -Skipped 0 -Pending 0 -CurrentFile '' -CurrentHost '' -Message 'Downloader encountered a fatal error; details were saved to downloader_fatal.log'
    }
    catch { }
    exit 99
}
