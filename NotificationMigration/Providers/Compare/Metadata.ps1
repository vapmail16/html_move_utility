# Compare providers: created, modified, attributes, acl (FR-05, C-05).
# Contract: param($Ctx, $Source, $Target, $Options) -> $null when equal, else a mismatch detail string.
# Timestamps honour compare.timestampToleranceSec; attributes ignore compare.ignoreAttributes.

function ConvertTo-MigUtcDateTime {
    <# Accepts an ISO-8601 string or a [DateTime] (JSON readers may already have converted it). Returns UTC or $null. #>
    param($Value)
    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $d = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
    return $null
}

function Compare-MigTimestampField {
    param($Ctx, $Source, $Target, $Options, [Parameter(Mandatory = $true)][string] $Field, [Parameter(Mandatory = $true)][string] $Label)
    if (-not (Test-MigRecordPresent $Source) -or -not (Test-MigRecordPresent $Target)) { return $null }
    if ($null -eq $Options -and $Ctx) { $Options = $Ctx.Config.compare }
    $tol = 0.0
    if ($Options -and $null -ne $Options['timestampToleranceSec']) { $tol = [double]$Options['timestampToleranceSec'] }
    $s = ConvertTo-MigUtcDateTime $Source[$Field]
    $t = ConvertTo-MigUtcDateTime $Target[$Field]
    if ($null -eq $s -and $null -eq $t) { return $null }
    if ($null -eq $s -or $null -eq $t) { return ('{0} unknown: source={1} target={2}' -f $Label, $Source[$Field], $Target[$Field]) }
    $diff = [Math]::Abs(($s - $t).TotalSeconds)
    if ($diff -gt $tol) {
        return ('{0} differs by {1}s (tolerance {2}s): source={3} target={4}' -f $Label, [Math]::Round($diff, 3), $tol, $s.ToString('o'), $t.ToString('o'))
    }
    return $null
}

function ConvertTo-MigAttributeSet {
    <# 'ReadOnly, Archive' -> sorted array without ignored names; 'Normal' alone means no attributes. #>
    param($Value, [string[]] $Ignore = @())
    $parts = @(([string]$Value) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'Normal' })
    $parts = @($parts | Where-Object { $Ignore -notcontains $_ } | Sort-Object -Unique)
    return , [string[]]$parts
}

Register-MigProvider -Kind Compare -Name 'created' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    Compare-MigTimestampField -Ctx $Ctx -Source $Source -Target $Target -Options $Options -Field 'created_utc' -Label 'created'
}

Register-MigProvider -Kind Compare -Name 'modified' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    Compare-MigTimestampField -Ctx $Ctx -Source $Source -Target $Target -Options $Options -Field 'modified_utc' -Label 'modified'
}

Register-MigProvider -Kind Compare -Name 'attributes' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    if (-not (Test-MigRecordPresent $Source) -or -not (Test-MigRecordPresent $Target)) { return $null }
    if ($null -eq $Options -and $Ctx) { $Options = $Ctx.Config.compare }
    $ignore = @()
    if ($Options -and $Options['ignoreAttributes']) { $ignore = @($Options['ignoreAttributes'] | ForEach-Object { [string]$_ }) }
    $s = ConvertTo-MigAttributeSet -Value $Source['attributes'] -Ignore $ignore
    $t = ConvertTo-MigAttributeSet -Value $Target['attributes'] -Ignore $ignore
    if (($s -join ',') -ne ($t -join ',')) {
        return ('attributes differ: source=[{0}] target=[{1}]' -f ($s -join ', '), ($t -join ', '))
    }
    return $null
}

Register-MigProvider -Kind Compare -Name 'acl' -ScriptBlock {
    param($Ctx, $Source, $Target, $Options)
    if (-not (Test-MigRecordPresent $Source) -or -not (Test-MigRecordPresent $Target)) { return $null }
    $s = [string]$Source['acl_hash']; $t = [string]$Target['acl_hash']
    if (-not $s -and -not $t) { return $null }
    if (-not $s -or -not $t) { return ('ACL hash missing: source={0} target={1}' -f $s, $t) }
    if (-not $s.Equals($t, [StringComparison]::OrdinalIgnoreCase)) { return ('ACL differs: source={0} target={1}' -f $s, $t) }
    return $null
}
