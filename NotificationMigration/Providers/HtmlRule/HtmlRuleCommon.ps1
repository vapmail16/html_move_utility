# Shared helpers for HtmlRule providers (no HTML parser dependency: regex + .NET only).
#
# Finding shape (every rule):
#   rule, rel_path, severity ('info'|'warning'|'error'), code, detail, parity_key, side_specific
# - rel_path is canonical and relative: findings never contain a root, so source and target can be compared.
# - parity_key identifies "the same finding" on both sides (rule|code|rel_path|fact), lower-cased
#   because NTFS is case-insensitive. It must never contain side-specific information.
# - side_specific is informational only (display). EVERY finding takes part in the source/target parity
#   comparison: a finding present on one side only is a parity difference (e.g. longPath when the target
#   root is longer than the source root).
#
# Rule contract extension (Core/Registry.ps1 has the base signature
#   param($Ctx, $BatchId, $Side, $Root, $Records, $Options)).
# The stage (Stages/HtmlChecks.ps1) passes a SHALLOW COPY of the rule's config section as $Options, with
# these optional run-time keys added (a rule called directly, e.g. in tests, works without them):
#   _htmlCache  : per-side, per-chunk text cache from New-MigHtmlTextCache. Content rules read HTML only
#                 through Get-MigHtmlContent, so each file is read and decoded ONCE per side and the text is
#                 shared by every content rule. The cache holds only the current chunk (bounded memory).
#   _knownPaths : HashSet[string] (case-insensitive) of every file/dir rel_path on this side. Content rules
#                 receive only a chunk of the HTML records in $Records; use this for existence lookups.
#   _sample     : string[] of rel_paths to render (renderSample). Computed ONCE by the stage from the
#                 intersection of source and target HTML rel_paths, so both sides render the same files.
#                 The rule renders the entries that are in its $Records.
# Content rules ($script:MigHtmlContentRules) read HTML file contents; the stage runs them per chunk of
# HTML files (htmlChecks.chunkSize). Every other rule runs once with all records of the side.
# A content rule reports a file above its maxBytesToParse as code 'skipped_large' (severity warning).

$script:MigHtmlContentRules = @('malformed', 'linkedAssets', 'absoluteLinks', 'renderSample')

