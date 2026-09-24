# HtmlRule 'fileName': checks the leaf name of every file and folder (htmlChecks.rules.fileName):
#   non_ascii          warning  characters above U+007F                          (flagNonAscii)
#   control_chars      error    U+0000-U+001F, U+007F                            (flagControlChars)
#   leading_space      warning  name starts with a space                         (flagLeadingSpace)
#   trailing_dot_space error    name ends with a dot or space                    (flagTrailingDotSpace)
#   invalid_chars      error    characters in invalidChars (cannot exist on NTFS; found on other sources)
#   special_chars      warning  characters in specialChars (legal on NTFS but break URLs, scripts or tools)
#   reserved_name      error    a reservedNames entry, with or without extension (CON, CON.txt, com1.tar.gz)
#   case_duplicate     error    case-only duplicates within one folder           (flagCaseDuplicates)
# Character checks use one precompiled regex each (built once per call from config, not per name).
# Case duplicates are detected from the records AND from a listing of each parent folder on disk, because
# the manifest store keys rel_path case-insensitively and would already have folded such duplicates.

function New-MigCharClassRegex {
    <# Regex matching any single character of $Chars (each escaped as \uXXXX, so ] ^ - \ are safe). $null when empty. #>
    param([AllowEmptyString()][string] $Chars)
    if ([string]::IsNullOrEmpty($Chars)) { return $null }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    foreach ($c in $Chars.ToCharArray()) { [void]$sb.Append(('\u{0:X4}' -f [int]$c)) }
    [void]$sb.Append(']')
    return New-Object regex($sb.ToString(), 'Compiled')
}

function Get-MigRegexUniqueMatches {
    <# Distinct matched values of $Regex in $Text, in order of first appearance. #>
    param([Parameter(Mandatory = $true)] [regex] $Regex, [Parameter(Mandatory = $true)][string] $Text)
    $seen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($m in $Regex.Matches($Text)) { if (-not $seen.Contains($m.Value)) { $seen.Add($m.Value) } }
    return , $seen.ToArray()
}

function Format-MigCodePoints {
    param([string[]] $Chars)
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in $Chars) { $parts.Add(('U+{0:X4}' -f [int][char]$c)) }
    return ($parts.ToArray() -join ' ')
}

