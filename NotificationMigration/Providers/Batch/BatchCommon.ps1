# Shared helpers for Batch providers (FR-02).
# A Batch provider maps one manifest entry to a batch id: param($RelPath, $Record, $Options) -> id.
# Options come from config batching.options. Keys common to every strategy:
#   unmatchedBatchId  batch for entries the strategy cannot place (default 'UNBATCHED')
#   parentDirBatchId  optional batch for DIRECTORY entries the strategy cannot place, typically the
#                     folders above the batch level (e.g. '2019' when batches are '2019-03').
#                     When not set, such directories go to unmatchedBatchId.
# Walk errors (kind 'error') are always unlistable directories, so they follow the directory rule.

$script:MigBatchRegexCache = @{}
$script:MigBatchSafeIdRegex = New-Object System.Text.RegularExpressions.Regex('[^A-Za-z0-9._-]', [System.Text.RegularExpressions.RegexOptions]::Compiled)

# ---- Per-run compiled options ------------------------------------------------------------------------
# Providers are called once per entry (millions of times). Parsing options and templates per call cost
# ~0.3 ms/entry, so each provider compiles its options ONCE into a hashtable, cached by the options object.
# The cache holds its keys weakly and is reset at every stage run (Reset-MigBatchCompileCache), so an
# edited config is always picked up by the next run.

# Providers check $script:MigBatchLast inline first (a PowerShell function call costs ~40 us, more than the
# work itself): @{ Strategy; Options; Compiled } of the most recent lookup.
$script:MigBatchCompiled = $null
$script:MigBatchLast = $null
$script:MigBatchSafeIdOk = New-Object System.Text.RegularExpressions.Regex('^[A-Za-z0-9._-]+$')

function Reset-MigBatchCompileCache {
    $script:MigBatchCompiled = New-Object 'System.Runtime.CompilerServices.ConditionalWeakTable[object,object]'
    $script:MigBatchLast = $null
}

function Get-MigBatchCompiled {
    <#
    Returns the compiled form of $Options for $Strategy, building it with $Builder (param($Options) -> hashtable)
    on first use. Null options are compiled on every call (nothing to key the cache on).
    #>
    param($Options, [Parameter(Mandatory = $true)][string] $Strategy, [Parameter(Mandatory = $true)][scriptblock] $Builder)
    if ($null -eq $Options) { return (& $Builder $Options) }
    if ($null -eq $script:MigBatchCompiled) { Reset-MigBatchCompileCache }
    $key = ([psobject]$Options).psobject.BaseObject
    $perOptions = $null
    if (-not $script:MigBatchCompiled.TryGetValue($key, [ref]$perOptions)) {
        $perOptions = @{}
        $script:MigBatchCompiled.Add($key, $perOptions)
    }
    if (-not $perOptions.ContainsKey($Strategy)) { $perOptions[$Strategy] = (& $Builder $Options) }
    $script:MigBatchLast = @{ Strategy = $Strategy; Options = $key; Compiled = $perOptions[$Strategy] }
    return $perOptions[$Strategy]
}

function New-MigBatchFallbackIds {
    <# Compiled fallback ids (see Get-MigBatchFallbackId): @{ Unmatched; ParentDir ($null when not set) }. #>
    param($Options)
    $unmatched = ConvertTo-MigSafeBatchId ([string](Get-MigBatchOption -Options $Options -Name 'unmatchedBatchId' -Default 'UNBATCHED'))
    $parent = [string](Get-MigBatchOption -Options $Options -Name 'parentDirBatchId' -Default '')
    $parentId = $null
    if (-not [string]::IsNullOrWhiteSpace($parent)) { $parentId = ConvertTo-MigSafeBatchId $parent }
    return @{ Unmatched = $unmatched; ParentDir = $parentId }
}

function Select-MigBatchFallbackId {
    <# Fast fallback from compiled ids: directories / walk errors go to ParentDir when set. #>
    param([Parameter(Mandatory = $true)] $Fallback, [string] $Kind)
    if ($null -ne $Fallback.ParentDir -and ($Kind -eq 'dir' -or $Kind -eq 'error')) { return $Fallback.ParentDir }
    return $Fallback.Unmatched
}

