param(
    [Parameter(Mandatory=$true)]
    [string]$ProjectRoot,

    [ValidateSet('Preflight','Full')]
    [string]$Mode = 'Full'
)

$ErrorActionPreference = 'Stop'
$EngineVersion = 'UNIVERSAL-1.4.0-GITHUB'
$script:UrlRegex = [regex]::new('https?://[^\s<>"''\]]+',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Compiled)

function Write-JsonAtomic {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    }
    finally { $sha.Dispose() }
}

function Get-FileSignature {
    param([System.IO.FileInfo]$File)
    return ('{0}|{1}|{2}' -f $File.FullName.ToLowerInvariant(), $File.Length, $File.LastWriteTimeUtc.Ticks)
}

function Get-CacheId {
    param([System.IO.FileInfo]$File)
    return (Get-Sha256Text -Text $File.FullName.ToLowerInvariant()).Substring(0,24)
}

function Read-MetaSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Test-TextLikeFile {
    param([System.IO.FileInfo]$File,[int]$SampleBytes=65536)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($File.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $sampleSize = [Math]::Max(4096,[Math]::Min(65536,$SampleBytes))
        if ($File.Length -lt $sampleSize) { $sampleSize = [int]$File.Length }
        if ($sampleSize -le 0) { return $true }

        $buffer = New-Object byte[] $sampleSize
        $read = $stream.Read($buffer,0,$sampleSize)
        if ($read -le 0) { return $true }

        # Reject common binary formats before applying generic text heuristics.
        # This keeps PDFs/images/archives/program files out even when they have no extension.
        $isBinaryMagic = $false
        if ($read -ge 2 -and $buffer[0] -eq 0x4D -and $buffer[1] -eq 0x5A) { $isBinaryMagic = $true } # PE/MZ
        elseif ($read -ge 4 -and $buffer[0] -eq 0x25 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x44 -and $buffer[3] -eq 0x46) { $isBinaryMagic = $true } # PDF
        elseif ($read -ge 4 -and $buffer[0] -eq 0x89 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x4E -and $buffer[3] -eq 0x47) { $isBinaryMagic = $true } # PNG
        elseif ($read -ge 3 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xD8 -and $buffer[2] -eq 0xFF) { $isBinaryMagic = $true } # JPEG
        elseif ($read -ge 4 -and $buffer[0] -eq 0x47 -and $buffer[1] -eq 0x49 -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x38) { $isBinaryMagic = $true } # GIF
        elseif ($read -ge 4 -and $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and $buffer[2] -in @(0x03,0x05,0x07) -and $buffer[3] -in @(0x04,0x06,0x08)) { $isBinaryMagic = $true } # ZIP family
        elseif ($read -ge 4 -and $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x61 -and $buffer[2] -eq 0x72 -and $buffer[3] -eq 0x21) { $isBinaryMagic = $true } # RAR
        elseif ($read -ge 4 -and $buffer[0] -eq 0x37 -and $buffer[1] -eq 0x7A -and $buffer[2] -eq 0xBC -and $buffer[3] -eq 0xAF) { $isBinaryMagic = $true } # 7z
        elseif ($read -ge 2 -and $buffer[0] -eq 0x1F -and $buffer[1] -eq 0x8B) { $isBinaryMagic = $true } # gzip
        elseif ($read -ge 4 -and $buffer[0] -eq 0xD0 -and $buffer[1] -eq 0xCF -and $buffer[2] -eq 0x11 -and $buffer[3] -eq 0xE0) { $isBinaryMagic = $true } # OLE
        elseif ($read -ge 4 -and $buffer[0] -eq 0x7F -and $buffer[1] -eq 0x45 -and $buffer[2] -eq 0x4C -and $buffer[3] -eq 0x46) { $isBinaryMagic = $true } # ELF
        elseif ($read -ge 4 -and $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x49 -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x46) { $isBinaryMagic = $true } # RIFF
        elseif ($read -ge 8 -and $buffer[4] -eq 0x66 -and $buffer[5] -eq 0x74 -and $buffer[6] -eq 0x79 -and $buffer[7] -eq 0x70) { $isBinaryMagic = $true } # MP4/MOV family
        if ($isBinaryMagic) { return $false }

        # BOMs for UTF-8 / UTF-16 / UTF-32 are authoritative text signals.
        if ($read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { return $true }
        if ($read -ge 2 -and (($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) -or ($buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF))) { return $true }
        if ($read -ge 4 -and (($buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE -and $buffer[2] -eq 0x00 -and $buffer[3] -eq 0x00) -or ($buffer[0] -eq 0x00 -and $buffer[1] -eq 0x00 -and $buffer[2] -eq 0xFE -and $buffer[3] -eq 0xFF))) { return $true }

        # Most modern exports are UTF-8, but "valid UTF-8" alone is not enough:
        # some binary formats can also contain byte sequences that decode successfully.
        # Keep the signal, then still apply NUL/control-character heuristics.
        $validUtf8 = $false
        try {
            $strictUtf8 = New-Object System.Text.UTF8Encoding($false,$true)
            [void]$strictUtf8.GetString($buffer,0,$read)
            $validUtf8 = $true
        }
        catch {
            # Could be legacy ANSI or a sample ending in a split multibyte character;
            # fall through to conservative byte heuristics below.
        }

        $nul = 0
        $badControl = 0
        $printableLike = 0
        for ($i=0; $i -lt $read; $i++) {
            $b = [int]$buffer[$i]
            if ($b -eq 0) { $nul++; continue }
            if (($b -lt 9) -or ($b -gt 13 -and $b -lt 32)) { $badControl++ }
            else { $printableLike++ }
        }

        # UTF-16 without a BOM often has NULs on every second byte.
        if ($nul -gt 0) {
            $evenNul = 0; $oddNul = 0; $evenCount = 0; $oddCount = 0
            for ($i=0; $i -lt $read; $i++) {
                if (($i % 2) -eq 0) { $evenCount++; if ($buffer[$i] -eq 0) { $evenNul++ } }
                else { $oddCount++; if ($buffer[$i] -eq 0) { $oddNul++ } }
            }
            $evenRatio = if ($evenCount -gt 0) { $evenNul / [double]$evenCount } else { 0 }
            $oddRatio = if ($oddCount -gt 0) { $oddNul / [double]$oddCount } else { 0 }
            if (($evenRatio -gt 0.35 -and $oddRatio -lt 0.08) -or ($oddRatio -gt 0.35 -and $evenRatio -lt 0.08)) { return $true }

            # Random/binary NULs are a strong binary signal.
            if (($nul / [double]$read) -gt 0.01) { return $false }
        }

        $controlRatio=($badControl / [double]$read)
        if ($validUtf8) { return ($controlRatio -lt 0.03) }
        return ($controlRatio -lt 0.02)
    }
    catch { return $false }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-DetectedEncoding {
    param([System.IO.FileInfo]$File)
    $stream=$null
    try {
        $stream=[System.IO.File]::Open($File.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
        $size=4096
        if ($File.Length -lt $size) { $size=[int]$File.Length }
        if ($size -le 0) { return [System.Text.Encoding]::UTF8 }
        $buffer=New-Object byte[] $size
        $read=$stream.Read($buffer,0,$size)
        # Check UTF-32 BOMs before UTF-16: UTF-32 LE begins with FF FE too.
        if ($read -ge 4 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE -and $buffer[2] -eq 0x00 -and $buffer[3] -eq 0x00) { return [System.Text.Encoding]::UTF32 }
        if ($read -ge 4 -and $buffer[0] -eq 0x00 -and $buffer[1] -eq 0x00 -and $buffer[2] -eq 0xFE -and $buffer[3] -eq 0xFF) { return [System.Text.Encoding]::GetEncoding(12001) }
        if ($read -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
        if ($read -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }

        $evenNul=0; $oddNul=0; $evenCount=0; $oddCount=0
        for ($i=0; $i -lt $read; $i++) {
            if (($i % 2) -eq 0) { $evenCount++; if ($buffer[$i] -eq 0) { $evenNul++ } }
            else { $oddCount++; if ($buffer[$i] -eq 0) { $oddNul++ } }
        }
        $evenRatio=if($evenCount -gt 0){$evenNul/[double]$evenCount}else{0}
        $oddRatio=if($oddCount -gt 0){$oddNul/[double]$oddCount}else{0}
        if ($oddRatio -gt 0.35 -and $evenRatio -lt 0.08) { return [System.Text.Encoding]::Unicode }
        if ($evenRatio -gt 0.35 -and $oddRatio -lt 0.08) { return [System.Text.Encoding]::BigEndianUnicode }
    }
    catch { }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    return [System.Text.Encoding]::UTF8
}

function Get-SourceFiles {
    param([string]$SourceRoot,[string]$OutputRoot,[string]$ProjectRoot,[bool]$Recurse)

    if ($Recurse) { $all = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName) }
    else { $all = @(Get-ChildItem -LiteralPath $SourceRoot -File -ErrorAction SilentlyContinue | Sort-Object FullName) }

    $result = New-Object System.Collections.ArrayList
    $projectPrefix = ''
    $downloadFilesPrefix = ''
    try { $projectPrefix = ([IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\').ToLowerInvariant() } catch { }
    try { $downloadFilesPrefix = ([IO.Path]::GetFullPath((Join-Path $OutputRoot 'files')).TrimEnd('\') + '\').ToLowerInvariant() } catch { }
    $generatedNames = @('all_urls_inventory.csv','all_urls.txt','source_files_detected.csv','scan_errors.csv','attachments_failed.csv','attachments_index.csv','urls_skipped_as_nonfiles.csv')
    $knownTextExt = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ext in @('.txt','.json','.jsonl','.csv','.tsv','.log','.html','.htm','.xml','.md','.markdown','.yaml','.yml','.ini','.cfg','.conf')) { [void]$knownTextExt.Add($ext) }

    foreach ($f in $all) {
        $fp = $f.FullName.ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($projectPrefix) -and $fp.StartsWith($projectPrefix)) { continue }
        if (-not [string]::IsNullOrWhiteSpace($downloadFilesPrefix) -and $fp.StartsWith($downloadFilesPrefix)) { continue }
        if ($f.DirectoryName.TrimEnd('\') -ieq $OutputRoot.TrimEnd('\') -and $generatedNames -contains $f.Name.ToLowerInvariant()) { continue }

        # Known text extensions need only a small binary sanity sample. Unknown/extensionless
        # files keep the larger content-based test so the scanner remains format-independent.
        $sampleBytes=if($knownTextExt.Contains([string]$f.Extension)){8192}else{65536}
        if (Test-TextLikeFile -File $f -SampleBytes $sampleBytes) { [void]$result.Add($f) }
    }
    return @($result)
}

function Get-ExpectedRecordsFromHeader {
    param([string]$Path)
    $reader = $null
    try {
        $fi=Get-Item -LiteralPath $Path -ErrorAction Stop
        $enc=Get-DetectedEncoding -File $fi
        $reader = [System.IO.StreamReader]::new($Path,$enc,$true,65536)
        for ($i=0; $i -lt 40; $i++) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -match '^\s*Total archive entries:\s*(\d+)\s*$') { return [long]$matches[1] }
            if ($line -match '^\s*Records in this part:\s*(\d+)\s*$') { return [long]$matches[1] }
            if ($line -match '^\s*Total records:\s*(\d+)\s*$') { return [long]$matches[1] }
        }
    }
    catch { }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
    return [long]0
}

function Convert-JsonEscapesForUrl {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    # Fast path: ordinary LiveChat URLs need no HTML/JSON decoding at all.
    # Avoiding HtmlDecode + Regex.Replace on millions of normal chat lines is
    # the main FASTSCAN optimization.
    if ($Text.IndexOf('\\') -lt 0 -and $Text.IndexOf('&') -lt 0) { return $Text }

    $s = $Text
    if ($s.IndexOf('&') -ge 0) { $s = [System.Net.WebUtility]::HtmlDecode($s) }
    if ($s.IndexOf('\\') -ge 0) {
        # JSON commonly escapes slashes as \/ and URL punctuation as \uXXXX.
        $s = [regex]::Replace($s,'\\+/','/')
        if ($s.IndexOf('\\u') -ge 0 -or $s.IndexOf('\\U') -ge 0) {
            $s = [regex]::Replace($s,'\\u([0-9A-Fa-f]{4})',{
                param($m)
                try { return [string][char][Convert]::ToInt32($m.Groups[1].Value,16) }
                catch { return $m.Value }
            })
        }
    }
    return $s
}

function Get-UrlsFromText {
    param([string]$Text)
    $clean = Convert-JsonEscapesForUrl -Text $Text
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $matchesUrl = $script:UrlRegex.Matches($clean)
    foreach ($m in $matchesUrl) {
        $url = $m.Value.Trim().TrimEnd([char[]]'. ,;:!?)]}')
        try {
            $uri = [Uri]$url
            if ($uri.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($uri.Host)) { continue }
            $url = $uri.AbsoluteUri
        }
        catch { continue }
        if ($seen.Add($url)) { $out.Add($url) }
    }
    return $out.ToArray()
}

function Get-UrlClassification {
    param([string]$Url,[string]$ExplicitFileName,[string]$ExplicitMimeType)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitFileName) -or -not [string]::IsNullOrWhiteSpace($ExplicitMimeType)) { return 'ExplicitAttachment' }
    try { $uri = [Uri]$Url } catch { return 'InvalidUrl' }
    $path = [Uri]::UnescapeDataString([string]$uri.AbsolutePath).ToLowerInvariant()

    $knownExt = @(
        '.jpg','.jpeg','.png','.gif','.webp','.bmp','.tif','.tiff','.svg','.heic','.heif',
        '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.txt','.csv','.tsv','.rtf','.json','.jsonl','.xml','.yaml','.yml','.ini','.cfg','.conf','.log','.md','.html','.htm',
        '.zip','.rar','.7z','.gz','.tar',
        '.mp3','.wav','.m4a','.ogg','.flac',
        '.mp4','.mov','.avi','.mkv','.webm'
    )
    foreach ($ext in $knownExt) { if ($path.EndsWith($ext)) { return 'FileExtension' } }

    foreach ($piece in @('/att/','/attachment/','/attachments/','/download/','/downloads/','/dl/','/omnichannel/file/')) {
        if ($path.Contains($piece)) { return 'AttachmentPath' }
    }

    $query = [string]$uri.Query
    if ($query -match '(?i)(filename|file|name|download)=([^&]+)') {
        $qv = [Uri]::UnescapeDataString($matches[2]).ToLowerInvariant()
        foreach ($ext in $knownExt) { if ($qv.EndsWith($ext)) { return 'FileQuery' } }
    }
    return 'UnknownUrl'
}

function Write-ScanStatus {
    param(
        [string]$State,[int]$TxtTotal,[int]$TxtCompleted,[int]$TxtErrors,
        [long]$ChatsDone,[long]$ChatsExpected,[long]$UrlsFound,[long]$AttachmentsFound,
        [string]$CurrentTxt,[string]$CurrentChat,[long]$CurrentLine,[string]$Message,[string]$StatusPath
    )
    $pct = 0.0
    if ($ChatsExpected -gt 0) { $pct = [Math]::Round([Math]::Min(100.0,($ChatsDone*100.0/$ChatsExpected)),2) }
    elseif ($TxtTotal -gt 0) { $pct = [Math]::Round([Math]::Min(100.0,($TxtCompleted*100.0/$TxtTotal)),2) }

    $obj = [ordered]@{
        EngineVersion=$EngineVersion; State=$State; UpdatedAt=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        TxtTotal=$TxtTotal; TxtCompleted=$TxtCompleted; TxtErrors=$TxtErrors
        ChatsDone=$ChatsDone; ChatsExpected=$ChatsExpected; UrlsFound=$UrlsFound; AttachmentsFound=$AttachmentsFound
        CurrentTxt=$CurrentTxt; CurrentChat=$CurrentChat; CurrentLine=$CurrentLine; Percent=$pct; Message=$Message
    }
    try { Write-JsonAtomic -Path $StatusPath -Object $obj } catch { }
}

function Get-PropertyText {
    param($Object,[string[]]$Names)
    if ($null -eq $Object) { return '' }
    foreach ($n in $Names) {
        try {
            $p = $Object.PSObject.Properties[$n]
            if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
        }
        catch { }
    }
    return ''
}

function Get-AttachmentFromMarker {
    param([string]$Line)

    if ($Line -notmatch '^\s*\[ATTACHMENT\]\s*(\{.*\})\s*$') { return $null }
    try { $obj = $matches[1] | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }

    $fileObj = $null
    try {
        if ($null -ne $obj.content -and $null -ne $obj.content.file) { $fileObj = $obj.content.file }
        elseif ($null -ne $obj.file) { $fileObj = $obj.file }
        else { $fileObj = $obj }
    }
    catch { $fileObj = $obj }

    $url = Get-PropertyText -Object $fileObj -Names @('url','URL','href','downloadUrl','downloadURL')
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }
    $url = Convert-JsonEscapesForUrl -Text $url
    $name = Get-PropertyText -Object $fileObj -Names @('name','filename','fileName','title')
    $mime = Get-PropertyText -Object $fileObj -Names @('mimeType','contentType','mime','type')
    $size = Get-PropertyText -Object $fileObj -Names @('size','fileSize','bytes')

    return [pscustomobject]@{ URL=$url; Name=$name; MimeType=$mime; Size=$size }
}

function ConvertTo-CsvField {
    param($Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    return ('"' + $s.Replace('"','""') + '"')
}

function Write-InventoryCsvRow {
    param(
        [System.IO.StreamWriter]$Writer,
        [long]$Number,[string]$RecordType,[string]$RecordNumber,[string]$ConversationId,[string]$RecordName,
        [System.IO.FileInfo]$SourceFile,[long]$SourceLine,[string]$ExplicitFileName,[string]$ExplicitMimeType,[string]$ExplicitSize,
        [string]$Evidence,[string]$Url,[string]$Classification
    )

    $fields = [string[]]@(
        (ConvertTo-CsvField $Number),
        (ConvertTo-CsvField $RecordType),
        (ConvertTo-CsvField $RecordNumber),
        (ConvertTo-CsvField $ConversationId),
        (ConvertTo-CsvField $RecordName),
        (ConvertTo-CsvField $SourceFile.Name),
        (ConvertTo-CsvField $SourceFile.Name),
        (ConvertTo-CsvField $SourceFile.FullName),
        (ConvertTo-CsvField $SourceLine),
        (ConvertTo-CsvField $ExplicitFileName),
        (ConvertTo-CsvField $ExplicitMimeType),
        (ConvertTo-CsvField $ExplicitSize),
        (ConvertTo-CsvField $Evidence),
        (ConvertTo-CsvField $Url),
        (ConvertTo-CsvField $Classification)
    )
    $Writer.WriteLine([string]::Join(',', $fields))
}

function Add-InventoryRow {
    param(
        [System.IO.StreamWriter]$CsvWriter,[System.IO.StreamWriter]$UrlTextWriter,[System.Collections.Generic.HashSet[string]]$Seen,[ref]$UrlCount,[ref]$AttachmentCount,[ref]$UnknownCount,
        [string]$Url,[string]$ExplicitFileName,[string]$ExplicitMimeType,[string]$ExplicitSize,[string]$Evidence,
        [string]$RecordType,[string]$RecordNumber,[string]$ConversationId,[string]$RecordName,
        [System.IO.FileInfo]$SourceFile,[long]$SourceLine
    )

    try {
        $uri = [Uri]$Url
        if ($uri.Scheme -notin @('http','https') -or [string]::IsNullOrWhiteSpace($uri.Host)) { return }
        $Url = $uri.AbsoluteUri
    }
    catch { return }

    $contextKey = ('{0}|{1}|{2}' -f $ConversationId,$RecordNumber,$Url)
    if (-not $Seen.Add($contextKey)) { return }

    $classification = Get-UrlClassification -Url $Url -ExplicitFileName $ExplicitFileName -ExplicitMimeType $ExplicitMimeType
    if ($classification -eq 'InvalidUrl') { return }

    $UrlCount.Value = [long]$UrlCount.Value + 1
    if ($classification -eq 'UnknownUrl') { $UnknownCount.Value = [long]$UnknownCount.Value + 1 }
    else { $AttachmentCount.Value = [long]$AttachmentCount.Value + 1 }

    Write-InventoryCsvRow -Writer $CsvWriter -Number ([long]$UrlCount.Value) -RecordType $RecordType -RecordNumber $RecordNumber -ConversationId $ConversationId -RecordName $RecordName `
        -SourceFile $SourceFile -SourceLine $SourceLine -ExplicitFileName $ExplicitFileName -ExplicitMimeType $ExplicitMimeType -ExplicitSize $ExplicitSize `
        -Evidence $Evidence -Url $Url -Classification $classification
    if ($null -ne $UrlTextWriter) { $UrlTextWriter.WriteLine($Url) }
}

function Scan-OneTextFile {
    param(
        [System.IO.FileInfo]$File,[string]$CacheCsv,[string]$CacheUrls,[string]$StatusPath,
        [int]$TxtTotal,[int]$TxtCompletedBefore,[int]$TxtErrorsBefore,
        [long]$RecordsBase,[long]$RecordsExpected,[long]$UrlsBase,[long]$AttachmentsBase,
        [long]$MaxLines = 0
    )

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $lineNumber=[long]0; $recordCount=[long]0; $urlCount=[long]0; $attachmentCount=[long]0; $unknownCount=[long]0
    $recordType='GENERIC'; $recordNumber=''; $conversationId='UNKNOWN_RECORD'; $recordName=''
    $pendingFileName=''; $pendingMime=''; $pendingSize=''; $pendingFileLine=[long]0
    $lastStatus=[DateTime]::MinValue
    $reader=$null; $csvWriter=$null; $urlWriter=$null

    $cacheDir=Split-Path -Parent $CacheCsv
    if (-not (Test-Path -LiteralPath $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }
    $tmpCsv=$CacheCsv+'.tmp'
    $tmpUrls=$CacheUrls+'.tmp'
    if (Test-Path -LiteralPath $tmpCsv) { Remove-Item -LiteralPath $tmpCsv -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tmpUrls) { Remove-Item -LiteralPath $tmpUrls -Force -ErrorAction SilentlyContinue }
    $header='"Number","RecordType","ChatNumber","ChatID","ChatName","SourceTXT","SourceFile","SourcePath","SourceLine","ExplicitFileName","ExplicitMimeType","ExplicitSize","Evidence","URL","Classification"'

    try {
        $csvWriter=[System.IO.StreamWriter]::new($tmpCsv,$false,[System.Text.UTF8Encoding]::new($true),65536)
        $urlWriter=[System.IO.StreamWriter]::new($tmpUrls,$false,[System.Text.UTF8Encoding]::new($false),65536)
        $csvWriter.WriteLine($header)

        $enc=Get-DetectedEncoding -File $File
        $reader=[System.IO.StreamReader]::new($File.FullName,$enc,$true,65536)
        while ($true) {
            $line=$reader.ReadLine(); if ($null -eq $line) { break }; $lineNumber++

            # FASTSCAN: cheap prefix checks first. Heavy regex/JSON/URL decoding is
            # only executed for the tiny fraction of lines that can actually match.
            if ($line.Length -gt 0 -and [char]::IsWhiteSpace([char]$line[0])) { $trimmed=$line.TrimStart() }
            else { $trimmed=$line }
            $firstChar=if ($trimmed.Length -gt 0) { [char]$trimmed[0] } else { [char]0 }

            # Known export record headers. Avoid running this regex on every message line.
            if ($firstChar -eq 'C' -or $firstChar -eq 'c' -or $firstChar -eq 'R' -or $firstChar -eq 'r') {
                if ($trimmed -match '^(CHAT|RECORD)\s*#\s*(\d+)\s*$') {
                    $recordType=$matches[1].ToUpperInvariant(); $recordNumber=$matches[2].Trim(); $conversationId='UNKNOWN_RECORD'; $recordName=''; $recordCount++
                    $pendingFileName=''; $pendingMime=''; $pendingSize=''; $pendingFileLine=0
                }
                elseif ($trimmed -match '^(Chat ID|Conversation ID)\s*:\s*(.+?)\s*$') { $conversationId=$matches[2].Trim() }
                elseif ($trimmed -match '^Customer\s*:\s*(.+?)\s*$') { $recordName=$matches[1].Trim() }
            }
            elseif ($firstChar -eq 'N' -or $firstChar -eq 'n') {
                if ($trimmed -match '^Name\s*:\s*(.+?)\s*$') { $recordName=$matches[1].Trim() }
            }
            elseif ($trimmed -match '^(?:\u0646\u0627\u0645|\u0645\u0634\u062a\u0631\u06cc)\s*:') {
                if ($trimmed -match '^(?:\u0646\u0627\u0645|\u0645\u0634\u062a\u0631\u06cc)\s*:\s*(.+?)\s*$') { $recordName=$matches[1].Trim() }
            }

            # Generic JSON IDs are relevant only when the line contains a likely quoted key.
            if (
                ($line.IndexOf('"conversation',[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                ($line.IndexOf('"chat',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            ) {
                if ($line -match '(?i)"(?:conversationId|conversation_id|chatId|chat_id)"\s*:\s*"([^"\\]+)"') { $conversationId=$matches[1] }
            }

            $handledAttachmentJson=$false

            # Attachment/FILE markers always start with '['. Do not run marker regexes
            # against ordinary chat text.
            if ($firstChar -eq '[') {
                if ($trimmed.StartsWith('[ATTACHMENT]',[System.StringComparison]::OrdinalIgnoreCase) -and $trimmed.IndexOf('{') -ge 0) {
                    $att = Get-AttachmentFromMarker -Line $line
                    if ($null -ne $att) {
                        Add-InventoryRow -CsvWriter $csvWriter -UrlTextWriter $urlWriter -Seen $seen -UrlCount ([ref]$urlCount) -AttachmentCount ([ref]$attachmentCount) -UnknownCount ([ref]$unknownCount) `
                            -Url ([string]$att.URL) -ExplicitFileName ([string]$att.Name) -ExplicitMimeType ([string]$att.MimeType) -ExplicitSize ([string]$att.Size) -Evidence 'AttachmentJson' `
                            -RecordType $recordType -RecordNumber $recordNumber -ConversationId $conversationId -RecordName $recordName -SourceFile $File -SourceLine $lineNumber
                        $pendingFileName=''; $pendingMime=''; $pendingSize=''; $pendingFileLine=0
                        $handledAttachmentJson=$true
                    }
                }

                if (-not $handledAttachmentJson) {
                    $looksLikeMarker =
                        $trimmed.StartsWith('[FILE]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[IMAGE]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[PHOTO]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[VIDEO]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[AUDIO]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[DOCUMENT]',[System.StringComparison]::OrdinalIgnoreCase) -or
                        $trimmed.StartsWith('[ATTACHMENT]',[System.StringComparison]::OrdinalIgnoreCase)

                    if ($looksLikeMarker -and $trimmed -match '^\[(FILE|IMAGE|PHOTO|VIDEO|AUDIO|DOCUMENT|ATTACHMENT)\](?:\s+|$)(.*?)\s*$') {
                        $candidate=$matches[2].Trim()
                        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -notmatch '^\{' -and $candidate -notmatch '(?i)^https?[\:\\/]' ) { $pendingFileName=$candidate }
                        else { $pendingFileName='' }
                        $pendingFileLine=$lineNumber
                    }
                }
            }

            if ($pendingFileLine -gt 0 -and ($lineNumber-$pendingFileLine) -gt 4) { $pendingFileName=''; $pendingMime=''; $pendingSize=''; $pendingFileLine=0 }

            # The expensive URL normalizer/extractor is called ONLY on lines that
            # actually contain the literal token 'http'. This still covers plain,
            # JSON-escaped (https:\/\/) and HTML-escaped URLs.
            if (-not $handledAttachmentJson -and $line.IndexOf('http',[System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                foreach ($url in (Get-UrlsFromText -Text $line)) {
                    $explicit=''; $evidence='URL'
                    if ($pendingFileLine -gt 0 -and ($lineNumber-$pendingFileLine) -le 4) { $explicit=$pendingFileName; $evidence='MarkerContext' }
                    if ([string]::IsNullOrWhiteSpace($explicit) -and $line -match '^\s*(.+?)\s*\|\s*[\d\.,]+\s*(KB|MB|GB|B)\s*\|\s*https?://') { $explicit=$matches[1].Trim(); $evidence='InlineFileRow' }

                    Add-InventoryRow -CsvWriter $csvWriter -UrlTextWriter $urlWriter -Seen $seen -UrlCount ([ref]$urlCount) -AttachmentCount ([ref]$attachmentCount) -UnknownCount ([ref]$unknownCount) `
                        -Url $url -ExplicitFileName $explicit -ExplicitMimeType '' -ExplicitSize '' -Evidence $evidence `
                        -RecordType $recordType -RecordNumber $recordNumber -ConversationId $conversationId -RecordName $recordName -SourceFile $File -SourceLine $lineNumber

                    if (-not [string]::IsNullOrWhiteSpace($explicit)) { $pendingFileName=''; $pendingFileLine=0 }
                }
            }

            # Checking the wall clock on every line is surprisingly expensive on huge
            # archives. Only check every 2048 lines; GUI refreshes every 2 seconds anyway.
            if (($lineNumber -band 2047) -eq 0 -and ([DateTime]::UtcNow-$lastStatus).TotalSeconds -ge 2) {
                Write-ScanStatus -State 'SCANNING' -TxtTotal $TxtTotal -TxtCompleted $TxtCompletedBefore -TxtErrors $TxtErrorsBefore `
                    -ChatsDone ($RecordsBase+$recordCount) -ChatsExpected $RecordsExpected -UrlsFound ($UrlsBase+$urlCount) -AttachmentsFound ($AttachmentsBase+$attachmentCount) `
                    -CurrentTxt $File.Name -CurrentChat $recordNumber -CurrentLine $lineNumber -Message 'FASTSCAN: streaming inventory; expensive processing runs only on lines containing URLs/attachments' -StatusPath $StatusPath
                $lastStatus=[DateTime]::UtcNow
            }

            if ($MaxLines -gt 0 -and $lineNumber -ge $MaxLines) { break }
        }
        $csvWriter.Flush()
        $urlWriter.Flush()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $csvWriter) { $csvWriter.Dispose() }
        if ($null -ne $urlWriter) { $urlWriter.Dispose() }
    }

    Move-Item -LiteralPath $tmpCsv -Destination $CacheCsv -Force
    Move-Item -LiteralPath $tmpUrls -Destination $CacheUrls -Force
    return [pscustomobject]@{ Status='COMPLETE'; Chats=$recordCount; Urls=$urlCount; Attachments=$attachmentCount; Unknown=$unknownCount; Lines=$lineNumber }
}

function Merge-Inventory {
    param([System.IO.FileInfo[]]$Files,[string]$CacheRoot,[string]$OutputCsv,[string]$OutputTxt='')

    $tmp=$OutputCsv+'.tmp'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $writer=[System.IO.StreamWriter]::new($tmp,$false,[System.Text.UTF8Encoding]::new($true),65536)

    $urlTmp=''; $urlOut=$null
    if (-not [string]::IsNullOrWhiteSpace($OutputTxt)) {
        $urlTmp=$OutputTxt+'.tmp'
        if (Test-Path -LiteralPath $urlTmp) { Remove-Item -LiteralPath $urlTmp -Force -ErrorAction SilentlyContinue }
        $urlOut=[System.IO.StreamWriter]::new($urlTmp,$false,[System.Text.UTF8Encoding]::new($false),65536)
    }

    $wroteHeader=$false
    try {
        foreach ($file in $Files) {
            $id=Get-CacheId -File $file
            $meta=Read-MetaSafe -Path (Join-Path $CacheRoot ($id+'.json'))
            $csvPath=Join-Path $CacheRoot ($id+'.csv')
            if ($null -eq $meta -or [string]$meta.Signature -ne (Get-FileSignature -File $file) -or [string]$meta.Status -ne 'COMPLETE' -or -not (Test-Path -LiteralPath $csvPath)) { continue }

            # Merge CSV with raw StreamReader/Writer: no Import-Csv object allocation.
            $reader=[System.IO.StreamReader]::new($csvPath,[System.Text.Encoding]::UTF8,$true,65536)
            try {
                $ln=0
                while ($true) {
                    $line=$reader.ReadLine(); if ($null -eq $line) { break }; $ln++
                    if ($ln -eq 1) { if (-not $wroteHeader) { $writer.WriteLine($line); $wroteHeader=$true }; continue }
                    $writer.WriteLine($line)
                }
            }
            finally { $reader.Dispose() }

            if ($null -ne $urlOut) {
                $urlsPath=Join-Path $CacheRoot ($id+'.urls.txt')
                if (Test-Path -LiteralPath $urlsPath) {
                    $urlReader=[System.IO.StreamReader]::new($urlsPath,[System.Text.Encoding]::UTF8,$true,65536)
                    try {
                        while ($true) {
                            $u=$urlReader.ReadLine(); if ($null -eq $u) { break }
                            if (-not [string]::IsNullOrWhiteSpace($u)) { $urlOut.WriteLine($u) }
                        }
                    }
                    finally { $urlReader.Dispose() }
                }
                else {
                    # Backward compatibility for cache produced by 1.2.x/early 1.3:
                    # derive URL text once without forcing a rescan of source archives.
                    Import-Csv -LiteralPath $csvPath -Encoding UTF8 | ForEach-Object {
                        $u=[string]$_.URL
                        if (-not [string]::IsNullOrWhiteSpace($u)) { $urlOut.WriteLine($u) }
                    }
                }
            }
        }
        if (-not $wroteHeader) { $writer.WriteLine('"Number","RecordType","ChatNumber","ChatID","ChatName","SourceTXT","SourceFile","SourcePath","SourceLine","ExplicitFileName","ExplicitMimeType","ExplicitSize","Evidence","URL","Classification"') }
        $writer.Flush()
        if ($null -ne $urlOut) { $urlOut.Flush() }
    }
    finally {
        $writer.Dispose()
        if ($null -ne $urlOut) { $urlOut.Dispose() }
    }

    Move-Item -LiteralPath $tmp -Destination $OutputCsv -Force
    if (-not [string]::IsNullOrWhiteSpace($OutputTxt)) { Move-Item -LiteralPath $urlTmp -Destination $OutputTxt -Force }
}

try {
    if (-not (Test-Path -LiteralPath $ProjectRoot)) { throw "ProjectRoot not found: $ProjectRoot" }
    $projectJson=Join-Path $ProjectRoot 'project.json'
    if (-not (Test-Path -LiteralPath $projectJson)) { throw "project.json not found: $projectJson" }
    $cfg=Get-Content -LiteralPath $projectJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceRoot=[string]$cfg.SourceFolder; $outputRoot=[string]$cfg.OutputFolder; $scanSubfolders=[bool]$cfg.ScanSubfolders
    if (-not (Test-Path -LiteralPath $sourceRoot)) { throw "Source folder not found: $sourceRoot" }
    if (-not (Test-Path -LiteralPath $outputRoot)) { New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null }

    if ($Mode -eq 'Preflight') {
        $workRoot=Join-Path $ProjectRoot 'preflight'
        if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        $statusPath=Join-Path $ProjectRoot 'preflight_status.json'; $cacheRoot=Join-Path $workRoot 'cache'
    }
    else {
        $workRoot=Join-Path $ProjectRoot 'scan'; New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
        $statusPath=Join-Path $ProjectRoot 'scan_status.json'; $cacheRoot=Join-Path $workRoot 'cache'
    }
    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null

    $sourceFiles=@(Get-SourceFiles -SourceRoot $sourceRoot -OutputRoot $outputRoot -ProjectRoot $ProjectRoot -Recurse $scanSubfolders)
    if ($Mode -eq 'Preflight' -and $sourceFiles.Count -gt 3) { $sourceFiles=@($sourceFiles | Select-Object -First 3) }
    if ($sourceFiles.Count -eq 0) {
        Write-ScanStatus -State 'NO_TEXT_FILES' -TxtTotal 0 -TxtCompleted 0 -TxtErrors 0 -ChatsDone 0 -ChatsExpected 0 -UrlsFound 0 -AttachmentsFound 0 -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'No readable text files were found' -StatusPath $statusPath
        exit 12
    }

    # Human-readable discovery list: proves which files were accepted as text.
    if ($Mode -eq 'Full') {
        $sourceFiles | Select-Object @{N='SourceFile';E={$_.Name}},Extension,FullName,Length,LastWriteTime | Export-Csv -LiteralPath (Join-Path $outputRoot 'source_files_detected.csv') -NoTypeInformation -Encoding UTF8
    }

    $expectedRecords=[long]0
    foreach ($f in $sourceFiles) { $expectedRecords += (Get-ExpectedRecordsFromHeader -Path $f.FullName) }

    $completed=0; $errors=0; $baseRecords=[long]0; $baseUrls=[long]0; $baseAttachments=[long]0
    foreach ($f in $sourceFiles) {
        $id=Get-CacheId -File $f; $meta=Read-MetaSafe -Path (Join-Path $cacheRoot ($id+'.json'))
        if ($null -eq $meta -or [string]$meta.Signature -ne (Get-FileSignature -File $f)) { continue }
        if ([string]$meta.Status -eq 'COMPLETE') { $completed++; $baseRecords += [long]$meta.Chats; $baseUrls += [long]$meta.Urls; $baseAttachments += [long]$meta.Attachments }
    }

    Write-ScanStatus -State 'SCANNING' -TxtTotal $sourceFiles.Count -TxtCompleted $completed -TxtErrors 0 -ChatsDone $baseRecords -ChatsExpected $expectedRecords -UrlsFound $baseUrls -AttachmentsFound $baseAttachments -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'Starting resumable general scan' -StatusPath $statusPath

    foreach ($f in $sourceFiles) {
        $id=Get-CacheId -File $f; $signature=Get-FileSignature -File $f; $metaPath=Join-Path $cacheRoot ($id+'.json'); $csvPath=Join-Path $cacheRoot ($id+'.csv')
        $oldMeta=Read-MetaSafe -Path $metaPath
        if ($null -ne $oldMeta -and [string]$oldMeta.Signature -eq $signature -and [string]$oldMeta.Status -eq 'COMPLETE') { continue }
        try {
            $preflightLineLimit = if ($Mode -eq 'Preflight') { [long]6000 } else { [long]0 }
            $urlsPath=Join-Path $cacheRoot ($id+'.urls.txt')
            $result=Scan-OneTextFile -File $f -CacheCsv $csvPath -CacheUrls $urlsPath -StatusPath $statusPath -TxtTotal $sourceFiles.Count -TxtCompletedBefore $completed -TxtErrorsBefore $errors -RecordsBase $baseRecords -RecordsExpected $expectedRecords -UrlsBase $baseUrls -AttachmentsBase $baseAttachments -MaxLines $preflightLineLimit
            Write-JsonAtomic -Path $metaPath -Object ([ordered]@{
                EngineVersion=$EngineVersion; SourcePath=$f.FullName; Signature=$signature; Status='COMPLETE'; CompletedAt=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
                Chats=[long]$result.Chats; Urls=[long]$result.Urls; Attachments=[long]$result.Attachments; UnknownUrls=[long]$result.Unknown; Lines=[long]$result.Lines; Error=''
            })
            $completed++; $baseRecords += [long]$result.Chats; $baseUrls += [long]$result.Urls; $baseAttachments += [long]$result.Attachments
        }
        catch {
            $errors++; $errText=$_ | Out-String
            try { Write-JsonAtomic -Path $metaPath -Object ([ordered]@{ EngineVersion=$EngineVersion; SourcePath=$f.FullName; Signature=$signature; Status='ERROR'; CompletedAt=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'); Chats=0; Urls=0; Attachments=0; UnknownUrls=0; Lines=0; Error=$errText }) } catch { }
        }
        Write-ScanStatus -State 'SCANNING' -TxtTotal $sourceFiles.Count -TxtCompleted $completed -TxtErrors $errors -ChatsDone $baseRecords -ChatsExpected $expectedRecords -UrlsFound $baseUrls -AttachmentsFound $baseAttachments -CurrentTxt $f.Name -CurrentChat '' -CurrentLine 0 -Message 'Result for this source file was saved; scanning can resume from here after interruption' -StatusPath $statusPath
    }

    if ($Mode -eq 'Preflight') {
        if ($errors -gt 0) { Write-ScanStatus -State 'PREFLIGHT_FAILED' -TxtTotal $sourceFiles.Count -TxtCompleted $completed -TxtErrors $errors -ChatsDone $baseRecords -ChatsExpected $expectedRecords -UrlsFound $baseUrls -AttachmentsFound $baseAttachments -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'Preflight failed on source files; full scan was not started' -StatusPath $statusPath; exit 31 }
        $preflightInventory=Join-Path $workRoot 'preflight_inventory.csv'; Merge-Inventory -Files $sourceFiles -CacheRoot $cacheRoot -OutputCsv $preflightInventory
        Write-JsonAtomic -Path (Join-Path $ProjectRoot 'preflight_scanner_ok.json') -Object ([ordered]@{ EngineVersion=$EngineVersion; CompletedAt=[DateTime]::Now.ToString('o'); FilesTested=$sourceFiles.Count; RecordsTested=$baseRecords; UrlRows=$baseUrls; AttachmentCandidates=$baseAttachments })
        Write-ScanStatus -State 'PREFLIGHT_SCANNER_OK' -TxtTotal $sourceFiles.Count -TxtCompleted $completed -TxtErrors 0 -ChatsDone $baseRecords -ChatsExpected $expectedRecords -UrlsFound $baseUrls -AttachmentsFound $baseAttachments -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'General scanner and merge stage succeeded on the sample files' -StatusPath $statusPath
        exit 0
    }

    $inventoryCsv=Join-Path $outputRoot 'all_urls_inventory.csv'
    $urlText=Join-Path $outputRoot 'all_urls.txt'
    Merge-Inventory -Files $sourceFiles -CacheRoot $cacheRoot -OutputCsv $inventoryCsv -OutputTxt $urlText

    $errorRows=New-Object System.Collections.ArrayList
    foreach ($f in $sourceFiles) {
        $id=Get-CacheId -File $f; $meta=Read-MetaSafe -Path (Join-Path $cacheRoot ($id+'.json'))
        if ($null -ne $meta -and [string]$meta.Signature -eq (Get-FileSignature -File $f) -and [string]$meta.Status -eq 'ERROR') { [void]$errorRows.Add([pscustomobject]@{ SourceFile=$f.Name; SourcePath=$f.FullName; Error=[string]$meta.Error }) }
    }
    $scanErrorsCsv=Join-Path $outputRoot 'scan_errors.csv'
    if ($errorRows.Count -gt 0) { $errorRows | Export-Csv -LiteralPath $scanErrorsCsv -NoTypeInformation -Encoding UTF8 }
    elseif (Test-Path -LiteralPath $scanErrorsCsv) { Remove-Item -LiteralPath $scanErrorsCsv -Force -ErrorAction SilentlyContinue }

    $finalState=if ($errors -gt 0) { 'COMPLETE_WITH_ERRORS' } else { 'COMPLETE' }
    Write-ScanStatus -State $finalState -TxtTotal $sourceFiles.Count -TxtCompleted $completed -TxtErrors $errors -ChatsDone $baseRecords -ChatsExpected $expectedRecords -UrlsFound $baseUrls -AttachmentsFound $baseAttachments -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'Scan complete; all_urls.txt was created and Downloader will validate all URLs using real HTTP responses' -StatusPath $statusPath
    exit 0
}
catch {
    try {
        ($_ | Out-String) | Set-Content -LiteralPath (Join-Path $ProjectRoot 'scanner_fatal.log') -Encoding UTF8
        Write-ScanStatus -State 'FATAL' -TxtTotal 0 -TxtCompleted 0 -TxtErrors 1 -ChatsDone 0 -ChatsExpected 0 -UrlsFound 0 -AttachmentsFound 0 -CurrentTxt '' -CurrentChat '' -CurrentLine 0 -Message 'Scanner encountered a fatal error; details were saved to scanner_fatal.log' -StatusPath (Join-Path $ProjectRoot 'scan_status.json')
    }
    catch { }
    exit 99
}