Register-MigProvider -Kind HtmlRule -Name 'fileName' -ScriptBlock {
    param($Ctx, $BatchId, $Side, $Root, $Records, $Options)
    $flagNonAscii = [bool](Get-MigHtmlOption $Options 'flagNonAscii' $false)
    $flagTrailing = [bool](Get-MigHtmlOption $Options 'flagTrailingDotSpace' $false)
    $flagLeading = [bool](Get-MigHtmlOption $Options 'flagLeadingSpace' $false)
    $flagControl = [bool](Get-MigHtmlOption $Options 'flagControlChars' $false)
    $flagCaseDup = [bool](Get-MigHtmlOption $Options 'flagCaseDuplicates' $false)
    $invalidRx = New-MigCharClassRegex ([string](Get-MigHtmlOption $Options 'invalidChars' ''))
    $specialRx = New-MigCharClassRegex ([string](Get-MigHtmlOption $Options 'specialChars' ''))
    $nonAsciiRx = $null; if ($flagNonAscii) { $nonAsciiRx = New-Object regex('[^\u0000-\u007F]', 'Compiled') }
    $controlRx = $null; if ($flagControl) { $controlRx = New-Object regex('[\u0000-\u001F\u007F]', 'Compiled') }
    $reserved = @(Get-MigHtmlOption $Options 'reservedNames' @() | Where-Object { $_ } | ForEach-Object { [regex]::Escape(([string]$_).Trim()) })
    $reservedRx = $null
    if ($reserved.Count -gt 0) { $reservedRx = New-Object regex(('^(?:' + ($reserved -join '|') + ')(?:\..*)?$'), 'IgnoreCase, Compiled') }

    $out = New-Object System.Collections.Generic.List[object]
    $folders = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $kind = $r['kind']
        if ($kind -ne 'file' -and $kind -ne 'dir') { continue }
        $rel = [string]$r['rel_path']
        if (-not $rel) { continue }
        $i = $rel.LastIndexOf('\')
        $parent = ''
        $name = $rel
        if ($i -ge 0) { $parent = $rel.Substring(0, $i); $name = $rel.Substring($i + 1) }

        if ($nonAsciiRx -and $nonAsciiRx.IsMatch($name)) {
            $bad = Get-MigRegexUniqueMatches -Regex $nonAsciiRx -Text $name
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'warning' -Code 'non_ascii' `
                -Detail ("name contains non-ASCII characters: {0}" -f (Format-MigCodePoints $bad))))
        }
        if ($controlRx -and $controlRx.IsMatch($name)) {
            $bad = Get-MigRegexUniqueMatches -Regex $controlRx -Text $name
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'error' -Code 'control_chars' `
                -Detail ("name contains control characters: {0}" -f (Format-MigCodePoints $bad)) -ParityFact (Format-MigCodePoints $bad)))
        }
        if ($flagLeading -and $name.StartsWith(' ')) {
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'warning' -Code 'leading_space' -Detail 'name starts with a space'))
        }
        if ($flagTrailing -and ($name.EndsWith('.') -or $name.EndsWith(' '))) {
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'error' -Code 'trailing_dot_space' -Detail 'name ends with a dot or space'))
        }
        if ($invalidRx -and $invalidRx.IsMatch($name)) {
            $found = Get-MigRegexUniqueMatches -Regex $invalidRx -Text $name
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'error' -Code 'invalid_chars' `
                -Detail ("name contains invalid characters: {0}" -f ($found -join ' ')) -ParityFact ($found -join '')))
        }
        if ($specialRx -and $specialRx.IsMatch($name)) {
            $found = Get-MigRegexUniqueMatches -Regex $specialRx -Text $name
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'warning' -Code 'special_chars' `
                -Detail ("name contains special characters: {0}" -f ($found -join ' ')) -ParityFact ($found -join '')))
        }
        if ($reservedRx -and $reservedRx.IsMatch($name)) {
            $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $rel -Severity 'error' -Code 'reserved_name' `
                -Detail ("name is a reserved device name: {0}" -f $name)))
        }
        if ($flagCaseDup) {
            if (-not $folders.ContainsKey($parent)) { $folders[$parent] = New-Object System.Collections.Generic.List[string] }
            $folders[$parent].Add($rel)
        }
    }

    if ($flagCaseDup) {
        foreach ($parent in @($folders.Keys)) {
            # Exact-case set of names: from records plus the folder listing on this side.
            $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($rel in $folders[$parent]) { [void]$names.Add($rel) }
            try {
                $dir = Get-MigHtmlFullPath -Ctx $Ctx -Root $Root -RelPath $parent
                foreach ($p in [System.IO.Directory]::EnumerateFileSystemEntries($dir)) {
                    $leaf = [System.IO.Path]::GetFileName($p)
                    if ($parent) { [void]$names.Add($parent + '\' + $leaf) } else { [void]$names.Add($leaf) }
                }
            } catch { }
            if ($names.Count -lt 2) { continue }
            $groups = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($n in $names) {
                if (-not $groups.ContainsKey($n)) { $groups[$n] = New-Object System.Collections.Generic.List[string] }
                $groups[$n].Add($n)
            }
            $dupKeys = New-Object 'System.Collections.Generic.List[string]'
            foreach ($kv in $groups.GetEnumerator()) { if ($kv.Value.Count -ge 2) { $dupKeys.Add($kv.Key) } }
            if ($dupKeys.Count -eq 0) { continue }
            $dupKeys.Sort([StringComparer]::OrdinalIgnoreCase)
            foreach ($k in $dupKeys) {
                $g = @($groups[$k] | Sort-Object)
                foreach ($n in $g) {
                    $others = @($g | Where-Object { $_ -cne $n } | ForEach-Object { $_.Substring($_.LastIndexOf('\') + 1) })
                    $out.Add((New-MigHtmlFinding -Rule 'fileName' -RelPath $n -Severity 'error' -Code 'case_duplicate' `
                        -Detail ("case-only duplicate of: {0}" -f ($others -join ', ')) -ParityFact ([string]$g.Count)))
                }
            }
        }
    }
    return , $out.ToArray()
}