function Get-MigBatchOption {
    <# Reads one provider option; missing key or null options -> $Default. #>
    param($Options, [Parameter(Mandatory = $true)][string] $Name, $Default = $null)
    if ($null -eq $Options) { return $Default }
    if ($Options -is [System.Collections.IDictionary]) {
        if ($Options.Contains($Name) -and $null -ne $Options[$Name]) { return $Options[$Name] }
        return $Default
    }
    $p = $Options.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Get-MigBatchRecordKind {
    <# 'file' | 'dir' | 'error'. Unknown record (provider called with a path only) is treated as a file. #>
    param($Record)
    if ($null -eq $Record) { return 'file' }
    $k = $null
    if ($Record -is [System.Collections.IDictionary]) { if ($Record.Contains('kind')) { $k = $Record['kind'] } }
    elseif ($Record.PSObject.Properties['kind']) { $k = $Record.kind }
    if ([string]::IsNullOrEmpty($k)) { return 'file' }
    return [string]$k
}

function Get-MigBatchRecordValue {
    param($Record, [Parameter(Mandatory = $true)][string] $Name)
    if ($null -eq $Record) { return $null }
    if ($Record -is [System.Collections.IDictionary]) {
        if ($Record.Contains($Name)) { return $Record[$Name] }
        return $null
    }
    $p = $Record.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-MigBatchFallbackId {
    <# Batch id for an entry the strategy could not place (see header for the directory rule). #>
    param($Record, $Options)
    $unmatched = [string](Get-MigBatchOption -Options $Options -Name 'unmatchedBatchId' -Default 'UNBATCHED')
    $kind = Get-MigBatchRecordKind $Record
    if ($kind -eq 'dir' -or $kind -eq 'error') {
        $parent = [string](Get-MigBatchOption -Options $Options -Name 'parentDirBatchId' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($parent)) { return ConvertTo-MigSafeBatchId $parent }
    }
    return ConvertTo-MigSafeBatchId $unmatched
}

function Get-MigBatchRegex {
    <# Compiled, cached regex per pattern (providers are called once per entry). Case-insensitive, like NTFS. #>
    param([Parameter(Mandatory = $true)][string] $Pattern)
    if (-not $script:MigBatchRegexCache.ContainsKey($Pattern)) {
        $opts = [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, CultureInvariant'
        $script:MigBatchRegexCache[$Pattern] = New-Object System.Text.RegularExpressions.Regex($Pattern, $opts)
    }
    return $script:MigBatchRegexCache[$Pattern]
}

function ConvertTo-MigBatchTemplateParts {
    <#
    Compiles a template once: returns object[] of parts, each a literal string or @{ Group = name }.
    Throws when the template references a group the pattern does not define.
    #>
    param([Parameter(Mandatory = $true)][string] $Template, [Parameter(Mandatory = $true)] $Regex)
    $parts = New-Object System.Collections.Generic.List[object]
    $pos = 0
    foreach ($ph in [regex]::Matches($Template, '\{(\w+)\}')) {
        if ($ph.Index -gt $pos) { $parts.Add($Template.Substring($pos, $ph.Index - $pos)) }
        $name = $ph.Groups[1].Value
        if ($Regex.GroupNumberFromName($name) -lt 0) {
            throw "batching.options.template references group '{$name}' which the pattern does not define."
        }
        $parts.Add(@{ Group = $name })
        $pos = $ph.Index + $ph.Length
    }
    if ($pos -lt $Template.Length) { $parts.Add($Template.Substring($pos)) }
    return , $parts.ToArray()
}

function Expand-MigBatchTemplate {
    <# Fills {name} / {1} placeholders in $Template from the groups of $Match. Unknown group names throw. #>
    param([Parameter(Mandatory = $true)][string] $Template, [Parameter(Mandatory = $true)] $Regex,
          [Parameter(Mandatory = $true)] $Match)
    $sb = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($ph in [regex]::Matches($Template, '\{(\w+)\}')) {
        [void]$sb.Append($Template.Substring($pos, $ph.Index - $pos))
        $name = $ph.Groups[1].Value
        if ($Regex.GroupNumberFromName($name) -lt 0) {
            throw "batching.options.template references group '{$name}' which the pattern does not define."
        }
        [void]$sb.Append($Match.Groups[$name].Value)
        $pos = $ph.Index + $ph.Length
    }
    [void]$sb.Append($Template.Substring($pos))
    return $sb.ToString()
}

function ConvertTo-MigBatchDate {
    <#
    Normalises a manifest timestamp to a UTC DateTime, or $null. Accepts ISO strings (as written by the
    scanner), DateTime (PowerShell 7 ConvertFrom-Json turns ISO strings into dates) and DateTimeOffset.
    #>
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $d = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal'
    if ([DateTime]::TryParse($s, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) {
        return [DateTime]::SpecifyKind($d, [DateTimeKind]::Utc)
    }
    return $null
}
