<#
.SYNOPSIS
Generates a deterministic synthetic notification archive (yyyy\MM\dd\*.html + assets) full of migration edge cases.

.DESCRIPTION
Test-data generator for NotificationMigration. Writes ONLY under -Path. Never point it at a real source share.
Windows PowerShell 5.1 compatible; also runs on PowerShell 7 on any platform.
The script is ASCII-only on purpose: Unicode names are built from code points so PS 5.1 reads the file correctly.

Edge cases (each can be switched off with the matching -Skip* switch):
  LongPaths         directory chain + file name so the relative path exceeds 260 chars (\\?\ prefix on Windows)
  DeepNesting       20+ nested directory levels
  Unicode           accented, German, CJK and emoji file names
  TrailingDotSpace  names ending in a space or a dot (non-Windows directly; Windows via \\?\; skipped if impossible)
  CaseDuplicates    'Notice_Case.html' and 'notice_case.html' in one folder (only on case-sensitive file systems)
  ZeroByte          empty .html and empty asset
  Malformed         HTML without <html>, HTML with binary NULs, truncated HTML
  Encodings         UTF-8 with BOM, UTF-16 LE (with BOM), explicit CRLF and LF files
  Assets            per-month assets\style.css + assets\logo.png referenced relatively by every regular file
  MissingAsset      HTML referencing an image that does not exist
  AbsoluteLinks     links hard-coded to -OldHost as UNC (\\host\share\x.css), http://host/x.png and file://host/...
  LargeFile         one HTML file of about -LargeFileMB MB
  Unbatched         a file at the root that matches no yyyy\MM folder

Same parameters + same -Seed => byte-identical tree (content, names and timestamps).

.EXAMPLE
./tools/New-SyntheticDataset.ps1 -Path ./.dev/source -Years 2019..2020 -MonthsPerYear 2 -FilesPerMonth 10 -Seed 7 -OldHost 'SRV-NOTIF-01','srv-notif-01.corp.local'

.OUTPUTS
PSCustomObject: Path, Seed, TotalFiles, TotalDirs, TotalBytes, EdgeCases (ordered name -> file count),
Skipped (messages), Files (rel_path, bytes, tags) and CaseSensitive.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Path,
    [int[]] $Years = @(2019, 2020),
    [ValidateRange(1, 12)][int] $MonthsPerYear = 2,
    [ValidateRange(0, 100000)][int] $FilesPerMonth = 5,
    [int] $Seed = 42,
    [string[]] $OldHost = @('OLDSERVER01'),
    [ValidateRange(1, 4096)][int] $LargeFileMB = 2,
    [switch] $Force,
    [switch] $SkipLongPaths,
    [switch] $SkipDeepNesting,
    [switch] $SkipUnicode,
    [switch] $SkipTrailingDotSpace,
    [switch] $SkipCaseDuplicates,
    [switch] $SkipZeroByte,
    [switch] $SkipMalformed,
    [switch] $SkipEncodings,
    [switch] $SkipAssets,
    [switch] $SkipMissingAsset,
    [switch] $SkipAbsoluteLinks,
    [switch] $SkipLargeFile,
    [switch] $SkipUnbatched
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- environment
$isWin = $false
if ($PSVersionTable.PSEdition -eq 'Desktop') { $isWin = $true } else { $isWin = [bool]$IsWindows }
$sep = [System.IO.Path]::DirectorySeparatorChar

$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
$root = $root.TrimEnd('\', '/')
if ([System.IO.Directory]::Exists($root)) {
    $existing = @([System.IO.Directory]::GetFileSystemEntries($root))
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Target folder '$root' is not empty. Use -Force to add to it (existing files with the same names are overwritten)."
    }
} else {
    [void][System.IO.Directory]::CreateDirectory($root)
}

$rng = New-Object System.Random($Seed)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$files = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[string]
$caseSensitive = $null
$dirTimes = @{}     # native full dir path -> DateTime (UTC), applied at the end (deepest first)