function New-MigHtmlFinding {
    param(
        [Parameter(Mandatory = $true)][string] $Rule,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $RelPath,
        [Parameter(Mandatory = $true)][ValidateSet('info', 'warning', 'error')][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Code,
        [string] $Detail,
        [string] $ParityFact = '',
        [bool] $SideSpecific = $false
    )
    $key = ('{0}|{1}|{2}|{3}' -f $Rule, $Code, $RelPath, $ParityFact).ToLowerInvariant()
    return [ordered]@{
        rule = $Rule; rel_path = $RelPath; severity = $Severity; code = $Code; detail = $Detail
        parity_key = $key; side_specific = $SideSpecific
    }
}

function Get-MigHtmlOption {
    <# Reads a rule option (or any dictionary key) with a default; safe under StrictMode for any IDictionary. #>
    param($Options, [Parameter(Mandatory = $true)][string] $Name, $Default = $null)
    if ($null -eq $Options) { return $Default }
    if ($Options -is [System.Collections.IDictionary]) {
        # Dictionary[string,object] (PS 5.1 store records) implements Contains only explicitly; use ContainsKey there.
        if ($Options -is [System.Collections.Specialized.OrderedDictionary]) { $has = $Options.Contains($Name) } else { $has = $Options.ContainsKey($Name) }
        if ($has -and $null -ne $Options[$Name]) { return $Options[$Name] }
        return $Default
    }
    $p = $Options.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-MigHtmlExtensions {
    param([Parameter(Mandatory = $true)] $Ctx)
    $hc = Get-MigHtmlOption $Ctx.Config 'htmlChecks'
    return @(Get-MigHtmlOption $hc 'fileExtensions' @() | Where-Object { $_ } | ForEach-Object {
        $e = [string]$_
        if (-not $e.StartsWith('.')) { $e = '.' + $e }
        $e
    })
}

function Test-MigHtmlExtension {
    param([Parameter(Mandatory = $true)][string] $RelPath, [string[]] $Extensions)
    $ext = [System.IO.Path]::GetExtension($RelPath.Replace('\', '/'))
    foreach ($e in $Extensions) { if ([string]::Equals($ext, $e, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Get-MigHtmlFileRecords {
    <# File records (kind 'file', no scan error) whose extension is in htmlChecks.fileExtensions. #>
    param([Parameter(Mandatory = $true)] $Ctx, [AllowEmptyCollection()][object[]] $Records)
    $exts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in (Get-MigHtmlExtensions -Ctx $Ctx)) { [void]$exts.Add($e) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Records)) {
        if ($null -eq $r -or $r['kind'] -ne 'file') { continue }
        $rel = [string]$r['rel_path']
        $dot = $rel.LastIndexOf('.')
        if ($dot -lt 0 -or $dot -lt $rel.LastIndexOf('\')) { continue }
        if ($exts.Contains($rel.Substring($dot))) { $out.Add($r) }
    }
    return , $out.ToArray()
}

function Get-MigHtmlFullPath {
    <# Native full path for reading (long-path prefix per paths.useLongPathPrefix). #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Root, [AllowEmptyString()][string] $RelPath)
    $paths = Get-MigHtmlOption $Ctx.Config 'paths'
    $useLong = [bool](Get-MigHtmlOption $paths 'useLongPathPrefix' $true)
    return Get-MigLongPath -Path (Join-MigPath -Root $Root -RelPath $RelPath) -Enabled $useLong
}

function Get-MigHtmlMaxParseBytes {
    <# Default parse limit for content rules: htmlChecks.rules.malformed.maxBytesToParse (0 = unlimited). #>
    param([Parameter(Mandatory = $true)] $Ctx)
    $rules = Get-MigHtmlOption (Get-MigHtmlOption $Ctx.Config 'htmlChecks') 'rules'
    $m = Get-MigHtmlOption $rules 'malformed'
    return [long](Get-MigHtmlOption $m 'maxBytesToParse' 0)
}

function Get-MigHtmlRuleMaxBytes {
    <# A rule's own maxBytesToParse when set, else malformed's (Get-MigHtmlMaxParseBytes). 0 = unlimited. #>
    param([Parameter(Mandatory = $true)] $Ctx, $Options)
    $own = Get-MigHtmlOption $Options 'maxBytesToParse'
    if ($null -ne $own) { return [long]$own }
    return Get-MigHtmlMaxParseBytes -Ctx $Ctx
}

function Get-MigHtmlReadMaxBytes {
    <# Limit for the shared read: the largest limit of the enabled content rules (0 = unlimited wins). #>
    param([Parameter(Mandatory = $true)] $Ctx, [object[]] $Rules)
    $max = [long]0
    foreach ($r in @($Rules)) {
        if ($script:MigHtmlContentRules -notcontains $r.name) { continue }
        $m = Get-MigHtmlRuleMaxBytes -Ctx $Ctx -Options $r.options
        if ($m -le 0) { return [long]0 }
        if ($m -gt $max) { $max = $m }
    }
    return $max
}

function New-MigHtmlTextCache {
    <# Per-side, per-chunk cache of Read-MigHtmlText results (see Get-MigHtmlContent). #>
    param([long] $MaxBytes = 0)
    return @{ max_bytes = $MaxBytes; reads = 0; items = (New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)); root = $null; prefix = $null }
}

function Get-MigHtmlContent {
    <#
    Read result for one HTML file of this side, honouring the rule's own limit ($MaxBytes, 0 = unlimited).
    With $Options._htmlCache the file is read once and shared by all content rules; otherwise it is read now.
    Returns the Read-MigHtmlText shape; too_large is set when size > $MaxBytes (text is then not returned).
    #>
    param([Parameter(Mandatory = $true)] $Ctx, [Parameter(Mandatory = $true)][string] $Root, [Parameter(Mandatory = $true)][string] $RelPath,
          [long] $MaxBytes = 0, $Options)
    $cache = Get-MigHtmlOption $Options '_htmlCache'
    if ($null -eq $cache) {
        return Read-MigHtmlText -Path (Get-MigHtmlFullPath -Ctx $Ctx -Root $Root -RelPath $RelPath) -MaxBytes $MaxBytes
    }
    $read = $null
    if (-not $cache.items.TryGetValue($RelPath, [ref]$read)) {
        if ($cache.root -ne $Root) {
            # Full path = native root prefix + native rel_path (same result as Get-MigHtmlFullPath, built once per root).
            $cache.root = $Root
            $cache.prefix = Get-MigHtmlFullPath -Ctx $Ctx -Root $Root -RelPath '_'
            $cache.prefix = $cache.prefix.Substring(0, $cache.prefix.Length - 1)
        }
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $rp = $RelPath; if ($sep -ne '\') { $rp = $RelPath.Replace('\', $sep) }
        $read = Read-MigHtmlText -Path ($cache.prefix + $rp) -MaxBytes ([long]$cache.max_bytes)
        $cache.reads++
        $cache.items[$RelPath] = $read
    }
    if ($MaxBytes -gt 0 -and -not $read.too_large -and [long]$read.size -gt $MaxBytes) {
        return @{ ok = $false; text = $null; encoding = $read.encoding; size = $read.size; too_large = $true; binary = $false; error = $null }
    }
    return $read
}

function New-MigHtmlSkippedLarge {
    <# The 'skipped_large' finding every content rule reports for a file it did not parse. #>
    param([Parameter(Mandatory = $true)][string] $Rule, [Parameter(Mandatory = $true)][string] $RelPath, [long] $Size, [long] $MaxBytes)
    return New-MigHtmlFinding -Rule $Rule -RelPath $RelPath -Severity 'warning' -Code 'skipped_large' `
        -Detail ("not checked by {0}: {1} bytes > maxBytesToParse {2}" -f $Rule, $Size, $MaxBytes)
}

function Get-MigHtmlFullPathLength {
    <# Length of the full path of a rel_path under a root (without the long-path prefix), as longPath measures it. #>
    param([Parameter(Mandatory = $true)][string] $Root, [AllowEmptyString()][string] $RelPath)
    $rootLen = (Join-MigPath -Root (Remove-MigLongPathPrefix $Root) -RelPath '').Length
    return $rootLen + 1 + $RelPath.Length
}

function Get-MigAnsiEncoding {
    <# The machine's default ANSI code page; Latin-1 when that code page is unavailable (e.g. .NET Core without the code-pages provider). #>
    try {
        $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        return [System.Text.Encoding]::GetEncoding($cp)
    } catch {
        return [System.Text.Encoding]::GetEncoding(28591)
    }
}

$script:MigEncUtf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:MigEncUtf8 = New-Object System.Text.UTF8Encoding($false)
$script:MigEncUtf16Le = New-Object System.Text.UnicodeEncoding($false, $false)
$script:MigEncUtf16Be = New-Object System.Text.UnicodeEncoding($true, $false)
$script:MigEncUtf32Le = New-Object System.Text.UTF32Encoding($false, $false)
$script:MigEncUtf32Be = New-Object System.Text.UTF32Encoding($true, $false)
$script:MigEncAnsi = $null

function Read-MigHtmlText {
    <#
    Reads a text file with encoding detection:
      BOM (UTF-32 LE/BE, UTF-8, UTF-16 LE/BE) -> that encoding;
      no BOM -> strict UTF-8, falling back to the default ANSI code page when the bytes are not valid UTF-8.
    Returns @{ ok; text; encoding; size; too_large; binary; error }. Never throws.
    binary = decoded text contains NUL characters (binary-looking content).
    #>
    param([Parameter(Mandatory = $true)][string] $Path, [long] $MaxBytes = 0)
    $res = @{ ok = $false; text = $null; encoding = $null; size = 0; too_large = $false; binary = $false; error = $null }
    try {
        if ($MaxBytes -gt 0) {
            $len = ([System.IO.FileInfo]$Path).Length
            if ($len -gt $MaxBytes) { $res.size = $len; $res.too_large = $true; return $res }
        }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        $res.error = $_.Exception.Message
        return $res
    }
    $n = $bytes.Length
    $res.size = $n
    $enc = $null; $offset = 0
    if ($n -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $enc = $script:MigEncUtf32Le; $offset = 4; $res.encoding = 'utf-32le-bom'
    } elseif ($n -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $enc = $script:MigEncUtf32Be; $offset = 4; $res.encoding = 'utf-32be-bom'
    } elseif ($n -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = $script:MigEncUtf8; $offset = 3; $res.encoding = 'utf-8-bom'
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = $script:MigEncUtf16Le; $offset = 2; $res.encoding = 'utf-16le-bom'
    } elseif ($n -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = $script:MigEncUtf16Be; $offset = 2; $res.encoding = 'utf-16be-bom'
    }
    try {
        if ($enc) {
            $text = $enc.GetString($bytes, $offset, $n - $offset)
        } else {
            try {
                $text = $script:MigEncUtf8Strict.GetString($bytes)
                $res.encoding = 'utf-8'
            } catch {
                if ($null -eq $script:MigEncAnsi) { $script:MigEncAnsi = Get-MigAnsiEncoding }
                $ansi = $script:MigEncAnsi
                $text = $ansi.GetString($bytes)
                $res.encoding = 'ansi-' + $ansi.CodePage
            }
        }
    } catch {
        $res.error = 'decode failed: ' + $_.Exception.Message
        return $res
    }
    $res.text = $text
    $res.binary = ($text.IndexOf([char]0) -ge 0)
    $res.ok = $true
    return $res
}

$script:MigHtmlCommentRx = New-Object regex('<!--.*?-->', 'Singleline, Compiled')
$script:MigHtmlScriptRx = New-Object regex('(<script\b[^>]*>).*?(</script\s*>)', 'IgnoreCase, Singleline, Compiled')

function Remove-MigHtmlNoise {
    <# Removes comments and script bodies (keeps the <script ...> tag itself, so its src still counts). #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text)
    $t = $Text
    if ($t.IndexOf('<!--', [StringComparison]::Ordinal) -ge 0) { $t = $script:MigHtmlCommentRx.Replace($t, ' ') }
    if ($t.IndexOf('<script', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $t = $script:MigHtmlScriptRx.Replace($t, '$1$2') }
    return $t
}

$script:MigHtmlRxCache = @{}
$script:MigHtmlStyleBlockRx = New-Object regex('<style\b[^>]*>(.*?)</style\s*>', 'IgnoreCase, Singleline, Compiled')
$script:MigHtmlCssUrlRx = New-Object regex('url\(\s*(?:"([^"]*)"|''([^'']*)''|([^)''"\s][^)]*?))\s*\)', 'IgnoreCase, Singleline, Compiled')
$script:MigHtmlCssCommentRx = New-Object regex('/\*.*?\*/', 'Singleline, Compiled')

function Get-MigHtmlAttributeRegex {
    <#
    Precompiled (cached) regex that finds the given attributes directly in the text, but only inside an element
    start tag (lookbehind back to '<tag', skipping quoted values), so one Matches() call per file is enough.
    Groups: 1 = name, 2/3/4 = double-quoted / single-quoted / unquoted value.
    #>
    param([Parameter(Mandatory = $true)][string[]] $Names)
    $key = [string]::Join('|', $Names).ToLowerInvariant()
    if (-not $script:MigHtmlRxCache.ContainsKey($key)) {
        $alt = @($Names | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
        $pattern = '(?<![\w:.-])(?=(?:' + $alt + ')\s*=)(?<=<[A-Za-z][A-Za-z0-9:-]*\s(?:"[^"]*"|''[^'']*''|[^''"<>])*)(' + $alt + ')\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s"''>]+))'
        $script:MigHtmlRxCache[$key] = New-Object regex($pattern, 'IgnoreCase, Singleline, Compiled')
    }
    return $script:MigHtmlRxCache[$key]
}

function Get-MigHtmlAttributeValues {
    <# Returns @{ attr; value } for each configured attribute found in an element start tag (values HTML-decoded). #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text, [Parameter(Mandatory = $true)][string[]] $Attributes)
    return Get-MigHtmlReferences -Text $Text -Attributes $Attributes
}

$script:MigHtmlSrcsetRx = New-Object regex('\G[\s,]*(\S+)(?:(?<=,)|[^,]*)', 'Compiled')

function Get-MigCssUrls {
    <# url(...) values in a CSS text (comments removed). #>
    param([AllowEmptyString()][string] $Css)
    $out = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Css) -or $Css.IndexOf('url(', [StringComparison]::OrdinalIgnoreCase) -lt 0) { return , $out.ToArray() }
    if ($Css.IndexOf('/*', [StringComparison]::Ordinal) -ge 0) { $Css = $script:MigHtmlCssCommentRx.Replace($Css, ' ') }
    foreach ($m in $script:MigHtmlCssUrlRx.Matches($Css)) {
        $g = $m.Groups
        if ($g[1].Success) { $out.Add($g[1].Value.Trim()) } elseif ($g[2].Success) { $out.Add($g[2].Value.Trim()) } else { $out.Add($g[3].Value.Trim()) }
    }
    return , $out.ToArray()
}

function Get-MigSrcsetUrls {
    <#
    URLs of a srcset value (HTML spec candidate parsing: a URL is a run of non-whitespace; trailing commas end
    it; otherwise descriptors run to the next comma). Commas inside a URL (e.g. data: URLs) are kept.
    #>
    param([AllowEmptyString()][string] $Value)
    $out = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Value)) { return , $out.ToArray() }
    foreach ($m in $script:MigHtmlSrcsetRx.Matches($Value)) {
        $u = $m.Groups[1].Value.TrimEnd(',')
        if ($u) { $out.Add($u) }
    }
    return , $out.ToArray()
}

function New-MigHtmlReferenceSpec {
    <# Precomputed options for Get-MigHtmlReferences (build once per rule call, reuse for every file). #>
    param([string[]] $Attributes, [bool] $ParseCssUrls, [bool] $ParseSrcset)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($Attributes)) { if ($a -and -not $names.Contains(([string]$a).ToLowerInvariant())) { $names.Add(([string]$a).ToLowerInvariant()) } }
    if ($ParseSrcset -and -not $names.Contains('srcset')) { $names.Add('srcset') }
    if ($ParseCssUrls -and -not $names.Contains('style')) { $names.Add('style') }
    $rx = $null
    if ($names.Count -gt 0) { $rx = Get-MigHtmlAttributeRegex -Names $names.ToArray() }
    return @{ rx = $rx; css = $ParseCssUrls; srcset = $ParseSrcset }
}

function Get-MigHtmlReferences {
    <#
    References in an HTML text as @{ attr; value } (values HTML-decoded, trimmed). Comments and script bodies
    are ignored. Sources:
      - every attribute in $Attributes (e.g. src, href);
      - srcset candidates (-ParseSrcset; attr 'srcset');
      - CSS url(...) in style attributes (attr 'style') and <style> blocks (attr 'style-block') (-ParseCssUrls).
    Pass -Spec (New-MigHtmlReferenceSpec) to avoid rebuilding the options for every file.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text, [string[]] $Attributes, [switch] $ParseCssUrls, [switch] $ParseSrcset, $Spec)
    if ($null -eq $Spec) { $Spec = New-MigHtmlReferenceSpec -Attributes $Attributes -ParseCssUrls ([bool]$ParseCssUrls) -ParseSrcset ([bool]$ParseSrcset) }
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Spec.rx) { return , $out.ToArray() }
    $clean = Remove-MigHtmlNoise $Text
    foreach ($m in $Spec.rx.Matches($clean)) {
        $g = $m.Groups
        if ($g[2].Success) { $v = $g[2].Value } elseif ($g[3].Success) { $v = $g[3].Value } else { $v = $g[4].Value }
        $attr = $g[1].Value.ToLowerInvariant()
        if ($v.IndexOf('&') -ge 0) { $v = [System.Net.WebUtility]::HtmlDecode($v) }
        $v = $v.Trim()
        if ($attr -eq 'srcset' -and $Spec.srcset) {
            foreach ($u in (Get-MigSrcsetUrls $v)) { $out.Add(@{ attr = 'srcset'; value = $u }) }
        } elseif ($attr -eq 'style' -and $Spec.css) {
            foreach ($u in (Get-MigCssUrls $v)) { $out.Add(@{ attr = 'style'; value = $u }) }
        } else {
            $out.Add(@{ attr = $attr; value = $v })
        }
    }
    if ($Spec.css -and $clean.IndexOf('<style', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        foreach ($b in $script:MigHtmlStyleBlockRx.Matches($clean)) {
            foreach ($u in (Get-MigCssUrls $b.Groups[1].Value)) { $out.Add(@{ attr = 'style-block'; value = $u }) }
        }
    }
    return , $out.ToArray()
}

function Resolve-MigHtmlReference {
    <#
    Classifies a src/href value relative to the canonical rel_path of the file containing it.
    Returns @{ kind = 'ignore'|'relative'|'outside'; rel_path; reason }.
      ignore   : empty, anchor, configured scheme, any other absolute URL (scheme:, //host, \\host, C:\), templated value
      relative : resolved canonical rel_path (root-relative '/x' resolves against the root of this side)
      outside  : '..' climbs above the root, cannot be verified
    #>
    param([Parameter(Mandatory = $true)][string] $BaseRelPath, [AllowEmptyString()][string] $Reference, [string[]] $IgnoreSchemes)
    $v = $Reference
    if ([string]::IsNullOrWhiteSpace($v)) { return @{ kind = 'ignore'; rel_path = $null; reason = 'empty' } }
    $v = $v.Trim()
    if ($v.StartsWith('#')) { return @{ kind = 'ignore'; rel_path = $null; reason = 'anchor' } }
    if ($v.Contains('{{') -or $v.Contains('<%') -or $v.Contains('${')) { return @{ kind = 'ignore'; rel_path = $null; reason = 'template' } }
    $sm = [regex]::Match($v, '^([A-Za-z][A-Za-z0-9+.\-]*):')
    if ($sm.Success -and $sm.Groups[1].Value.Length -gt 1) {
        $scheme = $sm.Groups[1].Value
        foreach ($s in @($IgnoreSchemes)) { if ([string]::Equals([string]$s, $scheme, [StringComparison]::OrdinalIgnoreCase)) { return @{ kind = 'ignore'; rel_path = $null; reason = 'scheme' } } }
        return @{ kind = 'ignore'; rel_path = $null; reason = 'absolute' }
    }
    if ($v.StartsWith('//') -or $v.StartsWith('\\')) { return @{ kind = 'ignore'; rel_path = $null; reason = 'absolute' } }
    if ($v -match '^[A-Za-z]:[\\/]') { return @{ kind = 'ignore'; rel_path = $null; reason = 'absolute' } }

    $cut = $v.IndexOfAny([char[]]@('?', '#'))
    if ($cut -ge 0) { $v = $v.Substring(0, $cut) }
    if ($v.Length -eq 0) { return @{ kind = 'ignore'; rel_path = $null; reason = 'query-only' } }
    try { $v = [Uri]::UnescapeDataString($v) } catch { }

    $segments = New-Object System.Collections.Generic.List[string]
    $rootRelative = ($v.StartsWith('/') -or $v.StartsWith('\'))
    if (-not $rootRelative) {
        $baseDir = ''
        $i = $BaseRelPath.LastIndexOf('\')
        if ($i -gt 0) { $baseDir = $BaseRelPath.Substring(0, $i) }
        foreach ($s in ($baseDir -split '\\')) { if ($s) { $segments.Add($s) } }
    }
    foreach ($s in ($v -split '[\\/]')) {
        if ($s -eq '' -or $s -eq '.') { continue }
        if ($s -eq '..') {
            if ($segments.Count -eq 0) { return @{ kind = 'outside'; rel_path = $null; reason = 'above root' } }
            $segments.RemoveAt($segments.Count - 1)
            continue
        }
        $segments.Add($s)
    }
    if ($segments.Count -eq 0) { return @{ kind = 'ignore'; rel_path = $null; reason = 'root' } }
    return @{ kind = 'relative'; rel_path = ($segments.ToArray() -join '\'); reason = $null }
}

function Get-MigHtmlStableRank {
    <# Deterministic rank for sampling: hex SHA-256 of "<seed>|<batch>|<lower rel_path>" (same on every host and PS edition). #>
    param([Parameter(Mandatory = $true)][string] $Seed, [Parameter(Mandatory = $true)][string] $BatchId, [Parameter(Mandatory = $true)][string] $RelPath)
    return Get-MigStringHash -Text ('{0}|{1}|{2}' -f $Seed, $BatchId, $RelPath.ToLowerInvariant()) -Algorithm 'SHA256'
}