function Get-NativeFull([string] $RelPath) {
    # Canonical rel paths use '\'. Returns an absolute native path, \\?\-prefixed on Windows.
    $rel = $RelPath.Replace('\', [string]$sep).Replace('/', [string]$sep)
    $full = $root + $sep + $rel
    if ($isWin) {
        if ($full.StartsWith('\\?\')) { return $full }
        if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
        return '\\?\' + $full
    }
    return $full
}

function Get-DateForRel([string] $RelPath) {
    # yyyy\MM\dd\... -> that day (UTC, 06:00 + deterministic seconds). Anything else -> 2018-12-31.
    $m = [regex]::Match($RelPath, '^(\d{4})\\(\d{2})(?:\\(\d{2}))?')
    if ($m.Success) {
        $d = 1
        if ($m.Groups[3].Success) { $d = [int]$m.Groups[3].Value }
        return New-Object DateTime([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, $d, 6, 0, 0, [DateTimeKind]::Utc)
    }
    return New-Object DateTime(2018, 12, 31, 6, 0, 0, [DateTimeKind]::Utc)
}

function Register-Dirs([string] $RelPath) {
    $parts = $RelPath.Split('\')
    $acc = ''
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        if ($acc) { $acc = $acc + '\' + $parts[$i] } else { $acc = $parts[$i] }
        $full = Get-NativeFull $acc
        if (-not $dirTimes.ContainsKey($full)) { $dirTimes[$full] = (Get-DateForRel $acc) }
    }
}

function Write-SynthFile {
    <# Writes bytes to root\RelPath, sets deterministic timestamps, records tags. Returns $true or $false (skipped). #>
    param([string] $RelPath, [byte[]] $Bytes, [string[]] $Tags)
    $full = Get-NativeFull $RelPath
    try {
        $dir = [System.IO.Path]::GetDirectoryName($full)
        [void][System.IO.Directory]::CreateDirectory($dir)
        [System.IO.File]::WriteAllBytes($full, $Bytes)
        $when = (Get-DateForRel $RelPath).AddSeconds($rng.Next(0, 36000))
        try { [System.IO.File]::SetCreationTimeUtc($full, $when) } catch { }
        [System.IO.File]::SetLastWriteTimeUtc($full, $when.AddSeconds(5))
    } catch {
        $msg = "Skipped '$RelPath' ($($Tags -join ',')): $($_.Exception.Message)"
        $skipped.Add($msg)
        Write-Warning $msg
        return $false
    }
    Register-Dirs $RelPath
    $files.Add([pscustomobject]@{ rel_path = $RelPath; bytes = [long]$Bytes.Length; tags = @($Tags) })
    return $true
}

function Get-Eol([bool] $Crlf) { if ($Crlf) { return "`r`n" } else { return "`n" } }

function New-HtmlText {
    param([string] $Title, [string[]] $BodyLines, [string[]] $HeadLines = @(), [string] $Eol = "`r`n")
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<!DOCTYPE html>')
    $lines.Add('<html lang="en">')
    $lines.Add('<head>')
    $lines.Add('<meta charset="utf-8">')
    $lines.Add("<title>$Title</title>")
    foreach ($h in $HeadLines) { $lines.Add($h) }
    $lines.Add('</head>')
    $lines.Add('<body>')
    foreach ($b in $BodyLines) { $lines.Add($b) }
    $lines.Add('</body>')
    $lines.Add('</html>')
    return (($lines.ToArray()) -join $Eol) + $Eol
}

function New-NotificationBody([string] $Id) {
    $n = $rng.Next(2, 6)
    $out = @("<h1>Notification $Id</h1>", '<table>')
    for ($i = 0; $i -lt $n; $i++) {
        $out += ('<tr><td>REF-{0:D8}</td><td>{1}</td><td>{2:N2}</td></tr>' -f $rng.Next(0, 99999999), ('Account ' + $rng.Next(1000, 9999)), ($rng.NextDouble() * 10000))
    }
    $out += '</table>'
    return $out
}

function Get-AbsoluteLinkLines([string] $HostName) {
    return @(
        ('<link rel="stylesheet" href="\\{0}\notifications\shared\x.css">' -f $HostName),
        ('<img src="http://{0}/notifications/x.png" alt="old host http">' -f $HostName),
        ('<a href="file://{0}/notifications/archive/index.html">archive</a>' -f $HostName)
    )
}

# ---------------------------------------------------------------- assets
# 1x1 PNG (valid file header) - deterministic bytes.
$pngBytes = [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,0x78,0x9C,0x63,0x60,0x00,0x02,0x00,0x00,0x05,0x00,0x01,0x7A,0x5E,0xAB,0x3F,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42,0x60,0x82)
$cssText = "body { font-family: Arial, sans-serif; }`r`ntable { border-collapse: collapse; }`r`ntd { border: 1px solid #ccc; padding: 2px 6px; }`r`n"

$years = @($Years | Sort-Object -Unique)
$months = @(1..$MonthsPerYear)
$firstYM = '{0:D4}\{1:D2}' -f $years[0], $months[0]
$lastYM = '{0:D4}\{1:D2}' -f $years[$years.Length - 1], $months[$months.Length - 1]

# ---------------------------------------------------------------- regular notifications
foreach ($y in $years) {
    foreach ($m in $months) {
        $ym = '{0:D4}\{1:D2}' -f $y, $m
        if (-not $SkipAssets) {
            [void](Write-SynthFile -RelPath "$ym\assets\style.css" -Bytes $utf8NoBom.GetBytes($cssText) -Tags @('asset'))
            [void](Write-SynthFile -RelPath "$ym\assets\logo.png" -Bytes $pngBytes -Tags @('asset'))
        }
        for ($i = 1; $i -le $FilesPerMonth; $i++) {
            $day = $rng.Next(1, 29)
            $rel = '{0}\{1:D2}\notification_{2:D4}{3:D2}{4:D2}_{5:D5}.html' -f $ym, $day, $y, $m, $day, $i
            $crlf = ($rng.Next(0, 2) -eq 0)
            $tags = @('regular')
            if ($crlf) { $tags += 'crlf' } else { $tags += 'lf' }
            $head = @()
            $body = New-NotificationBody ('{0:D4}{1:D2}{2:D2}-{3}' -f $y, $m, $day, $i)
            if (-not $SkipAssets) {
                $head += '<link rel="stylesheet" href="../assets/style.css">'
                $body += '<img src="../assets/logo.png" alt="logo">'
                $tags += 'relative_assets'
            }
            if (-not $SkipAbsoluteLinks -and $OldHost.Count -gt 0 -and $rng.Next(0, 5) -eq 0) {
                $body += Get-AbsoluteLinkLines $OldHost[$rng.Next(0, $OldHost.Count)]
                $tags += 'absolute_links'
            }
            $text = New-HtmlText -Title "Notification $i" -HeadLines $head -BodyLines $body -Eol (Get-Eol $crlf)
            [void](Write-SynthFile -RelPath $rel -Bytes $utf8NoBom.GetBytes($text) -Tags $tags)
        }
    }
}

# ---------------------------------------------------------------- edge cases
$edgeDir = "$firstYM\01"

if (-not $SkipUnicode) {
    $e = [string][char]0x00E9
    $names = @(
        ('caf' + $e + '_r' + $e + 'sum' + $e + '.html'),                                                    # cafe/resume with e-acute
        ([string][char]0x00DC + 'berpr' + [char]0x00FC + 'fung_Stra' + [char]0x00DF + 'e.html'),            # German umlauts + sharp s
        ('notice_' + [char]0x901A + [char]0x77E5 + [char]0x0032 + [char]0x0030 + '.html'),                  # CJK
        ('alert_' + [char]::ConvertFromUtf32(0x1F600) + '_' + [char]::ConvertFromUtf32(0x1F4E7) + '.html'),  # emoji (surrogate pairs)
        ('space and (parens) & amp #hash.html')
    )
    foreach ($n in $names) {
        $t = New-HtmlText -Title 'Unicode name' -BodyLines @('<p>Unicode file name test</p>')
        $tag = 'unicode'
        if ($n -match '^[\x20-\x7E]+$') { $tag = 'special_chars' }
        [void](Write-SynthFile -RelPath "$edgeDir\unicode\$n" -Bytes $utf8NoBom.GetBytes($t) -Tags @($tag))
    }
    $udir = [string][char]0x00C5 + 'rsrapport_' + [char]0x65E5 + [char]0x672C
    $t = New-HtmlText -Title 'Unicode dir' -BodyLines @('<p>inside a Unicode directory</p>')
    [void](Write-SynthFile -RelPath "$edgeDir\$udir\inside.html" -Bytes $utf8NoBom.GetBytes($t) -Tags @('unicode'))
}

if (-not $SkipTrailingDotSpace) {
    $t = New-HtmlText -Title 'Trailing' -BodyLines @('<p>name ends with space or dot</p>')
    foreach ($n in @('trailing_space.html ', 'trailing_dot.html.')) {
        [void](Write-SynthFile -RelPath "$edgeDir\trailing\$n" -Bytes $utf8NoBom.GetBytes($t) -Tags @('trailing_dot_space'))
    }
}

if (-not $SkipCaseDuplicates) {
    $cdir = Get-NativeFull "$edgeDir\case"
    [void][System.IO.Directory]::CreateDirectory($cdir)
    $probeA = $cdir + $sep + 'CaseProbe.tmp'
    $probeB = $cdir + $sep + 'caseprobe.tmp'
    [System.IO.File]::WriteAllText($probeA, 'x')
    $caseSensitive = -not [System.IO.File]::Exists($probeB)
    [System.IO.File]::Delete($probeA)
    if ($caseSensitive) {
        $t1 = New-HtmlText -Title 'Case A' -BodyLines @('<p>Upper-case variant</p>')
        $t2 = New-HtmlText -Title 'Case B' -BodyLines @('<p>lower-case variant</p>')
        [void](Write-SynthFile -RelPath "$edgeDir\case\Notice_Case.html" -Bytes $utf8NoBom.GetBytes($t1) -Tags @('case_duplicate'))
        [void](Write-SynthFile -RelPath "$edgeDir\case\notice_case.html" -Bytes $utf8NoBom.GetBytes($t2) -Tags @('case_duplicate'))
    } else {
        $msg = 'Skipped case_duplicate: file system under -Path is case-insensitive.'
        $skipped.Add($msg); Write-Warning $msg
        try { [System.IO.Directory]::Delete($cdir) } catch { }
    }
}

if (-not $SkipZeroByte) {
    [void](Write-SynthFile -RelPath "$edgeDir\zero_byte.html" -Bytes (New-Object byte[] 0) -Tags @('zero_byte'))
    [void](Write-SynthFile -RelPath "$lastYM\02\zero_byte_2.html" -Bytes (New-Object byte[] 0) -Tags @('zero_byte'))
    [void](Write-SynthFile -RelPath "$edgeDir\zero_byte.txt" -Bytes (New-Object byte[] 0) -Tags @('zero_byte'))
}

if (-not $SkipMalformed) {
    [void](Write-SynthFile -RelPath "$edgeDir\malformed_no_html_tag.html" -Bytes $utf8NoBom.GetBytes("<div><p>fragment without html element<p>unclosed</div>`r`n") -Tags @('malformed'))
    $nul = New-Object System.Collections.Generic.List[byte]
    $nul.AddRange($utf8NoBom.GetBytes("<html><body>binary "))
    for ($i = 0; $i -lt 64; $i++) { $nul.Add([byte]($rng.Next(0, 4))) }   # NULs and control bytes
    $nul.AddRange($utf8NoBom.GetBytes(" tail</body></html>`n"))
    [void](Write-SynthFile -RelPath "$edgeDir\malformed_binary_nul.html" -Bytes $nul.ToArray() -Tags @('malformed'))
    [void](Write-SynthFile -RelPath "$edgeDir\malformed_truncated.html" -Bytes $utf8NoBom.GetBytes("<!DOCTYPE html>`r`n<html><head><title>cut") -Tags @('malformed'))
}

if (-not $SkipEncodings) {
    $t = New-HtmlText -Title 'UTF-8 BOM' -BodyLines @(('<p>UTF-8 with BOM: na' + [char]0x00EF + 've</p>'))
    [void](Write-SynthFile -RelPath "$edgeDir\encoding_utf8_bom.html" -Bytes ((New-Object System.Text.UTF8Encoding($true)).GetPreamble() + $utf8NoBom.GetBytes($t)) -Tags @('utf8_bom'))
    $t = New-HtmlText -Title 'UTF-16 LE' -BodyLines @(('<p>UTF-16 LE: ' + [char]0x00E9 + [char]0x4E2D + '</p>'))
    $u16 = New-Object System.Text.UnicodeEncoding($false, $true)
    [void](Write-SynthFile -RelPath "$edgeDir\encoding_utf16le.html" -Bytes ($u16.GetPreamble() + $u16.GetBytes($t)) -Tags @('utf16_le'))
    $t = New-HtmlText -Title 'CRLF' -BodyLines @('<p>CRLF line endings</p>') -Eol "`r`n"
    [void](Write-SynthFile -RelPath "$edgeDir\eol_crlf.html" -Bytes $utf8NoBom.GetBytes($t) -Tags @('crlf'))
    $t = New-HtmlText -Title 'LF' -BodyLines @('<p>LF line endings</p>') -Eol "`n"
    [void](Write-SynthFile -RelPath "$edgeDir\eol_lf.html" -Bytes $utf8NoBom.GetBytes($t) -Tags @('lf'))
}

if (-not $SkipMissingAsset) {
    $body = @('<p>references an image that does not exist</p>', '<img src="../assets/missing_banner.png" alt="missing">', '<link rel="stylesheet" href="css/not_there.css">')
    [void](Write-SynthFile -RelPath "$edgeDir\missing_asset.html" -Bytes $utf8NoBom.GetBytes((New-HtmlText -Title 'Missing asset' -BodyLines $body)) -Tags @('missing_asset'))
}

if (-not $SkipAbsoluteLinks -and $OldHost.Count -gt 0) {
    $body = @('<p>hard-coded links to the old server</p>')
    foreach ($h in $OldHost) { $body += Get-AbsoluteLinkLines $h }
    [void](Write-SynthFile -RelPath "$edgeDir\absolute_links.html" -Bytes $utf8NoBom.GetBytes((New-HtmlText -Title 'Absolute links' -BodyLines $body)) -Tags @('absolute_links'))
}

if (-not $SkipDeepNesting) {
    $parts = @()
    for ($i = 1; $i -le 24; $i++) { $parts += ('lvl{0:D2}' -f $i) }
    $rel = "$firstYM\02\deep\" + ($parts -join '\') + '\deep_notice.html'
    [void](Write-SynthFile -RelPath $rel -Bytes $utf8NoBom.GetBytes((New-HtmlText -Title 'Deep' -BodyLines @('<p>24 levels deep</p>'))) -Tags @('deep_nesting'))
}

if (-not $SkipLongPaths) {
    # Relative path well over 260 chars (so the absolute path is too, on any root). Each component < 255 bytes.
    $seg = 'long_directory_name_for_path_length_testing_' + ('x' * 40)     # 84 chars
    $rel = "$firstYM\03\longpath\$seg\$seg\$seg\" + ('long_file_name_' + ('y' * 60) + '.html')
    $t = New-HtmlText -Title 'Long path' -BodyLines @("<p>relative path length $($rel.Length)</p>")
    [void](Write-SynthFile -RelPath $rel -Bytes $utf8NoBom.GetBytes($t) -Tags @('long_path'))
}

if (-not $SkipLargeFile) {
    $rel = "$lastYM\28\large_notification.html"
    $target = [long]$LargeFileMB * 1024 * 1024
    $full = Get-NativeFull $rel
    try {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full))
        $fs = New-Object System.IO.FileStream($full, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        try {
            $head = $utf8NoBom.GetBytes("<!DOCTYPE html>`r`n<html><head><meta charset=`"utf-8`"><title>Large</title></head><body><table>`r`n")
            $tail = $utf8NoBom.GetBytes("</table></body></html>`r`n")
            $fs.Write($head, 0, $head.Length)
            $written = [long]$head.Length
            $row = 0
            while ($written + $tail.Length -lt $target) {
                $row++
                $b = $utf8NoBom.GetBytes(('<tr><td>{0:D9}</td><td>REF-{1:D8}</td><td>{2}</td></tr>' -f $row, $rng.Next(0, 99999999), ('z' * $rng.Next(10, 60))) + "`r`n")
                $fs.Write($b, 0, $b.Length)
                $written += $b.Length
            }
            $fs.Write($tail, 0, $tail.Length)
            $written += $tail.Length
        } finally { $fs.Dispose() }
        $when = (Get-DateForRel $rel).AddSeconds($rng.Next(0, 36000))
        try { [System.IO.File]::SetCreationTimeUtc($full, $when) } catch { }
        [System.IO.File]::SetLastWriteTimeUtc($full, $when.AddSeconds(5))
        Register-Dirs $rel
        $files.Add([pscustomobject]@{ rel_path = $rel; bytes = $written; tags = @('large_file') })
    } catch {
        $msg = "Skipped large file: $($_.Exception.Message)"; $skipped.Add($msg); Write-Warning $msg
    }
}

if (-not $SkipUnbatched) {
    [void](Write-SynthFile -RelPath 'index_unbatched.html' -Bytes $utf8NoBom.GetBytes((New-HtmlText -Title 'Root index' -BodyLines @('<p>not under yyyy\MM</p>'))) -Tags @('unbatched'))
}

# ---------------------------------------------------------------- directory timestamps (deepest first)
foreach ($d in ($dirTimes.Keys | Sort-Object { $_.Length } -Descending)) {
    try {
        try { [System.IO.Directory]::SetCreationTimeUtc($d, $dirTimes[$d]) } catch { }
        [System.IO.Directory]::SetLastWriteTimeUtc($d, $dirTimes[$d].AddHours(12))
    } catch { Write-Verbose "Could not set directory time on '$d': $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- summary
$edge = [ordered]@{}
foreach ($name in @('regular', 'asset', 'relative_assets', 'crlf', 'lf', 'unicode', 'special_chars', 'trailing_dot_space', 'case_duplicate', 'zero_byte',
                    'malformed', 'utf8_bom', 'utf16_le', 'missing_asset', 'absolute_links', 'deep_nesting', 'long_path', 'large_file', 'unbatched')) {
    $edge[$name] = @($files | Where-Object { $_.tags -contains $name }).Count
}
$totalBytes = [long]0
$maxLen = 0
foreach ($f in $files) { $totalBytes += $f.bytes; if ($f.rel_path.Length -gt $maxLen) { $maxLen = $f.rel_path.Length } }

[pscustomobject]@{
    Path          = $root
    Seed          = $Seed
    Years         = $years
    TotalFiles    = $files.Count
    TotalDirs     = $dirTimes.Count
    TotalBytes    = $totalBytes
    MaxRelPathLen = $maxLen
    CaseSensitive = $caseSensitive
    EdgeCases     = $edge
    Skipped       = $skipped.ToArray()
    Files         = $files.ToArray()
}
